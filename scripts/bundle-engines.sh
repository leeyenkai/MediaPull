#!/bin/bash
# Xcode build phase: copies the engine runtime, bridge and ffmpeg into the app bundle and removes
# extended attributes (iCloud adds some) so code signing succeeds.
set -euo pipefail

CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}/engines"
APP="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
RESOURCES="$APP/Resources/Engines"
HELPERS="$APP/Helpers"
LICENSES="$APP/Resources/Licenses"

bash "$PROJECT_DIR/scripts/bundle-models.sh"

if [[ ! -x "$CACHE/python/bin/python3" ]]; then
  echo "warning: MediaPull engines are missing. Run scripts/fetch-engines.sh and scripts/build-ffmpeg.sh, then build again."
  exit 0
fi

mkdir -p "$RESOURCES" "$HELPERS" "$LICENSES"
rsync -a --delete "$CACHE/python/" "$RESOURCES/python/"
rsync -a --delete "$CACHE/site-packages/" "$RESOURCES/site-packages/"
rsync -a --delete --exclude "__pycache__" --exclude "test_*.py" "$PROJECT_DIR/Engines/bridge/" "$RESOURCES/bridge/"
cp "$CACHE/versions.json" "$RESOURCES/versions.json"
if [[ -x "$CACHE/ffmpeg/ffmpeg" ]]; then
  rsync -a "$CACHE/ffmpeg/ffmpeg" "$CACHE/ffmpeg/ffprobe" "$HELPERS/"
  cp "$CACHE/ffmpeg/LICENSE-ffmpeg.txt" "$LICENSES/ffmpeg-LGPL-2.1.txt" 2>/dev/null || true
else
  echo "warning: ffmpeg is missing. Run scripts/build-ffmpeg.sh for video merging and conversion."
fi
if [[ -d "$PROJECT_DIR/Config/Licenses" ]]; then
  rsync -a "$PROJECT_DIR/Config/Licenses/" "$LICENSES/"
fi
for dist in "$CACHE"/site-packages/*.dist-info; do
  name="$(basename "$dist" .dist-info)"
  for file in "$dist"/LICENSE* "$dist"/licenses/*; do
    [[ -f "$file" ]] && cp "$file" "$LICENSES/$name-$(basename "$file")"
  done
done
cp "$CACHE/python/lib/python3.13/LICENSE.txt" "$LICENSES/python-LICENSE.txt" 2>/dev/null || true

xattr -cr "$APP" 2>/dev/null || true

# Release builds signed with a real identity re-sign every nested Mach-O with the hardened runtime.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" && "${CONFIGURATION:-Debug}" == "Release" ]]; then
  find "$RESOURCES/python" "$HELPERS" -type f \( -perm -u+x -o -name "*.so" -o -name "*.dylib" \) -print0 |
    while IFS= read -r -d '' file; do
      if file "$file" | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$file"
      fi
    done
fi
