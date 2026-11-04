#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Assets/MiniAgent.iconset"
TARGET="$ROOT/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$TARGET" "$ROOT/build"
test -s "$ROOT/Assets/MiniAgentIcon.png"
for size in 16 32 128 256 512; do
  for suffix in "" "@2x"; do
    src="$SOURCE/icon_${size}x${size}${suffix}.png"
    test -s "$src" || { echo "APPICON_MISSING: $src" >&2; exit 2; }
    cp -f "$src" "$TARGET/$(basename "$src")"
  done
done
test -s "$TARGET/Contents.json"
iconutil -c icns "$SOURCE" -o "$ROOT/build/MiniAgent.icns"
test -s "$ROOT/build/MiniAgent.icns"
echo "APP_ICON_READY: 10 PNG variants, asset catalog and complete MiniAgent.icns from approved icon"
