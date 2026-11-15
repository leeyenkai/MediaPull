#!/bin/bash
# Converts the analysis model candidates to Core ML (SPEC section 36, D-58).
# Build-time only: a throwaway virtual environment in the build cache; nothing here is bundled.
# Model weights are downloaded at pinned revisions by convert_models.py; buffalo_l.zip by scripts/fetch-models.sh.
set -euo pipefail

CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}"
MODELS="$CACHE/models"
VENV="$MODELS/venv"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Versions tested together; coremltools 9.0 supports torch up to 2.7.
PACKAGES=(
  "torch==2.7.0" "torchvision==0.22.0" "coremltools==9.0" "numpy==2.2.6"
  "open-clip-torch==4.2.2" "timm==1.0.31" "onnx==1.23.2" "onnx2torch==1.5.15" "safetensors==0.8.0"
  "huggingface-hub==2.4.0" "omegaconf==2.3.0"
)

if [ ! -x "$VENV/bin/python" ]; then
  uv venv -q -p 3.12 "$VENV"
fi
uv pip install -q -p "$VENV/bin/python" "${PACKAGES[@]}"
"$VENV/bin/python" -W ignore "$HERE/convert_models.py" "$MODELS" "$@"
