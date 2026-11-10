# Simulator UI-test harness — notes (branch ios-clone-v66/simulator-uitests)

## What this adds

- **New XCUITest target `OnBudgetUITests`** (`com.apple.product-type.bundle.ui-testing`,
  `TEST_TARGET_NAME = OnBudget`, bundle id `com.onbudget.app.uitests`) in
  `ios-clone/OnBudget.xcodeproj`, added to the `OnBudget` scheme's Build and
  Test actions, so the existing `test-without-building` step in
  `macos_simulator_test.sh` runs it. New object ids use the unused 8x/9x
  24-hex families. `validate_project.py` updated to expect the three
  targets and to assert the UITests target is a ui-testing bundle for
  the app target.
- **Accessibility identifiers** (additive only, no visual/behaviour change):
  `auth.email`, `auth.password` (both the TextField and SecureField),
  `auth.signIn`, `auth.createAccount`, `auth.name`,
  `auth.createAccountConfirm`, `household.inviteCode`,
  `household.joinAsMember`, `household.createHousehold`, `tab.home`,
  `tab.transactions`, `tab.funds`, `home.weeklyBudget`,
  `transactions.countLine`, `transaction.row` (every row),
  `funds.extraFund`, `funds.charity`.
- **`ios-clone/OnBudgetUITests/OnBudgetUITests.swift`** — one test,
  `testSignUpJoinAndBrowse`, which on a fresh simulator: launches the
  app, signs up a FRESH account (`ios-clone-uitest-<8 hex>@example.com`,
  generated password), completes the name step as "UI Test", joins the
  TEST household **Proof Household 2** as a member via invite code
  `Q6GFME`, then asserts Home renders (Weekly Budget card), Transactions
  loads ≥ 1 row (test household holds ~1000 rows), and Funds renders
  (Extra Fund + Charity). Screenshots attached at each step
  (`01-auth`, `02-auth-filled`, `03-household-join`, `04-home`,
  `05-transactions`, `06-funds`) with lifetime `.keepAlways`.
  Tab taps prefer the `tab.*` identifier and fall back to the visible
  label. The keyboard is dismissed via Return, with a newline-submit
  fallback, so it cannot cover the button below a field.
- **`macos_simulator_test.sh`**: after the (unchanged) summary
  assertions, exports attachments from `tests.xcresult` into
  `ios-clone/CloudResults/Attachments` via
  `xcrun xcresulttool export attachments`. Best effort only — a failed
  export warns and the run still passes, because the whole
  `tests.xcresult` is uploaded as the artifact too.
- **Workflow** (scaffold branch only): `timeout-minutes` 25 → 40, plus an
  `actions/upload-artifact` step (`if: always()`) uploading
  `Attachments`, `tests.xcresult`, `test-summary.json`,
  `runtimes.json` (NOT `CloudResults/` wholesale — `DerivedData` lives
  there and would bloat the artifact).

## What the CI run proves (milestone a)

A green run proves the clone **builds, launches on a real simulator,
signs up against the live test backend, joins Proof Household 2, and
renders Home / Transactions (real rows) / Funds** — i.e. the app runs
end-to-end against live Supabase, not just compiles. The screenshots
in the artifact are the visible proof.

## What it cannot prove

- Anything about the REAL household or the owner's account: the test
  only ever touches Proof Household 2 with a fresh synthetic member.
- Plaid Link / Gmail OAuth (not exercised; needs Xcode/simulator
  wiring by the next phase).
- Push notifications, App Store review, or real-device behaviour.
- That the run is flake-free: it depends on live network + live
  Supabase latency; timeouts are generous (60–120s per wait) but a
  slow runner can still fail a wait. A failure needs the xcresult
  logs + screenshots to distinguish app bug from infra slowness.

## Verification limits (no local type-check)

There is no Xcode/Swift toolchain on this VM (`swiftc` is gone), so
nothing here was compiled locally. Checked instead: pbxproj braces /
parens balanced, every 24-hex reference resolves, three targets with
the right product types, `TEST_TARGET_NAME = OnBudget` present,
scheme XML well-formed (python `xml.etree` parse), edited Swift
files brace-balanced, and `validate_project.py` logic reviewed by
hand. **CI is the only type-check** — the first run of this branch
is the real verification of the pbxproj/scheme/test code.

## Run history

- **Run 42727052431 (FAILED, 11s)**: `validate_project.py` failed with
  `Missing PBX reference: 8D8D8D8D8D8D8D8D8D8D8D8D`. Root cause: the
  `add_uitests_target.py` script inserted the new `PBXContainerItemProxy`
  object immediately after the opening line of the existing proxy object,
  nesting it *inside* that object instead of as a sibling — so `plutil`
  never saw it as a top-level object. Fixed by moving the proxy block
  after the existing object's closing `};`. Lesson: the local
  line-regex reference check could not catch nesting — the project is
  now also checked with a brace-depth scan asserting every object
  entry sits at depth 2 inside `objects {}`. The upload-artifact step
  ran on this failed run and warned (correctly) that no result files
  existed yet.

## Test-data note

Each CI run creates exactly one fresh synthetic member in Proof
Household 2 (a new `ios-clone-uitest-*@example.com` account). That is
accepted and matches the prior web proofs. No test account is ever
created in the real household.
