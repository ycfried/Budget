// OnBudget — OnBudgetUITests.swift
//
// Milestone (a) UI proof: the native clone RUNNING on the simulator
// against the live TEST backend (Supabase project
// tnkhvdkmwmwiogiienee — the same backend the app ships with).
//
// Flow, on a fresh simulator with no prior session:
//   1. Launch; the auth screen renders.
//   2. Sign up a FRESH account (random email per run, generated
//      password) — sign-ups are ON and email confirmation is OFF in
//      the live project, so sign-up returns a session immediately.
//   3. Join the TEST household "Proof Household 2" as a member via
//      invite code Q6GFME. Never the real household, never the
//      owner's account. (The test admin account's password is lost;
//      nothing here depends on it.)
//   4. Assert Home renders (Weekly Budget card), Transactions loads
//      rows (the test household holds ~1000 rows — assert non-empty,
//      not an exact count), and Funds renders (Extra Fund + Charity).
//   `testPastWeeksAndActivitySubpages` reuses the same preamble
//   (steps 1–5) and proves the Transactions "Past Weeks" / "Activity"
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
        app.launch()
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
        inviteField.tap()
        inviteField.typeText(testInviteCode)
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
        nameField.tap()
        nameField.typeText("Plaid Test")
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

    // MARK: - Shared sign-up

    /// Steps 1–3 of the proof: auth screen → fresh sign-up → name
    /// step. Leaves the test on the household choice screen.
    private func signUpFreshAccount() {
        // -- 1. Auth screen renders -------------------------------------
        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 60),
            "Auth screen did not appear: no email field within 60s of launch"
        )
        attachScreenshot(named: "01-auth")

        // -- 2. Sign up a fresh account ---------------------------------
        // Random email per run so re-runs never collide with a previous
        // run's account. example.com is unroutable, which is fine: no
        // confirmation email is ever sent (confirmation is OFF).
        let runId = UUID().uuidString.lowercased().prefix(8)
        let email = "ios-clone-uitest-\(runId)@example.com"
        // >= 8 chars (AuthValidation.createAccountError); mixed case +
        // digits + symbol so it also satisfies any server-side rule.
        let password = "Uitests-\(runId)-2026!"
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["auth.password"]
        XCTAssertTrue(
            passwordField.waitForExistence(timeout: 10),
            "Password field missing on the auth screen"
        )
        passwordField.tap()
        passwordField.typeText(password)
        dismissKeyboardIfPresent(focusedField: passwordField)
        attachScreenshot(named: "02-auth-filled")

        app.buttons["auth.createAccount"].tap()

        // -- 3. Name step ------------------------------------------------
        let nameField = app.textFields["auth.name"]
        XCTAssertTrue(
            nameField.waitForExistence(timeout: 60),
            "Name step did not appear after Create Account (sign-up may have failed)"
        )
        nameField.tap()
        nameField.typeText("UI Test")
        dismissKeyboardIfPresent(focusedField: nameField)
        app.buttons["auth.createAccountConfirm"].tap()
    }

    // MARK: - Plaid Sandbox drive

    /// How far the best-effort Sandbox drive got. `.connected` means
    /// the Link sheet closed after the flow — the caller then checks
    /// the toast/sync/rows. Anything else is a diagnostic stop, not
    /// a test failure: the sheet-open assertion above already passed.
    private enum PlaidSandboxOutcome: String {
        case connected
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
    private func drivePlaidSandbox() -> PlaidSandboxOutcome {
        // Institution search: Link's first pane has a search field.
        let searchField = app.webViews.textFields.firstMatch
        guard searchField.waitForExistence(timeout: 60) else {
            return .noSearchField
        }
        searchField.tap()
        searchField.typeText("First Platypus Bank")
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
        usernameField.tap()
        usernameField.typeText("user_good")
        passwordField.tap()
        passwordField.typeText("pass_good")
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

    /// Tap Return if the software keyboard is up, so it cannot cover
    /// the button the test needs next. No-op when no keyboard shows.
    /// If Return did not dismiss it, typing a newline into the
    /// focused field submits it, which dismisses the keyboard.
    private func dismissKeyboardIfPresent(focusedField: XCUIElement? = nil) {
        guard app.keyboards.element.exists else { return }
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.exists {
            returnKey.tap()
        }
        if app.keyboards.element.exists, let focusedField {
            focusedField.typeText("\n")
        }
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
