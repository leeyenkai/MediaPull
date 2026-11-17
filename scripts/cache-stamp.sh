#!/bin/bash
# Cache stamps (SPEC 26): each build cache records a hash of the pins that made it, written last by the script that
# fills it. Bundling and installing refuse a cache whose stamp is missing or differs from today's pins, so a changed pin
# or a fetch that failed part way never ships.
#   source scripts/cache-stamp.sh; cache_stamp engines|ffmpeg|models   -> prints the expected stamp
#   cache_current engines|ffmpeg|models                                   -> succeeds when the cache matches

STAMP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP_CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}"

cache_dir() {
  case "$1" in
    engines) echo "$STAMP_CACHE/engines" ;;
    ffmpeg) echo "$STAMP_CACHE/engines/ffmpeg" ;;
    models) echo "$STAMP_CACHE/models/bundle" ;;
  esac
}

cache_stamp() {
  local files
  case "$1" in
    engines) files=("$STAMP_HERE/fetch-engines.sh") ;;
    ffmpeg) files=("$STAMP_HERE/build-ffmpeg.sh") ;;
    models) files=("$STAMP_HERE/fetch-models.sh" "$STAMP_HERE/convert-models.sh" "$STAMP_HERE/convert_models.py"
                   "$STAMP_HERE/build_places.py" "$STAMP_HERE/models.lock") ;;
  esac
  local file
  for file in "${files[@]}"; do
    if [[ ! -f "$file" ]]; then echo "error: cache-stamp.sh cannot find $file" >&2; return 1; fi
  done
  cat "${files[@]}" | shasum -a 256 | cut -c1-64
}

cache_current() {
  local stamp="$(cache_dir "$1")/.stamp" expected
  expected="$(cache_stamp "$1")" || return 1
  [[ -f "$stamp" && "$(cat "$stamp")" == "$expected" ]]
}

cache_mark() {
  local expected
  expected="$(cache_stamp "$1")" || return 1
  echo "$expected" > "$(cache_dir "$1")/.stamp"
}
cache_unmark() { rm -f "$(cache_dir "$1")/.stamp"; }
