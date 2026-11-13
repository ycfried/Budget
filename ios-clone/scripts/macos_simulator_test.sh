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

# Gmail callback check, part 1 — scheme + OS routing (LOUD, so the
# run log shows it ran; run 42746242404's silent simctl lines were
# mistaken for a missing check).
#
# What simctl openurl proves here — and what it does NOT prove:
# an exit 0 means the OS routes onbudget://gmail-callback to
# OnBudget. It does NOT prove the app received the URL: iOS
# answers with a SpringBoard "Open in 'OnBudget'?" prompt, and
# nothing taps it here — in run 42746242404 that prompt sat on the
# auth screen until XCTest's default handler CANCELLED it in the
# first UI test, so the URL never reached the app. Delivery is
# proven by the UI tests instead: setUp's interruption monitor
# taps Open on that prompt, the app records the callback
# (AppViewModel.handleGmailDeepLink, persisted to UserDefaults),
# and testGmailCallbackDeepLink asserts the record in Settings →
# Email Alerts. Part 2 below re-asserts the persisted record
# after the tests.
# (Full Google consent cannot run on CI — it needs a real Google
# account and the not-yet-deployed server redirect change.)
echo "=== Gmail callback check, part 1: OS routing ==="
echo "Installing OnBudget.app on $onbudget_simulator_id ..."
xcrun simctl install "$onbudget_simulator_id" "$onbudget_app_path"
echo "Launching com.onbudget.ios ..."
xcrun simctl launch "$onbudget_simulator_id" com.onbudget.ios
echo "Opening onbudget://gmail-callback?gmail=connected (expect a SpringBoard 'Open in ...?' prompt; the UI tests answer Open) ..."
xcrun simctl openurl "$onbudget_simulator_id" "onbudget://gmail-callback?gmail=connected"
echo "simctl openurl exit 0: the OS routes the onbudget scheme to OnBudget (delivery is proven by testGmailCallbackDeepLink)."

# The tests run with their exit code CAPTURED, not fatal: the old
# script ran under `set -e`, so a test failure (xcodebuild exit
# 65) aborted the script here and nothing after it ever ran. The
# Gmail check in part 2 must run even when the tests fail, and the
# run must still fail overall when they do — so each phase records
# its own status and the script exits non-zero at the end if any
# phase failed.
set +e
xcodebuild -project ios-clone/OnBudget.xcodeproj -scheme OnBudget -configuration Debug \
  -destination "platform=iOS Simulator,id=$onbudget_simulator_id" \
  -derivedDataPath ios-clone/CloudResults/DerivedData -resultBundlePath ios-clone/CloudResults/tests.xcresult \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= test-without-building
onbudget_test_status=$?
set -e
echo "xcodebuild test exit status: $onbudget_test_status"

onbudget_summary_status=0
if [[ -e ios-clone/CloudResults/tests.xcresult ]]; then
  xcrun xcresulttool get test-results summary --path ios-clone/CloudResults/tests.xcresult > ios-clone/CloudResults/test-summary.json || onbudget_summary_status=1
  python3 - <<'PY' || onbudget_summary_status=1
import json
from pathlib import Path
summary = json.loads(Path('ios-clone/CloudResults/test-summary.json').read_text())
assert summary.get('totalTestCount', 0) >= 2, 'Tests did not execute'
assert summary.get('failedTests') == 0, 'Test failures or unknown result schema'
# Skipped tests are ALLOWED (Nov 13, 2026): the sign-up test skips
# cleanly (XCTSkip) while Supabase's email rate limit is active —
# that is the designed behaviour, not a failure (the 429 must never
# fail the run). Only that one test has a skip path, and it fires
# solely on the HTTP 429 signal, so a skip cannot hide a real
# regression. The count is printed so a skip stays visible.
print(f"Skipped tests (designed 429 skip only): {summary.get('skippedTests')}")
assert summary.get('passedTests', 0) >= 2, 'No positive pass count'
print(json.dumps(summary, indent=2))
PY
else
  echo "FAIL: tests.xcresult is missing; cannot summarise the test run." >&2
  onbudget_summary_status=1
fi

# Gmail callback check, part 2 — the app recorded the outcome.
# Runs ALWAYS, even when the tests failed (that is the point: a
# failing UI run must not hide whether the deep link works). It
# re-opens the callback URL (exit 0 re-proves OS routing; the
# prompt it raises is unanswered and harmless — the simulator is
# deleted next) and then reads the record the app persisted when
# the UI-test delivery happened:
# onbudget.lastGmailCallback in the app's Preferences plist.
# A separate `if: always()` workflow step cannot do this: the
# script's EXIT trap deletes this simulator, so a later step
# would need a whole new simulator of its own.
echo "=== Gmail callback check, part 2: the app recorded the outcome (runs even when the tests failed) ==="
onbudget_gmail_status=0
xcrun simctl install "$onbudget_simulator_id" "$onbudget_app_path" || onbudget_gmail_status=1
xcrun simctl launch "$onbudget_simulator_id" com.onbudget.ios || onbudget_gmail_status=1
xcrun simctl openurl "$onbudget_simulator_id" "onbudget://gmail-callback?gmail=connected" || onbudget_gmail_status=1
echo "Re-opened the callback URL (OS routing re-proven)."
sleep 5
onbudget_container="$(xcrun simctl get_app_container "$onbudget_simulator_id" com.onbudget.ios data)" || onbudget_gmail_status=1
echo "App data container: $onbudget_container"
python3 - "$onbudget_container/Library/Preferences/com.onbudget.ios.plist" <<'PY' || onbudget_gmail_status=1
import plistlib
import sys
from pathlib import Path
plist_path = Path(sys.argv[1])
if not plist_path.exists():
    print(f"FAIL: no app Preferences plist at {plist_path} — the app never recorded a Gmail callback", file=sys.stderr)
    raise SystemExit(1)
info = plistlib.load(open(plist_path, 'rb'))
value = info.get('onbudget.lastGmailCallback')
print(f"App-recorded Gmail callback: {value!r}")
if value != 'connected':
    print("FAIL: expected 'connected' — the onbudget://gmail-callback URL was not delivered to, or not recorded by, the app (see testGmailCallbackDeepLink)", file=sys.stderr)
    raise SystemExit(1)
print("PASS: the app recorded the Gmail callback (onbudget.lastGmailCallback == 'connected').")
PY
if [[ "$onbudget_gmail_status" == 0 ]]; then
  echo "Gmail callback check: PASS."
else
  echo "Gmail callback check: FAIL (see above)." >&2
fi

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

# Fail the run if any phase failed — tests, summary, or the Gmail
# callback check (which already ran above even on test failure,
# so a failing UI run no longer hides the deep-link result).
onbudget_failed=0
if [[ "$onbudget_test_status" != 0 ]]; then
  echo "FAIL: UI tests failed (xcodebuild exit $onbudget_test_status)." >&2
  onbudget_failed=1
fi
if [[ "$onbudget_summary_status" != 0 ]]; then
  echo "FAIL: test-summary assertions failed." >&2
  onbudget_failed=1
fi
if [[ "$onbudget_gmail_status" != 0 ]]; then
  echo "FAIL: Gmail callback check failed." >&2
  onbudget_failed=1
fi
if [[ "$onbudget_failed" == 0 ]]; then
  echo "ALL CHECKS PASSED (tests + Gmail callback record)."
else
  echo "RUN FAILED (see failures above)." >&2
fi
exit "$onbudget_failed"
