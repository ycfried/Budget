#!/bin/bash
# OnBudget iOS clone — record the walkthrough TOUR video in an iOS simulator.
# Runs ONLY OnBudgetUITests.testTourVideo (no kit/UI proof suite)
# while `xcrun simctl io recordVideo` captures the simulator screen.
# Adapted from ios-clone/scripts/macos_video_screens.sh (same build +
# simulator pattern). Inert until explicitly run: GitHub Actions
# (workflow_dispatch, ONBUDGET_APPROVED_WORKFLOW=1) or a local Mac
# with ONBUDGET_LOCAL_RUN=1. No signing, deployment, downloads or
# providers. The fixtures are seeded by a separate workflow step
# (seed_video_fixtures.mjs) before this script runs.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'BLOCKED: Xcode and an iOS simulator require macOS.' >&2
  exit 2
fi

# The script only runs when explicitly approved: the GitHub Actions
# workflow sets ONBUDGET_APPROVED_WORKFLOW=1; a local Mac run opts in
# with ONBUDGET_LOCAL_RUN=1. Anything else exits without doing work.
if [[ "${ONBUDGET_APPROVED_WORKFLOW:-0}" != 1 && "${ONBUDGET_LOCAL_RUN:-0}" != 1 ]]; then
  echo 'BLOCKED: set ONBUDGET_APPROVED_WORKFLOW=1 (CI) or ONBUDGET_LOCAL_RUN=1 (local Mac) to run.' >&2
  exit 2
fi

if [[ -n "${GITHUB_SHA:-}" && "$(git rev-parse HEAD)" != "$GITHUB_SHA" ]]; then
  echo 'FAIL: checkout no longer matches the approved push SHA.' >&2
  exit 1
fi

