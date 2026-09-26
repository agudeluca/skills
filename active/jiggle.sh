#!/bin/bash
# Mouse jiggler para mantener presencia "activo" (Slack/Teams/etc).
# Mueve el cursor 1px y lo devuelve cada N segundos. No roba foco ni clickea.
#
# Uso:
#   jiggle.sh start [intervalo_seg] [duracion_min]   # arranca (default 60s, sin límite)
#   jiggle.sh stop                                    # frena
#   jiggle.sh status                                  # estado

DIR="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="$DIR/.jiggle.pid"
LOGFILE="$DIR/.jiggle.log"

is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

case "${1:-start}" in
  start)
    if ! command -v cliclick >/dev/null 2>&1; then
      echo "ERROR: cliclick no está instalado (brew install cliclick)"; exit 1
    fi
    if is_running; then
      echo "Ya está corriendo (PID $(cat "$PIDFILE"))."; exit 0
    fi
    INTERVAL="${2:-60}"
    DURATION_MIN="${3:-0}"   # 0 = sin límite
    if [ "$DURATION_MIN" -gt 0 ] 2>/dev/null; then CUT=", corte en ${DURATION_MIN}min"; else CUT=""; fi
    (
      end=0
      if [ "$DURATION_MIN" -gt 0 ] 2>/dev/null; then end=$(( $(date +%s) + DURATION_MIN * 60 )); fi
      echo "$(date '+%Y-%m-%d %H:%M:%S') jiggle iniciado — cada ${INTERVAL}s${CUT}" >> "$LOGFILE"
      while true; do
        cliclick m:+1,+0 >/dev/null 2>&1
        cliclick m:-1,+0 >/dev/null 2>&1
        echo "$(date '+%H:%M:%S') jiggle" >> "$LOGFILE"
        if [ "$end" -gt 0 ] && [ "$(date +%s)" -ge "$end" ]; then
          echo "$(date '+%H:%M:%S') fin por duración" >> "$LOGFILE"; break
        fi
        sleep "$INTERVAL"
      done
      rm -f "$PIDFILE"
    ) &
    echo $! > "$PIDFILE"
    echo "Jiggle activo (PID $!) — cada ${INTERVAL}s${CUT}. Frenar: jiggle.sh stop"
    ;;
  stop)
    if is_running; then
      kill "$(cat "$PIDFILE")" 2>/dev/null
      # matar el subshell hijo también
      pkill -P "$(cat "$PIDFILE")" 2>/dev/null
      rm -f "$PIDFILE"
      echo "Jiggle frenado."
    else
      pkill -f "$DIR/jiggle.sh" 2>/dev/null
      rm -f "$PIDFILE"
      echo "No estaba corriendo (limpié residuos por las dudas)."
    fi
    ;;
  status)
    if is_running; then
      echo "ACTIVO (PID $(cat "$PIDFILE"))"
      tail -3 "$LOGFILE" 2>/dev/null
    else
      echo "detenido"
    fi
    ;;
  *)
    echo "Uso: jiggle.sh {start [intervalo_seg] [duracion_min] | stop | status}"; exit 1
    ;;
esac
