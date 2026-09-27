#!/usr/bin/env bash
# engage — reintenta un comando SÓLO cuando falló por la red.
#
# El punto entero es la palabra SÓLO. Un wrapper que reintenta cualquier fallo convierte un
# error real (permiso denegado, PR ya mergeado, SQL inválido) en N errores iguales y tarda N
# veces más en decírtelo. Y en un repo donde los retiros se ejecutan por GET, un reintento
# ciego puede pagar dos veces.
#
#   engage.sh [--tries N] [--max-wait S] [--label TXT] [--probe URL] -- comando args...
#
# Devuelve el exit code y la salida del comando, intactos. Los avisos de reintento van a
# stderr para no ensuciar un stdout que alguien esté parseando.
set -uo pipefail

TRIES=5
MAX_WAIT=300          # techo total de espera acumulada, en segundos
LABEL=""
PROBE_URL="https://1.1.1.1"  # sólo se usa para saber si la red volvió; no se le manda nada

while [ $# -gt 0 ]; do
  case "$1" in
    --tries)    TRIES="$2"; shift 2 ;;
    --max-wait) MAX_WAIT="$2"; shift 2 ;;
    --label)    LABEL="$2"; shift 2 ;;
    --probe)    PROBE_URL="$2"; shift 2 ;;
    --)         shift; break ;;
    *)          echo "engage: argumento desconocido: $1" >&2; exit 2 ;;
  esac
done

if [ $# -eq 0 ]; then
  echo "engage: falta el comando (usá -- antes del comando)" >&2
  exit 2
fi

[ -n "$LABEL" ] || LABEL="$1"

# Firmas de fallo TRANSITORIO de red, recolectadas de las herramientas que este entorno usa de
# verdad: gh, git, psql, curl y el fetch de Bun/undici. Deliberadamente NO incluye cosas como
# "timeout" a secas ni "error" — un statement_timeout de Postgres o un test que falla por
# timeout son fallos REALES y reintentarlos esconde el problema.
NET_RE='error connecting to|Could not resolve host|Temporary failure in name resolution|Name or service not known'
NET_RE="$NET_RE"'|Connection refused|Connection reset by peer|Connection timed out|connection reset|Broken pipe'
NET_RE="$NET_RE"'|[Nn]etwork is unreachable|No route to host|Host is down|Operation timed out'
NET_RE="$NET_RE"'|could not connect to server|server closed the connection unexpectedly'
NET_RE="$NET_RE"'|SSL connection has been closed unexpectedly|SSL_ERROR_SYSCALL|TLS handshake timeout'
NET_RE="$NET_RE"'|Failed to connect to|The remote end hung up unexpectedly|RPC failed|early EOF'
NET_RE="$NET_RE"'|Connection closed by remote host|kex_exchange_identification|Connection to .* closed by remote host'
NET_RE="$NET_RE"'|ETIMEDOUT|ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|EHOSTUNREACH|ENETUNREACH|EPIPE'
NET_RE="$NET_RE"'|socket hang up|fetch failed|ConnectionRefused|Unable to connect'
NET_RE="$NET_RE"'|curl: \(6\)|curl: \(7\)|curl: \(28\)|curl: \(35\)|curl: \(52\)|curl: \(55\)|curl: \(56\)'
NET_RE="$NET_RE"'|502 Bad Gateway|503 Service Unavailable|504 Gateway Time-?out'

# ¿Hay salida a internet?
#
# curl y no ping, por dos razones medidas: `-W` de ping significa MILISEGUNDOS en macOS y
# SEGUNDOS en Linux, así que el mismo `-W2` es un timeout de 2 ms de un lado y de 2 s del otro —
# un enlace apenas lento se leería como "caída" en una Mac. Y hay redes que bloquean ICMP
# enteramente, donde ping diría "sin internet" para siempre. `--max-time` no es ambiguo y prueba
# TCP+TLS, que es lo que los comandos que envolvemos realmente necesitan.
#
# La sonda default va por IP y NO resuelve DNS a propósito: acá sólo se pregunta "¿hay camino
# afuera?". Un DNS caído lo clasifica el matcher de firmas (Could not resolve host, EAI_AGAIN),
# que es donde corresponde. Separar las dos preguntas evita que una sonda con DNS roto declare
# que no hay red cuando el problema es otro.
online() {
  if command -v curl >/dev/null 2>&1; then
    curl -s --max-time 3 -o /dev/null "$PROBE_URL" 2>/dev/null
  else
    ping -c1 "$PROBE_URL" >/dev/null 2>&1
  fi
}

# Espera a que la red VUELVA en vez de dormir a ciegas. Un sleep fijo o se queda corto en un
# corte largo o desperdicia minutos en uno de tres segundos; esto sondea y sale apenas hay red.
# El backoff sigue existiendo como piso, porque "hay ruta" no es lo mismo que "el servidor ya
# te acepta" — un endpoint que se está recuperando necesita aire.
wait_for_net() {
  local floor="$1" budget="$2" waited=0
  while [ "$waited" -lt "$budget" ]; do
    sleep 2; waited=$((waited + 2))
    if online && [ "$waited" -ge "$floor" ]; then return 0; fi
  done
  return 1
}

OUT=$(mktemp); ERR=$(mktemp)
trap 'rm -f "$OUT" "$ERR"' EXIT

attempt=1
spent=0

while :; do
  "$@" >"$OUT" 2>"$ERR"
  code=$?

  if [ "$code" -eq 0 ]; then
    cat "$OUT"; cat "$ERR" >&2
    [ "$attempt" -gt 1 ] && echo "engage[$LABEL]: OK en el intento $attempt" >&2
    exit 0
  fi

  # ¿Fallo de red, o fallo real? Sólo lo primero se reintenta.
  if ! grep -qE "$NET_RE" "$OUT" "$ERR" 2>/dev/null; then
    cat "$OUT"; cat "$ERR" >&2
    [ "$attempt" -gt 1 ] && echo "engage[$LABEL]: fallo NO transitorio (exit $code) — no se reintenta" >&2
    exit "$code"
  fi

  if [ "$attempt" -ge "$TRIES" ]; then
    cat "$OUT"; cat "$ERR" >&2
    echo "engage[$LABEL]: $TRIES intentos, sigue cayendo por red (exit $code)" >&2
    exit "$code"
  fi

  floor=$((2 ** attempt)); [ "$floor" -gt 30 ] && floor=30
  budget=$((MAX_WAIT - spent)); [ "$budget" -lt "$floor" ] && budget=$floor
  echo "engage[$LABEL]: caída de red en el intento $attempt (exit $code) — esperando a que vuelva…" >&2
  head -c 400 "$ERR" | tr '\n' ' ' >&2; echo >&2

  if ! wait_for_net "$floor" "$budget"; then
    cat "$OUT"; cat "$ERR" >&2
    echo "engage[$LABEL]: la red no volvió en ${MAX_WAIT}s — abandono" >&2
    exit "$code"
  fi

  spent=$((spent + floor))
  attempt=$((attempt + 1))
done
