#!/bin/bash
# Removes 负载侦探 (LoadLens).
#   ./uninstall.sh          quit the app, remove it and its login item
#   ./uninstall.sh --purge  also delete settings and the API keys saved in the Keychain
set -uo pipefail

TARGET="$HOME/Applications/负载侦探.app"
AGENT="$HOME/Library/LaunchAgents/local.loadlens.agent.plist"

pkill -x LoadLens 2>/dev/null && echo "已退出负载侦探"

if [ -f "$AGENT" ]; then
    launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null
    rm -f "$AGENT"
    echo "已移除开机自启"
fi

if [ -d "$TARGET" ]; then
    rm -rf "$TARGET"
    echo "已删除 $TARGET"
fi

if [ "${1:-}" = "--purge" ]; then
    defaults delete local.loadlens 2>/dev/null && echo "已删除设置"
    # One Keychain item per AI provider, all under the same service name.
    removed=0
    while security delete-generic-password -s "local.loadlens.ai" >/dev/null 2>&1; do
        removed=$((removed + 1))
    done
    security delete-generic-password -s "local.loadlens.deepseek" >/dev/null 2>&1 && removed=$((removed + 1))
    echo "已删除钥匙串里的 API Key：$removed 个"
else
    echo "设置和 API Key 已保留；如需一并删除，运行 ./uninstall.sh --purge"
fi

echo "卸载完成。"
