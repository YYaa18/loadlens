#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/Applications/负载侦探.app"

"$ROOT/build.sh"

mkdir -p "$HOME/Applications"
rm -rf "$TARGET"
ditto "$ROOT/build/LoadLens.app" "$TARGET"

open "$TARGET"
echo "已安装并启动：$TARGET"
echo "下次可以在「应用程序」里找到「负载侦探」，或把它拖到登录项实现开机自启。"
