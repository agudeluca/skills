#!/usr/bin/env bash
# engage-watch — emite UNA línea cada vez que la conectividad CAMBIA de estado.
#
# Pensado para el tool Monitor: cada línea de stdout es una notificación. Por eso emite en las
# TRANSICIONES y no en cada sondeo — un "sigo online" cada 10s sería un firehose que el propio
# Monitor termina apagando.
#
# Cubre las dos direcciones a propósito. Un watcher que sólo avisa las caídas deja el silencio
# significando dos cosas incompatibles ("todo bien" y "sigue caído"), que es justo la ambigüedad
# que uno quiere sacarse de encima cuando la conexión está inestable.
#
#   engage-watch.sh [intervalo_seg] [host_a_sondear]
set -uo pipefail

INTERVAL="${1:-10}"
PROBE="${2:-https://1.1.1.1}"
state="init"
down_since=0

while :; do
  # curl y no ping: en macOS `ping -W` son MILISEGUNDOS y en Linux SEGUNDOS, y hay redes que
  # bloquean ICMP del todo. `--max-time` es inequívoco y prueba TCP+TLS.
  if curl -s --max-time 3 -o /dev/null "$PROBE" 2>/dev/null; then now="up"; else now="down"; fi

  if [ "$now" != "$state" ]; then
    ts=$(date -u +%H:%M:%S)
    if [ "$now" = "down" ]; then
      down_since=$(date +%s)
      # Se anuncia TAMBIÉN cuando arranca ya caído. Suprimir ese primer aviso era el mismo bug
      # que este archivo dice evitar: dejaba al silencio significando "todo bien" y "arrancaste
      # sin internet" a la vez.
      if [ "$state" = "init" ]; then
        echo "🔴 $ts  arrancó SIN conexión (sonda $PROBE sin respuesta)"
      else
        echo "🔴 $ts  conexión CAÍDA (sonda $PROBE sin respuesta)"
      fi
    else
      if [ "$state" = "down" ]; then
        echo "🟢 $ts  conexión RESTABLECIDA tras $(( $(date +%s) - down_since ))s caída"
      fi
    fi
    state="$now"
  fi

  sleep "$INTERVAL"
done
