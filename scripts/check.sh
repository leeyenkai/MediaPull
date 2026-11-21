#!/bin/bash
# Runs every automated check (SPEC section 25): module-boundary lint, Swift unit and engine tests,
# the bridge's Python tests and an app build. Build products stay outside the iCloud-synced folder.
#   scripts/check.sh            every check; missing tools or engines fail it
#   scripts/check.sh --quick    skips what is missing and the two builds, and never reports a full pass
#   scripts/check.sh --release  also fails while any requirement in docs/CONFORMANCE.md is open
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CACHE="${MEDIAPULL_ENGINE_CACHE:-$HOME/Library/Caches/MediaPullBuild}"
FAILED=0
QUICK=0
RELEASE=0
SKIPPED=()
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --release) RELEASE=1 ;;
    *) echo "unknown option $arg"; exit 2 ;;
  esac
done

# Something needed for a full check is missing: a full run fails, a quick run notes it.
missing() {
  if [[ $QUICK -eq 1 ]]; then
    echo "skipped: $1"
    SKIPPED+=("$1")
  else
    echo "error: $1 (scripts/check.sh --quick runs without it)"
    FAILED=1
  fi
}

echo "== iCloud copies (the project lives in an iCloud-synced folder)"
# iCloud makes "Name 2.swift" when two versions meet; a copy compiles as a duplicate and must never be committed.
copies=$(find . -path ./.git -prune -o -path ./.build -prune -o -name '* [0-9]' -print -o -name '* [0-9].*' -print)
if [ -n "$copies" ]; then
  echo "error: iCloud copies found; compare each with its original and remove it:"
  echo "$copies"
  exit 1
fi

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
# WebKit: the MediaPullBrowser module and the browser pane's own files; everything else goes through MediaPullBrowser.
webkit="$(grep -rlnE '^import WebKit' MediaPullKit/Sources MediaPull --include=*.swift \
  | grep -vE '^(MediaPullKit/Sources/MediaPullBrowser/|MediaPull/Features/Browser/|MediaPull/Platform/)' || true)"
if [[ -n "$webkit" ]]; then
  echo "error: WebKit used outside MediaPullBrowser and the browser pane:"
  echo "$webkit"
  FAILED=1
fi
check_only_in '^import (Vision|CoreML)' 'MediaPullKit/Sources/MediaPullAnalysis/' 'Vision and Core ML'
# Devices are only read (R-4107, D-116): the camera framework only in MediaPullDevices, its pass-through only in the file
# that sends allow-listed reads, and none of its requests that change a device anywhere.
check_only_in '^(@[A-Za-z]+ +)*import +ImageCaptureCore\b' 'MediaPullKit/Sources/MediaPullDevices/' 'ImageCaptureCore'
check_only_in 'requestSendPTPCommand' 'MediaPullKit/Sources/MediaPullDevices/ImageCaptureDevices.swift' 'PTP pass-through'
check_only_in 'requestDelete|requestUpload|requestSyncClock|requestTakePicture|deleteAfterSuccessfulDownload|truncateAfterSuccessfulDownload|ICDeleteAfter|ICTruncateAfter|import +IOUSBHost' 'NONE' 'Writes to a device'
# Analysis runs offline (D-59): no online geocoding, map search, model downloads or Vision asset downloads.
check_only_in 'CLGeocoder|MKLocalSearch|MKReverseGeocod|MKGeocod|MKMapItem|MKDirections|MKLookAround|downloadAssets|MLModelCollection|import CoreLocation' 'NONE' 'Online analysis'
# The one map (D-110): drawn in one file, only after the person allows maps.
check_only_in '^(@[A-Za-z]+ +)*((public|internal|package|private|fileprivate) +)?import +((struct|class|enum|protocol|func|var|let|typealias) +)?MapKit\b' 'MediaPull/Platform/LocationMap.swift' 'MapKit'
if grep -rn "runOpenPanelWith" MediaPull MediaPullKit/Sources --include=*.swift; then
  echo "error: the browser pane must not implement a file open panel"
  FAILED=1
fi
if grep -rniE "local[c]hat" --include=* -r . --exclude-dir=.git --exclude-dir=.build 2>/dev/null | grep -v "scripts/check.sh"; then
  echo "error: references to other applications found"
  FAILED=1
fi

echo "== Invariants (patterns earlier audits found; scripts/lint_invariants.py)"
python3 scripts/lint_invariants.py || FAILED=1

