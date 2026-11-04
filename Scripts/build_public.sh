#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/generate_placeholder_icon.py
python3 Scripts/check_sources.py
xcodebuild -project MinyraForMac.xcodeproj -scheme MinyraForMac -configuration Release -sdk macosx -derivedDataPath build/PublicDerivedData CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO ENABLE_XOJIT_PREVIEWS=NO ARCHS=x86_64 build
APP="build/PublicDerivedData/Build/Products/Release/Minyra for Mac.app"
test -x "$APP/Contents/MacOS/MiniCodingAgent"
"$APP/Contents/MacOS/MiniCodingAgent" --self-test
"$APP/Contents/MacOS/MiniCodingAgent" --agent-e2e-test
echo PUBLIC_SOURCE_XCODE_AND_E2E_PASS
