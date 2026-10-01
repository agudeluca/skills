#!/bin/bash
# Stdlib-only Python. Prefers Homebrew's: pyenv's 3.10 on this machine has a broken SSL module.
#   run.sh [flags]          report (see SKILL.md)
#   run.sh refresh [T…]     re-scrape payment schedules from argen.bond
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PY=/opt/homebrew/bin/python3; [ -x "$PY" ] || PY=python3
if [ "${1:-}" = refresh ]; then shift; exec "$PY" "$DIR/refresh.py" "$@"; fi
exec "$PY" "$DIR/bonds.py" "$@"