echo "== Requirements (docs/CONFORMANCE.md against docs/SPEC.md and the code)"
if [[ $RELEASE -eq 1 ]]; then python3 scripts/conformance.py --strict || FAILED=1; else python3 scripts/conformance.py | tail -1 || FAILED=1; fi

echo "== Style (swiftlint and swiftformat with the repository's settings)"
if command -v swiftlint >/dev/null; then
  # A broken configuration or a crash is a failure too, not an empty report.
  if ! style="$(swiftlint lint --quiet 2>&1)"; then
    echo "$style" | head -20
    echo "error: swiftlint failed or reported problems"
    FAILED=1
  elif [[ -n "$style" ]]; then
    echo "$style" | head -20
    echo "error: swiftlint reported $(echo "$style" | wc -l | tr -d ' ') problems"
    FAILED=1
  fi
else
  missing "swiftlint is not installed"
fi
if command -v swiftformat >/dev/null; then
  swiftformat MediaPull MediaPullKit --lint --quiet >/dev/null 2>&1 || { echo "error: swiftformat would change files (run swiftformat MediaPull MediaPullKit)"; FAILED=1; }
else
  missing "swiftformat is not installed"
fi

echo "== Swift tests"
(cd MediaPullKit && swift test --scratch-path "$CACHE/spm" 2>&1 | grep -E "Executed [0-9]+ tests|error:|failed" | tail -3) || FAILED=1

echo "== Bridge tests"
if [[ -x "$CACHE/engines/python/bin/python3" ]]; then
  "$CACHE/engines/python/bin/python3" -I Engines/bridge/test_egress_guard.py "$CACHE/engines/site-packages" 2>&1 | tail -3 || FAILED=1
  "$CACHE/engines/python/bin/python3" -I Engines/bridge/test_bridge_details.py "$CACHE/engines/site-packages" 2>&1 | tail -1 || FAILED=1
  # Downloads through the bundled yt-dlp with a made-up site, offline (audit 15).
  "$CACHE/engines/python/bin/python3" -I Engines/bridge/test_stream_runs.py "$CACHE/engines/site-packages" 2>&1 | tail -1 || FAILED=1
else
  missing "engines not installed (scripts/fetch-engines.sh), so the egress guard was not tested"
fi

if [[ $QUICK -eq 1 ]]; then
  SKIPPED+=("the iOS Simulator package build and the app build")
