#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test -f "$ROOT/src/aksk_manager/ui/index.html" || { echo '请先在 frontend 中运行 npm ci 和 npm run build。' >&2; exit 1; }
if [ ! -f "$ROOT/runtime/AKSKHelper.app/Contents/MacOS/AKSKHelper" ]; then
  echo '本地组件尚未签名安装：可打开插件界面，但密钥操作暂不可用。' >&2
fi
python3 "$ROOT/scripts/stage-plugin.py"
codex plugin marketplace add "$ROOT"
codex plugin add aksk-manager@aksk-manager
