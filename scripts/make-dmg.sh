#!/bin/bash
# Builds the Release app (as install-app.sh does) and packs it into a compressed disk image with an Applications
# link: dist/MediaPull-<version>.dmg, outside the iCloud-synced folder by default.
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}"
OUT="${1:-$CACHE/dist}"

./scripts/install-app.sh
APP="$HOME/Applications/MediaPull.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGE="$CACHE/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT"
ditto "$APP" "$STAGE/MediaPull.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/MediaPull-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "MediaPull $VERSION" -srcfolder "$STAGE" -fs APFS -format ULMO "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG"
echo "Disk image: $DMG ($(du -h "$DMG" | cut -f1))"
