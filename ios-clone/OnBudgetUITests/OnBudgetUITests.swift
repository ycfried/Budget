// STAGE — OnBudgetUITests.swift
//
// Milestone (a) UI proof: the native clone RUNNING on the simulator
// against the live TEST backend (Supabase project
// tnkhvdkmwmwiogiienee — the same backend the app ships with).
//
// Flow: launch; setUp signs out first if a previous test in this
// run left a session behind (the Supabase session persists across
// launches in the same run), so every test starts on the auth
// screen; then create a PRE-CONFIRMED account via the Supabase Auth
// Admin API (service-role key baked into the test bundle at build
// time — UITestSecrets.swift, generated in CI from the
// SUPABASE_SERVICE_ROLE_KEY secret; never logged, never hard-coded)
// and sign in with it in the app UI. No email is ever sent, so the
// Supabase sign-up rate limit cannot block the suite (build 53,
// audit W1: 8 public sign-ups per run died at the 429 gate and
// proved nothing past auth). Only testSignUpJoinAndBrowse still
// exercises the public sign-up flow (one sign-up per run): sign-up
// returns .needsConfirmation and the app shows "Check Your Email",
// the helper then confirms the fresh account via the Admin API and
// signs in with the same credentials; the @example.com address can
// never receive the confirmation email, so there is no other path.
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

    // TEST BACKEND ONLY — the test household the video tests join
    // ("Goldstein Household", invite XPKVGJ). Was "Simcha House!"
    // until Nov 19, 2026 — the name is a shared constant now, so a
    // rename can never silently break the video assertions again
    // (build 53, audit W1).
    private let videoHouseholdInviteCode = "XPKVGJ"
    private let videoHouseholdName = "Goldstein Household"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The CI script opens onbudget://gmail-callback before the
        // tests (Gmail scheme check). iOS answers with a SpringBoard
        // "Open in 'STAGE'?" alert, and XCTest's default
        // interruption handler taps Cancel — so the URL never
        // reaches the app (CI run 42746242404: the alert sat on the
        // auth screen and was cancelled at t=36s of the first
        // test). Answer Open instead, so the callback is delivered
        // and the app records it; testGmailCallbackDeepLink asserts
        // the record. The handler only claims that one alert.
        addUIInterruptionMonitor(withDescription: "Open in STAGE") { alert in
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

        // No auth screen: the app must be signed in. It is either on
        // Home (tab bar visible) or on the Household screen — a
        // previous test failed between sign-in and join, so the
        // account has no household yet. The Household screen has no
        // sign-out, so join the test household first and sign out
        // from Home. (Without this branch, one preamble failure
        // poisons the whole suite: every later setUp fails here,
        // run 44963752823 proved it — 11 tests died in setUp after
        // the first test left the app signed-in on the Household
        // screen.) A stuck launch or an expired session is a state
        // this helper cannot recover from, so fail fast with the
        // actual state instead of burning the 60s auth wait in
        // signUpFreshAccount.
        let homeTab = app.tabBars.buttons["tab.home"]
        if !homeTab.waitForExistence(timeout: 10) {
            let inviteField = app.textFields["household.inviteCode"]
            if inviteField.waitForExistence(timeout: 10) {
                tapAndTypeText(inviteField, testInviteCode, fieldName: "household.inviteCode")
                dismissKeyboardIfPresent(focusedField: inviteField)
                app.buttons["household.joinAsMember"].tap()
                XCTAssertTrue(
                    app.staticTexts["Weekly Budget"].waitForExistence(timeout: 90),
                    "Home did not render after joining the test household from setUp recovery"
                )
            } else {
                XCTFail("Neither the auth screen, the signed-in Home, nor the Household screen appeared within ~30s of launch — cannot start from a known state")
                return
            }
        }

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
        signInAndJoinTestHousehold()

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
    /// 'STAGE'?" alert. setUp's interruption monitor taps Open,
    /// so the URL is delivered and AppViewModel records it
    /// (persisted across launches). This test runs first
    /// (alphabetical), signs up + joins the test household, opens
    /// Settings → Email Alerts, and asserts the recorded callback
    /// line is shown. If iOS ever delivers the URL without the
    /// alert, the persisted record from the script-launched
    /// instance covers the same assertion.
    func testGmailCallbackDeepLink() throws {
        signInAndJoinTestHousehold()

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

    /// Export (build 45, Nov 18, 2026): the Transactions page's
    /// "Export" chip opens the full-screen export popup; Generate
    /// builds the file for the chosen scope + format and opens the
    /// system share sheet. The test joins Proof Household 2 as a
    /// MEMBER, so the chip row holds Activity / Past Weeks / Export
    /// only (Review / Merchants / Trash are admin-only) and the
    /// chip is visible without scrolling. The popup fetches the
    /// whole history (~1000 rows) before it shows a count, so the
    /// count wait is generous. The share sheet's AirDrop section
    /// is the proof it presented (the popup's own Cancel button
    /// shares the "Cancel" label, so that label cannot prove the
    /// sheet). The second half re-proves the other scope + format:
    /// All + CSV.
    func testExportTransactions() throws {
        signInAndJoinTestHousehold()

        tapTab(identifier: "tab.transactions", label: "Transactions")
        let firstRow = app.buttons.matching(identifier: "transaction.row").firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 120),
            "Transactions did not load any rows within 120s"
        )

        // -- Export popup opens, history fetch shows a count --------
        // Build 53 (audit U2): Export lives in the "More" menu now.
        app.buttons["pageLinks.more"].tap()
        let exportChip = app.buttons["export.open"]
        XCTAssertTrue(
            exportChip.waitForExistence(timeout: 15),
            "Export chip missing on Transactions"
        )
        exportChip.tap()
        XCTAssertTrue(
            app.staticTexts["Export Transactions"].waitForExistence(timeout: 15),
            "Export popup did not open after tapping Export"
        )
        XCTAssertTrue(
            app.staticTexts["export.count"].waitForExistence(timeout: 60),
            "Export popup did not show a transaction count after fetching the history"
        )
        attachScreenshot(named: "09-export-popup")

        // -- Generate (PDF, filtered) opens the share sheet ---------
        app.buttons["export.generate"].tap()
        XCTAssertTrue(
            app.staticTexts["AirDrop"].waitForExistence(timeout: 30),
            "Share sheet did not appear after Generate (no AirDrop section)"
        )
        attachScreenshot(named: "10-export-share-sheet")
        tapHittableCancel()

        // -- Export all + CSV ---------------------------------------
        app.segmentedControls["export.scope"].buttons["All"].tap()
        app.segmentedControls["export.format"].buttons["CSV"].tap()
        XCTAssertTrue(
            app.staticTexts["export.count"].waitForExistence(timeout: 30),
            "Export popup lost its count after switching to All + CSV"
        )
        app.buttons["export.generate"].tap()
        XCTAssertTrue(
            app.staticTexts["AirDrop"].waitForExistence(timeout: 30),
            "Share sheet did not appear after Generate for All + CSV"
        )
        attachScreenshot(named: "11-export-all-csv")
        tapHittableCancel()

        // -- Close returns to the Transactions list ------------------
        app.buttons["Close"].tap()
        XCTAssertTrue(
            app.buttons.matching(identifier: "transaction.row").firstMatch
                .waitForExistence(timeout: 30),
            "Closing the export popup did not return to the Transactions list"
        )
    }

    /// Build 46 (owner, Nov 18, 2026): the Home hero shows the big
    /// amount in the white body (not the header) beside the progress
    /// circle (not the bar). Build 53 (audit W1): the preamble no
    /// longer signs up (Admin-API account instead), so the old 429
    /// sign-up gate cannot block it.
    func testHomeHeroAmountAndDonut() throws {
        signInAndJoinTestHousehold()

        XCTAssertTrue(
            app.staticTexts["Spending"].waitForExistence(timeout: 60),
            "Home hero did not render (no Spending title)"
        )
        XCTAssertTrue(
            app.staticTexts.matching(identifier: "home.heroAmount").firstMatch
                .waitForExistence(timeout: 60),
            "Home hero amount did not appear in the card body (home.heroAmount)"
        )
        XCTAssertTrue(
            app.otherElements.matching(identifier: "home.heroDonut").firstMatch
                .waitForExistence(timeout: 15),
            "Home hero progress circle did not appear beside the amount (home.heroDonut)"
        )
        attachScreenshot(named: "12-home-hero-amount-donut")
    }

    /// Build 46 (owner, Nov 18, 2026 — "the mockup layout is the
    /// new Home"): the simpler Home shows the Spending hero, the
    /// Tzedaka card second, and Savings + Overspent (Past) as
    /// quiet rows in one card. NOTE: blocked by the known 429
    /// sign-up gate in CI like the other UI tests — it fails in
    /// the sign-up preamble until the gate clears, and proves the
    /// layout then. The default layout is Simple, so no Settings
    /// flip is needed; the fund_prominence migration need not be
    /// applied for the defaults to show.
    func testSimpleHomeLayout() throws {
        signInAndJoinTestHousehold()

        XCTAssertTrue(
            app.staticTexts.matching(identifier: "home.heroAmount").firstMatch
                .waitForExistence(timeout: 60),
            "Simple Home hero amount did not appear (home.heroAmount)"
        )
        XCTAssertTrue(
            app.otherElements.matching(identifier: "home.tzedakaCard").firstMatch
                .waitForExistence(timeout: 15),
            "Simple Home Tzedaka card did not appear second (home.tzedakaCard)"
        )
        XCTAssertTrue(
            app.staticTexts.matching(identifier: "home.tzedakaAmount").firstMatch
                .waitForExistence(timeout: 15),
            "Simple Home Tzedaka amount did not appear (home.tzedakaAmount)"
        )
        XCTAssertTrue(
            app.buttons.matching(identifier: "home.quietSavings").firstMatch
                .waitForExistence(timeout: 15),
            "Simple Home quiet Savings row did not appear (home.quietSavings)"
        )
        XCTAssertTrue(
            app.buttons.matching(identifier: "home.quietDebt").firstMatch
                .waitForExistence(timeout: 15),
            "Simple Home quiet Overspent row did not appear (home.quietDebt)"
        )
        attachScreenshot(named: "13-simple-home-layout")
    }

    /// How-to video v1 (Nov 19, 2026): captures the clean STAGE
    /// screens the video is built from — Home, Transactions, the
    /// empty Add Transaction form, Funds, Home again. Uses the
    /// Admin API to create a PRE-CONFIRMED account (no public
    /// sign-up, so the 429 sign-up gate cannot block it), signs in
    /// via the app UI, and joins the TEST household (videoHouseholdName)
    /// via invite code XPKVGJ as a member. Never the live household.
    /// Screenshots are attached with lifetime .keepAlways and
    /// exported by the simulator workflow (and the video-screens
    /// workflow) as visible proof.
    func testVideoScreens() throws {
        guard let account = createConfirmedTestAccount() else { return }
        signInWithAccount(email: account.email, password: account.password)

        // Join the test household (videoHouseholdName) as a member.
        let inviteField = app.textFields["household.inviteCode"]
        waitForElement(
            inviteField, timeout: 90, screenshotName: "video-household-missing",
            message: "Household screen did not appear after sign-in (\(diagnosePostSignInState()))"
        )
        tapAndTypeText(inviteField, videoHouseholdInviteCode, fieldName: "household.inviteCode")
        dismissKeyboardIfPresent(focusedField: inviteField)
        app.buttons["household.joinAsMember"].tap()

        // -- Home (scenes 1, 2, 7): Spending hero + Tzedaka card +
        //    Savings / Overspent quiet rows ---------------------------
        // NOTE: the hero/quiet-row container identifiers (home.heroAmount,
        // home.quietSavings, home.quietDebt) are shadowed in the AX tree
        // by their containers (home.weeklyBudget / home.quietCard), so
        // wait on the elements' LABELS instead — the hero amount reads
        // "... left this week", the cards read by their fund names.
        // Goldstein Household still uses the DEFAULT fund names (Extra Fund,
        // Carried Debt, Charity) — the live household's renames
        // (Savings, Overspent (Past), Tzedaka) were never applied here.
        XCTAssertTrue(
            app.staticTexts[videoHouseholdName].waitForExistence(timeout: 90),
            "Home did not render after joining the household (no household title)"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'left this week'")).firstMatch
                .waitForExistence(timeout: 30),
            "Home hero amount did not appear after joining the household"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Charity'")).firstMatch
                .waitForExistence(timeout: 15),
            "Home Charity/Tzedaka card did not appear"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Extra Fund'")).firstMatch
                .waitForExistence(timeout: 15),
            "Home quiet Extra Fund row did not appear"
        )
        // Let the amounts settle (no skeleton, no toast) before the shot.
        Thread.sleep(forTimeInterval: 3)
        dismissNotificationAlertIfPresent()
        attachScreenshot(named: "video-01-home")

        // -- Transactions (scene 3) -----------------------------------
        tapTab(identifier: "tab.transactions", label: "Transactions")
        let firstRow = app.buttons.matching(identifier: "transaction.row").firstMatch
        // The list can hit a transient server error ("Could not load
        // transactions — the server did not answer", run 44585656267:
        // Home and sign-in worked in the same run, so the server was
        // up and this one fetch blipped). If the error state appears,
        // tap Try Again and wait again instead of failing outright.
        if !firstRow.waitForExistence(timeout: 60) {
            let tryAgain = app.buttons["Try Again"]
            if tryAgain.waitForExistence(timeout: 5) {
                tryAgain.tap()
            }
        }
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 120),
            "Transactions did not load any rows within 120s"
        )
        Thread.sleep(forTimeInterval: 3)
        dismissNotificationAlertIfPresent()
        attachScreenshot(named: "video-02-transactions")

        // -- Add Transaction, empty Purchase form (scene 6) -----------
        app.buttons["+ Add"].tap()
        let purchaseButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Purchase'")).firstMatch
        XCTAssertTrue(
            purchaseButton.waitForExistence(timeout: 15),
            "Add options did not appear after tapping + Add"
        )
        purchaseButton.tap()
        XCTAssertTrue(
            app.textFields["Merchant"].waitForExistence(timeout: 15),
            "Add Purchase form did not open (no Merchant field)"
        )
        XCTAssertTrue(
            app.buttons["Add Transaction"].waitForExistence(timeout: 15),
            "Add Purchase form did not render (no Add Transaction button)"
        )
        Thread.sleep(forTimeInterval: 2)
        dismissNotificationAlertIfPresent()
        attachScreenshot(named: "video-03-add")
        // Cancel clears the (empty) draft and closes the form.
        app.buttons["Cancel"].tap()

        // -- Funds (scenes 4, 5) --------------------------------------
        // NOTE: the Funds cards are BUTTONS (tappable cards), not
        // static texts — the fund names live in the buttons' labels
        // (e.g. "Charity, no charity tracked yet, show breakdown"),
        // so wait on the button identifiers funds.charity /
        // funds.extraFund, which the failure-time hierarchy in run
        // 44574566697 proves are present and queryable.
        tapTab(identifier: "tab.funds", label: "Funds")
        XCTAssertTrue(
            app.buttons.matching(identifier: "funds.charity").firstMatch
                .waitForExistence(timeout: 90),
            "Funds did not render (no Charity/Tzedaka card)"
        )
        XCTAssertTrue(
            app.buttons.matching(identifier: "funds.extraFund").firstMatch
                .waitForExistence(timeout: 15),
            "Funds did not render (no Extra Fund/Savings card)"
        )
        Thread.sleep(forTimeInterval: 3)
        dismissNotificationAlertIfPresent()
        attachScreenshot(named: "video-04-funds")

        // -- Home again (scene 7 closing) -----------------------------
        tapTab(identifier: "tab.home", label: "Home")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'left this week'")).firstMatch
                .waitForExistence(timeout: 30),
            "Home hero amount did not reappear"
        )
        Thread.sleep(forTimeInterval: 2)
        dismissNotificationAlertIfPresent()
        attachScreenshot(named: "video-05-home-close")
    }

    /// How-to video v2 (Nov 19, 2026): records the app being USED —
    /// a real screen recording with taps and animations, not stills.
    /// Same preamble as testVideoScreens (Admin-API account, sign in,
    /// join the test household (videoHouseholdName) via XPKVGJ). Then performs the tap
    /// sequence the narration describes, paced to the narration
    /// timings, while the CI script records the simulator screen with
    /// `xcrun simctl io recordVideo`. Each scene prints a VIDEO-MARK
    /// timestamp so assemble-v2 can cut the continuous recording
    /// into scenes. Holds are narration+gap plus a small buffer, so
    /// every scene's video is longer than its narration and the cut
    /// is clean. The test asserts only the gates that must hold for
    /// the video to be usable (Home loaded, Transactions rows exist,
    /// Funds rendered, Add form opened); the expand taps are
    /// best-effort — a missed expand shows in the frames, it must
    /// not fail the whole capture.
    ///
    /// Scene map (narration durations from the v1 clips):
    ///   S1 Home hold (8.76s + gap) — just Home, no taps.
    ///   S2 Spending (10.87s + gap) — tap the Spending hero to expand.
    ///   S3 Transactions (17.59s + gap) — tab + slow scroll of the
    ///       ~10 realistic fixture rows.
    ///   S4 Charity (22.39s + gap) — Funds tab, tap Charity card to
    ///       expand so Available/Given/owed are visible. The scene
    ///       v1 got wrong: the card must be OPEN.
    ///   S5 Savings (11.95s + gap) — tap the Extra Fund card to expand.
    ///   S6 Add (6.07s + gap) — tap + Add, Purchase, type merchant
    ///       "Coffee" + amount 4.50, tap Add Transaction.
    ///   S7 Home close (5.64s) — back to Home, hold.
    func testVideoRecordings() throws {
        guard let account = createConfirmedTestAccount() else { return }
        signInWithAccount(email: account.email, password: account.password)

        // Join the test household (videoHouseholdName) as a member (same as testVideoScreens).
        let inviteField = app.textFields["household.inviteCode"]
        waitForElement(
            inviteField, timeout: 90, screenshotName: "video-household-missing",
            message: "Household screen did not appear after sign-in (\(diagnosePostSignInState()))"
        )
        tapAndTypeText(inviteField, videoHouseholdInviteCode, fieldName: "household.inviteCode")
        dismissKeyboardIfPresent(focusedField: inviteField)
        app.buttons["household.joinAsMember"].tap()

        // -- Home ready: scene 1 starts here ------------------------
        XCTAssertTrue(
            app.staticTexts[videoHouseholdName].waitForExistence(timeout: 90),
            "Home did not render after joining the household (no household title)"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'left this week'")).firstMatch
                .waitForExistence(timeout: 30),
            "Home hero amount did not appear after joining the household"
        )
        // Settle the notification alert BEFORE scene 1. The alert
        // is requested ASYNCHRONOUSLY after Home loads — run
        // 44620606851: ~11-21 s after Home; run 44627761001: ~35 s
        // after Home, AFTER a fixed 30 s settle, so it sat in the
        // middle of scene 1's opening shot. A fixed wait cannot
        // catch it. So wait until the alert ACTUALLY shows (up to
        // 75 s), dismiss it, and only then start scene 1. Once
        // dismissed (Don't Allow) it never returns for this
        // install. If it never shows, the deadline still lets the
        // test proceed. This is all before the SCENE-1 marker, so
        // it never shows in the video — it only lengthens the
        // recording preamble.
        let alertDeadline = Date().addingTimeInterval(75)
        var alertDismissed = false
        while Date() < alertDeadline && !alertDismissed {
            alertDismissed = dismissNotificationAlertIfPresent()
        }
        videoMark("HOME-READY")

        // -- Scene 1: Home, hold (narration 8.76 + 1.5 gap = 10.26) --
        videoMark("SCENE-1")
        Thread.sleep(forTimeInterval: 12)

        // -- Scene 2: tap the Spending hero -------------------------
        // (narration 10.87 + 1.5 gap = 12.37). The hero amount reads
        // "... left this week"; tapping it opens the "Weekly Budget"
        // SHEET (full-screen modal: Spent / Balance / Purchases,
        // Show Transactions / Close) — NOT an inline expand. The
        // sheet covers the tab bar, which is why run 44620606851
        // failed the scene-3 tab tap (hit point -1,-1). So close
        // the sheet to return to Home instead of tapping the hero
        // again. The Close tap lands after the scene-2 video cut
        // (12.37s), so it never shows.
        videoMark("SCENE-2")
        let heroAmount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'left this week'")).firstMatch
        if heroAmount.waitForExistence(timeout: 10) {
            heroAmount.tap()
        }
        Thread.sleep(forTimeInterval: 13)
        let weeklyClose = app.buttons["Close"]
        if weeklyClose.waitForExistence(timeout: 10) {
            weeklyClose.tap()
        }
        Thread.sleep(forTimeInterval: 1)

        // -- Scene 3: Transactions, slow scroll (17.59 + 1.5 = 19.09)
        videoMark("SCENE-3")
        tapTab(identifier: "tab.transactions", label: "Transactions")
        let firstRow = app.buttons.matching(identifier: "transaction.row").firstMatch
        if !firstRow.waitForExistence(timeout: 60) {
            let tryAgain = app.buttons["Try Again"]
            if tryAgain.waitForExistence(timeout: 5) {
                tryAgain.tap()
            }
        }
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 120),
            "Transactions did not load any rows within 120s"
        )
        Thread.sleep(forTimeInterval: 5)
        app.swipeUp()
        Thread.sleep(forTimeInterval: 5)
        app.swipeUp()
        Thread.sleep(forTimeInterval: 5)
        Thread.sleep(forTimeInterval: 4)

        // -- Scene 4: Funds, expand the Charity card ----------------
        // (narration 22.39 + 1.5 gap = 23.89). This is the scene v1
        // got wrong: the card must be OPEN so Available / Given /
        // owed are visible while the narration talks about them.
        videoMark("SCENE-4")
        tapTab(identifier: "tab.funds", label: "Funds")
        XCTAssertTrue(
            app.buttons.matching(identifier: "funds.charity").firstMatch
                .waitForExistence(timeout: 90),
            "Funds did not render (no Charity/Tzedaka card)"
        )
        let charityCard = app.buttons.matching(identifier: "funds.charity").firstMatch
        charityCard.tap()
        Thread.sleep(forTimeInterval: 25)
        // Collapse Charity before moving on (same tab-bar lesson as
        // scene 2 — an expanded card can make the next tap fail).
        // The collapse lands after the scene-4 video cut (23.89s).
        charityCard.tap()

        // -- Scene 5: expand the Savings (Extra Fund) card ----------
        // (narration 11.95 + 1.5 gap = 13.45). One-open-at-a-time:
        // this collapses Charity and opens Savings. Collapse it
        // again before scene 6 — the "+ Add" button is a tab-bar
        // button and would hit the same expanded-card failure.
        // Hold is 14s so the collapse lands after the 13.45s cut.
        videoMark("SCENE-5")
        let savingsCard = app.buttons.matching(identifier: "funds.extraFund").firstMatch
        if savingsCard.waitForExistence(timeout: 10) {
            savingsCard.tap()
        }
        Thread.sleep(forTimeInterval: 14)
        if savingsCard.waitForExistence(timeout: 10) {
            savingsCard.tap()
        }

        // -- Scene 6: add a transaction by hand (6.07 + 1.5 = 7.57) -
        // The "+ Add" button lives ONLY in the Transactions header
        // (TransactionsView.swift:276) — run 44624214523 proved it
        // does not exist on Funds ("No matches found"). And the Add
        // flow is SLOW (run 44627761001: 53 s — the keyboard takes
        // seconds to appear and typeText is ~0.5 s/char), so the
        // typing lands far outside the 7.57 s cut if the navigation
        // is inside it. So do the slow navigation BEFORE the marker
        // (Transactions tab, + Add, Purchase — the form opens), and
        // put ONLY the typing + Add inside the cut. Short values
        // ("Tea", "5") keep the typing to ~3 s so it and the Add
        // tap both fit. The new "Tea" row lands in the Transactions
        // list (test household only). The form sheet dismisses the
        // decimal-pad keyboard interactively on scroll, so swipe
        // before tapping Add.
        tapTab(identifier: "tab.transactions", label: "Transactions")
        app.buttons["+ Add"].tap()
        let purchaseButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Purchase'")).firstMatch
        XCTAssertTrue(
            purchaseButton.waitForExistence(timeout: 15),
            "Add options did not appear after tapping + Add"
        )
        purchaseButton.tap()
        XCTAssertTrue(
            app.textFields["Merchant"].waitForExistence(timeout: 15),
            "Add Purchase form did not open (no Merchant field)"
        )
        videoMark("SCENE-6")
        tapAndTypeText(app.textFields["Merchant"], "Tea", fieldName: "Merchant")
        let amountField = app.textFields["0.00"]
        if amountField.waitForExistence(timeout: 10) {
            tapAndTypeText(amountField, "5", fieldName: "Amount")
        }
        // Dismiss the keyboard, then tap Add Transaction.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        let addButton = app.buttons["Add Transaction"]
        if addButton.waitForExistence(timeout: 10) {
            addButton.tap()
        }
        Thread.sleep(forTimeInterval: 3)
        Thread.sleep(forTimeInterval: 3)

        // -- Scene 7: back Home, hold to close (narration 5.64) ----
        videoMark("SCENE-7")
        tapTab(identifier: "tab.home", label: "Home")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'left this week'")).firstMatch
                .waitForExistence(timeout: 30),
            "Home hero amount did not reappear"
        )
        Thread.sleep(forTimeInterval: 6)
        videoMark("DONE")
    }

    /// Prints a timestamped marker the assembler uses to cut the
    /// continuous screen recording into scenes. Markers go to the
    /// test log (stdout) as `VIDEO-MARK <name> <epoch seconds>`.
    private func videoMark(_ name: String) {
        print("VIDEO-MARK \(name) \(Date().timeIntervalSince1970)")
    }

    /// Build 46 (owner, Nov 18, 2026 — "you can't delete it once it
    /// was added"): record a $1 cash gift from the Charity card,
    /// then delete it from the Activity feed — the row must go and
    /// the figures must move back. PRECONDITION: the test household
    /// needs $1+ of charity Available, or the record step refuses
    /// with a plain-language error (seed an income first if it
    /// does). NOTE: blocked by the known 429 sign-up gate in CI
    /// like the other UI tests — it fails in the sign-up preamble
    /// until the gate clears, and proves the delete flow then.
    /// The reverse RPC (`supabase/reverse-charity-cash-gift.sql`)
    /// must be applied live first, or the delete step fails with a
    /// plain-language error and nothing is changed.
    func testDeleteCashGiftFromFundsFeed() throws {
        signInAndJoinTestHousehold()

        tapTab(identifier: "tab.funds", label: "Funds")
        XCTAssertTrue(
            app.staticTexts["Charity"].waitForExistence(timeout: 90),
            "Funds did not render (no Charity card)"
        )
        // Expand the Charity card: the Record a Transaction button
        // lives in the expanded card.
        app.staticTexts["Charity"].tap()
        let recordButton = app.buttons["funds.recordCashGift"]
        XCTAssertTrue(
            recordButton.waitForExistence(timeout: 30),
            "Charity card did not offer Record a Transaction after expanding"
        )
        recordButton.tap()
        XCTAssertTrue(
            app.staticTexts["Record a Transaction to Charity"].waitForExistence(timeout: 15),
            "Record a Transaction popup did not open"
        )
        let amountField = app.textFields["0.00"]
        XCTAssertTrue(
            amountField.waitForExistence(timeout: 15),
            "Record popup did not show an amount field"
        )
        amountField.tap()
        amountField.typeText("1.00")
        app.buttons["Record"].tap()
        XCTAssertTrue(
            app.staticTexts["Cash gift"].waitForExistence(timeout: 30),
            "Cash gift did not appear in the Charity Activity feed after recording"
        )

        // -- Delete it from the feed --------------------------------
        let cashGiftRows = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cash gift'"))
        let countBefore = cashGiftRows.count
        XCTAssertGreaterThan(countBefore, 0, "No Cash gift row to delete")
        cashGiftRows.firstMatch.tap()
        let deleteButton = app.buttons["funds.deleteCashGift"]
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 15),
            "Cash gift detail did not offer Delete"
        )
        deleteButton.tap()
        let confirmButton = app.buttons["funds.confirmDeleteCashGift"]
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: 15),
            "Delete confirm did not appear for the cash gift"
        )
        confirmButton.tap()
        // The row leaves the feed once the reversal lands.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: cashGiftRows.firstMatch, handler: nil)
        waitForExpectations(timeout: 30, handler: nil)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cash gift'")).count,
            countBefore - 1,
            "Cash gift row is still in the feed after Delete"
        )
        attachScreenshot(named: "13-cash-gift-deleted")
    }

    /// Taps the hittable Cancel button. The export popup and the
    /// share sheet both have one, so the first match may be the
    /// covered popup button, which is not hittable while the sheet
    /// is up — the sheet's Cancel is the hittable one.
    private func tapHittableCancel() {
        let cancels = app.buttons.matching(NSPredicate(format: "label == 'Cancel'"))
        for index in 0..<cancels.count {
            let button = cancels.element(boundBy: index)
            if button.isHittable {
                button.tap()
                return
            }
        }
        XCTFail("No hittable Cancel button found")
    }

    /// Past Weeks / Activity (Nov 9, 2026): the Transactions page
    /// links push PastWeeksView / ActivityView as subpages in the
    /// Transactions NavigationStack — the native equivalent of the
    /// web's full pages. The explainer line under each heading is
    /// the assertion (it is unique to the subpage; the title text
    /// alone could also match the link's label).
    func testPastWeeksAndActivitySubpages() throws {
        signInAndJoinTestHousehold()

        tapTab(identifier: "tab.transactions", label: "Transactions")
        let firstRow = app.buttons.matching(identifier: "transaction.row").firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 120),
            "Transactions did not load any rows within 120s"
        )

        // -- Past Weeks pushes -------------------------------------------
        // Build 53 (audit U2): Past Weeks lives in the "More" menu now.
        app.buttons["pageLinks.more"].tap()
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
        // Build 53 (audit U2): Activity lives in the "More" menu now.
        app.buttons["pageLinks.more"].tap()
        let activityLink = app.buttons["Activity"]
        XCTAssertTrue(
            activityLink.waitForExistence(timeout: 15),
            "Activity link missing on Transactions (shell did not supply the handler)"
        )
        activityLink.tap()
        XCTAssertTrue(
            app.staticTexts["General Activity"]
                .waitForExistence(timeout: 60),
            "Activity subpage did not open"
        )
        attachScreenshot(named: "08-activity")
    }

    // MARK: - Shared preamble

    // MARK: - Failure diagnostics (build 53, audit W1)

    /// Visible static texts, error-like ones first — the evidence
    /// a failure message needs. The 429 gate was blamed for 8
    /// failures with NO rate-limit string in the log, because no
    /// failure ever captured the app's actual error text. A
    /// failure that names the visible error text is evidence; one
    /// that only says "did not appear" is a guess.
    private func visibleErrorText() -> String {
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        let errorLike = labels.filter { label in
            let lower = label.lowercased()
            return lower.contains("invalid") || lower.contains("fail") || lower.contains("error")
                || lower.contains("rate") || lower.contains("limit") || lower.contains("many")
                || lower.contains("try again") || lower.contains("expired") || lower.contains("offline")
        }
        let shown = errorLike.isEmpty ? Array(labels.prefix(5)) : Array(errorLike.prefix(5))
        return shown.isEmpty ? "(no visible text)" : shown.joined(separator: " | ")
    }

    /// What the app is actually showing when a post-sign-in step
    /// stalls. The video-test hang ("Household screen did not
    /// appear after sign-in") was undiagnosed because the failure
    /// never said WHERE the app was stuck — still on the auth
    /// screen with a sign-in error, on the boot-error panel
    /// (membership read failed; the invite field is hidden by
    /// design there), on the session-expired screen, or already on
    /// Home. This names the visible state so the next failure is
    /// self-diagnosing instead of another "did not appear".
    private func diagnosePostSignInState() -> String {
        if app.textFields["auth.email"].exists {
            return "still on the auth screen (sign-in did not complete); visible text: \(visibleErrorText())"
        }
        if app.buttons["household.retryBoot"].exists || app.staticTexts["Could not load your household."].exists {
            return "household boot-error panel is showing (membership read failed — the invite field is hidden by design; tap Try Again)"
        }
        if app.buttons["Sign In Again"].exists {
            return "session-expired screen is showing"
        }
        if app.staticTexts["Weekly Budget"].exists {
            return "Home already rendered (the account already has a household?)"
        }
        return "unknown state (not auth, not boot-error, not session-expired, not Home)"
    }

    /// Wait for an element, screenshotting on failure first:
    /// XCTAssertTrue with continueAfterFailure=false aborts before
    /// any screenshot, so the wait captures the stuck state and
    /// the diagnosis names it.
    /// Waits for an element, screenshotting + failing with `message`
    /// when it never appears. The message is an @autoclosure on
    /// purpose — build 53's first simulator run proved why: a plain
    /// String argument evaluates the diagnostic BEFORE the wait
    /// starts, so `diagnosePostSignInState()` ran one second after
    /// the sign-in tap, mid-transition, and its
    /// `allElementsBoundByIndex` walk hit a hierarchy that was
    /// changing under it ("Failed to get matching snapshot", run
    /// 44963752823) — failing the test before the wait even began.
    /// Lazy, the diagnostic only runs after the wait has actually
    /// failed, when the screen has been stable for the whole timeout.
    private func waitForElement(_ element: XCUIElement, timeout: TimeInterval, screenshotName: String, message: @autoclosure () -> String) {
        if element.waitForExistence(timeout: timeout) { return }
        attachScreenshot(named: screenshotName)
        XCTFail(message())
    }

    /// Steps 1–4 of the milestone proof, WITHOUT the public
    /// sign-up: create a PRE-CONFIRMED account via the Admin API
    /// (no email is ever sent, so the Supabase sign-up rate limit
    /// cannot block it) and sign in with it in the app UI, then
    /// join Proof Household 2 as a member → Home renders. Shared
    /// by the browse + subpage tests. Build 53 (audit W1): the old
    /// preamble signed up a fresh account per test — 8 public
    /// sign-ups per run — and the run died at the sign-up rate
    /// limit, proving nothing past auth. Only
    /// testSignUpJoinAndBrowse still exercises the public sign-up
    /// flow (one sign-up per run).
    private func signInAndJoinTestHousehold() {
        guard let account = createConfirmedTestAccount() else { return }
        signInWithAccount(email: account.email, password: account.password)

        // Join Proof Household 2 as a member.
        let inviteField = app.textFields["household.inviteCode"]
        waitForElement(
            inviteField, timeout: 90, screenshotName: "03-household-missing",
            message: "Household screen did not appear after sign-in (\(diagnosePostSignInState()))"
        )
        attachScreenshot(named: "03-household-join")
        tapAndTypeText(inviteField, testInviteCode, fieldName: "household.inviteCode")
        dismissKeyboardIfPresent(focusedField: inviteField)
        app.buttons["household.joinAsMember"].tap()

        // Home renders.
        waitForElement(
            app.staticTexts["Weekly Budget"], timeout: 90, screenshotName: "04-home-missing",
            message: "Home did not render after joining the household (\(diagnosePostSignInState()))"
        )
        XCTAssertTrue(
            app.tabBars.buttons["tab.home"].exists
                || app.tabBars.buttons["Home"].exists,
            "Tab bar missing on Home"
        )
        attachScreenshot(named: "04-home")
    }

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
        waitForElement(
            inviteField, timeout: 90, screenshotName: "03-household-missing",
            message: "Household screen did not appear after sign-up (\(diagnosePostSignInState()))"
        )
        attachScreenshot(named: "03-household-join")
        tapAndTypeText(inviteField, testInviteCode, fieldName: "household.inviteCode")
        dismissKeyboardIfPresent(focusedField: inviteField)
        app.buttons["household.joinAsMember"].tap()

        // -- 5. Home renders ---------------------------------------------
        waitForElement(
            app.staticTexts["Weekly Budget"], timeout: 90, screenshotName: "04-home-missing",
            message: "Home did not render after joining the household (\(diagnosePostSignInState()))"
        )
        XCTAssertTrue(
            app.tabBars.buttons["tab.home"].exists
                || app.tabBars.buttons["Home"].exists,
            "Tab bar missing on Home"
        )
        attachScreenshot(named: "04-home")
    }

    /// Creates a fresh PRE-CONFIRMED account via the Supabase Auth
    /// Admin API (bypasses the public sign-up endpoint, so the 429
    /// sign-up gate cannot block it) and returns its credentials.
    /// The account is a throwaway video-capture account: it joins
    /// the test household as a member and is never used again.
    private func createConfirmedTestAccount() -> (email: String, password: String)? {
        guard let serviceKey = Self.uiTestServiceKey(), !serviceKey.isEmpty else {
            XCTFail("No service-role key reached the UI test runner — cannot create the video account")
            return nil
        }
        let runId = UUID().uuidString.lowercased().prefix(8)
        let email = "ios-clone-video-\(runId)@example.com"
        let password = "Video-\(runId)-2026!"
        var request = URLRequest(url: URL(string: "\(Self.supabaseAuthAdminBase)/users")!)
        request.httpMethod = "POST"
        request.setValue(serviceKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password,
            "email_confirm": true,
            "user_metadata": ["display_name": "Video Test"],
        ])
        let (status, _) = performAdminRequest(request)
        guard status == 200 || status == 201 else {
            XCTFail("Admin API create user failed for \(email) (HTTP \(status))")
            return nil
        }
        return (email, password)
    }

    /// Signs in via the app UI with the given credentials. The
    /// account is already confirmed, so there is no "Check Your
    /// Email" step.
    private func signInWithAccount(email: String, password: String) {
        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 60),
            "Auth screen did not appear: no email field within 60s of launch"
        )
        tapAndTypeText(emailField, email, fieldName: "auth.email")
        let passwordField = app.secureTextFields["auth.password"]
        XCTAssertTrue(
            passwordField.waitForExistence(timeout: 10),
            "Password field missing on the auth screen"
        )
        tapAndTypeText(passwordField, password, fieldName: "auth.password")
        dismissKeyboardIfPresent(focusedField: passwordField)
        app.buttons["auth.signIn"].tap()
    }

    func testPlaidSandboxConnect() throws {
        // SKIPPED — invite-only launch (Nov 17, 2026): this test signed
        // up a fresh account and created its own admin household to
        // prove the Plaid Link sheet opens. Household creation is now
        // closed to app users (only an invite code gets you in), so
        // the test has no admin household to connect a bank to. Plaid
        // Link opening was proven in earlier simulator runs and the
        // live Amex connection is proven in production. Re-prove
        // manually on TestFlight with the test admin account if the
        // Link flow ever changes. Previous body in git history
        // (branch point aef4e9e); restore it if creation re-opens.
        throw XCTSkip(
            "Household creation is disabled in invite-only mode — "
            + "this test needs an admin household to connect Plaid."
        )
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
        // Build 43 (owner, Nov 17, 2026): sign-up collects First Name
        // and Last Name as separate fields (ids auth.firstName /
        // auth.lastName); the stored display name is derived as
        // "First L.".
        let firstNameField = app.textFields["auth.firstName"]
        XCTAssertTrue(
            firstNameField.waitForExistence(timeout: 60),
            "Name step did not appear after Create Account (sign-up may have failed)"
        )
        tapAndTypeText(firstNameField, "UI", fieldName: "auth.firstName")
        let lastNameField = app.textFields["auth.lastName"]
        XCTAssertTrue(
            lastNameField.waitForExistence(timeout: 10),
            "Last Name field missing on the sign-up name step"
        )
        tapAndTypeText(lastNameField, "Test", fieldName: "auth.lastName")
        dismissKeyboardIfPresent(focusedField: lastNameField)
        app.buttons["auth.createAccountConfirm"].tap()

        // -- 4. Confirm via the Admin API, then sign in -----------------
        // Sign-up with confirmation ON lands on the persistent
        // "Check Your Email" state (NameStepView.confirmationSent).
        // Build 53 (audit W1): when this fails, the message names
        // the app's actual error text — the 429 gate was blamed for
        // 8 failures with no rate-limit string in the log, because
        // no failure ever captured it.
        if !app.staticTexts["Check Your Email"].waitForExistence(timeout: 60) {
            attachScreenshot(named: "02-signup-failed")
            XCTFail("Check Your Email did not appear after Create Account (sign-up may have failed or confirmation may be off); visible text: \(visibleErrorText())")
        }
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
    /// How-to video v1 (Nov 19, 2026): on a fresh install the app
    /// asks for notification permission the first time Home loads,
    /// and the system alert ("STAGE Would Like to Send You
    /// Notifications") covers the middle of the screen — it ruined
    /// the video-01-home still in runs 44574566697 and 44585656267.
    /// Dismiss it with "Don't Allow" (a test install never needs
    /// pushes) whenever it is present, before any screenshot.
    /// NOTE: system permission alerts live in SPRINGBOARD, not in
    /// app.alerts — app.alerts only holds the app's own alerts, so
    /// the first version of this helper (app.alerts) never found
    /// the dialog and the alert stayed on screen. Query SpringBoard.
    /// Returns true when it dismissed an alert.
    @discardableResult
    private func dismissNotificationAlertIfPresent() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 5) else { return false }
        let dontAllow = alert.buttons["Don't Allow"]
        if dontAllow.waitForExistence(timeout: 5) {
            dontAllow.tap()
            Thread.sleep(forTimeInterval: 1)
            return true
        }
        return false
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
