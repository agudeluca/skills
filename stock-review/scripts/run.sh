#!/bin/bash
# Bootstrap a private venv (yfinance + pandas) on first use, then run the screener.
# Prefers Homebrew's python: pyenv's 3.10 on this machine has a broken SSL module and pip fails.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$HOME/.cache/stock-review/venv"
if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c "import yfinance, pandas" 2>/dev/null; then
  PY=/opt/homebrew/bin/python3; [ -x "$PY" ] || PY=python3
  rm -rf "$VENV"; mkdir -p "$(dirname "$VENV")"
  "$PY" -m venv "$VENV" >&2
  "$VENV/bin/pip" install -q --disable-pip-version-check yfinance pandas >&2
fi
exec "$VENV/bin/python" "$DIR/screener.py" "$@"
