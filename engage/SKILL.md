---
name: engage
description: Sobrevivir a una conexión a internet inestable. Reintenta comandos que fallaron POR LA RED (gh, git, psql, curl, scripts que llaman APIs) esperando a que la conexión vuelva, sin reintentar jamás un fallo real ni una operación que mueve plata. Incluye un watcher que avisa cuando la conexión se cae y cuando vuelve. Usalo cuando aparezcan errores tipo "error connecting to", "Could not resolve host", "connection reset", "fetch failed", "server closed the connection", o cuando el usuario diga que la conexión está inestable / se le corta.
---

# engage — trabajar con la conexión inestable

Dos herramientas. Una envuelve comandos; la otra vigila la conexión.

```
~/.claude/skills/engage/scripts/engage.sh         # wrapper con reintentos
~/.claude/skills/engage/scripts/engage-watch.sh   # watcher de conectividad (para Monitor)
```

---

## La regla que hace que esto sea seguro y no peligroso

**Reintentar sólo lo que falló POR LA RED, y sólo lo que es seguro repetir.** Son dos
condiciones distintas y las dos tienen que cumplirse.

`engage.sh` se encarga de la primera: mira la salida del comando contra una lista cerrada de
firmas transitorias (`error connecting to`, `ECONNRESET`, `could not connect to server`,
`fetch failed`, `RPC failed`, …). Si el fallo no matchea, **sale con el mismo exit code al
primer intento**. Un `gh pr merge` rechazado, un SQL inválido o un test que falla no se
reintentan: reintentarlos convierte un error en N errores iguales y tarda N veces más en
decírtelo.

La segunda condición **no la puede decidir el script — la decidís vos**, y es la que importa:

> ⚠️ **El método HTTP NO es una señal de seguridad.** En el repo `exchange-rebalance` los
> transfers y los retiros están implementados como **GET**. Un wrapper que "reintenta todos los
> GET" puede **pagar dos veces**. `engage.sh` no sabe qué hace el comando que le pasás: lo repite
> tal cual.

### Envolvé sin pensarlo

Lecturas y operaciones idempotentes:

- `gh pr view/list/checks`, `gh run view/list`, `gh api` de sólo lectura
- `git fetch`, `git pull --ff-only`, `git push` (mismo ref = no-op), `git ls-remote`
- `psql -c "select …"` y cualquier consulta de sólo lectura
- `curl` a endpoints de lectura
- descargas, instalaciones de dependencias

### NUNCA envuelvas sin pensarlo

- **Cualquier cosa que mueva plata.** En este repo: `scripts/api.ts … --write`, transfers,
  retiros, `*-transfer`, `withdraw`. Un timeout ambiguo —la request llegó pero la respuesta no—
  es exactamente el caso donde el reintento duplica.
- **Creaciones**: `gh pr create`, `gh issue create`, un `INSERT` sin llave de idempotencia.
  Reintentar crea duplicados.
- **Migraciones y DDL**: `bun run db:migrate`, `ALTER TABLE`. Si se cortó a mitad, lo que hace
  falta es MIRAR el estado, no repetir a ciegas.

Para esos casos, el patrón correcto es al revés: **verificá el estado y decidí**. Ejemplo real —
un `gh pr merge` que devolvió error de conexión ya había mergeado; lo que corresponde es
`gh pr view N --json state`, no reintentar.

---

## Uso

```bash
ENGAGE=~/.claude/skills/engage/scripts/engage.sh

# lo típico
"$ENGAGE" -- gh pr view 203 --json mergeable,statusCheckRollup
"$ENGAGE" -- git fetch origin
"$ENGAGE" --label "prod-db" -- psql "$BACKUP_DATABASE_URL" -X -A -c "select count(*) from log;"

# corte largo: más intentos y más presupuesto de espera
"$ENGAGE" --tries 8 --max-wait 900 -- git push
```

Opciones: `--tries N` (5), `--max-wait S` (300, techo TOTAL de espera acumulada),
`--label TXT` (para leer los avisos), `--probe HOST` (1.1.1.1).

**Qué hace distinto a un `sleep` y reintentar:** ante un fallo de red **sondea hasta que la red
vuelve** en vez de dormir a ciegas. Un sleep fijo o se queda corto en un corte de dos minutos o
desperdicia minutos en uno de tres segundos. Igual mantiene un piso de backoff exponencial,
porque "hay ruta" no es lo mismo que "el servidor ya te acepta".

**stdout y stderr salen intactos y el exit code se preserva**, así que se puede envolver un
comando cuya salida después se parsea. Los avisos de reintento van a **stderr** para no
contaminar ese stdout.

---

## El watcher

Cuando la conexión está inestable durante un rato largo, armá el watcher con el tool `Monitor`
para enterarte de las caídas sin tener que descubrirlas por un comando que falla:

```
Monitor({
  command: "~/.claude/skills/engage/scripts/engage-watch.sh 10",
  description: "conectividad a internet",
  persistent: true
})
```

Emite una línea **sólo en las transiciones** (🔴 caída / 🟢 restablecida, con cuántos segundos
duró), no en cada sondeo — un "sigo online" cada 10s sería un firehose que el propio Monitor
termina apagando.

Cubre las **dos** direcciones a propósito. Un watcher que sólo avisa las caídas deja al silencio
significando dos cosas incompatibles —"todo bien" y "sigue caído"—, que es justo la ambigüedad de
la que uno quiere salir cuando la conexión falla.

---

## Trampas que ya costaron caro

- **Un pipe se come el exit code.** `bun run test | tail` devuelve el exit code de `tail`, que
  siempre es 0: una suite ROJA se lee como verde. Vale para `engage.sh` igual que para cualquier
  comando. Redirigí a archivo y leé `$?`:
  ```bash
  "$ENGAGE" -- bun run test > /tmp/suite.log 2>&1; echo "EXIT=$?"
  grep -E "^ *[1-9][0-9]* fail|tests failed" /tmp/suite.log
  ```
- **No agregues firmas genéricas** a la lista de transitorios. `timeout` a secas matchearía un
  `statement_timeout` de Postgres o un test lento — fallos REALES que hay que ver, no repetir.
- **`ping` puede estar bloqueado** en algunas redes; si el sondeo da siempre negativo, pasá
  `--probe` con un host que sí responda, o el wrapper va a creer que nunca vuelve la red.
- **Un timeout ambiguo no es un fallo.** Si la request llegó y se perdió la respuesta, el trabajo
  YA se hizo. Por eso las mutaciones se verifican, no se reintentan.
