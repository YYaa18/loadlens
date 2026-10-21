#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/Applications/负载侦探.app"

"$ROOT/build.sh"

# Quit a running copy first; otherwise `open` would just bring the old version to the front.
if pgrep -x LoadLens >/dev/null 2>&1; then
    pkill -x LoadLens || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x LoadLens >/dev/null 2>&1 || break
        sleep 0.3
    done
fi

mkdir -p "$HOME/Applications"
rm -rf "$TARGET"
ditto "$ROOT/build/LoadLens.app" "$TARGET"

open "$TARGET"
echo "已安装并启动：$TARGET"
echo "菜单栏右上角会出现一个圆环和 CPU 百分比，点击它打开面板。"
