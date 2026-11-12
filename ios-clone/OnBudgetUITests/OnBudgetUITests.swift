// OnBudget — OnBudgetUITests.swift
//
// Milestone (a) UI proof: the native clone RUNNING on the simulator
// against the live TEST backend (Supabase project
// tnkhvdkmwmwiogiienee — the same backend the app ships with).
//
// Flow: launch; setUp signs out first if a previous test in this
// run left a session behind (the Supabase session persists across
// launches in the same run), so every test starts on the auth
// screen; then sign up a FRESH account (random email per run,
// generated password) — sign-ups are ON and email confirmation
// is ON in the live project (owner, Nov 12, 2026), so sign-up
// returns .needsConfirmation and the app shows "Check Your Email".
// The helper then confirms the fresh account via the Supabase Auth
// Admin API (service-role key baked into the test bundle at build
// time — UITestSecrets.swift, generated in CI from the
// SUPABASE_SERVICE_ROLE_KEY secret; never logged, never hard-coded)
// and signs in with the same credentials; the @example.com address can never
// receive the confirmation email, so there is no other path.
//   Then join the TEST household "Proof Household 2" as a member via
//      invite code Q6GFME. Never the real household, never the
//      owner's account. (The test admin account's password is lost;
//      nothing here depends on it.)
//   Assert Home renders (Weekly Budget card), Transactions loads
//      rows (the test household holds ~1000 rows — assert non-empty,
//      not an exact count), and Funds renders (Extra Fund + Charity).
//   `testPastWeeksAndActivitySubpages` reuses the same preamble
//   and proves the Transactions "Past Weeks" / "Activity"
//   links push their subpages and Back returns to the list.
//   `testPlaidSandboxConnect` instead CREATES a fresh household
//   (the new account is its admin — only an admin can connect a
//   bank) and drives Plaid Link against Plaid Sandbox; its HARD
//   assertion is the Link sheet opening, the Sandbox drive after
//   that is best-effort (see that test).
//
// testPlaidSandboxConnect: fresh sign-up, CREATE a fresh household
// (the new account is its admin — only an admin can connect a bank;
// the test admin account's password is lost, so Proof Household 2
// cannot be used for this), open Settings → Bank Connection, tap
// Connect New Account, and drive Plaid Link against Plaid Sandbox
// (First Platypus Bank, user_good / pass_good — Plaid's public
// Sandbox test credentials). HARD assertion: the Link sheet opens
// (a Link webview appears). The Sandbox drive after that is
// best-effort: Plaid owns the webview tree, so each step proceeds
// only if its element is found, screenshots record how far it got,
// and the test still passes on sheet-open alone. If the drive
// completes, the test additionally asserts the "Connected" toast,
// Sync Transactions finishing ("Last synced"), and transaction rows
// appearing — that is the full-connect proof.
//
//   Run 42746242404 (Nov 10, 2026) diagnosis — the drive stopped
//   BEFORE any Sandbox step, and the recorded failure was a
//   screenshot, not the search wait: the Link webview existed in
//   the AX tree ~2s after tapping Connect, but the plaid-04
//   screenshot still showed Settings ("Connecting…") 8s later —
//   the sheet never became visible — and every existence poll on
//   the webview's descendants then blocked ~60s on a snapshot of
//   the WebContent process. The drive now probes presentation
//   first (the webview never becomes hittable within 30s of
//   appearing → .sheetNotPresented, without touching the webview
//   interior),
//   polls the first pane in short slices over several plausible
//   queries, and screenshots via XCUIScreen so a wedged webview
//   can no longer fail the test from a screenshot. Whether the
//   sheet never presented (app/LinkKit) or the page never loaded
//   (Plaid CDN / simulator) is still open — the launcher now logs
//   Link open/load events (see PlaidLinkKitLauncher) so the next
//   run's diagnostics can tell them apart.
//
// Each CI run creates fresh synthetic test accounts/households; that
// is the accepted cost of a live proof, the same as the prior web
// proofs. Screenshots are attached at every step with lifetime
// .keepAlways so the CI script can export them from the xcresult as
// visible proof the app ran.
//
// Timeouts are generous on purpose: the first launch boots the app
// and each step waits on a live network round-trip. The whole test
// should land in a few minutes; the workflow timeout is 40 min.

import XCTest

final class OnBudgetUITests: XCTestCase {
    private var app: XCUIApplication!

