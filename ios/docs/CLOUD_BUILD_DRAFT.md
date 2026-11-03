# Inactive macOS cloud build proposal — review required

This Markdown file is documentation, not an installed workflow. Nothing is under
.github/workflows and no build service, runner, billing or Apple action is enabled.
Do not copy/activate it without explicit owner approval of triggers, permissions,
runner cost, toolchain and production isolation.

Proposed initial trigger: manual workflow_dispatch on ios-native-rebuild only.
Permissions: contents:read only. No write permissions, deployment environment,
production endpoints, staging credentials, secrets, signing or Apple submissions.
GitHub-hosted macOS minutes may be billable; confirm the repository plan and budget
before activation. Cancel superseded runs and use a 20-minute timeout.

Proposed steps (pseudocode, intentionally not executable YAML):

1. Verify the triggering ref is refs/heads/ios-native-rebuild; otherwise fail.
2. Check out that exact SHA using a reviewed commit-pinned checkout action with
   persist-credentials false. No pull_request_target and no production secrets.
3. Select a reviewed macOS image and exact supported Xcode path (do not depend
   on the host default). Check installed SDK/simulator availability and print versions.
4. Run the checked-in branch/path/credential guard after fetching main read-only.
5. Run cd ios && swift test --jobs 4; retain test output. No external dependencies.
6. Use a reviewed checksum-pinned XcodeGen installation, generate ios/project.yml.
   Current project disables signing and uses only the local Swift package.
7. Choose an installed simulator UUID with xcodebuild -showdestinations; fail if
   none satisfies the declared deployment target, do not pick a nonexistent name.
8. Build-for-testing and test-without-building using commands in ios/README.md.
   No archive/export/upload and no App Store Connect key. No Supabase connection.
9. Retain redacted .xcresult/build reports for 7 days with a reviewed pinned
   artifact action. Do not upload credentials, simulator keychains or app user data.
10. Report core test counts separately from UI/simulator results. A syntax parse
    is not an Xcode build; a successful build is not a device/signing test.

Future PR triggers, caches, dependency updates, signed archives, TestFlight uploads,
App Groups and staging integration jobs each require separate review. Staging must
use synthetic-only users/data and a fail-closed project allowlist; production must
not be reachable by the test adapter. Any future signing job must use protected
release controls and owner-approved costs. No Apple actions are authorized now.

Review checklist: manual-only trigger; branch restriction; exact toolchain; action
pins; contents read only; timeout/concurrency; billable minutes; artifact retention;
no production URLs or credentials; no signing/deploy/upload; owner activation approval.
