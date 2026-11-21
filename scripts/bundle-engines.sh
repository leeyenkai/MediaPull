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
source "$PROJECT_DIR/scripts/cache-stamp.sh"

if [[ ! -x "$CACHE/python/bin/python3" ]]; then
  echo "warning: MediaPull engines are missing. Run scripts/fetch-engines.sh and scripts/build-ffmpeg.sh, then build again."
  exit 0
fi
# Engines that do not match today's pins (a pin changed, or a fetch stopped part way) are never bundled.
if ! cache_current engines; then
  echo "error: the engine cache does not match scripts/fetch-engines.sh. Run scripts/fetch-engines.sh, then build again."
  exit 1
fi
if [[ -x "$CACHE/ffmpeg/ffmpeg" ]] && ! cache_current ffmpeg; then
  echo "error: ffmpeg does not match scripts/build-ffmpeg.sh. Run scripts/build-ffmpeg.sh, then build again."
  exit 1
fi

mkdir -p "$RESOURCES" "$HELPERS" "$LICENSES"
rsync -a --delete "$CACHE/python/" "$RESOURCES/python/"
rsync -a --delete "$CACHE/site-packages/" "$RESOURCES/site-packages/"
rsync -a --delete --exclude "__pycache__" --exclude "test_*.py" "$PROJECT_DIR/Engines/bridge/" "$RESOURCES/bridge/"
cp "$CACHE/versions.json" "$RESOURCES/versions.json"
if [[ -x "$CACHE/ffmpeg/ffmpeg" ]]; then
  rsync -a "$CACHE/ffmpeg/ffmpeg" "$CACHE/ffmpeg/ffprobe" "$HELPERS/"
  cp "$CACHE/ffmpeg/LICENSE-ffmpeg.txt" "$LICENSES/ffmpeg-LGPL-2.1.txt" 2>/dev/null || true
  cp "$CACHE/ffmpeg/LICENSE-lame.txt" "$LICENSES/lame-LGPL.txt" 2>/dev/null || true
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

# R-307: where the source code of every bundled component can be obtained, with the exact versions bundled.
"$CACHE/python/bin/python3" -I - "$CACHE/versions.json" "$CACHE/ffmpeg/VERSION" "$LICENSES/SOURCES.txt" "$CACHE/ffmpeg/LAME_VERSION" <<'PY'
import json, os, sys
versions = json.load(open(sys.argv[1]))
ffmpeg = open(sys.argv[2]).read().strip() if os.path.exists(sys.argv[2]) else "not bundled"
lame = open(sys.argv[4]).read().strip() if os.path.exists(sys.argv[4]) else "3.100"
lines = [
    "MediaPull bundles these components unmodified, except that LAME's export list (include/libmp3lame.sym) drops",
    "lame_init_old, a function its own source no longer has (scripts/build-ffmpeg.sh). Their source code is available at:",
    "",
    f"gallery-dl {versions.get('gallery_dl')} (GPL-2.0): https://github.com/mikf/gallery-dl and https://pypi.org/project/gallery-dl/",
    f"yt-dlp {versions.get('yt_dlp')} (Unlicense): https://github.com/yt-dlp/yt-dlp and https://pypi.org/project/yt-dlp/",
    f"Python {versions.get('python')} (PSF): https://www.python.org/downloads/source/ (built by python-build-standalone)",
    f"ffmpeg {ffmpeg} (LGPL-2.1): https://ffmpeg.org/releases/ffmpeg-{ffmpeg}.tar.xz, configured by scripts/build-ffmpeg.sh",
]
# LAME is part of the ffmpeg build only (audit 2026-11-21-4, C4-10).
if ffmpeg != "not bundled":
    lines.append(f"LAME {lame} (LGPL-2.0), built into ffmpeg for MP3 output: "
                 f"https://downloads.sourceforge.net/project/lame/lame/{lame}/lame-{lame}.tar.gz")
for name in ("requests", "urllib3", "idna", "charset_normalizer", "certifi"):
    lines.append(f"{name} {versions.get(name)}: https://pypi.org/project/{name.replace('_', '-')}/{versions.get(name)}/")
lines += ["", "To ask for a copy of the exact sources used in this build, contact the person who gave you this copy of MediaPull."]
open(sys.argv[3], "w").write("\n".join(lines) + "\n")
PY

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
