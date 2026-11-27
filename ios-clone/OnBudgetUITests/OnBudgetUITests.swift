// STAGE — OnBudgetUITests.swift
//
// Milestone (a) UI proof: the native clone RUNNING on the simulator
// against the live TEST backend (Supabase project
// tnkhvdkmwmwiogiienee — the same backend the app ships with).
// Updated Nov 25, 2026 for the current app (build 78 + widget deep
// links + Actions-sheet tag fast fix): page-select coordinate taps,
// label-based Home hero queries, Settings hub navigation,
// TzedakaActionSheet cash-gift flow, sign-up
// Trigger: re-run Round 4 test fixes against the current app — run
// 45717830965 was cancelled by the Actions-sheet-tag push
// (concurrency), so this commit re-triggers the suite for the
// current HEAD.
// confirmation OFF.
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
// exercises the public sign-up flow (one sign-up per run). Email
// confirmation is OFF (owner, Nov 24, 2026), so sign-up signs the
// account in directly and lands on the Household screen — there is
// no "Check Your Email" step and no Admin-API confirm is needed;
// the @example.com address can never receive email, which is fine
// because none is ever sent.
//   Then join the TEST household "Proof Household 2" as a member via
//      invite code Q6GFME. Never the real household, never the
//      owner's account. (The test admin account's password is lost;
//      nothing here depends on it.)
//   Assert Home renders (household title), Transactions loads
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
// cannot be used for this), open Settings → Connections → Bank
// Connection, tap Connect New Account, and drive Plaid Link against
// Plaid Sandbox
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
    /// TEST BACKEND ONLY — the household the shared preambles join
    /// ("Proof Household 2", invite Q6GFME). Home's title is the
    /// household NAME — the hero card is titled by the fund name
    /// ("Spending"), and "Weekly Budget" is not a visible text
    /// anywhere on Home (it only exists on the Funds page's Weekly
    /// Budget Calculator popup), so the old Home waits for
    /// "Weekly Budget" could never pass even though Home rendered
    /// fine (proven by run 44970315808's 04-home-missing
    /// screenshot: Home fully rendered behind the notifications
    /// alert). Wait for this name, not "Weekly Budget".
    private let proofHouseholdName = "Proof Household 2"

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
        // The notifications-permission alert ("STAGE Would Like
        // to Send You Notifications") is a SYSTEM alert: it
        // blocks the app's whole accessibility tree while it is
        // up, so every content wait behind it fails. It is
        // requested asynchronously after first Home load and can
        // appear 11 s to 75 s+ after Home renders, so no bounded
        // poll can reliably catch it — run 44987157759 proved
        // the SpringBoard query never dismissed it (the alert sat
        // up for the whole 75 s settle). The interruption
        // monitor is Apple's own mechanism for system alerts: it
        // fires on the next UI interaction while the alert is
        // present. dismissNotificationAlertIfPresent pokes the
        // app to trigger it; the monitor taps "Don't Allow".
        addUIInterruptionMonitor(withDescription: "Notifications permission") { alert in
            if alert.buttons["Don't Allow"].exists {
                alert.buttons["Don't Allow"].tap()
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
        // account has no household yet. The Household screen HAS its
        // own Sign Out button (household.signOut, HouseholdViews) —
        // tap it directly instead of joining first: joining would
        // render Home and fire the one-time notifications-permission
        // alert, which then blocks the sign-out taps. (Without this
        // branch, one preamble failure poisons the whole suite:
        // every later setUp fails here, run 44963752823 proved it —
        // 11 tests died in setUp after the first test left the app
        // signed-in on the Household screen.) A stuck launch or an
        // expired session is a state this helper cannot recover
        // from, so fail fast with the actual state instead of
        // burning the 60s auth wait in signUpFreshAccount.
        let homeTab = app.buttons["pageSelect.home"]
        if !homeTab.waitForExistence(timeout: 10) {
            let inviteField = app.textFields["household.inviteCode"]
            if inviteField.waitForExistence(timeout: 10) {
                app.buttons["household.signOut"].tap()
            } else {
                XCTFail("Neither the auth screen, the signed-in Home, nor the Household screen appeared within ~30s of launch — cannot start from a known state")
                return
            }
        }

        // Profile menu → Settings → Profile subpage → Sign Out
        // (the app's own sign-out path; AppState.signOut dismisses
        // Settings and lands on the auth screen). Build 74 split
        // Settings into a hub: the root is a short list and Sign
        // Out lives on the Profile subpage, so tap the
        // settings.hub.profile row after Settings renders. Clear
        // any overlay first: run 44980488090's
        // testHomeHeroAmountAndDonut and testPageSelectIsSingleNavigation both
        // died here — the Profile tap failed to scroll into view
        // (kAXErrorCannotComplete), which is what an overlay
        // (walkthrough, or the notifications alert) covering Home
        // looks like from XCTest. Coordinate taps throughout (see
        // tapCoordinate): menu items and hub rows are on screen,
        // and a plain .tap() risks the same AX scroll failure.
        dismissTourIfPresent()
        dismissNotificationAlertIfPresent()
        tapCoordinate(app.buttons["Profile"])
        let settingsItem = app.buttons["Settings"]
        XCTAssertTrue(
            settingsItem.waitForExistence(timeout: 10),
            "Profile menu did not offer Settings"
        )
        tapCoordinate(settingsItem)
        let profileHubRow = app.buttons["settings.hub.profile"]
        XCTAssertTrue(
            profileHubRow.waitForExistence(timeout: 30),
            "Settings hub did not render (no Profile row)"
        )
        tapCoordinate(profileHubRow)
        let signOutButton = app.buttons["settings.signOut"]
        XCTAssertTrue(
            signOutButton.waitForExistence(timeout: 10),
            "Settings Profile subpage did not offer Sign Out"
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
        // Funds cards are button-like elements whose card container
        // carries the funds.* identifier AND an accessibilityLabel
        // — the name is not a separate staticText, so query the
        // cards as buttons by identifier (a staticTexts["Extra
        // Fund"] lookup never matches).
        tapTab(identifier: "tab.funds", label: "Funds")
        XCTAssertTrue(
            app.buttons.matching(identifier: "funds.extraFund").firstMatch.waitForExistence(timeout: 90),
            "Funds did not render (no Extra Fund card)"
        )
        XCTAssertTrue(
            app.buttons.matching(identifier: "funds.charity").firstMatch.waitForExistence(timeout: 30),
            "Funds did not render (no Charity card)"
        )
        attachScreenshot(named: "06-funds")
    }

    /// Page select is the ONE navigation (build 65, owner Nov 23,
    /// 2026): the TabView is gone — the duplicate Home /
    /// Transactions / Funds bar (bottom tab bar + Lean floater)
    /// is replaced by a single PageSelectControl under the top
    /// bar. This test proves there is NO tab bar at all, the page
    /// select exists with all three segments, and each segment
    /// switches content. NOTE: CI runs on an iPhone 16 simulator
    /// (compact size class) — this guards the navigation on
    /// iPhone; the iPad rendering itself can only be proven on a
    /// real iPad.
    func testPageSelectIsSingleNavigation() throws {
        signInAndJoinTestHousehold()

        XCTAssertFalse(
            app.tabBars.firstMatch.exists,
            "A tab bar is still present — build 65 removed the TabView; navigation is the page select only"
        )
        for identifier in ["pageSelect.home", "pageSelect.transactions", "pageSelect.funds"] {
            XCTAssertTrue(
                app.buttons[identifier].exists,
                "Page select is missing the \(identifier) segment"
            )
        }

        tapTab(identifier: "tab.transactions", label: "Transactions")
        XCTAssertTrue(
            app.staticTexts["Transactions"].waitForExistence(timeout: 30),
            "Transactions page select did not show the Transactions screen"
        )
        tapTab(identifier: "tab.funds", label: "Funds")
        XCTAssertTrue(
            app.buttons.matching(identifier: "funds.extraFund").firstMatch.waitForExistence(timeout: 30),
            "Funds page select did not show the Funds screen (no Extra Fund card)"
        )
        // The household name is the shell's persistent top-bar
        // title — it shows on EVERY tab (AppShellView topBar), so
        // its presence cannot prove the switch. The Home hero is
        // Home-only: its amount ("left this week") must be gone
        // once Funds is showing (run 45588370579: the old
        // "household title still showing" assertion failed because
        // the top bar legitimately keeps the name on Funds).
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'left this week' OR label CONTAINS 'over budget'")).firstMatch.exists,
            "Home hero still showing after switching to Funds"
        )
        tapTab(identifier: "tab.home", label: "Home")
        XCTAssertTrue(
            app.staticTexts[proofHouseholdName].waitForExistence(timeout: 30),
            "Home page select did not return to the household title"
        )
        attachScreenshot(named: "07-page-select")
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

        // Profile menu → Settings hub → Connections subpage (build
        // 74 split Settings into a hub; Bank Connection and Email
        // Alerts both live on the Connections subpage now).
        // Coordinate taps (see tapCoordinate): menu items and hub
        // rows are on screen and a plain .tap() risks the AX
        // scroll-to-visible failure.
        tapCoordinate(app.buttons["Profile"])
        let settingsItem = app.buttons["Settings"]
        XCTAssertTrue(
            settingsItem.waitForExistence(timeout: 15),
            "Profile menu did not offer Settings"
        )
        tapCoordinate(settingsItem)
        let connectionsHubRow = app.buttons["settings.hub.connections"]
        XCTAssertTrue(
            connectionsHubRow.waitForExistence(timeout: 30),
            "Settings hub did not render (no Connections row)"
        )
        tapCoordinate(connectionsHubRow)
        XCTAssertTrue(
            app.staticTexts["Bank Connection"].waitForExistence(timeout: 30),
            "Connections subpage did not render (no Bank Connection card)"
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
        // Coordinate taps (see tapCoordinate): menu items and the
        // export chip are on screen, and a plain .tap() risks the
        // AX scroll-to-visible failure that killed the page-select
        // taps in run 45542061108.
        tapCoordinate(app.buttons["header.more"])
        let exportChip = app.buttons["export.open"]
        XCTAssertTrue(
            exportChip.waitForExistence(timeout: 15),
            "Export chip missing on Transactions"
        )
        tapCoordinate(exportChip)
        XCTAssertTrue(
            app.staticTexts["Export Transactions"].waitForExistence(timeout: 15),
            "Export popup did not open after tapping Export"
        )
        XCTAssertTrue(
            app.staticTexts["export.count"].waitForExistence(timeout: 60),
            "Export popup did not show a transaction count after fetching the history"
        )
        attachScreenshot(named: "09-export-popup")

        // -- Filter picker (build 61) -------------------------------
        // Choosing Filtered must let the user pick HOW to filter —
        // kind, date range, amount, account. The controls live in
        // the popup; picking a kind updates the summary and the
        // count, and Clear Filters restores the no-filters state.
        let kindPicker = app.buttons["export.filter.kind"]
        XCTAssertTrue(
            kindPicker.waitForExistence(timeout: 15),
            "Kind filter picker missing on Export popup"
        )
        XCTAssertTrue(
            app.buttons["export.filter.when"].waitForExistence(timeout: 15),
            "Date filter missing on Export popup"
        )
        XCTAssertTrue(
            app.buttons["export.filter.card"].waitForExistence(timeout: 15),
            "Account filter picker missing on Export popup"
        )
        XCTAssertTrue(
            app.textFields["export.filter.min"].waitForExistence(timeout: 15),
            "Min amount field missing on Export popup"
        )
        XCTAssertTrue(
            app.textFields["export.filter.max"].waitForExistence(timeout: 15),
            "Max amount field missing on Export popup"
        )
        // Round 4 (run 45688666692): open the menu with a plain
        // .tap(), not a coordinate tap — the coordinate tap was
        // not activating this menu Picker, so the menu never
        // opened and 'Charge' never surfaced. The picker sits in
        // a scrollable sheet (unlike the page select in its
        // non-scrollable shell), so XCTest can scroll it into
        // view and a plain tap works.
        kindPicker.tap()
        // The Menu-style Picker exposes its options as menuItems
        // or as buttons depending on the iOS version — poll for
        // either and tap whichever appears. Round 2: pass a reopen
        // tap — a coordinate tap on the PopUpButton can be absorbed
        // (run 45650165521: 'Charge' never surfaced after one tap),
        // so tapPickerOption re-taps the picker once mid-wait.
        // Round 4 (run 45688666692): the menu STILL never opened
        // — the coordinate tap is not activating this menu Picker
        // (unlike the page select, the picker sits in a scrollable
        // sheet, so a plain .tap() is the standard menu open and
        // XCTest can scroll it into view). Reopen with a plain
        // .tap() instead of another coordinate tap.
        tapPickerOption("Charge", reopen: { kindPicker.tap() })
        // The summary now names the picked kind, and the count
        // still shows (the filtered count).
        let summaryCharge = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'Charge'")).firstMatch
        XCTAssertTrue(
            summaryCharge.waitForExistence(timeout: 15),
            "Filter summary did not show the picked kind"
        )
        XCTAssertTrue(
            app.staticTexts["export.count"].waitForExistence(timeout: 30),
            "Count disappeared after picking a kind filter"
        )
        attachScreenshot(named: "09-export-filtered-kind")
        // Clear Filters restores the no-filters state.
        tapCoordinate(app.buttons["export.filter.clear"])
        let summaryClear = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'No filters active'")).firstMatch
        XCTAssertTrue(
            summaryClear.waitForExistence(timeout: 15),
            "Clear Filters did not restore the no-filters summary"
        )

        // -- Generate (PDF, filtered) opens the PREVIEW first ----
        // Build 59 (owner, Nov 22, 2026): a PDF is previewed
        // in-app before anything is shared — Generate opens the
        // preview sheet, Share inside it opens the share sheet.
        tapCoordinate(app.buttons["export.generate"])
        XCTAssertTrue(
            app.buttons["export.preview.share"].waitForExistence(timeout: 30),
            "Preview did not appear after Generate (PDF)"
        )
        attachScreenshot(named: "10-export-preview")
        tapCoordinate(app.buttons["export.preview.share"])
        XCTAssertTrue(
            app.staticTexts["AirDrop"].waitForExistence(timeout: 30),
            "Share sheet did not appear after Share in the preview (no AirDrop section)"
        )
        attachScreenshot(named: "10-export-share-sheet")
        tapHittableCancel()
        // Back on the preview — close it to return to the popup.
        tapCoordinate(app.buttons["export.preview.close"])
        XCTAssertTrue(
            app.staticTexts["export.count"].waitForExistence(timeout: 15),
            "Closing the preview did not return to the export popup"
        )

        // -- Export all + CSV ---------------------------------------
        app.segmentedControls["export.scope"].buttons["All"].tap()
        app.segmentedControls["export.format"].buttons["CSV"].tap()
        XCTAssertTrue(
            app.staticTexts["export.count"].waitForExistence(timeout: 30),
            "Export popup lost its count after switching to All + CSV"
        )
        tapCoordinate(app.buttons["export.generate"])
        XCTAssertTrue(
            app.staticTexts["AirDrop"].waitForExistence(timeout: 30),
            "Share sheet did not appear after Generate for All + CSV"
        )
        attachScreenshot(named: "11-export-all-csv")
        tapHittableCancel()

        // -- Close returns to the Transactions list ------------------
        tapCoordinate(app.buttons["Close"])
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
        // The hero amount Text still carries the home.heroAmount
        // identifier, but it is shadowed by the hero card
        // container's own accessibilityLabel (the container is the
        // single AX element) — an identifier query never matches
        // it. Find it by its spoken label instead, which the
        // label-based pattern in testVideoScreens already proved
        // works in this suite.
        let heroAmount = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'left this week' OR label CONTAINS 'over budget'")
        ).firstMatch
        XCTAssertTrue(
            heroAmount.waitForExistence(timeout: 60),
            "Home hero amount did not appear in the card body (expected a 'left this week' / 'over budget' label)"
        )
        // The donut's identifier (home.heroDonut) never surfaces as
        // its own element — the ZStack's children are exposed
        // individually, and the percent + "used" Texts read as
        // staticTexts carrying the donut's spoken label ("X percent
        // of the weekly budget used", run 45588370579 hierarchy
        // dump). So find it by its spoken label among staticTexts,
        // not otherElements.
        let heroDonut = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'percent of the weekly budget used'")
        ).firstMatch
        XCTAssertTrue(
            heroDonut.waitForExistence(timeout: 15),
            "Home hero progress circle did not appear beside the amount (expected a 'percent of the weekly budget used' label)"
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

        // The hero amount / Tzedaka amount identifiers are
        // shadowed by their card containers' accessibilityLabels
        // (see testHomeHeroAmountAndDonut) — find the hero by its
        // spoken label and the Tzedaka amount by the card label,
        // which reads "<name>, $<amount>, show fund" once loaded.
        // The Tzedaka card's identifier (home.tzedakaCard) lands
        // on its CHILDREN (Image + staticTexts), not on a separate
        // Other element — so query staticTexts by identifier, not
        // otherElements (run 45588370579 hierarchy dump).
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'left this week' OR label CONTAINS 'over budget'")
            ).firstMatch.waitForExistence(timeout: 60),
            "Simple Home hero amount did not appear (expected a 'left this week' / 'over budget' label)"
        )
        let tzedakaCard = app.staticTexts.matching(identifier: "home.tzedakaCard").firstMatch
        XCTAssertTrue(
            tzedakaCard.waitForExistence(timeout: 15),
            "Simple Home Tzedaka card did not appear second (home.tzedakaCard)"
        )
        XCTAssertTrue(
            tzedakaCard.label.contains("$"),
            "Simple Home Tzedaka card has no amount (expected a '$' amount in its label; got '\(tzedakaCard.label)')"
        )
        // The quiet rows are Buttons, but their identifier is the
        // quiet CARD's (home.quietCard) — the container's
        // identifier wins over the rows' own home.quietSavings /
        // home.quietDebt in the AX tree (run 45588370579 dump).
        // Distinguish the rows by their fund-name label: Proof
        // Household 2 uses the default names (Extra Fund, Debt).
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier == 'home.quietCard' AND label CONTAINS 'Extra Fund'")).firstMatch
                .waitForExistence(timeout: 15),
            "Simple Home quiet Extra Fund row did not appear (home.quietCard / Extra Fund)"
        )
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier == 'home.quietCard' AND label CONTAINS 'Debt'")).firstMatch
                .waitForExistence(timeout: 15),
            "Simple Home quiet Debt row did not appear (home.quietCard / Debt)"
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
        // The walkthrough starts on first Home entry and its dimmed
        // overlay hides the background from the accessibility tree —
        // dismiss it before waiting on the hero/cards (run
        // 44975531594: the Funds Charity card was on screen behind
        // the tour and its 90 s wait still failed).
        dismissTourIfPresent()
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
        // The quiet rows are Buttons (HomeView), not static texts —
        // a staticTexts lookup never matches them. Their identifier
        // is the quiet CARD's (home.quietCard) — the container's
        // identifier wins over the rows' own home.quietSavings in
        // the AX tree (run 45588370579 dump) — so query the card
        // identifier and distinguish the row by its fund-name
        // label. Goldstein's fund reads "Savings" (the 'left this
        // week' and 'Charity' checks above are card containers
        // whose labels DO surface as static texts, and they passed
        // in the build-73 run — leave them alone).
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier == 'home.quietCard' AND label CONTAINS 'Savings'")).firstMatch
                .waitForExistence(timeout: 15),
            "Home quiet Extra Fund row did not appear (home.quietCard / Savings)"
        )
        // Let the amounts settle (no skeleton, no toast) before the shot.
        Thread.sleep(forTimeInterval: 3)
        dismissNotificationAlertIfPresent()
        attachScreenshot(named: "video-01-home")

        // -- Transactions (scene 3) -----------------------------------
        tapTab(identifier: "tab.transactions", label: "Transactions")
        // Round 2 (run 45650165521): the tab tap fired but the app
        // stayed on Home — the failure-time hierarchy shows Home,
        // no Transactions rows, no Try Again. A tap can be absorbed
        // (toast/alert covering the page select, or a race with the
        // Home load). So verify the navigation actually landed: if
        // the Transactions header is not there within 10s, tap the
        // tab again before waiting on rows.
        // Round 3 (run 45673494611): BOTH the first tap and the
        // Round-2 re-tap were absorbed — the app stayed on Home
        // (all 5 failure dumps are Home, 0 transaction.row). The
        // re-tap used the same tapTab coordinate tap that had just
        // failed, so retrying it changed nothing.
        // Round 4 (run 45688666692): a plain .tap() retry is NOT
        // the answer — it throws kAXErrorCannotComplete
        // (scroll-to-visible) on the page-select buttons, failing
        // the test outright. So retry with tapTab again, but only
        // after a settle delay: the first tap can land while Home
        // is still loading/animating, and an immediate re-tap
        // hits the same unsettled state.
        let transactionsHeader = app.staticTexts["Transactions"]
        if !transactionsHeader.waitForExistence(timeout: 10) {
            Thread.sleep(forTimeInterval: 3)
            tapTab(identifier: "tab.transactions", label: "Transactions")
            if !transactionsHeader.waitForExistence(timeout: 10) {
                Thread.sleep(forTimeInterval: 3)
                tapTab(identifier: "tab.transactions", label: "Transactions")
            }
        }
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
        tapCoordinate(app.buttons["+ Add"])
        let purchaseButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Purchase'")).firstMatch
        XCTAssertTrue(
            purchaseButton.waitForExistence(timeout: 15),
            "Add options did not appear after tapping + Add"
        )
        tapCoordinate(purchaseButton)
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
        tapCoordinate(app.buttons["Cancel"])

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
        // Round 2: same slow-reload / absorbed-tap risk as
        // testVideoRecordings scene 7 — give the hero 60s and
        // re-tap Home once mid-wait if it has not reappeared.
        // Round 3 (run 45673494611): same stale-`firstMatch` risk
        // as testVideoRecordings scene 7 — the hero reference goes
        // stale across a Home reload, so poll with a fresh query.
        // Round 4 re-run (45704206944) hit the 90-min job timeout
        // with no test results, so the 90s waits are trimmed back
        // to 60s total (fresh query is the real fix; if it works
        // the hero appears fast, and if not, 90s only burns
        // timeout budget).
        if !waitForStaticTextContaining("left this week", timeout: 30) {
            tapTab(identifier: "tab.home", label: "Home")
        }
        XCTAssertTrue(
            waitForStaticTextContaining("left this week", timeout: 30),
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
        // The walkthrough starts on first Home entry and its dimmed
        // overlay hides the background from the accessibility tree —
        // dismiss it before waiting on the hero/cards (run
        // 44975531594: the Funds Charity card was on screen behind
        // the tour and its 90 s wait still failed).
        dismissTourIfPresent()
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
        settleNotificationAlertIfNeeded()
        dismissTourIfPresent()
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
        // Round 2: same absorbed-tap risk as testVideoScreens —
        // verify the navigation landed before waiting on rows.
        // Round 3 (run 45673494611): the Round-2 re-tap used the
        // same coordinate tap that had just been absorbed, so it
        // changed nothing.
        // Round 4 (run 45688666692): a plain .tap() retry is NOT
        // the answer — it throws kAXErrorCannotComplete
        // (scroll-to-visible) on the page-select buttons. Retry
        // with tapTab again, but only after a settle delay.
        let transactionsHeader = app.staticTexts["Transactions"]
        if !transactionsHeader.waitForExistence(timeout: 10) {
            Thread.sleep(forTimeInterval: 3)
            tapTab(identifier: "tab.transactions", label: "Transactions")
            if !transactionsHeader.waitForExistence(timeout: 10) {
                Thread.sleep(forTimeInterval: 3)
                tapTab(identifier: "tab.transactions", label: "Transactions")
            }
        }
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
        tapCoordinate(app.buttons["+ Add"])
        let purchaseButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Purchase'")).firstMatch
        XCTAssertTrue(
            purchaseButton.waitForExistence(timeout: 15),
            "Add options did not appear after tapping + Add"
        )
        tapCoordinate(purchaseButton)
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
        // Round 2 (run 45650165521): the hero did not reappear
        // within 30s — Home refetches after the Scene-6 add and
        // the reload can be slow on the simulator backend, and the
        // failure-time hierarchy shows the hero DID load (just
        // after the timeout). Give it 60s, and re-tap Home once
        // mid-wait in case the first tab tap was absorbed.
        // Round 3 (run 45673494611): the 60s wait STILL failed
        // even though both failure-time dumps show the hero
        // StaticText present — the reused `firstMatch` reference
        // went stale across the Home reload. Poll with a FRESH
        // query each time (waitForStaticTextContaining) instead.
        // Round 4 (run 45688666692): the fresh-query 60s wait
        // STILL failed, and the log shows "App animations complete
        // notification not received" — Home's refetch after the
        // Scene-6 add can take very long on the simulator backend.
        // Round 4 re-run (45704206944) hit the 90-min job timeout
        // with no test results, so the 90s waits are trimmed back
        // to 60s total: the fresh query is the real fix, and if
        // it works the hero appears fast.
        if !waitForStaticTextContaining("left this week", timeout: 30) {
            tapTab(identifier: "tab.home", label: "Home")
        }
        XCTAssertTrue(
            waitForStaticTextContaining("left this week", timeout: 30),
            "Home hero amount did not reappear"
        )
        Thread.sleep(forTimeInterval: 6)
        videoMark("DONE")
    }

    /// Tour video (Nov 27, 2026 — accurate-rebuild review): run the
    /// rebuilt 39-step walkthrough end to end in the simulator while
    /// `simctl io recordVideo` captures it, so the owner can review
    /// every tooltip + highlight for accuracy BEFORE it ships live.
    /// Same sign-in + join preamble as testVideoRecordings (fresh
    /// account, test household as a member). The tour auto-shows on
    /// first Home entry; the test taps Next through every step.
    /// Admin-only steps are skipped for members, so a member sees
    /// ~31 of 39 — the three page-overview steps (now centred
    /// tooltips, no spotlight) and all member-visible spotlights are
    /// covered. Sheets (Weekly, Calculator, Add, Settings) open and
    /// close as the tour drives them; the test just taps Next and
    /// waits for each transition. The notification alert is settled
    /// first so it cannot pop up mid-tour and block a Next tap.
    /// Run ONLY via the tour-video workflow
    /// (ios-clone-tour-video.yml / macos_tour_video.sh) — it is not
    /// part of the simulator proof suite.
    func testTourVideo() throws {
        guard let account = createConfirmedTestAccount() else { return }
        signInWithAccount(email: account.email, password: account.password)

        // Join the test household (videoHouseholdName) as a member (same as testVideoScreens).
        let inviteField = app.textFields["household.inviteCode"]
        waitForElement(
            inviteField, timeout: 90, screenshotName: "tour-household-missing",
            message: "Household screen did not appear after sign-in (\(diagnosePostSignInState()))"
        )
        tapAndTypeText(inviteField, videoHouseholdInviteCode, fieldName: "household.inviteCode")
        dismissKeyboardIfPresent(focusedField: inviteField)
        app.buttons["household.joinAsMember"].tap()

        XCTAssertTrue(
            app.staticTexts[videoHouseholdName].waitForExistence(timeout: 90),
            "Home did not render after joining the household (no household title)"
        )
        // Settle the notification alert BEFORE stepping, so it cannot
        // pop up mid-tour and block a Next tap (it appears ~11-35 s
        // after Home loads; once dismissed it never returns for this
        // install).
        settleNotificationAlertIfNeeded()

        // Start the tour on demand via Settings → App → Replay
        // Tutorial. The tour no longer auto-shows on first Home
        // entry (auto-show default OFF since build 113), so the
        // test starts it explicitly — the same button a user taps.
        tapCoordinate(app.buttons["Profile"])
        let settingsItem = app.buttons["Settings"]
        XCTAssertTrue(
            settingsItem.waitForExistence(timeout: 10),
            "Profile menu did not offer Settings"
        )
        tapCoordinate(settingsItem)
        let appHubRow = app.buttons["settings.hub.app"]
        XCTAssertTrue(
            appHubRow.waitForExistence(timeout: 30),
            "Settings hub did not render (no App row)"
        )
        tapCoordinate(appHubRow)
        let replayButton = app.buttons["settings.replayTutorial"]
        XCTAssertTrue(
            replayButton.waitForExistence(timeout: 30),
            "App settings did not offer Replay Tutorial"
        )
        tapCoordinate(replayButton)

        // Replay returns to Home and starts the tour. Wait for its
        // tooltip (Next button).
        let nextButton = app.buttons["Next"]
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: 60),
            "Tour tooltip did not appear after Replay Tutorial"
        )
        videoMark("TOUR-START")

        // Step through the tour: tap Next (Done on the last step),
        // wait for the transition (tab switch / sheet open / close),
        // repeat until the tooltip is gone. Cap at 45 taps so a
        // stuck tour cannot loop forever. 2.5 s per step is a brisk
        // but watchable pace — the owner reads each tooltip.
        var taps = 0
        while taps < 45 {
            if app.buttons["Done"].exists {
                videoMark("TOUR-STEP-DONE")
                app.buttons["Done"].tap()
                break
            }
            guard app.buttons["Next"].exists else { break }
            taps += 1
            videoMark("TOUR-STEP-\(taps)")
            app.buttons["Next"].tap()
            Thread.sleep(forTimeInterval: 2.5)
        }
        // The tour is over when its tooltip (Next/Done) is gone.
        XCTAssertFalse(app.buttons["Next"].exists, "Tour tooltip still showing after \(taps) Next taps")
        XCTAssertFalse(app.buttons["Done"].exists, "Tour Done button still showing")
        videoMark("TOUR-DONE")
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
    /// Cash gift record + delete (build 40, Nov 16, 2026): the
    /// Charity card's Record a Donation moves Available to Given
    /// and logs a "Cash donation" row in the Charity Activity
    /// feed; deleting the row reverses it and the row leaves the
    /// feed. Rewritten for the current app (build 74): the record
    /// popup is now the TzedakaActionSheet (mode slider "Add" /
    /// "Record a Donation", submit "Record Donation", amount field
    /// placeholder "0.00") and the feed row is labelled "Cash
    /// donation", not "Cash gift". The test creates its OWN
    /// household (signInAndCreateTestHousehold) because recording
    /// a cash gift is admin-only and a member of Proof Household
    /// 2 can never record one — and it seeds $5 Available first
    /// via "Add to Charity", because a fresh household has $0
    /// Available and the record is capped at Available.
    func testDeleteCashGiftFromFundsFeed() throws {
        _ = signInAndCreateTestHousehold()

        tapTab(identifier: "tab.funds", label: "Funds")
        // Round 3 (run 45673494611): the Funds tap was absorbed —
        // the app stayed on Home and funds.charity never appeared
        // in 90s (the failure-time hierarchy is Home, no funds.*
        // identifiers). Verify the navigation landed: the Extra
        // Fund card (funds.extraFund) is the Funds-page marker
        // testPageSelectIsSingleNavigation proves.
        // Round 4 (run 45688666692): a plain .tap() retry is NOT
        // the answer — it throws kAXErrorCannotComplete
        // (scroll-to-visible) on the page-select buttons, failing
        // the test outright. Retry with tapTab again, but only
        // after a settle delay.
        let fundsMarker = app.buttons.matching(identifier: "funds.extraFund").firstMatch
        if !fundsMarker.waitForExistence(timeout: 10) {
            Thread.sleep(forTimeInterval: 3)
            tapTab(identifier: "tab.funds", label: "Funds")
            if !fundsMarker.waitForExistence(timeout: 10) {
                Thread.sleep(forTimeInterval: 3)
                tapTab(identifier: "tab.funds", label: "Funds")
            }
        }
        let charityCard = app.buttons.matching(identifier: "funds.charity").firstMatch
        XCTAssertTrue(
            charityCard.waitForExistence(timeout: 90),
            "Funds did not render (no Charity card)"
        )
        // Expand the Charity card: the Add / Record buttons live
        // in the expanded card. Scroll it into view first — it can
        // sit below the fold when another card is expanded, and a
        // coordinate tap on an off-screen card misses (run
        // 45588370579: the tap never expanded the card and
        // funds.addToCharity never appeared). Tap by coordinate
        // (see tapCoordinate) — the card is on screen and a plain
        // .tap() risks the AX scroll-to-visible failure.
        let fundsScroll = app.scrollViews.firstMatch
        for _ in 0..<4 {
            if charityCard.isHittable { break }
            fundsScroll.swipeUp()
        }
        tapCoordinate(charityCard)

        // -- Seed $5 Available via "Add to Charity" ---------------
        // If the Add button does not appear, the tap may have been
        // absorbed — tap again once, but only if the card is not
        // already expanded (the Record button lives in the same
        // expanded detail, so its presence proves the card is
        // open and a second tap would collapse it).
        // Round 2 (run 45650165521): the Add / Record buttons do
        // NOT surface under funds.addToCharity / funds.recordCashGift
        // — the card container's identifier 'funds.charity' wins
        // over the children's own identifiers in the AX tree (the
        // hierarchy dump proves it: the buttons exist with
        // identifier 'funds.charity' and labels 'Add to Charity' /
        // 'Record a Donation'). Query by LABEL instead.
        let addButton = app.buttons.matching(NSPredicate(format: "label == 'Add to Charity'")).firstMatch
        if !addButton.waitForExistence(timeout: 15) {
            let recordIsThere = app.buttons.matching(NSPredicate(format: "label == 'Record a Donation'")).firstMatch
            if !recordIsThere.exists {
                tapCoordinate(charityCard)
            }
        }
        XCTAssertTrue(
            addButton.waitForExistence(timeout: 30),
            "Charity card did not offer Add to Charity after expanding"
        )
        addButton.tap()
        let addAmountField = app.textFields["0.00"]
        XCTAssertTrue(
            addAmountField.waitForExistence(timeout: 15),
            "Add to Charity sheet did not show an amount field"
        )
        tapAndTypeText(addAmountField, "5.00", fieldName: "add amount")
        dismissKeyboardIfPresent(focusedField: addAmountField)
        // The sheet's submit shares its "Add to Charity" label
        // with the section button behind the sheet — tap the
        // hittable one (the submit), not the covered one.
        tapHittableButton(label: "Add to Charity")
        // The sheet closes when the save succeeds — prove it by
        // the amount field disappearing before going on.
        let sheetClosed = NSPredicate(format: "exists == false")
        expectation(for: sheetClosed, evaluatedWith: addAmountField, handler: nil)
        waitForExpectations(timeout: 15, handler: nil)

        // -- Record a $1 cash donation ------------------------------
        // Round 2: same AX rule as the Add button above — the
        // Record button surfaces with identifier 'funds.charity'
        // and label 'Record a Donation', not funds.recordCashGift.
        let recordButton = app.buttons.matching(NSPredicate(format: "label == 'Record a Donation'")).firstMatch
        XCTAssertTrue(
            recordButton.waitForExistence(timeout: 30),
            "Charity card did not offer Record a Donation after expanding"
        )
        recordButton.tap()
        // The sheet opens in Record mode (the Record button
        // pre-sets it); its amount field is the proof it opened —
        // the "Record a Donation" label also matches the section
        // button behind the sheet, so it cannot prove anything.
        let amountField = app.textFields["0.00"]
        XCTAssertTrue(
            amountField.waitForExistence(timeout: 15),
            "Record sheet did not show an amount field"
        )
        tapAndTypeText(amountField, "1.00", fieldName: "record amount")
        dismissKeyboardIfPresent(focusedField: amountField)
        tapCoordinate(app.buttons["Record Donation"])
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cash donation'")).firstMatch
                .waitForExistence(timeout: 30),
            "Cash donation did not appear in the Charity Activity feed after recording"
        )

        // -- Delete it from the feed --------------------------------
        let cashGiftRows = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cash donation'"))
        let countBefore = cashGiftRows.count
        XCTAssertGreaterThan(countBefore, 0, "No Cash donation row to delete")
        // The row is the most recent feed entry, so it is at the
        // top of the feed; a plain .tap() scrolls it into view if
        // needed.
        cashGiftRows.firstMatch.tap()
        let deleteButton = app.buttons["funds.deleteCashGift"]
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 15),
            "Cash donation detail did not offer Delete"
        )
        deleteButton.tap()
        let confirmButton = app.buttons["funds.confirmDeleteCashGift"]
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: 15),
            "Delete confirm did not appear for the cash donation"
        )
        confirmButton.tap()
        // The row leaves the feed once the reversal lands (the
        // fetch filters status == active).
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: cashGiftRows.firstMatch, handler: nil)
        waitForExpectations(timeout: 30, handler: nil)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cash donation'")).count,
            countBefore - 1,
            "Cash donation row is still in the feed after Delete"
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
        // Coordinate taps (see tapCoordinate): menu items are on
        // screen and a plain .tap() risks the AX scroll-to-visible
        // failure that killed the page-select taps in run
        // 45542061108. One retry: a tap that lands on the menu's
        // dismiss area closes the menu without navigating.
        tapCoordinate(app.buttons["header.more"])
        let pastWeeksLink = app.buttons["Past Weeks"]
        XCTAssertTrue(
            pastWeeksLink.waitForExistence(timeout: 15),
            "Past Weeks link missing on Transactions (shell did not supply the handler)"
        )
        tapCoordinate(pastWeeksLink)
        // The subpage marker is the "About Past Weeks" ⓘ — build
        // 68 moved the explainer behind it, so it is no longer an
        // inline staticText and waiting for the explainer text can
        // never pass. Retry the menu tap ONLY if the subpage did
        // not open: tapping header.more while already on the
        // subpage crashes the query (run 45588370579), because
        // header.more is not on the subpage.
        if !app.buttons["About Past Weeks"].waitForExistence(timeout: 15) {
            // Still on the Transactions list — the first tap missed
            // the menu item. Retry once, guarded by header.more
            // still existing.
            if app.buttons["header.more"].exists {
                tapCoordinate(app.buttons["header.more"])
                XCTAssertTrue(
                    pastWeeksLink.waitForExistence(timeout: 15),
                    "Past Weeks link missing on Transactions on the retry (shell did not supply the handler)"
                )
                tapCoordinate(pastWeeksLink)
            }
        }
        XCTAssertTrue(
            app.buttons["About Past Weeks"].waitForExistence(timeout: 60),
            "Past Weeks subpage did not open"
        )
        // The explainer lives behind the ⓘ — open it, prove the
        // text is there, then dismiss.
        tapCoordinate(app.buttons["About Past Weeks"])
        let aboutAlert = app.alerts["Past Weeks"]
        XCTAssertTrue(
            aboutAlert.waitForExistence(timeout: 15),
            "About Past Weeks did not open the explainer alert"
        )
        XCTAssertTrue(
            aboutAlert.staticTexts["Closed weeks, read-only. Tap a week to see its summary and its transactions."].waitForExistence(timeout: 15),
            "Explainer alert did not show the Past Weeks explainer text"
        )
        aboutAlert.buttons["OK"].tap()
        attachScreenshot(named: "07-past-weeks")

        // -- Back returns to the Transactions list -----------------------
        tapCoordinate(app.buttons["Back"])
        XCTAssertTrue(
            app.buttons.matching(identifier: "transaction.row").firstMatch
                .waitForExistence(timeout: 30),
            "Back from Past Weeks did not return to the Transactions list"
        )

        // -- Activity pushes ---------------------------------------------
        // Build 53 (audit U2): Activity lives in the "More" menu now.
        tapCoordinate(app.buttons["header.more"])
        let activityLink = app.buttons["Activity"]
        XCTAssertTrue(
            activityLink.waitForExistence(timeout: 15),
            "Activity link missing on Transactions (shell did not supply the handler)"
        )
        tapCoordinate(activityLink)
        if !app.staticTexts["General Activity"].waitForExistence(timeout: 15) {
            tapCoordinate(app.buttons["header.more"])
            XCTAssertTrue(
                activityLink.waitForExistence(timeout: 15),
                "Activity link missing on Transactions on the retry (shell did not supply the handler)"
            )
            tapCoordinate(activityLink)
        }
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
            return lower.contains("invalid") || lower.contains("incorrect") || lower.contains("wrong")
                || lower.contains("fail") || lower.contains("error") || lower.contains("could not")
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
        if app.textFields["household.inviteCode"].exists {
            return "still on the Household screen (join did not complete — the invite field is showing; visible text: \(visibleErrorText()))"
        }
        // Home's title is the household NAME (either household the
        // tests join), and the page select is the other Home signal.
        // The old check looked for "Weekly Budget", which is not a
        // visible text on Home at all — so a fully-rendered Home
        // was reported as "unknown state" (run 44970315808).
        if app.staticTexts[proofHouseholdName].exists || app.staticTexts[videoHouseholdName].exists
            || app.buttons["pageSelect.home"].exists || app.buttons["Home"].exists {
            return "Home already rendered (the account already has a household?)"
        }
        return "unknown state (not auth, not boot-error, not session-expired, not Household screen, not Home)"
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

        // Home renders — its title is the household NAME
        // (proofHouseholdName), not "Weekly Budget" (see the
        // constant's comment). Then settle the one-time
        // notifications-permission alert before the test proceeds:
        // it is requested asynchronously after first Home load and
        // blocks every tap while it is up (run 44970315808).
        waitForElement(
            app.staticTexts[proofHouseholdName], timeout: 90, screenshotName: "04-home-missing",
            message: "Home did not render after joining the household (\(diagnosePostSignInState()))"
        )
        settleNotificationAlertIfNeeded()
        dismissTourIfPresent()
        XCTAssertTrue(
            app.buttons["pageSelect.home"].exists
                || app.buttons["Home"].exists,
            "Tab bar missing on Home"
        )
        attachScreenshot(named: "04-home")
    }

    /// Create a fresh pre-confirmed account, sign in, and CREATE a
    /// household (instead of joining one). Household creation was
    /// re-enabled by the owner (build 72, Nov 24, 2026), so the
    /// test account is the household's OWNER — and therefore an
    /// admin, which the cash-gift record flow requires (Record a
    /// Donation is admin-only; joining Proof Household 2 as a
    /// member can never record one). Returns the household name.
    /// The household is test data left behind deliberately: each
    /// run creates a fresh account + household, so nothing is
    /// shared between runs.
    private func signInAndCreateTestHousehold() -> String {
        guard let account = createConfirmedTestAccount() else { return "" }
        signInWithAccount(email: account.email, password: account.password)

        let householdName = "Cash Gift Test"
        let createButton = app.buttons["household.createHousehold"]
        waitForElement(
            createButton, timeout: 90, screenshotName: "cashgift-household-missing",
            message: "Household screen did not appear after sign-in (\(diagnosePostSignInState()))"
        )
        tapCoordinate(createButton)
        let nameField = app.textFields["household.nameField"]
        XCTAssertTrue(
            nameField.waitForExistence(timeout: 15),
            "Name panel did not appear after tapping Create Household"
        )
        tapAndTypeText(nameField, householdName, fieldName: "household.nameField")
        dismissKeyboardIfPresent(focusedField: nameField)
        tapCoordinate(app.buttons["household.createConfirm"])

        // Home renders — its title is the household NAME.
        waitForElement(
            app.staticTexts[householdName], timeout: 90, screenshotName: "cashgift-home-missing",
            message: "Home did not render after creating the household (\(diagnosePostSignInState()))"
        )
        settleNotificationAlertIfNeeded()
        dismissTourIfPresent()
        return householdName
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
        // Title is the household NAME (proofHouseholdName), not
        // "Weekly Budget" (see the constant's comment). Then settle
        // the one-time notifications-permission alert before the
        // test proceeds (run 44970315808).
        waitForElement(
            app.staticTexts[proofHouseholdName], timeout: 90, screenshotName: "04-home-missing",
            message: "Home did not render after joining the household (\(diagnosePostSignInState()))"
        )
        settleNotificationAlertIfNeeded()
        dismissTourIfPresent()
        XCTAssertTrue(
            app.buttons["pageSelect.home"].exists
                || app.buttons["Home"].exists,
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
        // Letters + digits ONLY — no "-" or "!" anywhere. This is
        // belt-and-braces: the real sign-in killer in run
        // 44970315808 was NOT the password (it typed fine — 20
        // dots, and the accounts sign in via curl) but the EMAIL
        // field's clear (see clearField): the pre-filled email was
        // only partly cleared, so the app submitted
        // "<new>@example.com@example.com" and GoTrue quite rightly
        // said "invalid credentials". A password with no
        // keyboard-plane switches ("-" and "!" live on the
        // numbers/symbols planes) removes one more way typeText
        // can garble a credential. The "@" and "." in the email
        // are unavoidable for a valid address and typed fine.
        let email = "iosclonevideo\(runId)@example.com"
        let password = "Video\(runId)2026"
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
    /// Email" step. tapAndTypeText verifies each typed value
    /// settled (see its comment — the AX value read races the
    /// typing), so a garbled credential fails here with the
    /// evidence instead of burning a 90 s wait on a doomed
    /// sign-in.
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
        // RESTORED Nov 25, 2026 — household creation re-opened by
        // the owner (build 72), so the stale invite-only skip is
        // gone. Body restored from git history (pre-skip commit
        // c9c1c7b^) and updated for the current app: Settings is
        // now a hub (build 74 — Bank Connection lives on the
        // Connections subpage), Home's title is the household NAME
        // (not "Weekly Budget"), and menu/hub taps use
        // tapCoordinate (plain .tap() risks the AX scroll-to-
        // visible failure). The Sandbox drive helper
        // (drivePlaidSandbox) is restored below with it.
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
        tapCoordinate(createButton)
        let nameField = app.textFields["household.nameField"]
        XCTAssertTrue(
            nameField.waitForExistence(timeout: 30),
            "Household name panel did not appear after Create Household"
        )
        tapAndTypeText(nameField, "Plaid Test", fieldName: "household.nameField")
        dismissKeyboardIfPresent(focusedField: nameField)
        tapCoordinate(app.buttons["household.createConfirm"])
        XCTAssertTrue(
            app.staticTexts["Plaid Test"].waitForExistence(timeout: 90),
            "Home did not render after creating the household"
        )
        attachScreenshot(named: "plaid-02-home")
        settleNotificationAlertIfNeeded()
        dismissTourIfPresent()

        // -- Settings → Connections → Bank Connection -------------------
        // Build 74 split Settings into a hub; Bank Connection lives
        // on the Connections subpage (same navigation as
        // testGmailCallbackDeepLink).
        tapCoordinate(app.buttons["Profile"])
        let settingsItem = app.buttons["Settings"]
        XCTAssertTrue(
            settingsItem.waitForExistence(timeout: 15),
            "Profile menu did not offer Settings"
        )
        tapCoordinate(settingsItem)
        let connectionsHubRow = app.buttons["settings.hub.connections"]
        XCTAssertTrue(
            connectionsHubRow.waitForExistence(timeout: 30),
            "Settings hub did not render (no Connections row)"
        )
        tapCoordinate(connectionsHubRow)
        XCTAssertTrue(
            app.staticTexts["Bank Connection"].waitForExistence(timeout: 30),
            "Connections subpage did not render (no Bank Connection card)"
        )
        attachScreenshot(named: "plaid-03-settings")

        // -- Connect → HARD assertion: the Link sheet opens --------------
        let connectButton = app.buttons["bank.connect"]
        XCTAssertTrue(
            connectButton.waitForExistence(timeout: 15),
            "Connect Account button missing (admin-only — is this account admin?)"
        )
        tapCoordinate(connectButton)
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
        tapCoordinate(app.buttons["bank.sync"])
        let syncedLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Last synced'")).firstMatch
        XCTAssertTrue(
            syncedLine.waitForExistence(timeout: 180),
            "Sync did not finish within 180s (no 'Last synced' line in Settings)"
        )
        attachScreenshot(named: "plaid-11-synced")
        tapCoordinate(app.buttons["Back"])
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
    /// Sign up a fresh account via the public sign-up flow (one
    /// sign-up per run — the only test that exercises it). Email
    /// confirmation is OFF (owner, Nov 24, 2026), so after the
    /// name step the account signs in directly and lands on the
    /// Household screen — there is no "Check Your Email" step and
    /// no Admin-API confirm is needed. The @example.com address
    /// can never receive email, which is fine because none is
    /// ever sent.
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
        // run's account. example.com is unroutable, which is fine:
        // no confirmation email is ever sent (confirmation is OFF).
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

        // -- 4. Signed in straight to the Household screen --------------
        // Confirmation is OFF, so createAccount returns .signedIn
        // and the app boots straight to the Household screen (the
        // invite-code field is the proof it landed there). Build 53
        // (audit W1): when this fails, the message names the app's
        // actual error text — the 429 gate was blamed for 8
        // failures with no rate-limit string in the log, because no
        // failure ever captured it.
        let inviteField = app.textFields["household.inviteCode"]
        if !inviteField.waitForExistence(timeout: 60) {
            attachScreenshot(named: "02-signup-failed")
            XCTFail("Household screen did not appear after Create Account (sign-up may have failed; confirmation is OFF so there is no 'Check Your Email' step); visible text: \(visibleErrorText())")
        }
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

    // MARK: - Admin API (pre-confirmed accounts only)

    /// Supabase Auth Admin API base for the live project (public
    /// URL, same project as the app's Configuration.supabaseURL).
    /// Used by createConfirmedTestAccount to create pre-confirmed
    /// test accounts. Email confirmation is OFF (owner, Nov 24,
    /// 2026), so signUpFreshAccount no longer confirms anything
    /// via the Admin API — the confirm helpers were removed.
    private static let supabaseAuthAdminBase = "https://tnkhvdkmwmwiogiienee.supabase.co/auth/v1/admin"

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

    /// Wait for a static text whose label contains `substring`,
    /// re-querying FRESH on every poll. A single `firstMatch`
    /// reference held across a view reload goes stale: the Home
    /// hero is destroyed and recreated when Home refetches after
    // an add, and `waitForExistence` on the stale reference keeps
    // returning false even though the hero IS in the hierarchy
    // (run 45673494611: both failure-time dumps show the hero
    // StaticText, yet the reused `firstMatch` wait failed twice).
    /// Rebuilding the query each poll cannot go stale.
    private func waitForStaticTextContaining(_ substring: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let el = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", substring)).firstMatch
            if el.exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Tap an element by its centre coordinate, NOT by plain
    /// .tap(). A plain .tap() asks XCTest to scroll the element
    /// into view first (AX kAXScrollToVisibleAction), and that
    /// scroll fails with kAXErrorCannotComplete on elements that
    /// are already on screen but sit in a non-scrollable container
    /// — the shell's floating page select (run 45542061108:
    /// pageSelect.funds / pageSelect.home both died this way) and
    /// menu items. A coordinate tap goes straight to the element's
    /// centre without the scroll step. Only use it for elements
    /// that are already on screen; elements below the fold in a
    /// scrollable list still want a plain .tap(), which scrolls
    /// them into view first.
    private func tapCoordinate(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Tap the hittable button with the given label. Several
    /// buttons can share a label (e.g. the "Add to Charity"
    /// section button behind its own sheet's "Add to Charity"
    /// submit) — the one behind the sheet is not hittable, so
    /// firstMatch would tap the wrong one. Polls briefly for a
    /// hittable match instead of failing on the covered one.
    private func tapHittableButton(label: String, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label))
            for index in 0..<buttons.count {
                let button = buttons.element(boundBy: index)
                if button.isHittable {
                    button.tap()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("No hittable button labelled '\(label)' appeared within \(timeout)s")
    }

    /// Tap a menu/picker option by label. A SwiftUI Menu or menu
    /// Picker can expose its options as menuItems or as buttons
    /// depending on the iOS version and the picker style, so poll
    /// for either and tap whichever appears, by coordinate (the
    /// same scroll-to-visible failure as tapTab applies to menu
    /// items). Fails with the visible menu state when neither
    /// appears.
    private func tapPickerOption(_ label: String, timeout: TimeInterval = 15, reopen: (() -> Void)? = nil) {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var reopened = false
        while Date() < deadline {
            let menuItem = app.menuItems[label]
            if menuItem.exists {
                tapCoordinate(menuItem)
                return
            }
            let button = app.buttons[label]
            if button.exists {
                tapCoordinate(button)
                return
            }
            // A SwiftUI .pickerStyle(.menu) Picker is a PopUpButton
            // and its options can surface as menuItems, buttons, or
            // another type depending on the iOS version — match ANY
            // element type by label so the option is found however
            // it is exposed (run 45588370579: "Charge" never
            // appeared as a menuItem or a button).
            let any = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", label)).firstMatch
            if any.exists {
                tapCoordinate(any)
                return
            }
            // Round 2 (run 45650165521): the menu never opened at
            // all — a coordinate tap on the PopUpButton can be
            // absorbed (sheet animation, scroll-view). If the caller
            // gave a reopen tap, fire it once mid-wait so the menu
            // gets a second chance to open.
            // Round 3 (run 45673494611): the reopen fired on the
            // FIRST poll (Date() < deadline - 5s is true at t=0),
            // double-tapping the picker and toggling the menu shut
            // before it opened — 'Charge' never surfaced. Only
            // re-tap after 5s, once the first tap has had a real
            // chance to open the menu.
            if let reopen, !reopened, Date().timeIntervalSince(start) >= 5 {
                reopened = true
                reopen()
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("Picker/menu did not offer '\(label)' within \(timeout)s; visible text: \(visibleErrorText())")
    }

    // MARK: - Plaid Sandbox drive (restored Nov 25, 2026 with
    // testPlaidSandboxConnect; removed in c9c1c7b when the test
    // was skipped for invite-only). See the file header for the
    // run-42746242404 defences (probe presentation first on the
    // webview leaf only; short-slice polls; XCUIScreen
    // screenshots so a wedged webview can never fail the test
    // from a screenshot).
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

    /// Tab-bar buttons carry both the identifier (tab.*) and the
    /// visible label; prefer the identifier, fall back to the label.
    private func tapTab(identifier: String, label: String) {
        // Build 65: the TabView is gone — navigation is the shell
        // PageSelectControl (one control, under the top bar). The
        // call sites still pass the old "tab.*" identifiers; map
        // them to the page-select ids ("pageSelect.home" etc.).
        let pageSelectId = identifier.replacingOccurrences(of: "tab.", with: "pageSelect.")
        let byIdentifier = app.buttons[pageSelectId]
        if byIdentifier.waitForExistence(timeout: 15) {
            // A top toast can cover the control right after a flow
            // that shows one (join, add); it auto-dismisses after
            // ~4s, so wait for the button to become hittable first
            // rather than tapping through the toast. Then tap by
            // coordinate (see tapCoordinate): a plain .tap() asks
            // XCTest to scroll the page-select button into view and
            // that AX scroll fails (kAXErrorCannotComplete, run
            // 45542061108) even though the button is on screen.
            let hittableDeadline = Date().addingTimeInterval(6)
            while Date() < hittableDeadline, !byIdentifier.isHittable {
                Thread.sleep(forTimeInterval: 0.5)
            }
            tapCoordinate(byIdentifier)
            return
        }
        let byLabel = app.buttons[label]
        XCTAssertTrue(
            byLabel.waitForExistence(timeout: 15),
            "Page select button \(label) (\(pageSelectId)) not found"
        )
        tapCoordinate(byLabel)
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
                clearField(field, fieldName: fieldName)
                field.typeText(text)
                // Verify the typed value SETTLED — do not trust a
                // single read right after typing. The AX `value`
                // lags the field: run 44980488090 proved it — the
                // email assert read "iosclonevideo" (12 of 36
                // chars) in one test and the placeholder "Email"
                // (empty) in the next, while the message built in
                // the SAME assert call already saw the full email.
                // So poll until the value matches (up to 5 s) and
                // only then return; a value that never settles is
                // a real typing failure, reported with the actual
                // value instead of a stale snapshot. Secure fields
                // read back as bullets — compare the COUNT.
                // Round 3 (run 45673494611): Plaid's WebView search
                // field stayed EMPTY after typing ("typed: ;
                // expected: First Platypus Bank") — the typeText
                // went nowhere even though focus was gained. A
                // WebView field can drop the first type; clear and
                // retype ONCE before failing.
                if typedValueSettled(field, text: text, timeout: 5) {
                    return
                }
                clearField(field, fieldName: fieldName)
                field.typeText(text)
                if typedValueSettled(field, text: text, timeout: 5) {
                    return
                }
                verifyTypedValue(field, text: text, fieldName: fieldName)
                return
            }
        }
        XCTFail("Field \(fieldName) never gained keyboard focus after 3 taps — cannot type")
    }

    /// Polls until the field's value matches what was just typed
    /// (or the bullet count, for secure fields), up to `timeout`.
    /// Returns true when it settles, false when it never does.
    /// Non-failing, so callers can retry the typing before giving
    /// up (see tapAndTypeText).
    private func typedValueSettled(_ field: XCUIElement, text: String, timeout: TimeInterval) -> Bool {
        let isSecure = field.elementType == .secureTextField
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isSecure {
                let bullets = (field.value as? String)?.count ?? 0
                if bullets == text.count { return true }
            } else if fieldText(field) == text {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Polls until the field's value matches what was just typed
    /// (or the bullet count, for secure fields), up to 5 s. See
    /// tapAndTypeText: a single immediate read races the AX
    /// snapshot and can return a partial or placeholder value
    /// even though the typing landed fine.
    private func verifyTypedValue(_ field: XCUIElement, text: String, fieldName: String) {
        let isSecure = field.elementType == .secureTextField
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if isSecure {
                let bullets = (field.value as? String)?.count ?? 0
                if bullets == text.count { return }
            } else if fieldText(field) == text {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if isSecure {
            let bullets = (field.value as? String)?.count ?? 0
            XCTFail("Field \(fieldName): typed password has \(bullets) characters, expected \(text.count) — typeText dropped a character")
        } else {
            XCTFail("Field \(fieldName): typed value differs from expected — typed: \(fieldText(field)); expected: \(text)")
        }
    }

    /// The field's real text, or "" when it is empty. A
    /// UITextField's `value` returns its PLACEHOLDER when it holds
    /// no text ("Email" for the email field, "Password" for the
    /// password field) — so a bare `value as? String` read cannot
    /// tell empty from filled, and the first version of
    /// clearField() treated the placeholder as content, tried to
    /// delete it, read it back as a "leftover", and failed every
    /// test (run 44978341731: 'leftover: Email' on all 11). The
    /// placeholder is the empty signal: value == placeholderValue
    /// means the field holds nothing.
    private func fieldText(_ field: XCUIElement) -> String {
        guard let value = field.value as? String else { return "" }
        if let placeholder = field.placeholderValue, value == placeholder { return "" }
        return value
    }

    /// Empties a text field and PROVES it is empty before the
    /// caller types. The old approach typed `value.count` deletes
    /// from wherever the tap put the cursor — but a tap lands
    /// mid-field, so the deletes only cleared the text LEFT of
    /// the cursor and a suffix survived: run 44975531594 proved
    /// it — the email field held
    /// "iosclonevideo<new>@example.com@example.com" (the new
    /// address + the old "@example.com" tail), which GoTrue
    /// rejected as invalid credentials for 8 straight tests while
    /// the field LOOKED right (the tail scrolled out of view).
    /// So: tap the field's far-right edge to put the cursor at
    /// the END, delete `value.count` characters, then READ the
    /// value back. If anything survives, fall back to
    /// triple-tap select-all + delete, and fail loudly naming
    /// the leftover instead of letting a corrupted value reach
    /// a sign-in.
    private func clearField(_ field: XCUIElement, fieldName: String) {
        let current = fieldText(field)
        guard !current.isEmpty else { return }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        if !fieldText(field).isEmpty {
            field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        let remaining = fieldText(field)
        if !remaining.isEmpty {
            XCTFail("Field \(fieldName) could not be cleared — leftover: \(remaining)")
        }
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
    /// HOW IT WORKS (build 53 fix 7): the old version queried
    /// SpringBoard directly (XCUIApplication(bundleIdentifier:
    /// "com.apple.springboard")) — run 44987157759 proved that
    /// never dismisses the alert (it sat up for the whole 75 s
    /// settle while the query polled, and the alert then blocked
    /// every content wait behind it). So this version pokes the
    /// app (app.tap()) to TRIGGER the "Notifications permission"
    /// interruption monitor registered in setUpWithError, which
    /// taps "Don't Allow" when the alert is present. The poke
    /// itself lands in the middle of Home — on a card, which may
    /// expand it; that is harmless (cards still show their
    /// content and navigation is unaffected). Returns true when
    /// the app is responsive afterwards (a household title is
    /// visible), i.e. the alert is gone or was never there.
    @discardableResult
    private func dismissNotificationAlertIfPresent() -> Bool {
        app.tap()
        Thread.sleep(forTimeInterval: 1)
        return isHomeTitleVisible()
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Dismisses the in-app walkthrough (11 steps) when it is
    /// showing, via its Skip button. It triggers on first Home
    /// entry for a fresh account — and every test creates a fresh
    /// account — so without this the overlay sits over every
    /// screen the test then visits: run 44975531594's
    /// testDeleteCashGiftFromFundsFeed reached the Funds page
    /// fine, but the tutorial's dimmed overlay hid the background
    /// from the accessibility tree and the 90 s wait for the
    /// Charity card failed even though the card was on screen
    /// behind it. Skip ends the tour in one tap (the TourSeen
    /// flag is per-household per-device, so a fresh account sees
    /// it again next test — the helper runs every preamble).
    private func dismissTourIfPresent() {
        let skip = app.buttons["Skip"]
        // 3 s is enough: the tour triggers on Home appear, so by
        // the time any caller runs, it is either already showing
        // or never will be for this account. (A 10 s wait here
        // burned 10 s in every test whose tour was already gone —
        // ~100 s a run — for no benefit.)
        if skip.waitForExistence(timeout: 3) {
            skip.tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Polls for the one-time notifications-permission alert
    /// (requested asynchronously after first Home load, ~11-35 s
    /// later) and dismisses it with "Don't Allow", so no test
    /// proceeds while the alert can still pop up and block its
    /// taps. Run 44970315808: test #1 reached Home fine, but the
    /// alert sat in the middle of the screen and the test could
    /// not tap anything. Polls the FULL 75 s window (no early
    /// return on a merely-responsive app): the alert can appear
    /// at any point in the window, and an early return would
    /// leave a later-appearing alert up to block every content
    /// wait behind it (run 44987157759 — the alert was up for
    /// the whole settle and every wait behind it failed). The
    /// ONLY early exit is when an alert was actually observed
    /// blocking Home and is now gone: the prompt is one-time,
    /// so once dismissed it never returns. Runs ONCE per test
    /// process (static flag). The video tests share this helper
    /// instead of their own inline loop for the same reason.
    private static var notificationAlertSettled = false
    private func settleNotificationAlertIfNeeded() {
        guard !Self.notificationAlertSettled else { return }
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            let blockedBefore = !isHomeTitleVisible()
            let responsive = dismissNotificationAlertIfPresent()
            if blockedBefore && responsive { break }
            Thread.sleep(forTimeInterval: 4)
        }
        Self.notificationAlertSettled = true
    }

    /// True when Home's title (either household the tests join)
    /// is visible — i.e. no overlay (notifications alert,
    /// walkthrough) is covering Home.
    private func isHomeTitleVisible() -> Bool {
        app.staticTexts[proofHouseholdName].exists
            || app.staticTexts[videoHouseholdName].exists
    }
}