# Preferred toolchain is the reviewed Xcode 16.4, as in the proven
# pattern. If the runner image no longer carries it, fall back to the
# default Xcode provided it is 16.x or newer — and say so loudly.
if [[ -d /Applications/Xcode_16.4.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
  expected_version='Xcode 16.4'
else
  export DEVELOPER_DIR="$(xcode-select -p)"
  expected_version=''
  echo "NOTE: Xcode 16.4 not installed; using default Xcode at $DEVELOPER_DIR." >&2
fi
onbudget_xcode_version="$(xcodebuild -version)"
printf '%s\n' "$onbudget_xcode_version"
if [[ -n "$expected_version" ]]; then
  [[ "${onbudget_xcode_version%%$'\n'*}" == "$expected_version" ]] || {
    echo 'FAIL: expected Xcode 16.4; no fallback or download.' >&2; exit 1;
  }
else
  xcode_major="$(printf '%s' "$onbudget_xcode_version" | head -1 | awk '{print $2}' | cut -d. -f1)"
  [[ "$xcode_major" -ge 16 ]] || {
    echo 'FAIL: fallback Xcode must be 16.x or newer.' >&2; exit 1;
  }
fi

mkdir -p ios-clone/CloudResults
python3 ios-clone/scripts/validate_project.py
# Resolve remote Swift packages (Plaid LinkKit) BEFORE the build:
# build-for-testing runs with -disableAutomaticPackageResolution, so
# a newly-added remote package with no Package.resolved would fail
# there. This writes OnBudget.xcodeproj/project.xcworkspace/
# xcshareddata/swiftpm/Package.resolved for this checkout.
xcodebuild -resolvePackageDependencies -project ios-clone/OnBudget.xcodeproj
xcodebuild -list -project ios-clone/OnBudget.xcodeproj

xcrun simctl list runtimes --json > ios-clone/CloudResults/runtimes.json
onbudget_runtime="$(python3 - <<'PY'
import json
from pathlib import Path
runtimes = json.loads(Path('ios-clone/CloudResults/runtimes.json').read_text())['runtimes']
available = [r for r in runtimes if r.get('isAvailable') and r.get('platform') == 'iOS']
preferred = 'com.apple.CoreSimulator.SimRuntime.iOS-18-5'
if any(r['identifier'] == preferred for r in available):
    print(preferred)
else:
    def version_key(r):
        return tuple(int(p) for p in r.get('version', '0').split('.'))
    newest = max(available, key=version_key)
    print(f"NOTE: iOS 18.5 runtime missing; using newest available {newest['identifier']} ({newest.get('version')}).", file=__import__('sys').stderr)
    print(newest['identifier'])
PY
)"
echo "Using simulator runtime: $onbudget_runtime"

onbudget_simulator_id="$(xcrun simctl create "OnBudget-tour-video-rec-${GITHUB_RUN_ID:-local}" com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$onbudget_runtime")"
cleanup() {
  xcrun simctl shutdown "$onbudget_simulator_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$onbudget_simulator_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$onbudget_simulator_id"
xcrun simctl bootstatus "$onbudget_simulator_id" -b

# Do not overwrite results from an earlier local run.
[[ ! -e ios-clone/CloudResults/tour-video.xcresult ]] || {
  echo 'FAIL: tour-video.xcresult already exists. Preserve/remove it explicitly before rerunning.' >&2
  exit 1
}
xcodebuild -project ios-clone/OnBudget.xcodeproj -scheme OnBudget -configuration Debug \
  -destination "platform=iOS Simulator,id=$onbudget_simulator_id" \
  -destination-timeout 60 -derivedDataPath ios-clone/CloudResults/DerivedData \
  -resultBundlePath ios-clone/CloudResults/build.xcresult -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build-for-testing

# --- Screen recording ---------------------------------------------------
# Start the simulator screen recording BEFORE the test, so it captures
# the sign-in/join preamble as well as the scenes (the assembler trims
# everything before the HOME-READY marker). recordVideo runs until it
# gets SIGINT, then finalizes the file — so stop it with SIGINT and
# wait for the process to exit before checking the file.
# The start epoch is written out so assemble-v2 can turn the test's
# VIDEO-MARK epoch timestamps into offsets into the recording.
RECORD_START="$(date +%s)"
printf '%s\n' "$RECORD_START" > ios-clone/CloudResults/record-start-epoch.txt
echo "Recording start epoch: $RECORD_START"
xcrun simctl io "$onbudget_simulator_id" recordVideo --codec=h264 ios-clone/CloudResults/tour-video-recording.mp4 &
record_pid=$!
echo "recordVideo pid: $record_pid"
# Give the recorder a moment to attach before the test launches the app.
sleep 3

# The video test runs with its exit code CAPTURED, not fatal: the
# recording stop + attachment export below must run even when the
# test fails, so a failed capture still leaves its video behind.
set +e
xcodebuild -project ios-clone/OnBudget.xcodeproj -scheme OnBudget -configuration Debug \
  -destination "platform=iOS Simulator,id=$onbudget_simulator_id" \
  -derivedDataPath ios-clone/CloudResults/DerivedData -resultBundlePath ios-clone/CloudResults/tour-video.xcresult \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:OnBudgetUITests/OnBudgetUITests/testTourVideo \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= test-without-building
onbudget_test_status=$?
set -e
echo "xcodebuild video test exit status: $onbudget_test_status"

# Stop the recording (SIGINT finalizes the file) and wait for it.
kill -INT "$record_pid" 2>/dev/null || true
wait "$record_pid" 2>/dev/null || true
sleep 2
if [[ -s ios-clone/CloudResults/tour-video-recording.mp4 ]]; then
  echo "Recording saved:"
  ls -la ios-clone/CloudResults/tour-video-recording.mp4
  ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 ios-clone/CloudResults/tour-video-recording.mp4 || true
else
  echo "WARNING: tour-video-recording.mp4 is missing or empty." >&2
fi

# Export the test screenshots out of the result bundle so they are
# visible without opening the xcresult. Best effort only: the whole
# tour-video.xcresult is uploaded as the workflow artifact too,
# so a failed export must not fail the run.
mkdir -p ios-clone/CloudResults/Attachments
if xcrun xcresulttool export attachments --path ios-clone/CloudResults/tour-video.xcresult --output-path ios-clone/CloudResults/Attachments; then
  echo "Attachments exported to ios-clone/CloudResults/Attachments:"
  find ios-clone/CloudResults/Attachments -type f | head -50
else
  echo "WARNING: xcresulttool export attachments failed; the full tour-video.xcresult is still uploaded as the artifact." >&2
fi

if [[ "$onbudget_test_status" == 0 ]]; then
  echo "TOUR VIDEO RECORDING CAPTURED."
else
  echo "TOUR VIDEO TEST FAILED (xcodebuild exit $onbudget_test_status)." >echo "VIDEO TEST FAILED (xcodebuild exit $onbudget_test_status)." >&22
fi
exit "$onbudget_test_status"
