#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v uv >/dev/null 2>&1; then
  for candidate in "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
    if [ -x "$candidate" ]; then PATH="$(dirname "$candidate"):$PATH"; export PATH; break; fi
  done
fi
if ! command -v uv >/dev/null 2>&1; then
  echo 'AKSK Manager 需要 uv：https://docs.astral.sh/uv/getting-started/installation/' >&2
  exit 1
fi
export UV_PROJECT_ENVIRONMENT="${XDG_CACHE_HOME:-$HOME/Library/Caches}/aksk-manager/venv-0.1.0"
export AKSK_PLUGIN_ROOT="$ROOT"
exec uv run --project "$ROOT" --python 3.12 --frozen --no-dev --no-editable aksk-manager
