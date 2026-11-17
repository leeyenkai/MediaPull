#!/bin/bash
# Called by bundle-engines.sh in the Xcode build phase: copies the staged analysis models and place data into the app
# (SPEC section 36, D-58). Stage them first with scripts/fetch-models.sh.
set -euo pipefail

BUNDLE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}/models/bundle"
APP="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"

if [[ ! -f "$BUNDLE/manifest.json" ]]; then
  echo "warning: MediaPull analysis models are missing. Run scripts/fetch-models.sh, then build again."
  exit 0
fi
source "$PROJECT_DIR/scripts/cache-stamp.sh"
if ! cache_current models; then
  echo "error: the staged models do not match scripts/models.lock and the model scripts. Run scripts/fetch-models.sh."
  exit 1
fi
mkdir -p "$APP/Resources/Models" "$APP/Resources/Licenses"
rsync -a --delete --exclude Licenses "$BUNDLE/" "$APP/Resources/Models/"
cp "$BUNDLE/Licenses/models.txt" "$APP/Resources/Licenses/analysis-models.txt"
