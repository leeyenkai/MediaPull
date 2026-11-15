#!/bin/bash
# Runs every automated check (SPEC section 25): module-boundary lint, Swift unit and engine tests,
# the bridge's Python tests and an app build. Build products stay outside the iCloud-synced folder.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}"
FAILED=0

echo "== Module boundaries and read-only lint"
check_only_in() {
  local pattern="$1" allowed="$2" label="$3"
  local hits
  hits="$(grep -rnE "$pattern" MediaPullKit/Sources MediaPull --include=*.swift | grep -v "$allowed" | grep -v "webView.load(URLRequest" | grep -v "^[^:]*:[0-9]*: *//" || true)"
  if [[ -n "$hits" ]]; then
    echo "error: $label used outside $allowed:"
    echo "$hits"
    FAILED=1
  fi
}
check_only_in 'URLSession|URLRequest\(|uploadTask|httpBody' 'MediaPullKit/Sources/MediaPullNet/' 'URLSession'
check_only_in '^import SwiftData' 'MediaPullKit/Sources/MediaPullStore/' 'SwiftData'
check_only_in 'Process\(\)' 'MediaPullKit/Sources/MediaPullEngines/' 'Process'
check_only_in 'AsyncImage\(|Data\(contentsOf: *URL\(string' 'NONE' 'Remote loading that bypasses the gate'
check_only_in '^import AppKit' 'MediaPull/' 'AppKit'
check_only_in '^import (Vision|CoreML)' 'MediaPullKit/Sources/MediaPullAnalysis/' 'Vision and Core ML'
# Analysis runs offline (D-59): no online geocoding, map search, model downloads or Vision asset downloads.
check_only_in 'CLGeocoder|MKLocalSearch|MKReverseGeocod|downloadAssets|MLModelCollection|import CoreLocation|import MapKit' 'NONE' 'Online analysis'
if grep -rn "runOpenPanelWith" MediaPull MediaPullKit/Sources --include=*.swift; then
  echo "error: the browser pane must not implement a file open panel"
  FAILED=1
fi
if grep -rniE "local[c]hat" --include=* -r . --exclude-dir=.git --exclude-dir=.build 2>/dev/null | grep -v "scripts/check.sh"; then
  echo "error: references to other applications found"
  FAILED=1
fi

echo "== Swift tests"
(cd MediaPullKit && swift test --scratch-path "$CACHE/spm" 2>&1 | grep -E "Executed [0-9]+ tests|error:|failed" | tail -3) || FAILED=1

echo "== Bridge tests"
if [[ -x "$CACHE/engines/python/bin/python3" ]]; then
  "$CACHE/engines/python/bin/python3" -I Engines/bridge/test_egress_guard.py "$CACHE/engines/site-packages" 2>&1 | tail -3 || FAILED=1
  "$CACHE/engines/python/bin/python3" -I Engines/bridge/test_bridge_details.py "$CACHE/engines/site-packages" 2>&1 | tail -1 || FAILED=1
else
  echo "skipped: engines not installed (scripts/fetch-engines.sh)"
fi

echo "== Package build for the iOS Simulator (keeps an iPad port cheap)"
(cd MediaPullKit && xcodebuild -scheme MediaPullKit -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$CACHE/DerivedData-iOS" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u) || FAILED=1

echo "== App build"
xcodebuild -project MediaPull.xcodeproj -scheme MediaPull -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$CACHE/DerivedData" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u || FAILED=1

if [[ $FAILED -ne 0 ]]; then
  echo "Checks failed."
  exit 1
fi
echo "All checks passed."
