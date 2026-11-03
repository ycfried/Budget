# First cloud compilation — inactive draft, owner approval required

No workflow has been created or activated. All production safeguards still apply.
The proposal uses the public repository's **standard** GitHub-hosted Intel macOS
runner, existing GitHub Actions, and a checked-in Xcode project. No Mac purchase,
Apple membership/signing access, secrets, paid runner or third-party build service
is required for an unsigned simulator build.

## Cost and included usage

Read-only GitHub repository metadata reports ycfried/Budget public. Official GitHub
billing and runner documentation says standard hosted compute is free/unlimited
for public repositories. Expected compute charge for this proposal: **$0** while
that status and policy hold. A job-level check refuses private repositories.
Larger runners are billed even for public repos: none is used.

For context only, the current standard macOS listed rate outside that free case
is $0.062/minute; a 25-minute job would be $1.55 before any included credit.
Current documentation lists private-repository included compute as $12/month on
Free, $18/month on Pro/Team (not an assumption about this account's subscription
or remaining credit). Private use is not authorized and this draft skips it.

Artifacts/storage have separate limits. This first proof uploads no artifacts,
creates no caches, and uses console logs only; .xcresult stays on the ephemeral
runner. No paid storage, subscriptions or settings changes are requested.
A later artifact-upload proposal needs quota review and approval.

## Why this is not workflow_dispatch

GitHub requires workflow_dispatch's file to exist on the default branch. Main must
remain untouched, so a dispatch-only workflow placed solely on ios-native-rebuild
would not be a reliable first-build route. Instead, the candidate below handles
pushes only to ios-native-rebuild and allocates a Mac only when the head commit
message starts with `ci(ios): approved cloud build`. Ordinary branch pushes skip
the job. The marker is an operational convention, not an independent authorization
system: never create a marked push without owner approval.

## Exact approval requested

Allow one exception to the ios/-only write restriction: create ONLY
`.github/workflows/onbudget-ios-sample.yml` ON ios-native-rebuild, matching the
candidate below. Do not alter existing workflows, main, settings, default branch,
Pages or deployment integrations. Authorize ONE activation push with the marker
and ONE standard free public macOS build (timeout 25 minutes); no automatic reruns.
If Actions is disabled or a policy prevents this action, stop and report the exact
setting that needs review; do not change settings as part of this approval.

The workflow gets contents:read only, an immutable checkout action, no retained Git
credential, no repository/Apple/provider secrets, no artifact upload, no deployment,
no signing, and no Supabase/staging/production network adapter. No third-party tool
installation occurs: the Xcode project is checked in and the Swift package is local.

## Candidate (documentation only)

```yaml
name: OnBudget isolated simulator proof
on:
  push:
    branches: [ios-native-rebuild]
    paths:
      - 'ios/**'
      - '.github/workflows/onbudget-ios-sample.yml'
permissions:
  contents: read
concurrency:
  group: onbudget-isolated-simulator
  cancel-in-progress: true
jobs:
  simulator:
    if: >-
      github.ref == 'refs/heads/ios-native-rebuild' &&
      github.event.repository.private == false &&
      startsWith(github.event.head_commit.message, 'ci(ios): approved cloud build')
    runs-on: macos-15-intel
    timeout-minutes: 25
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          ref: ios-native-rebuild
          fetch-depth: 0
          persist-credentials: false
      - name: Validate, compile and test synthetic app
        env:
          ONBUDGET_APPROVED_WORKFLOW: '1'
        run: bash ios/scripts/macos_simulator_test.sh
```

## Toolchain and test contract

Standard macos-15-intel is documented as 4 Intel CPUs / 14 GB RAM. The reviewed
runner image lists Xcode 16.4 at /Applications/Xcode_16.4.app, Swift 6, iOS 18.5
SDK/runtime. The script selects that exact Xcode/runtime and fails if absent;
it never silently changes SDK, downloads a simulator, or registers a capability.
A runner label still receives image updates, so log actual Xcode/image versions.

The script validates the project, runs all core tests, creates its own temporary
iPhone 16 simulator, builds app + embedded WidgetKit + UI-test runner, and runs the
shared scheme's UI tests. Only that created simulator is removed on exit.
No archive, export, upload, provisioning or Apple account API is invoked. Local
App Group entitlements are absent intentionally; widget cache sharing remains a
separate approval/device milestone, not a simulator-compilation prerequisite.

The script has not run on macOS here. Linux syntax tests, project generation, and
plist checks do not establish successful Xcode compilation or UI test execution.

## Official evidence

- [Billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [Runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)
- [Standard runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Dispatch requirement source](https://github.com/github/docs/blob/main/data/reusables/actions/workflow-dispatch.md)
- [Reviewed macOS image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)

Reviewed November 2, 2026 (America/New_York). Account billing balance, Actions
organization policy and workflow permissions were not inspected. Repository
visibility was read without credentials; no production service was accessed.
