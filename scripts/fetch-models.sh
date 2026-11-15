#!/bin/bash
# Fetches, converts and stages the analysis models and place data (SPEC section 36, D-58, D-59).
# Output: $CACHE/models/bundle (manifest.json, compiled models, tokenizer files, places.tsv, licences),
# which scripts/bundle-models.sh copies into the app. Every file is checked against scripts/models.lock.
set -euo pipefail

CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}"
MODELS="$CACHE/models"
SRC="$MODELS/src"
BUNDLE="$MODELS/bundle"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCK="$HERE/models.lock"
mkdir -p "$SRC/clip" "$SRC/geonames" "$BUNDLE"

fetch() { # url, file, sha256 (empty: recorded on first fetch)
  local url="$1" file="$2" sha="$3"
  if [ ! -f "$file" ]; then
    curl -sSfL -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  if [ -n "$sha" ]; then
    local got
    got="$(shasum -a 256 "$file" | cut -c1-64)"
    if [ "$got" != "$sha" ]; then echo "error: $file has SHA-256 $got, expected $sha" >&2; exit 1; fi
  fi
}

CLIP=https://huggingface.co/laion/CLIP-ViT-B-16-DataComp.XL-s13B-b90K/resolve/d110532e8d4ff91c574ee60a342323f28468b287
fetch "$CLIP/vocab.json" "$SRC/clip/vocab.json" 5047b556ce86ccaf6aa22b3ffccfc52d391ea4accdab9c2f2407da5b742d4363
fetch "$CLIP/merges.txt" "$SRC/clip/merges.txt" f526393189112391ce6f9795d4695f704121ce452c3aad1f5335cc41337eba85
fetch https://github.com/deepinsight/insightface/releases/download/model-zoo/buffalo_l.zip "$SRC/buffalo_l.zip" \
  80ffe37d8a5940d59a7384c201a2a38d4741f2f3c51eef46ebb28218a7b0ca2f
# GeoNames publishes new files daily, so the copy fetched first is kept and its checksum recorded in models.lock.
for f in cities1000.zip admin1CodesASCII.txt countryInfo.txt; do
  fetch "https://download.geonames.org/export/dump/$f" "$SRC/geonames/$f" ""
done

# Convert (PyTorch and ONNX to Core ML) when the packages are missing.
CONVERTED="$MODELS/converted"
for p in mobileclip2_s3_image mobileclip2_s3_text adaface_ir101_rgb scrfd_10g; do
  if [ ! -d "$CONVERTED/$p.mlpackage" ]; then
    bash "$HERE/convert-models.sh"
    break
  fi
done

# Compile for the app (no compiling on the person's Mac at first launch).
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Licenses"
for p in mobileclip2_s3_image mobileclip2_s3_text adaface_ir101_rgb scrfd_10g; do
  xcrun coremlcompiler compile "$CONVERTED/$p.mlpackage" "$BUNDLE" >/dev/null
done
cp "$SRC/clip/vocab.json" "$SRC/clip/merges.txt" "$BUNDLE/"
python3 -I "$HERE/build_places.py" "$SRC/geonames" "$BUNDLE/places.tsv" >/dev/null
cat > "$BUNDLE/manifest.json" <<'JSON'
{
  "imageText": {
    "id": "mobileclip2-s3", "imageModel": "mobileclip2_s3_image.mlmodelc", "textModel": "mobileclip2_s3_text.mlmodelc",
    "imageSize": 256, "dimension": 768, "contextLength": 77, "vocab": "vocab.json", "merges": "merges.txt",
    "imageOutput": "embedding", "textOutput": "embedding", "logitScale": 100
  },
  "face": {
    "id": "adaface-ir101-webface12m", "model": "adaface_ir101_rgb.mlmodelc", "dimension": 512, "output": "embedding",
    "matchThreshold": 0.34, "detector": "scrfd_10g.mlmodelc", "flipFusion": false
  },
  "places": "places.tsv"
}
JSON
cat > "$BUNDLE/Licenses/models.txt" <<'TXT'
Analysis models and data bundled with MediaPull (personal use; see docs/spikes/analysis-models.md):
- MobileCLIP2-S3, Apple (apple/ml-mobileclip; weights timm/MobileCLIP2-S3-OpenCLIP revision 2a5959ca)
- AdaFace IR-101 trained on WebFace12M, CVLFace (minchul/cvlface_adaface_ir101_webface12m revision 54f602a0)
- SCRFD-10G with landmarks, InsightFace (buffalo_l det_10g.onnx)
- CLIP tokenizer vocabulary (OpenAI CLIP, via OpenCLIP)
- Place names: GeoNames (geonames.org), Creative Commons Attribution 4.0
TXT

# Check every staged file against the lock; record it when the lock has no entry (or MEDIAPULL_UPDATE_MODELS_LOCK=1).
# The compiler writes a different coremldata.bin each time, so the converted packages it starts from are locked instead.
LIST="$(cd "$BUNDLE" && find . -type f ! -name '.DS_Store' ! -name 'coremldata.bin' | LC_ALL=C sort)"
CURRENT="$(cd "$BUNDLE" && echo "$LIST" | while read -r f; do echo "$(shasum -a 256 "$f" | cut -c1-64)  ${f#./}"; done)"
PACKAGES="$(cd "$CONVERTED" && for p in mobileclip2_s3_image mobileclip2_s3_text adaface_ir101_rgb scrfd_10g; do
  echo "package $(cd "$p.mlpackage" && find . -type f ! -name '.DS_Store' | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-64)  $p.mlpackage"
done)"
SOURCES="$(cd "$SRC" && shasum -a 256 geonames/cities1000.zip geonames/admin1CodesASCII.txt geonames/countryInfo.txt | sed 's/^/source /')"
if [ ! -f "$LOCK" ] || [ "${MEDIAPULL_UPDATE_MODELS_LOCK:-0}" = 1 ]; then
  { echo "# Analysis models and data, SHA-256 (written by scripts/fetch-models.sh)"; echo "$SOURCES"; echo "$PACKAGES"; echo "$CURRENT"; } > "$LOCK"
  echo "Recorded $(echo "$CURRENT" | wc -l | tr -d ' ') files in models.lock"
else
  if ! diff <(grep '^source ' "$LOCK") <(echo "$SOURCES") >/dev/null; then echo "error: GeoNames sources differ from models.lock" >&2; exit 1; fi
  if ! diff <(grep '^package ' "$LOCK") <(echo "$PACKAGES") >/dev/null; then echo "error: converted models differ from models.lock" >&2; exit 1; fi
  if ! diff <(grep -v '^#' "$LOCK" | grep -v '^source ' | grep -v '^package ') <(echo "$CURRENT") >/dev/null; then
    echo "error: staged models differ from models.lock (set MEDIAPULL_UPDATE_MODELS_LOCK=1 after a deliberate change)" >&2
    exit 1
  fi
fi
du -sh "$BUNDLE"
