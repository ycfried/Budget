#!/bin/bash
# Inert until explicitly run on a Mac. No signing, deployment, downloads or providers.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'BLOCKED: Xcode and an iOS simulator require macOS.' >&2
  exit 2
fi
if [[ "${ONBUDGET_APPROVED_WORKFLOW:-0}" == 1 ]]; then
  python3 ios/scripts/check_safety.py --approved-cloud-workflow
else
  python3 ios/scripts/check_safety.py
fi
if [[ -n "${GITHUB_SHA:-}" && "$(git rev-parse HEAD)" != "$GITHUB_SHA" ]]; then
  echo 'FAIL: checkout no longer matches the approved push SHA.' >&2
  exit 1
fi
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
[[ -d "$DEVELOPER_DIR" ]] || { echo 'FAIL: reviewed Xcode 16.4 not installed; no fallback or download.' >&2; exit 1; }
xcodebuild -version
xcodebuild -version | head -n 1 | /usr/bin/grep -qx 'Xcode 16.4'
mkdir -p ios/CloudResults
python3 ios/scripts/validate_project.py
xcrun swift test --package-path ios --scratch-path ios/CloudResults/CoreBuild --jobs 4
xcrun simctl list runtimes --json > ios/CloudResults/runtimes.json
python3 - <<'PY'
import json
from pathlib import Path
runtimes=json.loads(Path('ios/CloudResults/runtimes.json').read_text())['runtimes']
assert any(r['identifier']=='com.apple.CoreSimulator.SimRuntime.iOS-18-5' and r.get('isAvailable') for r in runtimes), 'Required installed iOS 18.5 runtime missing; do not download one.'
PY
onbudget_simulator_id="$(xcrun simctl create "OnBudget-isolated-${GITHUB_RUN_ID:-local}" com.apple.CoreSimulator.SimDeviceType.iPhone-16 com.apple.CoreSimulator.SimRuntime.iOS-18-5)"
cleanup() {
  xcrun simctl shutdown "$onbudget_simulator_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$onbudget_simulator_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$onbudget_simulator_id"
xcrun simctl bootstatus "$onbudget_simulator_id" -b
# Do not overwrite results from an earlier local run.
[[ ! -e ios/CloudResults/build.xcresult && ! -e ios/CloudResults/tests.xcresult ]] || {
  echo 'FAIL: result bundles already exist. Preserve/remove them explicitly before rerunning.' >&2; exit 1;
}
xcodebuild -project ios/OnBudget.xcodeproj -scheme OnBudget -configuration Debug \
  -destination "platform=iOS Simulator,id=$onbudget_simulator_id" \
  -destination-timeout 60 -derivedDataPath ios/CloudResults/DerivedData \
  -resultBundlePath ios/CloudResults/build.xcresult -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build-for-testing
xcodebuild -project ios/OnBudget.xcodeproj -scheme OnBudget -configuration Debug \
  -destination "platform=iOS Simulator,id=$onbudget_simulator_id" \
  -derivedDataPath ios/CloudResults/DerivedData -resultBundlePath ios/CloudResults/tests.xcresult \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= test-without-building
xcrun xcresulttool get test-results summary --path ios/CloudResults/tests.xcresult > ios/CloudResults/test-summary.json
python3 - <<'PY'
import json
from pathlib import Path
summary=json.loads(Path('ios/CloudResults/test-summary.json').read_text())
assert summary.get('totalTestCount',0)>=2, 'UI tests did not execute'
assert summary.get('failedTests')==0, 'UI failures or unknown result schema'
assert summary.get('skippedTests')==0, 'Skipped UI tests or unknown result schema'
assert summary.get('passedTests',0)>=2, 'No positive UI pass count'
print(json.dumps(summary,indent=2))
PY
