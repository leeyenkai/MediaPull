#!/bin/bash
# Builds the Release app (fetching and building the engines first if needed) and installs it in
# ~/Applications/MediaPull.app. Build products stay outside the iCloud-synced project folder.
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}"

if [[ ! -x "$CACHE/engines/python/bin/python3" ]]; then ./scripts/fetch-engines.sh; fi
if [[ ! -x "$CACHE/engines/ffmpeg/ffmpeg" ]]; then ./scripts/build-ffmpeg.sh; fi
if [[ ! -f "$CACHE/models/bundle/manifest.json" ]]; then ./scripts/fetch-models.sh; fi

# Start from a fresh bundle: when only engine or bridge files change, Xcode copies them again but does not
# re-sign, and the signature check below would fail.
rm -rf "$CACHE/DerivedData/Build/Products/Release/MediaPull.app"
xcodebuild -project MediaPull.xcodeproj -scheme MediaPull -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$CACHE/DerivedData" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u

APP="$CACHE/DerivedData/Build/Products/Release/MediaPull.app"
codesign --verify --deep --strict "$APP"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/MediaPull.app"
ditto "$APP" "$HOME/Applications/MediaPull.app"
echo "Installed $HOME/Applications/MediaPull.app ($(du -sh "$HOME/Applications/MediaPull.app" | cut -f1))"
