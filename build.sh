#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/LoadLens.app"
BIN="$APP/Contents/MacOS/LoadLens"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -swift-version 5 \
    "$ROOT/Sources/Sampler.swift" \
    "$ROOT/Sources/Model.swift" \
    "$ROOT/Sources/Diagnoser.swift" \
    "$ROOT/Sources/LoginItem.swift" \
    "$ROOT/Sources/Notifier.swift" \
    "$ROOT/Sources/Keychain.swift" \
    "$ROOT/Sources/DeepSeekClient.swift" \
    "$ROOT/Sources/AIChat.swift" \
    "$ROOT/Sources/AIChatView.swift" \
    "$ROOT/Sources/AIChatWindow.swift" \
    "$ROOT/Sources/Monitor.swift" \
    "$ROOT/Sources/Views.swift" \
    "$ROOT/Sources/App.swift" \
    "$ROOT/Sources/CLI.swift" \
    "$ROOT/Sources/main.swift" \
    -o "$BIN"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "built: $APP"
