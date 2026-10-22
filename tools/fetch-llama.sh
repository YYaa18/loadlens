#!/bin/bash
# Downloads the pinned llama.cpp build (prebuilt framework with Metal) and keeps only the macOS
# slice in vendor/llama.framework. Idempotent: does nothing if that version is already there.
set -euo pipefail

VERSION="b11413"
SHA256="060ab53d591c8d9e3a4d7858d7b485a87f2e1b9dfcfbdad018f1fcd0d85d9f82"
URL="https://github.com/ggml-org/llama.cpp/releases/download/$VERSION/llama-$VERSION-xcframework.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/llama.framework"
STAMP="$ROOT/vendor/llama.version"

if [ -d "$DEST" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$VERSION" ]; then
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "下载 llama.cpp $VERSION …"
curl -fL --retry 3 -o "$WORK/llama.zip" "$URL"

ACTUAL="$(shasum -a 256 "$WORK/llama.zip" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA256" ]; then
    echo "error: 校验值不符（期望 $SHA256，实际 $ACTUAL），已停止" >&2
    exit 1
fi

unzip -q "$WORK/llama.zip" -d "$WORK/unzipped"
SLICE="$(find "$WORK/unzipped" -type d -path "*macos-arm64*" -name "llama.framework" | head -1)"
if [ -z "$SLICE" ]; then
    echo "error: 压缩包里没找到 macOS 版的 llama.framework" >&2
    exit 1
fi

rm -rf "$DEST"
mkdir -p "$ROOT/vendor"
cp -R "$SLICE" "$DEST"
echo "$VERSION" > "$STAMP"
echo "llama.cpp $VERSION 已就绪：$DEST"
