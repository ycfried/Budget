#!/bin/bash
# OnBudget iOS clone — build + test in an iOS simulator.
# Adapted from the proven pattern on branch ios-native-rebuild
# (ios/scripts/macos_simulator_test.sh). Inert until explicitly run
# on a Mac. No signing, deployment, downloads or providers.
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
# Capture the complete output before checking: head can close Xcode's pipe early.
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
xcrun swift test --package-path ios-clone/OnBudgetKit --scratch-path ios-clone/CloudResults/CoreBuild --jobs 4

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

onbudget_simulator_id="$(xcrun simctl create "OnBudget-clone-${GITHUB_RUN_ID:-local}" com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$onbudget_runtime")"
cleanup() {
  xcrun simctl shutdown "$onbudget_simulator_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$onbudget_simulator_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$onbudget_simulator_id"
xcrun simctl bootstatus "$onbudget_simulator_id" -b

# Do not overwrite results from an earlier local run.
[[ ! -e ios-clone/CloudResults/build.xcresult && ! -e ios-clone/CloudResults/tests.xcresult ]] || {
  echo 'FAIL: result bundles already exist. Preserve/remove them explicitly before rerunning.' >&2; exit 1;
}
xcodebuild -project ios-clone/OnBudget.xcodeproj -scheme OnBudget -configuration Debug \
  -destination "platform=iOS Simulator,id=$onbudget_simulator_id" \
  -destination-timeout 60 -derivedDataPath ios-clone/CloudResults/DerivedData \
  -resultBundlePath ios-clone/CloudResults/build.xcresult -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build-for-testing

# Prove the onbudget URL scheme landed in the built product: the
# built app's Info.plist must list it under CFBundleURLTypes.
# (A plain grep would pass on the bundle id alone, so parse the plist.)
onbudget_app_path="ios-clone/CloudResults/DerivedData/Build/Products/Debug-iphonesimulator/OnBudget.app"
python3 - "$onbudget_app_path/Info.plist" <<'PY'
import plistlib
import sys
info = plistlib.load(open(sys.argv[1], 'rb'))
schemes = [s for t in info.get('CFBundleURLTypes', []) for s in t.get('CFBundleURLSchemes', [])]
if 'onbudget' not in schemes:
    # Dump what the built plist actually contains before failing, so
    # the next failure shows the real state instead of just None.
    print(f"FAIL: onbudget scheme missing from built Info.plist; top-level keys: {sorted(info)}", file=sys.stderr)
    print(f"CFBundleURLTypes value: {info.get('CFBundleURLTypes')!r}", file=sys.stderr)
    print(f"Full built Info.plist: {info!r}", file=sys.stderr)
    raise SystemExit(1)
print(f"Built Info.plist URL schemes: {schemes}")
PY

# Prove the scheme opens the app on the simulator: simctl openurl
# fails when no app handles the URL, so an exit 0 here means the
# OS routes onbudget://gmail-callback to OnBudget. (Full Google
# consent cannot run on CI — it needs a real Google account and the
# not-yet-deployed server redirect change; this proves the
# registration + the app-level deep-link route only.)
xcrun simctl install "$onbudget_simulator_id" "$onbudget_app_path"
xcrun simctl launch "$onbudget_simulator_id" com.onbudget.app
xcrun simctl openurl "$onbudget_simulator_id" "onbudget://gmail-callback?gmail=connected"

xcodebuild -project ios-clone/OnBudget.xcodeproj -scheme OnBudget -configuration Debug \
  -destination "platform=iOS Simulator,id=$onbudget_simulator_id" \
  -derivedDataPath ios-clone/CloudResults/DerivedData -resultBundlePath ios-clone/CloudResults/tests.xcresult \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= test-without-building
xcrun xcresulttool get test-results summary --path ios-clone/CloudResults/tests.xcresult > ios-clone/CloudResults/test-summary.json
python3 - <<'PY'
import json
from pathlib import Path
summary = json.loads(Path('ios-clone/CloudResults/test-summary.json').read_text())
assert summary.get('totalTestCount', 0) >= 2, 'Tests did not execute'
assert summary.get('failedTests') == 0, 'Test failures or unknown result schema'
assert summary.get('skippedTests') == 0, 'Skipped tests or unknown result schema'
assert summary.get('passedTests', 0) >= 2, 'No positive pass count'
print(json.dumps(summary, indent=2))
PY

# Export the UI-test screenshots/attachments out of the test result
# bundle so they are visible without opening the xcresult. Best
# effort only: the whole tests.xcresult is uploaded as the workflow
# artifact too, so a failed export must not fail the run.
mkdir -p ios-clone/CloudResults/Attachments
if xcrun xcresulttool export attachments --path ios-clone/CloudResults/tests.xcresult --output-path ios-clone/CloudResults/Attachments; then
  echo "Attachments exported to ios-clone/CloudResults/Attachments:"
  find ios-clone/CloudResults/Attachments -type f | head -50
else
  echo "WARNING: xcresulttool export attachments failed; the full tests.xcresult is still uploaded as the artifact." >&2
fi
