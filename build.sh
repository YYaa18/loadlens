#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/LoadLens.app"
BIN="$APP/Contents/MacOS/LoadLens"

# Local model engine (llama.cpp, pinned version). Downloads once into vendor/.
"$ROOT/tools/fetch-llama.sh"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

xcrun swiftc -O -swift-version 5 \
    -F "$ROOT/vendor" -framework llama \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "$ROOT/Sources/Sampler.swift" \
    "$ROOT/Sources/Disk.swift" \
    "$ROOT/Sources/SpaceScanner.swift" \
    "$ROOT/Sources/Model.swift" \
    "$ROOT/Sources/Diagnoser.swift" \
    "$ROOT/Sources/DiskWatch.swift" \
    "$ROOT/Sources/FolderGrowth.swift" \
    "$ROOT/Sources/DiskWatchView.swift" \
    "$ROOT/Sources/LoginItem.swift" \
    "$ROOT/Sources/Notifier.swift" \
    "$ROOT/Sources/Keychain.swift" \
    "$ROOT/Sources/AIProviders.swift" \
    "$ROOT/Sources/LLMClient.swift" \
    "$ROOT/Sources/AITools.swift" \
    "$ROOT/Sources/LocalModel.swift" \
    "$ROOT/Sources/Triage.swift" \
    "$ROOT/Sources/DecisionModel.swift" \
    "$ROOT/Sources/HybridTriage.swift" \
    "$ROOT/Sources/TriageService.swift" \
    "$ROOT/Sources/AISettingsView.swift" \
    "$ROOT/Sources/Theme.swift" \
    "$ROOT/Sources/MarkdownText.swift" \
    "$ROOT/Sources/AIChat.swift" \
    "$ROOT/Sources/AIChatView.swift" \
    "$ROOT/Sources/AIChatWindow.swift" \
    "$ROOT/Sources/AIDock.swift" \
    "$ROOT/Sources/Monitor.swift" \
    "$ROOT/Sources/Views.swift" \
    "$ROOT/Sources/DiskViews.swift" \
    "$ROOT/Sources/App.swift" \
    "$ROOT/Sources/CLI.swift" \
    "$ROOT/Sources/main.swift" \
    -o "$BIN"

# Bundle llama.framework with only this Mac's architecture (about half the size).
cp -R "$ROOT/vendor/llama.framework" "$APP/Contents/Frameworks/"
LLAMA_BIN="$APP/Contents/Frameworks/llama.framework/Versions/A/llama"
lipo "$LLAMA_BIN" -thin "$(uname -m)" -output "$LLAMA_BIN.thin" && mv "$LLAMA_BIN.thin" "$LLAMA_BIN"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Local triage model (25MB embedding model + its classifier), see Resources/triage/NOTICE.md.
cp -R "$ROOT/Resources/triage" "$APP/Contents/Resources/triage"
# Sign with the local certificate when it exists (see tools/setup-signing.sh) so the app keeps
# the same identity across builds and Keychain "Always Allow" sticks. Otherwise sign ad hoc.
SIGN_NAME="LoadLens Local Signing"
if security find-certificate -c "$SIGN_NAME" >/dev/null 2>&1 \
    && codesign --force --sign "$SIGN_NAME" "$APP/Contents/Frameworks/llama.framework" >/dev/null 2>&1 \
    && codesign --force --sign "$SIGN_NAME" "$APP" >/dev/null 2>&1; then
    SIGNED_WITH="$SIGN_NAME"
else
    codesign --force --sign - "$APP/Contents/Frameworks/llama.framework" >/dev/null 2>&1
    codesign --force --sign - "$APP" >/dev/null 2>&1
    SIGNED_WITH="ad hoc（运行 tools/setup-signing.sh 可避免每次重新编译后钥匙串重复询问）"
fi

echo "built: $APP"
echo "signed: $SIGNED_WITH"
