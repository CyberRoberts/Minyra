#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required by the Xcode App Target}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH missing}"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST"
test -s "$ROOT/build/MiniAgent.icns" || { echo "Missing complete original Mini-chan icns" >&2; exit 21; }
cp -f "$ROOT/build/MiniAgent.icns" "$DEST/MiniAgent.icns"
cp -f "$ROOT/Assets/MiniAgentIcon.png" "$DEST/MiniAgentIcon.png"
if [[ -d "$ROOT/build/cubism-export/Live2D/output" ]]; then
  ditto "$ROOT/build/cubism-export/Live2D/output" "$DEST/Live2D"
elif [[ "${REQUIRE_CHARACTER_ASSETS:-NO}" == "YES" ]]; then
  echo "RELEASE_BLOCKED: Cubism model export missing" >&2; exit 22
fi
if [[ -d "$ROOT/build/cubism-export/Live2D/player" ]]; then
  ditto "$ROOT/build/cubism-export/Live2D/player" "$DEST/Live2DWeb"
elif [[ "${REQUIRE_CHARACTER_ASSETS:-NO}" == "YES" ]]; then
  echo "RELEASE_BLOCKED: animated Web player missing" >&2; exit 23
fi
if [[ -d "$ROOT/build/native-frames/frames" ]]; then
  ditto "$ROOT/build/native-frames/frames" "$DEST/Live2DFrames"
elif [[ "${REQUIRE_CHARACTER_ASSETS:-NO}" == "YES" ]]; then
  echo "RELEASE_BLOCKED: Native Mini-chan animation assets missing" >&2; exit 24
fi
echo "MINYRA_XCODE_RESOURCES_READY"
