---
name: active
description: >
  Keep the user shown as "active"/online (Slack, Teams, etc.) by jiggling the
  mouse 1px every N seconds via cliclick — no focus steal, no clicks. Use when
  the user says "/active", "manteneme activo", "keep me active", "no me pongas
  en idle", "jiggle the mouse", "mouse jiggler", "stay online", "pará el jiggle",
  "stop active".
argument-hint: "[start [seg] [min] | stop | status]"
---

# Active (mouse jiggler)

Mantiene al usuario visible como "activo" moviendo el cursor 1px y devolviéndolo cada N segundos. Corre en background e independiente de si el usuario usa la PC. No roba foco ni clickea.

Script: `jiggle.sh` en este mismo directorio de skill.

## Cómo actuar

Resolvé la ruta del script como `<este-directorio-de-skill>/jiggle.sh` y ejecutá según el argumento del usuario:

- **Sin argumento, "start", "manteneme activo", "keep me active"** → arrancar con default (cada 60s, sin límite):
  ```
  bash <skill-dir>/jiggle.sh start
  ```
- **Con intervalo** (ej. "cada 2 min", "every 30s") → pasar segundos:
  ```
  bash <skill-dir>/jiggle.sh start 120
  ```
- **Con corte automático** (ej. "por 3 horas", "hasta las 6") → tercer arg en minutos:
  ```
  bash <skill-dir>/jiggle.sh start 60 180
  ```
- **"stop", "pará", "frená el jiggle"** →
  ```
  bash <skill-dir>/jiggle.sh stop
  ```
- **"status", "está corriendo?"** →
  ```
  bash <skill-dir>/jiggle.sh status
  ```

Corré el `bash` en **background** (`run_in_background: true`) para start; stop/status son inmediatos y van en foreground.

## Requisitos y avisos

- Necesita `cliclick` (`brew install cliclick`). El script avisa si falta.
- Requiere permiso de **Accesibilidad** para el proceso que corre (Terminal/iTerm/Claude). Si falla silenciosamente, avisar al usuario que lo habilite en Ajustes del Sistema → Privacidad y Seguridad → Accesibilidad.
- El jiggle corre mientras viva la sesión/terminal. Si se cierra, se corta.
- Mientras el usuario usa la PC igual dispara cada N seg; el movimiento es 1px y vuelve, casi imperceptible.

## Primera vez / verificación

Tras arrancar, confirmar al usuario: PID, intervalo, y cómo frenarlo (`/active stop`). Opcionalmente correr `status` para verificar que quedó ACTIVO.