else
  echo "== Package build for the iOS Simulator (keeps an iPad port cheap)"
  (cd MediaPullKit && xcodebuild -scheme MediaPullKit -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$CACHE/DerivedData-iOS" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u) | tee /dev/stderr \
    | grep -q "BUILD SUCCEEDED" || FAILED=1

  echo "== App build"
  xcodebuild -project MediaPull.xcodeproj -scheme MediaPull -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$CACHE/DerivedData" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u | tee /dev/stderr \
    | grep -q "BUILD SUCCEEDED" || FAILED=1

  # Offline end to end: a stand-in engine replays account updates through the whole app (no network). Closures proved
  # only here must not regress unseen (audit 5, C5-m10).
  echo "== Self-test: editor Replace and account folder updates (offline)"
  APP="$CACHE/DerivedData/Build/Products/Debug/MediaPull.app/Contents/MacOS/MediaPull"
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/mediapull-selftest.XXXXXX")"
  if [[ -x "$APP" ]]; then
    RESULTS="$(NSUnbufferedIO=YES "$APP" -NSAppSleepDisabled YES --selftest-url about:blank --selftest-out "$OUT" \
      --selftest-update 2>&1 | grep -E "(update|replace|notes): (PASS|FAIL)" | tee /dev/stderr)"
    # Editor Replace and ⌘Z through the whole app (D-107), then the account folder updates.
    grep -q "replace: PASS" <<<"$RESULTS" && grep -q "notes: PASS" <<<"$RESULTS" && grep -q "update: PASS" <<<"$RESULTS" \
      && ! grep -q ": FAIL" <<<"$RESULTS" || FAILED=1
    # Save As in the Downloads pane never redirects (D-108): Instagram, videos and galleries, offline.
    rm -rf "$OUT"; OUT="$(mktemp -d "${TMPDIR:-/tmp}/mediapull-selftest.XXXXXX")"
    NSUnbufferedIO=YES "$APP" -NSAppSleepDisabled YES --selftest-url about:blank --selftest-out "$OUT" --selftest-save-as 2>&1 \
      | grep -E "save-as: (PASS|FAIL)" | tee /dev/stderr | grep -q "save-as: PASS" || FAILED=1
  else
    echo "error: the app was not built, so the self-test did not run"
    FAILED=1
  fi
  # A file's recorded details, offline, with maps left off (D-110, R-1009b); Organise's duplicates and Details tab (D-114).
  rm -rf "$OUT"; OUT="$(mktemp -d "${TMPDIR:-/tmp}/mediapull-selftest.XXXXXX")"
  if [[ -x "$APP" ]]; then
    NSUnbufferedIO=YES "$APP" -NSAppSleepDisabled YES --selftest-url about:blank --selftest-out "$OUT" --selftest-details 2>&1 \
      | grep -E "(details|organise): (PASS|FAIL)" | tee /dev/stderr | grep -c ": PASS" | grep -q "^2$" || FAILED=1
  fi
  # Drives (section 43) on a small exFAT disk image, attached here because the app may not start processes.
  rm -rf "$OUT"; OUT="$(mktemp -d "${TMPDIR:-/tmp}/mediapull-selftest.XXXXXX")"
  if [[ -x "$APP" ]]; then
    hdiutil create -size 64m -fs ExFAT -volname MPSELFTEST "$OUT/card.dmg" >/dev/null 2>&1
    MOUNT="$(hdiutil attach "$OUT/card.dmg" 2>/dev/null | awk -F'\t' '/MPSELFTEST/ {print $NF}' | tail -1)"
    if [[ -n "$MOUNT" ]]; then
      NSUnbufferedIO=YES "$APP" -NSAppSleepDisabled YES --selftest-url about:blank --selftest-out "$OUT" --selftest-drives "$MOUNT" 2>&1 \
        | grep -E "drives: (PASS|FAIL)" | tee /dev/stderr | grep -q "drives: PASS" || FAILED=1
      [[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1
    else
      echo "error: the exFAT test image could not be attached"
      FAILED=1
    fi
  fi
  # Formats, units and posts, offline (section 42).
  rm -rf "$OUT"; OUT="$(mktemp -d "${TMPDIR:-/tmp}/mediapull-selftest.XXXXXX")"
  if [[ -x "$APP" ]]; then
    NSUnbufferedIO=YES "$APP" -NSAppSleepDisabled YES --selftest-url about:blank --selftest-out "$OUT" --selftest-formats 2>&1 \
      | grep -E "formats: (PASS|FAIL)" | tee /dev/stderr | grep -q "formats: PASS" || FAILED=1
  fi
  # Metadata edits, offline (section 45).
  rm -rf "$OUT"; OUT="$(mktemp -d "${TMPDIR:-/tmp}/mediapull-selftest.XXXXXX")"
  if [[ -x "$APP" ]]; then
    NSUnbufferedIO=YES "$APP" -NSAppSleepDisabled YES --selftest-url about:blank --selftest-out "$OUT" --selftest-edits 2>&1 \
      | grep -E "edits: (PASS|FAIL)" | tee /dev/stderr | grep -q "edits: PASS" || FAILED=1
  fi
  # Devices with a stand-in iPhone and a simulated Android phone, offline (section 41).
  rm -rf "$OUT"; OUT="$(mktemp -d "${TMPDIR:-/tmp}/mediapull-selftest.XXXXXX")"
  if [[ -x "$APP" ]]; then
    NSUnbufferedIO=YES "$APP" -NSAppSleepDisabled YES --selftest-url about:blank --selftest-out "$OUT" --selftest-devices 2>&1 \
      | grep -E "devices: (PASS|FAIL)" | tee /dev/stderr | grep -q "devices: PASS" || FAILED=1
  fi
  # Profile views read saved folders only, offline (D-113).
  rm -rf "$OUT"; OUT="$(mktemp -d "${TMPDIR:-/tmp}/mediapull-selftest.XXXXXX")"
  if [[ -x "$APP" ]]; then
    NSUnbufferedIO=YES "$APP" -NSAppSleepDisabled YES --selftest-url about:blank --selftest-out "$OUT" --selftest-profile 2>&1 \
      | grep -E "profile: (PASS|FAIL)" | tee /dev/stderr | grep -q "profile: PASS" || FAILED=1
  fi
  rm -rf "$OUT"
fi

if [[ $FAILED -ne 0 ]]; then
  echo "Checks failed."
  exit 1
fi
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "Partial check: no failures, but skipped: ${SKIPPED[*]}."
  exit 0
fi
echo "All checks passed."
