#!/bin/bash
# Downloads the pinned engine runtime (standalone CPython) and the pure-Python engine wheels,
# verifies every SHA-256, trims the standard library and lays everything out in the build cache.
# The Xcode build copies the result into the app bundle (scripts/bundle-engines.sh).
set -euo pipefail

CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}"
DL="$CACHE/downloads"
OUT="$CACHE/engines"
mkdir -p "$DL/wheels" "$OUT"
source "$(dirname "$0")/cache-stamp.sh"
# Until this run finishes, the cache is not a complete set of today's pins.
cache_unmark engines
rm -f "$OUT/versions.json"

PY_VERSION="3.13.18"
PY_BUILD="20261110"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_BUILD}/cpython-${PY_VERSION}%2B${PY_BUILD}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PY_SHA="7a2384641584ab9984221fcb0fc9265df465922af71be71410529e2a9c3f0540"

# name version sha256 (pure-Python wheels only, so engine updates never add native code)
WHEELS=(
  "gallery-dl 1.32.19 f6b1eb5e9a7409a988b754335d99dbb1873e130d133ed5d164d32e5e645d1c50"
  "yt-dlp 2026.10.26 a05c5b5d8562f7e8a62f5334348b406af4930d56d3a65f8021d14af0e22339ae"
  "requests 2.34.2 2a0d60c172f83ac6ab31e4554906c0f3b3588d37b5cb939b1c061f4907e278e0"
  "urllib3 2.8.0 0cf3cae568d36aa9576b28dfb35f11328f1cb974ca7647d9475ebb86c75ac6e3"
  "idna 3.20 ab7ae7122974553370f0bdb919e1a960b2cd1bc1ef0276416d896db81c14582c"
  "charset-normalizer 3.5.2 b6b751274acb69d77b3323d6b7dbaa3c7fdfc1eb829b7eb61d262f32e1af9685"
  "certifi 2026.10.23 e9b54de76e530bb6cf0ccd036787103acb58fd42ba930ea8bf948ddbaa2f61d1"
)

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

fetch() {
  local url="$1" sha="$2" dest="$3"
  if [[ -f "$dest" && "$(sha_of "$dest")" == "$sha" ]]; then return 0; fi
  echo "Downloading $(basename "$dest")"
  curl -sSLf --retry 3 -o "$dest.part" "$url"
  local got; got="$(sha_of "$dest.part")"
  if [[ "$got" != "$sha" ]]; then
    rm -f "$dest.part"
    echo "error: SHA-256 mismatch for $(basename "$dest"): expected $sha, got $got" >&2
    exit 1
  fi
  mv "$dest.part" "$dest"
}

fetch "$PY_URL" "$PY_SHA" "$DL/python.tar.gz"

echo "Unpacking Python $PY_VERSION"
rm -rf "$OUT/python" "$OUT/site-packages"
tar -xzf "$DL/python.tar.gz" -C "$OUT"
PY="$OUT/python/bin/python3"
LIB="$OUT/python/lib/python3.13"

# Trim parts of the standard library and runtime the engines never use.
rm -rf "$LIB/test" "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/ensurepip" "$LIB/pydoc_data" \
       "$LIB/turtle.py" "$LIB/site-packages/pip" "$LIB"/site-packages/pip-* "$LIB/config-3.13-darwin" \
       "$OUT/python/share" "$OUT/python/include" "$OUT"/python/lib/tcl* "$OUT"/python/lib/tk* \
       "$OUT"/python/lib/itcl* "$OUT"/python/lib/thread* "$OUT"/python/lib/libtcl* "$OUT"/python/lib/libtk* \
       "$OUT/python/lib/pkgconfig"
rm -f "$LIB"/lib-dynload/_tkinter*.so "$LIB"/lib-dynload/_test*.so "$LIB"/lib-dynload/xxlimited*.so
# The interpreter is statically linked; the shared library is only for embedding.
if ! otool -L "$OUT/python/bin/python3.13" | grep -q libpython; then rm -f "$OUT"/python/lib/libpython3*.dylib; fi
rm -rf "$LIB/unittest" "$LIB/_pyrepl" "$LIB/pydoc.py" "$LIB/venv" "$LIB/lib2to3" "$LIB/__phello__" "$LIB/idlelib"
find "$OUT/python" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$OUT/python/bin" -type f ! -name "python3.13" -delete
find "$OUT/python/bin" -type l ! -name "python3" -delete

mkdir -p "$OUT/site-packages"
VERSIONS="{\"python\": \"$PY_VERSION\""
for entry in "${WHEELS[@]}"; do
  read -r name version sha <<< "$entry"
  meta="$(curl -sSLf --retry 3 "https://pypi.org/pypi/$name/$version/json")"
  url="$(printf '%s' "$meta" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(next(u['url'] for u in d['urls'] if u['filename'].endswith('py3-none-any.whl')))")"
  file="$DL/wheels/$(basename "$url")"
  fetch "$url" "$sha" "$file"
  "$PY" -I -m zipfile -e "$file" "$OUT/site-packages"
  key="$(echo "$name" | tr '-' '_')"
  VERSIONS="$VERSIONS, \"$key\": \"$version\""
done
rm -rf "$OUT/site-packages/bin"
echo "$VERSIONS}" > "$OUT/versions.json"

echo "Precompiling bytecode"
# Legacy-layout bytecode next to each module, then drop the sources: Python imports
# sourceless .pyc files, and the runtime shrinks by about half. Updated engines keep sources.
"$PY" -I -m compileall -q -b -j 0 --invalidation-mode unchecked-hash "$LIB" "$OUT/site-packages" > /dev/null || true
find "$LIB" "$OUT/site-packages" -name "*.py" -type f -exec sh -c 'test -f "${1}c" && rm "$1"' _ {} \;
find "$LIB" "$OUT/site-packages" -name "__pycache__" -type d -prune -exec rm -rf {} +

du -sh "$OUT/python" "$OUT/site-packages"
cache_mark engines
echo "Engines ready in $OUT"