    // TEST BACKEND ONLY — Proof Household 2 invite code.
    private let testInviteCode = "Q6GFME"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The CI script opens onbudget://gmail-callback before the
        // tests (Gmail scheme check). iOS answers with a SpringBoard
        // "Open in 'OnBudget'?" alert, and XCTest's default
        // interruption handler taps Cancel — so the URL never
        // reaches the app (CI run 42746242404: the alert sat on the
        // auth screen and was cancelled at t=36s of the first
        // test). Answer Open instead, so the callback is delivered
        // and the app records it; testGmailCallbackDeepLink asserts
        // the record. The handler only claims that one alert.
        addUIInterruptionMonitor(withDescription: "Open in OnBudget") { alert in
            if alert.buttons["Open"].exists {
                alert.buttons["Open"].tap()
                return true
            }
            return false
        }
        app.launch()
        // A previous test in this run may have left a session behind:
        // XCTest runs tests alphabetically, so the first test signs
        // in and the next launches open straight into the signed-in
        // shell (the Supabase session persists in the app sandbox
        // across launches in the same run). Every test must still
        // start from the auth screen with a FRESH account, so sign
        // out through the app's own Settings sign-out and wait for
        // the auth screen. No-op when the auth screen is already
        // showing (first launch on a fresh simulator).
        ensureSignedOut()
    }

    /// Leaves the app on the auth screen, signing out first when a
    /// previous test's session is still alive. See setUpWithError.
    private func ensureSignedOut() {
        let emailField = app.textFields["auth.email"]
        if emailField.waitForExistence(timeout: 10) { return }

        // No auth screen: the app must be signed in. The tab bar is
        // the proof — anything else (a stuck launch, an expired
        // session) is a state this helper cannot recover from, so
        // fail fast with the actual state instead of burning the
        // 60s auth wait in signUpFreshAccount.
        let homeTab = app.tabBars.buttons["tab.home"]
        XCTAssertTrue(
            homeTab.waitForExistence(timeout: 10),
            "Neither the auth screen nor the signed-in Home appeared within ~20s of launch — cannot start from a known state"
        )

        // Profile menu → Settings → Sign Out (the app's own
        // sign-out path; AppState.signOut dismisses Settings and
        // lands on the auth screen). The Profile card is first in
        // Settings, so its Sign Out button needs no scrolling.
        app.buttons["Profile"].tap()
        let settingsItem = app.buttons["Settings"]
        XCTAssertTrue(
            settingsItem.waitForExistence(timeout: 10),
            "Profile menu did not offer Settings"
        )
        settingsItem.tap()
        XCTAssertTrue(
            app.staticTexts["Bank Connection"].waitForExistence(timeout: 30),
            "Settings did not render (no Bank Connection card)"
        )
        let signOutButton = app.buttons["settings.signOut"]
        XCTAssertTrue(
            signOutButton.waitForExistence(timeout: 10),
            "Settings Profile card did not offer Sign Out"
        )
        signOutButton.tap()
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 60),
            "Auth screen did not appear within 60s of signing out of the previous test's session"
        )
    }

    func testSignUpJoinAndBrowse() throws {
        signUpAndJoinTestHousehold()

        // -- 6. Transactions loads rows ----------------------------------
        tapTab(identifier: "tab.transactions", label: "Transactions")
        let firstRow = app.buttons.matching(identifier: "transaction.row").firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 120),
            "Transactions did not load any rows within 120s (test household should hold ~1000 rows)"
        )
        let rowCount = app.buttons.matching(identifier: "transaction.row").count
        XCTAssertGreaterThan(rowCount, 0, "Transactions list is empty")
        attachScreenshot(named: "05-transactions")

        // -- 7. Funds renders --------------------------------------------
        tapTab(identifier: "tab.funds", label: "Funds")
        XCTAssertTrue(
            app.staticTexts["Extra Fund"].waitForExistence(timeout: 90),
            "Funds did not render (no Extra Fund card)"
        )
        XCTAssertTrue(
            app.staticTexts["Charity"].waitForExistence(timeout: 30),
            "Funds did not render (no Charity card)"
        )
        attachScreenshot(named: "06-funds")
    }

    /// Bottom tab bar (owner, Nov 11 2026): on iPad the system renders
    /// a plain TabView's tabs as a segmented control at the TOP —
    /// the "Home / Transactions / Funds segmented pill" that threw the
    /// owner off. `OnBudgetApp` registers `UseFloatingTabBar` = false
    /// so the traditional bottom tab bar is used on iPad too. This
    /// test pins the bar to the bottom of the screen and proves all
    /// three tabs switch content. NOTE: CI runs on an iPhone 16
    /// simulator (compact size class), where the bar is at the bottom
    /// with or without the flag — this test guards the placement on
    /// iPhone and the tab switching; the iPad rendering itself can
    /// only be proven on a real iPad.
    func testTabBarIsAtBottom() throws {
        signUpAndJoinTestHousehold()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(
            tabBar.waitForExistence(timeout: 30),
            "Tab bar missing on Home"
        )
        let screenHeight = app.windows.firstMatch.frame.height
        XCTAssertGreaterThan(screenHeight, 0, "No window frame to measure against")
        XCTAssertGreaterThan(
            tabBar.frame.minY, screenHeight * 0.5,
            "Tab bar is not at the bottom of the screen (minY \(tabBar.frame.minY) on a \(screenHeight)pt screen) — on iPad this is the top segmented control"
        )
        for identifier in ["tab.home", "tab.transactions", "tab.funds"] {
            XCTAssertTrue(
                app.tabBars.buttons[identifier].exists,
                "Tab bar is missing the \(identifier) tab"
            )
        }

        tapTab(identifier: "tab.transactions", label: "Transactions")
        XCTAssertTrue(
            app.staticTexts["Transactions"].waitForExistence(timeout: 30),
            "Transactions tab did not show the Transactions screen"
        )
        tapTab(identifier: "tab.funds", label: "Funds")
        XCTAssertTrue(
            app.staticTexts["Extra Fund"].waitForExistence(timeout: 30),
            "Funds tab did not show the Funds screen (no Extra Fund card)"
        )
        XCTAssertFalse(
            app.staticTexts["Weekly Budget"].exists,
            "Weekly Budget still showing after switching to Funds"
        )
        tapTab(identifier: "tab.home", label: "Home")
        XCTAssertTrue(
            app.staticTexts["Weekly Budget"].waitForExistence(timeout: 30),
            "Home tab did not return to the Weekly Budget card"
        )
        // The bar stays at the bottom after switching tabs.
        XCTAssertGreaterThan(
            app.tabBars.firstMatch.frame.minY, screenHeight * 0.5,
            "Tab bar left the bottom of the screen after switching tabs"
        )
        attachScreenshot(named: "07-tab-bar-bottom")
    }

    /// Gmail callback deep link (CI run 42746242404 finding): the
    /// script opens onbudget://gmail-callback?gmail=connected
    /// before the tests, which raises a SpringBoard "Open in
    /// 'OnBudget'?" alert. setUp's interruption monitor taps Open,
    /// so the URL is delivered and AppViewModel records it
    /// (persisted across launches). This test runs first
    /// (alphabetical), signs up + joins the test household, opens
    /// Settings → Email Alerts, and asserts the recorded callback
    /// line is shown. If iOS ever delivers the URL without the
    /// alert, the persisted record from the script-launched
    /// instance covers the same assertion.
    func testGmailCallbackDeepLink() throws {
        signUpAndJoinTestHousehold()

        app.buttons["Profile"].tap()
        let settingsItem = app.buttons["Settings"]
        XCTAssertTrue(
            settingsItem.waitForExistence(timeout: 15),
            "Profile menu did not offer Settings"
        )
        settingsItem.tap()
        XCTAssertTrue(
            app.staticTexts["Bank Connection"].waitForExistence(timeout: 30),
            "Settings did not render (no Bank Connection card)"
        )
        let callbackLine = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Gmail return:'")
        ).firstMatch
        XCTAssertTrue(
            callbackLine.waitForExistence(timeout: 30),
            "Email Alerts did not show the recorded Gmail callback (onbudget://gmail-callback was not delivered or not recorded)"
        )
        XCTAssertTrue(
            callbackLine.label.contains("Connected"),
            "Recorded Gmail callback is not 'Connected': \(callbackLine.label)"
        )
        attachScreenshot(named: "gmail-callback")
    }

    /// Past Weeks / Activity (Nov 9, 2026): the Transactions page
    /// links push PastWeeksView / ActivityView as subpages in the
    /// Transactions NavigationStack — the native equivalent of the
    /// web's full pages. The explainer line under each heading is
    /// the assertion (it is unique to the subpage; the title text
    /// alone could also match the link's label).
    func testPastWeeksAndActivitySubpages() throws {
        signUpAndJoinTestHousehold()

        tapTab(identifier: "tab.transactions", label: "Transactions")
        let firstRow = app.buttons.matching(identifier: "transaction.row").firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 120),
            "Transactions did not load any rows within 120s"
        )

        // -- Past Weeks pushes -------------------------------------------
        let pastWeeksLink = app.buttons["Past Weeks"]
        XCTAssertTrue(
            pastWeeksLink.waitForExistence(timeout: 15),
            "Past Weeks link missing on Transactions (shell did not supply the handler)"
        )
        pastWeeksLink.tap()
        XCTAssertTrue(
            app.staticTexts["Closed weeks, read-only. Tap a week to see its summary and its transactions."]
                .waitForExistence(timeout: 60),
            "Past Weeks subpage did not open"
        )
        attachScreenshot(named: "07-past-weeks")

        // -- Back returns to the Transactions list -----------------------
        app.buttons["Back"].tap()
        XCTAssertTrue(
            app.buttons.matching(identifier: "transaction.row").firstMatch
                .waitForExistence(timeout: 30),
            "Back from Past Weeks did not return to the Transactions list"
        )

        // -- Activity pushes ---------------------------------------------
        let activityLink = app.buttons["Activity"]
        XCTAssertTrue(
            activityLink.waitForExistence(timeout: 15),
            "Activity link missing on Transactions (shell did not supply the handler)"
        )
        activityLink.tap()
        XCTAssertTrue(
            app.staticTexts["Who did what, and when — not the transaction list."]
                .waitForExistence(timeout: 60),
            "Activity subpage did not open"
        )
        attachScreenshot(named: "08-activity")
    }

    // MARK: - Shared preamble

    /// Steps 1–5 of the milestone proof: launch → auth screen →
    /// sign up a fresh account → name step → join Proof Household 2
    /// as a member → Home renders. Shared by the browse + subpage
    /// tests; each test method gets its own fresh launch (and its own
    /// fresh account). The sign-up steps themselves live in
    /// `signUpFreshAccount()` below, shared with the Plaid test
    /// (which creates its own household instead of joining).
    private func signUpAndJoinTestHousehold() {
        signUpFreshAccount()

        // -- 4. Join Proof Household 2 as a member -----------------------
        let inviteField = app.textFields["household.inviteCode"]
        XCTAssertTrue(
            inviteField.waitForExistence(timeout: 90),
            "Household screen did not appear after sign-up (account creation or boot failed)"
        )
        attachScreenshot(named: "03-household-join")
        tapAndTypeText(inviteField, testInviteCode, fieldName: "household.inviteCode")
        dismissKeyboardIfPresent(focusedField: inviteField)
        app.buttons["household.joinAsMember"].tap()

        // -- 5. Home renders ---------------------------------------------
        XCTAssertTrue(
            app.staticTexts["Weekly Budget"].waitForExistence(timeout: 90),
            "Home did not render after joining the household (no Weekly Budget card)"
        )
        XCTAssertTrue(
            app.tabBars.buttons["tab.home"].exists
                || app.tabBars.buttons["Home"].exists,
            "Tab bar missing on Home"
        )
        attachScreenshot(named: "04-home")
    }

    func testPlaidSandboxConnect() throws {
        signUpFreshAccount()

        // -- Create a FRESH household (this account is its admin) --------
        // Proof Household 2 cannot be used here: only an admin can
        // connect a bank, and the test admin's password is lost.
        let createButton = app.buttons["household.createHousehold"]
        XCTAssertTrue(
            createButton.waitForExistence(timeout: 90),
            "Household screen did not appear after sign-up (account creation or boot failed)"
        )
        attachScreenshot(named: "plaid-01-household")
        createButton.tap()
        let nameField = app.textFields["household.nameField"]
        XCTAssertTrue(
            nameField.waitForExistence(timeout: 30),
            "Household name panel did not appear after Create Household"
        )
        tapAndTypeText(nameField, "Plaid Test", fieldName: "household.nameField")
        dismissKeyboardIfPresent(focusedField: nameField)
        app.buttons["household.createConfirm"].tap()
        XCTAssertTrue(
            app.staticTexts["Weekly Budget"].waitForExistence(timeout: 90),
            "Home did not render after creating the household"
        )
        attachScreenshot(named: "plaid-02-home")

        // -- Settings → Bank Connection ----------------------------------
        app.buttons["Profile"].tap()
        let settingsItem = app.buttons["Settings"]
        XCTAssertTrue(
            settingsItem.waitForExistence(timeout: 15),
            "Profile menu did not offer Settings"
        )
        settingsItem.tap()
        XCTAssertTrue(
            app.staticTexts["Bank Connection"].waitForExistence(timeout: 30),
            "Settings did not render (no Bank Connection card)"
        )
        attachScreenshot(named: "plaid-03-settings")

        // -- Connect → HARD assertion: the Link sheet opens --------------
        let connectButton = app.buttons["bank.connect"]
        XCTAssertTrue(
            connectButton.waitForExistence(timeout: 15),
            "Connect New Account button missing (admin-only — is this account admin?)"
        )
        connectButton.tap()
        let linkWebView = app.webViews.firstMatch
        XCTAssertTrue(
            linkWebView.waitForExistence(timeout: 90),
            "Plaid Link sheet did not open within 90s of tapping Connect (link-token fetch or LinkKit presentation failed — see plaid-04 screenshot)"
        )
        attachScreenshot(named: "plaid-04-link-open")

        // -- Sandbox drive (best effort; see file header) ----------------
        let outcome = drivePlaidSandbox()
        attachScreenshot(named: "plaid-09-after-sandbox")
        guard outcome == .connected else {
            XCTContext.runActivity(named: "Plaid Sandbox stopped at \(outcome.rawValue) — sheet-open is proven; full connect still needs a human/device run") { _ in }
            return
        }

        // -- Connected toast, sync, rows (only on a completed drive) -----
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Connected. Tap'")).firstMatch
        XCTAssertTrue(
            toast.waitForExistence(timeout: 90),
            "No 'Connected' toast after the Sandbox flow finished (exchange may have failed)"
        )
        attachScreenshot(named: "plaid-10-connected")
        app.buttons["bank.sync"].tap()
        let syncedLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Last synced'")).firstMatch
        XCTAssertTrue(
            syncedLine.waitForExistence(timeout: 180),
            "Sync did not finish within 180s (no 'Last synced' line in Settings)"
        )
        attachScreenshot(named: "plaid-11-synced")
        app.buttons["Back"].tap()
        tapTab(identifier: "tab.transactions", label: "Transactions")
        let firstRow = app.buttons.matching(identifier: "transaction.row").firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 120),
            "No transaction rows after Sync Transactions on the Sandbox-connected household"
        )
        attachScreenshot(named: "plaid-12-transactions")
    }

    func testForgotPasswordShowsConfirmation() throws {
        // Owner, Nov 12, 2026: tapping "Forgot Password?" must NEVER
        // send the email by itself — it opens the dedicated screen
        // with an email field + Reset Password button, and after
        // sending the sheet stays open on a "Check Your Email"
        // confirmation state. No sign-up needed: the test starts on
        // the auth screen. The address is fake — /recover answers
        // 200 generically without revealing whether it exists.
        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 60),
            "Auth screen did not appear: no email field within 60s of launch"
        )
        app.buttons["Forgot Password?"].tap()
        let forgotEmail = app.textFields["auth.forgotEmail"]
        XCTAssertTrue(
            forgotEmail.waitForExistence(timeout: 15),
            "Forgot-password screen did not open after tapping Forgot Password?"
        )
        // Nothing is sent yet: no confirmation text before pressing
        // the button.
        XCTAssertFalse(app.staticTexts["Check Your Email"].exists)
        tapAndTypeText(forgotEmail, "forgot-test@example.com", fieldName: "auth.forgotEmail")
        dismissKeyboardIfPresent(focusedField: forgotEmail)
        app.buttons["Send Reset Link"].tap()
        XCTAssertTrue(
            app.staticTexts["Check Your Email"].waitForExistence(timeout: 30),
            "No confirmation state after sending the reset link (the sheet should stay open on 'Check Your Email')"
        )
        attachScreenshot(named: "forgot-01-sent")
        XCTAssertTrue(app.buttons["Done"].exists)
        XCTAssertTrue(app.buttons["Send Again"].exists)
    }

    // MARK: - Shared sign-up

    /// Steps 1–3 of the proof: auth screen → fresh sign-up → name
    /// step. Leaves the test on the household choice screen.
    ///
    /// Email confirmation is ON (owner, Nov 12, 2026): sign-up
    /// returns .needsConfirmation, so after the name step the helper
    /// confirms the fresh account via the Supabase Auth Admin API
    /// and signs in with the same credentials. The service-role key
    /// comes from UITestSecrets.serviceRoleKey (CI generates
    /// UITestSecrets.swift from the SUPABASE_SERVICE_ROLE_KEY secret
    /// before building — the UI test runner inherits neither the
    /// step's environment nor the Mac runner's $HOME, so the key
    /// must travel inside the test bundle), falling back to the
    /// environment variable when present; when neither exists the
    /// test fails fast here instead of burning its 60–90s waits
    /// before failing at the same gate.
    private func signUpFreshAccount() {
        guard let serviceKey = Self.uiTestServiceKey(), !serviceKey.isEmpty else {
            XCTFail(
                "No service-role key reached the UI test runner: UITestSecrets.serviceRoleKey is empty and "
                + "SUPABASE_SERVICE_ROLE_KEY is not set in the test runner environment — "
                + "add it as a CI secret so the simulator workflow can generate UITestSecrets.swift. "
                + "Email confirmation is ON, so a fresh test account cannot sign in without being confirmed first."
            )
            return
        }

        // -- 1. Auth screen renders -------------------------------------
        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 60),
            "Auth screen did not appear: no email field within 60s of launch"
        )
        attachScreenshot(named: "01-auth")

        // -- 2. Sign up a fresh account ---------------------------------
        // Random email per run so re-runs never collide with a previous
        // run's account. example.com is unroutable, which is fine:
        // the account is confirmed via the Admin API below, never by
        // email.
        let runId = UUID().uuidString.lowercased().prefix(8)
        let email = "ios-clone-uitest-\(runId)@example.com"
        // >= 8 chars (AuthValidation.createAccountError); mixed case +
        // digits + symbol so it also satisfies any server-side rule.
        let password = "Uitests-\(runId)-2026!"
        tapAndTypeText(emailField, email, fieldName: "auth.email")
        let passwordField = app.secureTextFields["auth.password"]
        XCTAssertTrue(
            passwordField.waitForExistence(timeout: 10),
            "Password field missing on the auth screen"
        )
        tapAndTypeText(passwordField, password, fieldName: "auth.password")
        dismissKeyboardIfPresent(focusedField: passwordField)
        attachScreenshot(named: "02-auth-filled")

        app.buttons["auth.createAccount"].tap()

        // -- 3. Name step ------------------------------------------------
        let nameField = app.textFields["auth.name"]
        XCTAssertTrue(
            nameField.waitForExistence(timeout: 60),
            "Name step did not appear after Create Account (sign-up may have failed)"
        )
        tapAndTypeText(nameField, "UI Test", fieldName: "auth.name")
        dismissKeyboardIfPresent(focusedField: nameField)
        app.buttons["auth.createAccountConfirm"].tap()

        // -- 4. Confirm via the Admin API, then sign in -----------------
        // Sign-up with confirmation ON lands on the persistent
        // "Check Your Email" state (NameStepView.confirmationSent).
        XCTAssertTrue(
            app.staticTexts["Check Your Email"].waitForExistence(timeout: 60),
            "Check Your Email did not appear after Create Account (sign-up may have failed or confirmation may be off)"
        )
        guard confirmTestAccount(email: email, serviceKey: serviceKey) else { return }
        app.buttons["auth.backToSignIn"].tap()

        let signInEmail = app.textFields["auth.email"]
        XCTAssertTrue(
            signInEmail.waitForExistence(timeout: 30),
            "Sign-in screen did not appear after confirming the test account"
        )
        tapAndTypeText(signInEmail, email, fieldName: "auth.email")
        let signInPassword = app.secureTextFields["auth.password"]
        XCTAssertTrue(
            signInPassword.waitForExistence(timeout: 10),
            "Password field missing on the sign-in screen"
        )
        tapAndTypeText(signInPassword, password, fieldName: "auth.password")
        dismissKeyboardIfPresent(focusedField: signInPassword)
        app.buttons["auth.signIn"].tap()
    }

    /// Service-role key for the Admin-API confirm path. The UI test
    /// runner process does NOT inherit the xcodebuild shell's
    /// environment (proven by run 43247037525: the step env held the
    /// key — logged masked as *** — yet the runner saw nothing),
    /// and it runs inside the simulator, so it cannot read a file
    /// from the Mac runner's $HOME either (the 4bcad72 key file was
    /// also uncompilable: 'homeDirectoryForCurrentUser' is
    /// unavailable in iOS, run 43256312047). The key therefore
    /// travels inside the test bundle: CI overwrites the committed
    /// empty UITestSecrets.swift placeholder with a generated copy
    /// before building (see .github/workflows/ios-clone-simulator.yml).
    /// The environment variable stays as a fallback for a local run
    /// that injects it another way. The key is never logged.
    private static func uiTestServiceKey() -> String? {
        if !UITestSecrets.serviceRoleKey.isEmpty {
            return UITestSecrets.serviceRoleKey
        }
        if let fromEnv = ProcessInfo.processInfo.environment["SUPABASE_SERVICE_ROLE_KEY"],
           !fromEnv.isEmpty {
            return fromEnv
        }
        return nil
    }

    // MARK: - Admin-API confirmation (email confirmation is ON)

    /// Supabase Auth Admin API base for the live project (public
    /// URL, same project as the app's Configuration.supabaseURL).
    private static let supabaseAuthAdminBase = "https://tnkhvdkmwmwiogiienee.supabase.co/auth/v1/admin"

    /// Confirms the freshly signed-up test account: list users,
    /// match the email locally, then PUT email_confirm: true. The
    /// listUsers pattern (never getUserByEmail — it does not exist
    /// on supabase-js v2) is the same one the check-email-exists
    /// Edge Function uses. Returns false on failure (the caller
    /// returns early; the test is already marked failed). The key
    /// is never logged.
    private func confirmTestAccount(email: String, serviceKey: String) -> Bool {
        guard let userId = adminUserId(forEmail: email, serviceKey: serviceKey) else {
            XCTFail("Admin API: no user found for \(email) after sign-up — cannot confirm the test account")
            return false
        }
        var request = URLRequest(url: URL(string: "\(Self.supabaseAuthAdminBase)/users/\(userId)")!)
        request.httpMethod = "PUT"
        request.setValue(serviceKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email_confirm": true])
        let (status, _) = performAdminRequest(request)
        guard status == 200 else {
            XCTFail("Admin API confirm failed for \(email) (HTTP \(status))")
            return false
        }
        return true
    }

    /// Finds the fresh account's id via the Admin API list endpoint,
    /// polling briefly: the user row is created by sign-up, but the
    /// list must see it before the confirm can run. Returns nil when
    /// the user never appears.
    private func adminUserId(forEmail email: String, serviceKey: String) -> String? {
        let wanted = email.lowercased()
        for _ in 0..<15 {
            var request = URLRequest(url: URL(string: "\(Self.supabaseAuthAdminBase)/users?per_page=1000")!)
            request.setValue(serviceKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
            let (status, data) = performAdminRequest(request)
            if status == 200, let data,
               let json = try? JSONSerialization.jsonObject(with: data) {
                let users: [[String: Any]]?
                if let dict = json as? [String: Any] {
                    users = dict["users"] as? [[String: Any]]
                } else {
                    users = json as? [[String: Any]]
                }
                if let users,
                   let match = users.first(where: { ($0["email"] as? String)?.lowercased() == wanted }),
                   let id = match["id"] as? String {
                    return id
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
        return nil
    }

    /// Synchronous Admin API call (XCTest is synchronous): returns
    /// the HTTP status and body data, or (0, nil) on a transport
    /// error. The request — including the key in its headers — is
    /// never logged.
    private func performAdminRequest(_ request: URLRequest, timeout: TimeInterval = 15) -> (status: Int, data: Data?) {
        var result: (Int, Data?) = (0, nil)
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    // MARK: - Plaid Sandbox drive

    /// How far the best-effort Sandbox drive got. `.connected` means
    /// the Link sheet closed after the flow — the caller then checks
    /// the toast/sync/rows. Anything else is a diagnostic stop, not
    /// a test failure: the sheet-open assertion above already passed.
    /// `.sheetNotPresented` is the run-42746242404 stop: the Link
    /// webview existed in the AX tree but never became visible
    /// (Settings still showing, "Connecting…" still showing) and
    /// the webview's AX tree then wedged — every existence poll on
    /// its descendants blocked ~60s on a snapshot of the WebContent
    /// process, and app.screenshot() hung on the same tree
    /// (line 583).
    private enum PlaidSandboxOutcome: String {
        case connected
        case sheetNotPresented
        case noSearchField
        case noInstitutionResult
        case noCredentialFields
        case noSubmit
        case sheetStillOpen
    }

    /// Drives Plaid Link in the Sandbox with Plaid's public test
    /// credentials (First Platypus Bank, user_good / pass_good).
    /// Each step proceeds only if its element is found; a missing
    /// element stops the drive with the matching outcome.
    ///
    /// Two defences from run 42746242404, where the drive burned
    /// 687s and then failed on a screenshot:
    /// 1. Presentation is probed FIRST, on the webview leaf only
    ///    (never a descendant): if the webview never becomes
    ///    hittable within 30s of appearing, the sheet never
    ///    presented — stop there instead of querying a tree that
    ///    may be wedged.
    /// 2. The first-pane probe polls for ANY of several plausible
    ///    elements in short 5s slices (search text field, search
    ///    field, or an already-listed Platypus button) instead of
    ///    one 60s blind wait on a single query: on a wedged tree a
    ///    single waitForExistence never returns on time (each poll
    ///    blocked ~60s in that run). A slice can still block on a
    ///    wedged tree — public API offers no hard timeout — but the
    ///    test can no longer FAIL on it: screenshots now go through
    ///    XCUIScreen (see attachScreenshot), so the drive just
    ///    returns its diagnostic outcome.
    private func drivePlaidSandbox() -> PlaidSandboxOutcome {
        // -- 1. Is the Link sheet actually visible? -------------------
        // In run 42746242404 the webview existed in the AX tree but
        // nothing Plaid was on screen (Settings still visible,
        // "Connecting…" still showing), and every existence poll on
        // the webview's descendants then blocked ~60s on a snapshot
        // of the WebContent process. So probe the webview LEAF
        // only — never a descendant: poll up to 30s for the
        // webview to become hittable (i.e. presented and on
        // screen). If it never does, the sheet never presented —
        // stop here instead of querying a tree that may be wedged.
        // (Do NOT probe this via the Settings texts: covered
        // elements stay in the AX tree, so their `.exists` says
        // nothing about what is on screen.)
        let presentedDeadline = Date().addingTimeInterval(30)
        while Date() < presentedDeadline {
            if app.webViews.firstMatch.isHittable { break }
            Thread.sleep(forTimeInterval: 2)
        }
        if !app.webViews.firstMatch.isHittable {
            return .sheetNotPresented
        }

        // -- 2. First pane: search field, or institution already ----
        // listed (no search needed). Poll in short slices.
        let searchDeadline = Date().addingTimeInterval(90)
        var searchFieldFound = false
        var institutionListed = false
        while Date() < searchDeadline {
            if app.webViews.textFields.firstMatch.waitForExistence(timeout: 5) {
                searchFieldFound = true
                break
            }
            if app.webViews.searchFields.firstMatch.waitForExistence(timeout: 5) {
                searchFieldFound = true
                break
            }
            if app.webViews.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'Platypus'")
            ).firstMatch.waitForExistence(timeout: 5) {
                institutionListed = true
                break
            }
        }
        guard searchFieldFound || institutionListed else {
            return .noSearchField
        }
        if searchFieldFound {
            // Institution search: Link's first pane has a search field.
            let searchField = app.webViews.textFields.firstMatch.exists
                ? app.webViews.textFields.firstMatch
                : app.webViews.searchFields.firstMatch
            tapAndTypeText(searchField, "First Platypus Bank", fieldName: "plaid.search")
        }
        let institution = app.webViews.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Platypus'")
        ).firstMatch
        guard institution.waitForExistence(timeout: 30) else {
            return .noInstitutionResult
        }
        institution.tap()

        // Credentials pane: username + password. Some flows show an
        // interstitial first; if the fields are not there yet, try a
        // Continue button once, then look again.
        if !credentialFieldsExist(timeout: 45) {
            if tapWebButtonContaining("Continue", timeout: 15) {
                attachScreenshot(named: "plaid-05-interstitial")
            }
            guard credentialFieldsExist(timeout: 45) else {
                return .noCredentialFields
            }
        }
        let usernameField = app.webViews.textFields.firstMatch
        let passwordField = app.webViews.secureTextFields.firstMatch
        tapAndTypeText(usernameField, "user_good", fieldName: "plaid.username")
        tapAndTypeText(passwordField, "pass_good", fieldName: "plaid.password")
        dismissKeyboardIfPresent(focusedField: passwordField)
        attachScreenshot(named: "plaid-06-credentials")

        let submit = app.webViews.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Submit'")
        ).firstMatch
        guard submit.waitForExistence(timeout: 15) else {
            return .noSubmit
        }
        submit.tap()
        attachScreenshot(named: "plaid-07-submitted")

        // Account select / success panes: tap Continue while one is
        // offered, and return as soon as the sheet closes. Poll
        // rather than blocking on a single wait, so a flow that goes
        // straight to success does not burn a full timeout.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if !app.webViews.firstMatch.exists {
                return .connected
            }
            let cont = app.webViews.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'Continue'")
            ).firstMatch
            if cont.exists {
                cont.tap()
                attachScreenshot(named: "plaid-08-continue")
            }
            Thread.sleep(forTimeInterval: 2)
        }
        return .sheetStillOpen
    }

    private func credentialFieldsExist(timeout: TimeInterval) -> Bool {
        let usernameField = app.webViews.textFields.firstMatch
        let passwordField = app.webViews.secureTextFields.firstMatch
        return usernameField.waitForExistence(timeout: timeout)
            && passwordField.waitForExistence(timeout: 10)
    }

    /// Taps the first webview button whose label contains `text`.
    /// Returns false when none appears within `timeout`.
    @discardableResult
    private func tapWebButtonContaining(_ text: String, timeout: TimeInterval) -> Bool {
        let button = app.webViews.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", text)
        ).firstMatch
        guard button.waitForExistence(timeout: timeout) else { return false }
        button.tap()
        return true
    }

    // MARK: - Helpers

    /// Tab-bar buttons carry both the identifier (tab.*) and the
    /// visible label; prefer the identifier, fall back to the label.
    private func tapTab(identifier: String, label: String) {
        let byIdentifier = app.tabBars.buttons[identifier]
        if byIdentifier.waitForExistence(timeout: 15) {
            byIdentifier.tap()
            return
        }
        let byLabel = app.tabBars.buttons[label]
        XCTAssertTrue(
            byLabel.waitForExistence(timeout: 15),
            "Tab bar button \(label) (\(identifier)) not found"
        )
        byLabel.tap()
    }

    /// Tap a field and type into it only once it actually holds
    /// keyboard focus. A bare tap() + typeText() is racy: the tap can
    /// land while the field is still becoming first responder, and
    /// typeText then fails with "Neither element nor any descendant
    /// has keyboard focus", burning ~60s on XCTest's internal event
    /// retry before failing. So: tap, poll for the software keyboard
    /// to appear, retry the tap, and only then type. Fails fast with
    /// a clear message when focus never arrives.
    ///
    /// Focus is checked via the software keyboard, not via
    /// `hasKeyboardFocus`: that property does not exist on
    /// XCUIElement in this toolchain (Xcode 16.4) — the compiler
    /// rejects it (CI run 42736133920). A visible software keyboard
    /// means the tapped field holds focus.
    private func tapAndTypeText(_ field: XCUIElement, _ text: String, fieldName: String) {
        for _ in 1...3 {
            field.tap()
            if waitForKeyboardFocus(field, timeout: 5) {
                // Clear first: Remember-me pre-fills the email field from the
                // previous test's sign-in, so typing without clearing would
                // append and produce an invalid email.
                if let current = field.value as? String, !current.isEmpty {
                    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
                }
                field.typeText(text)
                return
            }
        }
        XCTFail("Field \(fieldName) never gained keyboard focus after 3 taps — cannot type")
    }

    /// Polls for the software keyboard to appear until `timeout`
    /// elapses. A visible keyboard means the tapped field holds
    /// keyboard focus. (`hasKeyboardFocus` does not exist on
    /// XCUIElement in this toolchain, so the keyboard is the only
    /// public-API proxy for focus. No KVC / private API is used.)
    private func waitForKeyboardFocus(_ field: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.keyboards.element.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return app.keyboards.element.exists
    }

    /// Tap Return if the software keyboard is up, so it cannot cover
    /// the button the test needs next. No-op when no keyboard shows.
    /// If Return did not dismiss it, typing a newline into the
    /// focused field submits it, which dismisses the keyboard.
    ///
    /// The newline fallback MUST only fire while the field still
    /// holds keyboard focus: tapping Return usually resigns the
    /// field, so by the time the keyboard is animating away the
    /// field is already unfocused — and typing into it fails event
    /// synthesis ("Neither element nor any descendant has keyboard
    /// focus"). That unguarded typeText("\n") is what killed all
    /// three UI tests in CI run 42733065258: the name field had
    /// already been typed into successfully ("UI Test"), then
    /// Return resigned it and the fallback typed into a field
    /// without focus.
    private func dismissKeyboardIfPresent(focusedField: XCUIElement? = nil) {
        guard app.keyboards.element.exists else { return }
        var attemptedDismiss = false
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.exists {
            returnKey.tap()
            attemptedDismiss = true
            // Return usually resigns the field, but the keyboard
            // takes a moment to animate away. Give it a brief grace
            // period to disappear before deciding the field is still
            // focused: typing "\n" into a field that already resigned
            // fails event synthesis. Only if the keyboard is STILL up
            // after that grace period is the field still first
            // responder — a visible keyboard is the public-API proxy
            // for focus (`hasKeyboardFocus` does not exist on
            // XCUIElement in this toolchain) — and only then is the
            // newline fallback safe. If the keyboard went away, the
            // dismiss already worked and there is nothing more to do.
            let graceDeadline = Date().addingTimeInterval(1)
            while Date() < graceDeadline, app.keyboards.element.exists {
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard app.keyboards.element.exists else { return }
        }
        if let focusedField, app.keyboards.element.exists {
            focusedField.typeText("\n")
            attemptedDismiss = true
        }
        guard attemptedDismiss else { return }
        // Give the keyboard a moment to finish dismissing before
        // the caller taps the next button; a bounded wait for the
        // condition, not a fixed sleep.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, app.keyboards.element.exists {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Screenshots go through XCUIScreen, NOT app.screenshot():
    /// app.screenshot() resolves the app's accessibility snapshot,
    /// and a wedged WKWebView (Plaid Link, CI run 42746242404)
    /// hangs that snapshot for 60s+ per try — the test then failed
    /// AT this line (OnBudgetUITests.swift:583, "Failed to get
    /// matching snapshot ... XCTPerformOnMainRunLoop work timed out
    /// after 60.0s") after the drive had already returned its
    /// diagnostic outcome. The screen capture does not need the
    /// AX tree, so a stuck webview can no longer fail the test
    /// from a screenshot.
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
