# OnBudget Native iOS Clone — Build Specification (live web v66)

**Baseline:** repo `https://github.com/ycfried/Budget`, remote `main` tip
`872ae11` (PR #61, "Refund-link suggestions + better merging + privacy/terms
publish", tests 746/746). Live pins served: `styles.css?v=53` / `live.js?v=66`.
**This spec is derived from `origin/main` only** (worktree at `872ae11`).
The local checkout in `~/workspace/household-budget/` is on a stale branch and
was NOT used as a source; where it disagrees with `origin/main`, `origin/main`
wins.

**Files read (all at `872ae11`):**

| Source | Measured size | Notes |
|---|---|---|
| `live.js` | **4,719 lines** (task brief said 4,121 — stale; 4,719 is the true count at `872ae11`) | The whole app logic |
| `live.html` | 580 lines (brief said 573 — stale) | Every view/section |
| `styles.css` | 1,322 lines (brief said 1,269 — stale) | Every visual rule; live rules are scoped under `body.live` |
| `config.js` | 6 lines | Supabase URL + anon key |
| `engine.mjs` | 328 lines | Canonical money engine (shared with compute-week / week-close) |
| `filterState.mjs` | 398 lines | Filter/sort/sheet helpers incl. `actionsForTxKind`, `classifyCsvKind` |
| `refundSuggestions.mjs` | — | Refund-link suggestion matcher + `REFUND_SUGGESTION_REASONS` |
| `reset.html` | — | Password-reset page (reached from Forgot Password) |
| `~/workspace/household-budget/HANDOFF.md` §§1–9 | — | App identity, engine, backend, integrations, boundaries |
| `FULL_AUDIT_2026-11-09_R5.md` | 226 lines | Latest audit (base `e5d693e`, pins v53/v64 — one PR behind this baseline) |
| `SYNTHETIC_PROOFS_2026-11-09.md` | 118 lines | Proof runbooks = behaviour the clone must reproduce (all 12 BLOCKED on a live run at that time; mechanisms code-verified) |
| `MATH_DECISIONS_N1_N2.md` | 197 lines | Restoration rules (N1/N2; owner picked Option A for both — see §14) |
| `Household_Budget_Spec_FINAL.pdf` | — | Base spec Nov 1, 2026 — **superseded by live v66 wherever they disagree** (see §15.4) |

**How to read this spec.** Line references are `live.js:<line>` (origin/main),
`live.html:<line>`, `styles.css:<line>`, `engine.mjs:<line>`,
`filterState.mjs:<line>`. Where a behaviour cannot be determined from the code
it is marked **NEEDS-LIVE-PROBE** with the exact question (§16). Where
`live.js` and `HANDOFF.md` disagree, **`live.js` wins** and the conflict is
listed in §15.3. Do not invent labels, flows, or figures: every label below is
copied from the live code. **OPEN** items are R5-audit items still open at v66
(§15.2). The clone uses the **same live backend** (same Supabase project,
Edge Functions, RPCs, auth, Plaid/Gmail flows) as the web app — no new backend.

**Conventions used below.** "Admin" = household role `admin` (the owner);
"member" = role `member` (spouse). All money is integer cents; display uses
`formatCents` (`engine.mjs:350`, plain `$1,234.56`, negative as `-$X`).
Dates are `YYYY-MM-DD` in America/New_York; weeks are Sunday–Saturday.
The app's data floor is **2026-11-01**: no transaction dated before it is ever
shown or accepted (`live.js:756` query floor; `isPreNovDate`, `live.js:231`).

---

## 0. Architecture — what the clone is

### 0.1 Top-level views (`show()` vs `showView()`)

Two different view systems exist; do not conflate them.

- `show(view)` (`live.js:349-368`) switches the **app shell**: `loading` /
  `auth` / `household` / `app`. It toggles `#view-loading`, `#view-auth`,
  `#view-household`, `#view-app`; hides the profile button and the "Last bank
  sync" footer whenever the view is not `app`.
- `showView(name)` (`live.js:3081-3218`) switches **screens inside the app**
  (`#view-app`). The `VIEWS` map (`live.js:3021-3041`) is the authoritative
  screen inventory:

| `showView` name | Tab / entry | Sections shown (`live.html` ids) |
|---|---|---|
| `week` (Home) | Tab "Home" | `section-week`, `section-stats`, `section-recent` |
| `purchases` (Transactions) | Tab "Transactions" | `section-manual`, `section-csv`, `section-charity-gift`, `section-transactions` |
| `prevweeks` (Past Weeks) | Link from Transactions | `section-prevweeks-head`, `section-history-filter`, `section-week-history` |
| `activity` (Activity) | Link from Transactions | `section-activity-head`, `section-activity` |
| `trash` (Trash) | Link from Transactions | `section-trash-head`, `section-trash` |
| `money` (Funds) | Tab "Funds" | `section-fund-balances`, `section-fund-more`, `section-fund-activity-more`, `section-fund-review-more`, `section-savings-more`, `section-fund-add`, `section-charity-income`, `section-fund-use`, `section-fund-ask` |
| `settings` (Settings) | Profile menu → Settings | `section-settings-head`, `section-profile`, `section-bank`, `section-email`, `settingsCard`, `section-settings-account` |

Unknown `showView` names fall back to `week` (`live.js:3082`). Only one
screen group is visible at a time; the app is never one long scrollable page
(`live.js:3018-3020`).

### 0.2 Boot flow (`boot()`, `live.js:2339-2395`)

1. `supabase.auth.getSession()` — no session → `show('auth')`, stop.
2. `loadMembership()` (`live.js:371-389`) reads `household_members` for the
   user (`household_id, role`, one row). No membership → `show('household')`.
   A read **error** is surfaced inline in `#householdMsg` (soft red), never
   silent.
3. Otherwise: stay on the full-screen loading view while the first `refresh()`
   runs, then `show('app')` once, then `showView(currentView)`.
4. **Home on EVERY fresh load** (`live.js:3042-3049`): boot always opens Home
   (`currentView` initialises to `'week'`) and never reads the saved view.
   `hb-view` is still written by in-app navigation but is inert on boot.
   `previousView` initialises to `'week'`, so Settings → Back after a reload
   returns Home.
5. Gmail OAuth return: `?gmail=connected` / `?gmail=failed` in the URL picks
   a toast message, then the param is stripped from the URL.
6. Scroll position for the current view is restored once from localStorage
   (`scrollStorageKey(currentView)`); first-ever load stays at top.
7. Empty-page guard: if no section is visible after boot, fall back to Home
   rather than a blank page.

### 0.3 `refresh()` (`live.js:424-2337`) — the single data load

Every screen's data comes from one `refresh()` call (on boot, on tab tap if
>30s since the last refresh, and after every mutation). Order inside
`refresh()`:

1. Webhook-triggered auto-sync first (races an 8s timeout) so numbers already
   include just-announced Plaid transactions.
2. Profile header (first name only from auth metadata `full_name`/`name`,
   else email), members list, invite code, household name.
3. `compute-week` Edge Function (POST, body `{household_id}` only — the
   client never sends D, T, or R_in) → week numbers; then week-close
   (admin only, once per session, skipped when the stored fingerprint says
   this week was already checked).
4. `loadInstitutionBySuffix()` (mask → institution map, best-effort).
5. `transactions` read: `gte('date','2026-11-01')`, `order date desc`,
   `limit(txLimit + 1)` — the +1 probe row proves whether older rows exist.
6. Fund requests, savings ledger, bank items/accounts, email connections,
   fund ledger + surplus releases, top-ups (admin), charity aggregates,
   charity income list (admin), restorations + held refunds (admin),
   duplicate candidates (admin), resolved duplicates (admin), refund-link
   suggestions (admin), week history, audit log.
7. `showView(currentView, {preserveScroll:true})`, then scroll is restored
   to the pre-refresh position (`savedScrollY`). **A refresh never scrolls
   the page** (`live.js:424-435`); a real page change (tab tap, Back) scrolls
   to top (`live.js:3216-3217`).

Failure rule (throughout): a failed read is an **error state, never a silent
empty list or stale numbers** (`live.js:757-775`). Cached figures are cleared
on failure (e.g. fund `currentFundData = null`, charity `currentCharityData =
null`) so old numbers never masquerade as current.

### 0.4 Backend connection

- Supabase project URL `https://tnkhvdkmwmwiogiienee.supabase.co`, anon key
  from `config.js` (publishable key — ships in the client by design; RLS +
  Edge Functions enforce access). Same project for the clone.
- Auth: Supabase Auth email + password (`supabase-js@2` via esm.sh in web;
  native uses the Supabase Swift client against the same project).
- Plaid Link: `https://cdn.plaid.com/link/v2/stable/link-initialize.js`
  (`live.html:569`); link token from `plaid-link`, exchange via
  `plaid-exchange`.
- Service worker `live-sw.js` registered on `load` (`live.html:570-576`);
  network-first app shell. Clone: no service worker; use native caching
  equivalents. **Do not copy the web's offline behaviour from code alone —
  see NEEDS-LIVE-PROBE P10.**
- Footer (visible only inside the app): "OnBudget · Last bank sync —"
  (`live.html:560-562`), updated from the freshest `plaid_items.last_sync_at`;
  stale warning (see §8.3) appears when the stalest active item is >180 min
  old.

### 0.5 The 33 admin role checks (complete inventory)

`live.js` contains exactly 33 `household.role === 'admin'` /
`!== 'admin'` checks (grep-verified at `872ae11`). Every one is
**presentation-only gating**; enforcement lives server-side in the RPCs /
Edge Functions / RLS (`live.js:14-18`). The clone must reproduce each gate
and must never rely on it for security.

| # | `live.js` line | Gate |
|---|---|---|
| 1 | 508 | Member row: `isAdmin` passed to `memberRowHtml` (Remove button) |
| 2 | 684 | Hero "Set Your Weekly Allowance" button shown only to admin (when no allowance set) |
| 3 | 724 | Week-close runs only for admin, once per session |
| 4 | 982 | Transaction row `hasActions` (admin sees Actions on every row; member only Extra Fund on charges) |
| 5 | 1180 | Trash link shown only to admin AND only when `trashRowCount > 0` |
| 6 | 1214 | Fund-request Approve/Decline buttons only for admin on pending requests |
| 7 | 1269 | `settingsCard` (Budget card) display admin-only |
| 8 | 1389 | "Connect New Account" button hidden for members |
| 9 | 1396 | "Sync Transactions" button hidden for members |
| 10 | 1455 | Nickname "Add nickname"/"Edit nickname" button admin-only |
| 11 | 1494 | Whole-item Disconnect (no-account item) admin-only |
| 12 | 1507 | Per-account Disconnect admin-only |
| 13 | 1564 | Email empty-state wording differs admin vs member |
| 14 | 1582 | Email Disconnect button admin-only |
| 15 | 1629 | Fund wording: admin "Available to use", member "Available to request" |
| 16 | 1666 | Fund top-ups history read only for admin |
| 17 | 1762 | Charity income list read only for admin |
| 18 | 1815 | Restorations + held refunds read only for admin |
| 19 | 1875 | Possible Duplicates read only for admin |
| 20 | 1999 | Resolved Duplicates read only for admin |
| 21 | 2051 | Refund Links read only for admin |
| 22 | 2498 | CSV confirm refused for members ("Only the admin can import transactions.") |
| 23 | 3119 | `showView`: `settingsCard`, `section-fund-add`, `section-charity-income`, `section-fund-use`, `section-fund-review-more` hidden for members |
| 24 | 3133 | Funds `moreShown` gating (Fund Activity + Review admin-only; Past Savings all roles) |
| 25 | 3172 | Settings: auto-sync row, Connect Email, Check Email Now hidden for members |
| 26 | 3212 | Home sync button hidden for members |
| 27 | 3280 | Invite code box hidden for members (`loadInviteCodeInline`) |
| 28 | 3572 | Fund/Charity expand actions use `isAdmin` |
| 29 | 3604 | Fund breakdown row label admin "Spendable available" vs member "Available to request" |
| 30 | 3764 | Actions sheet `isAdmin` |
| 31 | 4148 | Add popup options gating (Donation/Upload hidden for members) |
| 32 | 4185 | `setAddForm`: member reaching Donation/Upload is sent back to options |
| 33 | — (counted in grep) | `household?.role !== 'admin'` early-return in `loadInviteCodeInline` (line 3280 covers the same check; the 33rd is the `role !== 'admin'` at 3280 counted once — see note) |

Note: the 33 rows above are exactly the 33 grep matches. Row 1 (line 505)
is a display mapping (role *label*), not a gate; the other 32 are
behavioural gates. Builders: implement all 32 gates + the label mapping; do
not add new gates.

---

## 1. Design tokens

Live tokens are scoped under `body.live` (`styles.css:368-384`).

### 1.1 Palette

| Token | Value | Use |
|---|---|---|
| Brand blue (primary) | `#2f6bff` | Primary buttons, active tab, toast bg (success/info), hero outline, auto-sync switch on, sort chip active |
| Ink | `#0f172a` | Text, pale-button wording, `--green-deep` |
| Light brand blue | `#3b82f6` | **Back buttons only** (see §1.3) |
| Lighter blue | `#60a5fa` | Considered and **rejected** for link text (too light, ~2.5:1 on white) — do not use for text |
| Pale blue (middle tier) | `#bfdbfe` fill, ink `#0f172a` text | Base `.btn` — **ONLY as the middle tier of a three-button row** (option B, Nov 4). Also the sort-field select treatment |
| Grey tertiary | `#e5e7eb` fill, ink text | Second button in two-button rows |
| White | `#ffffff` | Page bg, card bg, primary-button text |
| Muted grey | `#6b7280` | Secondary labels, `.muted` |
| Hairline | `#ececf1` | Borders, tab-bar top border |
| Input border | `#e5e7eb` | Field borders |
| Soft red bg / text / border | `#fef2f2` / `#dc2626` / `#fecaca` | **All** error states (see §2.3) |
| Info bg | `#eef4ff` | `.result` (success/info inline boxes), reset-page `#msg` |
| Progress-bar over-budget | `#dc2626` | Hero progress bar when charges exceed capacity |
| Bank brand colours | Amex `#2e77bc`, BofA `#e31837`, Capital One `#004977`, Chase `#117aca`, Citi `#003b70`, Discover `#f48120`, PNC `#f58025`, TD `#00a651`, US Bank `#0c2074`, Wells Fargo `#d71e28`, fallback slate `#475569` | Monogram-tile fallback behind bank/merchant favicons (`live.js:72-124`) |

### 1.2 Type and layout

- Font: system sans throughout (`-apple-system, BlinkMacSystemFont, "Segoe
  UI", "Helvetica Neue", Helvetica, Arial, sans-serif`); no web-font download.
  On iOS this renders as San Francisco.
- Headings: `h1` 28px, `h2` 22px, `h3` 17px; live headings weight 700,
  letter-spacing −0.02em (`styles.css:40-42, 390`).
- Hero big figure: 44px desktop / 36px on small screens, weight 800
  (`styles.css:110-112, 301`); cents rendered smaller via `.cents` span
  (`formatCentsHtml`, `live.js:3651-3659`: `$1,234` + `.56` in a span).
- Cards: white, radius 20px, shadow `0 1px 2px rgba(16,24,40,.05)`
  (`styles.css:388`). **Hero exception: white card, 1.5px `#2f6bff` outline,
  NO shadow** (`styles.css:1127`).
- **Card-sizing rule (owner, Nov 2):** all cards, text fields, etc. sized to
  what is necessary and comfortable — never too long or big — and everything
  easy to find on its page and on the RIGHT page. Money inputs capped at
  220px (`styles.css:466`); Temp "New total" field capped 200px, "Weeks"
  select narrow 64px (biggest value is 4, one digit).
- Bottom tab bar: fixed, white, top hairline border, ~62px + safe-area;
  body bottom padding `calc(72px + env(safe-area-inset-bottom))` so no row
  ever hides behind it (`styles.css:381-384, 405-421`). Tab icons 22px,
  labels 11px semibold; inactive `#6b7280`, active `#2f6bff`.
- Top bar: white, bottom hairline, title centred, profile button right
  (white bg, dark icon, light-grey border, no blue fill — `styles.css:403`).
- Footer: "OnBudget · Last bank sync …" sits directly under the last card;
  gap between last card and footer is small breathing room, never forced
  scrolling (`styles.css:1084-1100`).

### 1.3 Buttons

- Base `.btn`: pale `#bfdbfe` fill, ink text, radius 14px, padding 13px 18px,
  15px semibold (`styles.css:456-457`). `.btn-small`: 8px 12px, 14px, radius
  10px.
- `.btn-primary`: `#2f6bff` fill, white text.
- `.btn-tertiary`: `#e5e7eb` fill, ink text.
- `.btn-danger`: soft-red treatment — bg `#fef2f2`, text `#dc2626` (NOT a
  solid red button; `styles.css:459`).
- `.btn-quiet`: no bg, `#6b7280` text.
- **Two-button rows: primary blue FIRST + grey tertiary SECOND. Pale
  `#bfdbfe` is ONLY the middle tier of a three-button row. No two adjacent
  buttons may share the same colour/treatment** (owner rule, Nov 3–4).
  Three-button rows in v66: filter sheet Apply (primary) / Reset (pale base
  `.btn`) / Cancel (tertiary); Add options Purchase (primary) / Donation
  (pale) / Upload (tertiary); fund expand Add Money (primary) / Spend from
  Fund (pale) / Request Money (tertiary). Sort row: select is pale, direction
  button is grey tertiary (never the same treatment side by side).
- **Back buttons: light blue `#3b82f6`, bold 700, 15px**, no bg, no border
  (`.back-link`, `.settings-back-link`; `styles.css:1165`). This supersedes
  the old primary+tertiary pair for Back buttons only. Back text is always
  "← Back" (with a destination in the aria-label, e.g. "Back to Transactions").
- Busy state: buttons disable + change label while an action runs
  ("Signing in…", "Creating account…", "Creating…", "Joining…", "Syncing…").

### 1.4 Title Case rule

**Every headline/header word starts with a capital; minor words stay lower
unless first: a, an, the, and, but, or, of, for, to, in, from**
(`live.js` comments; R5 §3). Applies to `h1–h3` (verified holding in R5 §4)
and — per the owner-delegated decision Nov 9 — to button labels.
**Exceptions:** "Sign In" and "Mark as Charity" (both words capitalised).
**OPEN (R5-NEW1, still open at v66):** the Title Case rule was applied to
only 5 button labels (PR #59, commit `84ba3dc`); ~30 sentence-case button
labels remain in v66 (verified by grep at `872ae11`). The clone must ship
Title Case on ALL of them — see the full list in §18.2. The web's remaining
sentence-case labels are a web bug, not the spec: implement the corrected
Title Case forms listed there.

---

## 2. Cross-cutting behaviour

### 2.1 Labels — exact wording

- No explainer sentence where a title already says it (declutter rule).
  Headings never repeat a word the heading already says; no status stamped
  on every row.
- Merchant names display Title-Cased (`titleCaseMerchant`,
  `filterState.mjs`); stored values stay upper-case. Dates display as
  Today/Yesterday (NY date) or `Mon D, YYYY` short form; raw `YYYY-MM-DD`
  stays in data and search.
- Transaction state pills: Posted (green-ish `pill ok`), Pending (`pill
  warn`), Reversed (`pill rev`), Excluded (`pill warn`) (`live.js:199-220`).
  "Reversed" renders as Reversed, never Posted.
- Source labels (display only; DB values unchanged): `plaid` → "Bank",
  `manual` → "By hand", `csv` → "File", `amex_alert` → "Email alert"
  (`live.js:347`).
- Kind labels in detail: `refund` → "Refund", `charity` → "Charity gift",
  `transfer` → "Transfer", otherwise "Transaction" (`live.js:990`).
- Card label: `••<suffix>`; charity cash gifts show "Cash / no card", never
  `••0000` (`live.js:989, 1040`).
- Amounts: negative amounts render with the `negative` class (red in the
  hero/stat faces; `live.js:669, 1645, 1726`).

### 2.2 Navigation

- Tab bar (3 tabs, always visible in-app): Home (`week`), Transactions
  (`purchases`), Funds (`money`). Settings is NOT a tab — reached from the
  profile menu only. Past Weeks / Activity / Trash are NOT tabs — linked
  from Transactions.
- Tab tap: `showView(name, {clearMessages:true})`; background refresh if
  >30s since last refresh (`live.js:3221-3230`).
- **Swipe-right back** (owner, Nov 4; `live.js:3405-3456`): dx > 80px, dx ≥
  2× vertical movement, within 1.5s. Ignored when the gesture starts on a
  button, link, input, select, or editable field; inside a horizontally
  scrolling element; while any sheet / filter sheet / Add popup is open.
  Actions: Settings → `previousView` (or Home); Past Weeks / Activity /
  Trash → Transactions; a Funds form open → close the form (back to Funds);
  an Add form open → ignored entirely. Home and other views with no Back
  action do nothing. Native equivalent: use the system swipe-back gesture
  with the same destination map; do not add swipe-back where the web has
  none (e.g. Home).
- Back buttons: Settings → `previousView || 'week'`; Past Weeks / Activity /
  Trash → Transactions; form Backs (manual/CSV/charity/fund forms) → options
  / Funds list (see per-screen).
- **Scroll preservation:** `refresh()` never scrolls; tab taps / Back /
  "Show Transactions" scroll to top; scroll position per view is saved on
  leave and on `beforeunload`, restored on fresh load (`live.js:3084-3090,
  4700-4705`).
- **Popup scroll = popup only:** while ANY overlay is open (sheet, filter
  sheet, Add popup), the page behind must not scroll; a scroll gesture inside
  a popup scrolls the popup only. Lock is derived from the DOM on every
  open/close (`anyOverlayOpen` / `syncScrollLock`, `live.js:3725-3761`); the
  profile menu is a small dropdown, not a scroll-blocking overlay, and is
  excluded from the lock.

### 2.3 Toasts, inline messages, sheets

- **Toast** (`showToast`, `live.js:3067-3080`): bottom only, fixed
  `left/right 16px, bottom 120px` (clear of the tab bar), max-width
  viewport − 32px, **auto-dismiss 4s**, tap dismisses sooner, tab switch
  clears it. Success/info: brand blue `#2f6bff`, white text. Error:
  **soft red bg `#fef2f2` / text `#dc2626` / border `#fecaca`, weight 600**
  (`styles.css:429-447`). This supersedes the Nov 2 "no red toasts ever"
  rule for genuine errors only (HANDOFF §7 still states the old rule — see
  §15.3).
- **Inline `.result` boxes** (`setResultMsg`, `live.js:3062-3066` — the ONLY
  way `.result` text is set): info bg `#eef4ff`, ink text; error adds class
  `.error` → soft red bg/text/border (`styles.css:573-580`). A failure can
  never stay blue because a caller forgot the class; a success never
  inherits a stale `.error`. Sign-in / join failures stay in the inline
  soft-red box under the field (never a toast — a 4s toast vanishes before
  the fix; `live.js:2425-2430`).
- **Field errors** sit inline beside the form, above the buttons
  (`#manualFormError`, `#charityFormError`, `#fundTopupError`,
  `#fundRequestError`, `#fundAllocateMsg`); the draft is preserved and the
  offending field is focused.
- **Sheets** (`showSheet`, `live.js:3965-4072`): replace browser
  prompt/confirm/alert. Structure: handle bar, top row (Cancel as a top
  text link on the left, title centred, spacer right), optional labelled
  metric rows, optional `<details>` calculation, message (plain text,
  newlines rendered), optional input (text/password/number/email or a
  select), button row. Rules: Cancel is NEVER a button in the row — it is
  the top text link — so no three-button sheet layout exists and pale never
  appears in a sheet. With an extra action, the extra is primary and
  Confirm is tertiary; a single-button sheet keeps primary Confirm.
  `showAlert(title, message)` = sheet with Confirm "Close", rendered
  **soft red** (`kind: 'error'`, `styles.css:321-328`) — alerts report a
  failure. `showConfirm(title, message, confirmLabel)` = white sheet, asks
  a question. Escape closes (same as Cancel/backdrop); Tab is trapped
  inside; focus returns to the opener on close. Password inputs in sheets
  get a Show/Hide text toggle. Every interpolated value is escaped.
- **Confirm-before-destructive:** every destructive or money action goes
  through `showConfirm` first (see per-screen). Double-tap guards disable
  the submit button before any awaited network call.

### 2.4 Loading / empty / error states (global)

- First paint is the full-screen loading view (`#view-loading`): S-mark
  ring + logo, "OnBudget", "Loading Your Household" (`live.html:39-43`).
  A signed-in reload never flashes the sign-in form; a signed-out visit
  goes loading → sign-in with no app-shell flash. Cards inside `#view-app`
  start `display:none` in CSS and are turned on by `showView()`; skeleton
  rows show inside lists while loading (`.skel` placeholders in
  `live.html:112-116, 131-132, 137`).
- Loading figure state: hero/stat faces show skeleton, then a real figure,
  then `—` ONLY on load failure, then `$0.00` for a confirmed zero
  (`live.js:1716-1726`). A successfully loaded zero is `$0.00`, never `—`.
- Empty states: one empty message only, in the summary — never repeated in
  the list below it. Examples: Transactions empty (no search/filter):
  "No transactions here yet — add one by hand above, or connect a bank
  account and sync."; with search/filter active: "No matching transactions.
  Try a different search, or clear the search and filters." + a "Clear
  Search and Filters" button; Refunds filter empty: "No refunds in this list
  yet."; Charity filter empty: "No charity gifts in this list yet — record
  one from Add, or mark a posted donation as a gift."
- Load failure: Transactions list shows "Your sign-in expired — sign in
  again to see transactions." + "Sign In Again" button (auth failure,
  detected via missing session or `JWT expired` / `PGRST301`), or "Could not
  load transactions — the server did not answer. Nothing here is a complete
  list." + "Try Again" button (server failure). Hero "Purchases" shows
  **N/A** (never a bare dash) when transactions could not load; a loaded
  week with no purchases shows 0 (`live.js:848, 1006-1009`). Week numbers
  failure: `#weekError` "Couldn't update this week's numbers — switch tabs
  or reopen the app to try again." (missing fields) or "…check your
  connection and try again." (fetch throw); faces cleared to `—`.
- **Do-not-copy (a):** the live web lists hung on "Loading…" from ~2:00 PM
  EST Nov 9 in a test session (reported in the task brief; root cause
  undetermined from code). The clone implements correct loading: loading
  state, then data, or a real error state as above. Never reproduce a
  stuck "Loading…".

### 2.5 Search behaviour

- Transactions search (`#txSearch`, `live.html:209`): placeholder "Search
  transactions (merchant, amount, date)". Searches **loaded transactions
  only** (note under the box: "Searches loaded transactions."). Matches
  merchant (case-insensitive substring), date substring, or the formatted
  amount (`live.js:796-799`). Debounced 250ms; a new search resets the
  page to 100 (`live.js:4490-4497`). Clearing search + filters is a single
  action ("Clear Search and Filters") that resets every filter to default
  and re-renders.
- No global search elsewhere. Past Weeks / Activity share the History date
  filter (From/To), not text search. Member names are never searchable.

---

## 3. Screen 1 — Loading

- `live.html:39-43`, `#view-loading`. Full-screen: loading-brand ring +
  logo, "OnBudget", muted "Loading Your Household".
- Shown on first paint and kept visible while `boot()` + first `refresh()`
  run; replaced directly by auth / household / app once known. Never show
  the app shell (topbar/nav/footer with empty content) during boot.
- Clone: native launch screen with the same mark + "Loading Your Household";
  keep it until the first data load completes or fails (on failure, show
  the app with inline errors, never a blank page).

## 4. Screen 2 — Auth (sign-in / sign-up / forgot password / reset)

`live.html:45-74` (`#view-auth`), `live.js:2397-2620`. Top bar: app logo +
"OnBudget" brand block, no card heading (the header already says OnBudget),
no subtitle, no lead-in text, no card-numbers note. Footer under the card
(both auth screens): "Your household budget, shared in one place." /
"Bank and email are read-only — nothing is ever moved or changed." /
"Privacy · Terms" links (`privacy.html`, `terms.html`).

### 4.1 Sign-in panel (`#authSigninPanel`)

- Fields: **Email** (`#authEmail`, type email, autocomplete email, required),
  **Password** (`#authPassword`, type password, autocomplete current-password,
  required) with an eye icon **inside** the field toggling Show/Hide
  (aria-label "Show Password"/"Hide Password", aria-pressed; icon swaps
  open-eye / slashed-eye; `live.js:2530-2549`).
- Button row (two-button rule): **Sign In** (primary) + **Create Account**
  (tertiary). Below, full-width quiet button **Forgot Password?**
  (underlined brand-blue link treatment, full tap area).
- `#authMsg` inline result under the buttons.
- Sign-in: button disables + label "Signing in…" while the call runs.
  On error: inline soft-red "Incorrect email or password" — deliberately
  does NOT say which field is wrong. On success: inline "Signed in.", then
  the loading screen while `boot()` restores the session; button restores
  to "Sign In".
- Sign-out (from profile menu) clears Email/Password/Name fields, resets to
  the sign-in panel (never stranded on the name step), and lands on auth.

### 4.2 Create-account name step (`#authNamePanel`, hidden until chosen)

- "Create Account" on the sign-in card validates Email + Password ONLY,
  then moves to this separate panel (same DOM, Email/Password values
  survive). Sign-in never shows the name step.
- Validation before moving on (no Supabase call): empty email → "Enter an
  email address to create an account."; bad format → "Enter a valid email
  address."; empty/short password → "Enter a password of at least 8
  characters." / "Password must be at least 8 characters." Each names the
  missing field and focuses it.
- Panel: heading **Choose Your Name**; field **Name** (`#authName`, max
  80 chars). Button row: **← Back** (light-blue back-link, returns to
  sign-in with values intact) + **Create Account** (primary).
- **Household name is REQUIRED at sign-up** (owner, Nov 4): empty name
  fails before any Supabase call — "Enter a name for your new account.",
  focus on Name. `supabase.auth.signUp({email, password, options: {data:
  {full_name: name}}})`. Button busy label "Creating account…".
- On error: "Could not create the account. Try again." On success:
  "Account created. If email confirmation is on in Auth settings, confirm
  the email first, then sign in." then loading + `boot()`.
- **NEEDS-LIVE-PROBE P14:** whether email confirmation is currently ON in
  Auth settings (the copy branches on it; the code cannot tell the clone).

### 4.3 Forgot password

- `#forgotPasswordBtn`. If the Email field is filled, use it; else open a
  sheet: title "Forgot Password?", 3-step message ("Step 1: enter the email
  for your account. Step 2: check your inbox for the reset link. Step 3:
  choose a new password on that page, then return here to sign in. If the
  link has expired, send a fresh one from here."), input Email, Confirm
  **Send Reset Link**, Cancel.
- Invalid email → inline "Enter a valid email address." Otherwise
  `supabase.auth.resetPasswordForEmail(email, {redirectTo: <base>reset.html})`.
  **Generic wording either way** (do not reveal whether an account exists):
  "If an account exists for that email, a password-reset link was sent to it."

### 4.4 Reset page (`reset.html`)

- Separate page, not part of `live.html`. Heading **Reset Your Password**;
  "Password requirements: at least 8 characters." Fields **New Password**
  and **Confirm New Password**, each with a Show/Hide text toggle button
  beside the field. Button **Save New Password** (full-width primary).
  Message box `#msg` (info blue; `.error` soft red on failure). Link
  "Back to Sign In" → `live.html`.
- Behaviour: `?code=…` in the URL is exchanged for a session
  (`exchangeCodeForSession`); a bad code shows "This reset link could not be
  used. Request a new one from the sign-in screen." Save calls
  `updateUser` as the recovering user. **NEEDS-LIVE-PROBE P9:** the exact
  success text and the mismatched/empty-password messages (the tail of
  `reset.html` was not in the read set for this spec — verify from the file
  before building; the file is in the repo at `872ae11`).

## 5. Screen 3 — Household (create or join)

`live.html:76-101` (`#view-household`), `live.js:2622-2720`. Same brand block
and footer as Auth.

### 5.1 Choice panel (`#householdChoicePanel`)

- Heading **Your Household**. Subtext: "Create a household as admin, or join
  one with an invite code."
- **Create Household** (primary, full-width) → opens the name panel (does
  NOT call the RPC itself).
- Label **Or Join a Household** + input `#joinId`, placeholder "Invite Code
  from the Owner".
- **Join As Member** (tertiary, full-width).
- `#householdMsg` inline result.

### 5.2 Name panel (`#householdNamePanel`)

- Heading **Name Your Household**. Field **Household Name** (`#householdNameInput`,
  max 80, placeholder "Household"). Button row: **← Back** + **Create Household**
  (primary). **Household name is REQUIRED** (owner, Nov 4): blank → inline
  "Enter a household name.", focus the field, no fallback to the default
  "Household". (Note: the `live.html` comment calls this step "optional" —
  stale comment; the code requires it. Live.js wins.)
- Create calls RPC `create_household(p_name)` — the ONLY path to admin;
  the client never grants itself admin. On success the client sets
  `household = {household_id: data, role: 'admin'}` directly (it does NOT
  re-read membership — the Nov 1 bug was re-reading too early and stranding
  the user) and goes straight to the app + `refresh()`. Success message:
  "Household created. Share the invite code from Settings so the second
  account can join as member." Failure: "Could not create household. Try again."
- Join calls RPC `join_household_by_code({code})`. Empty code → "Enter the
  invite code from the household owner." Not signed in → "Sign in first."
  Invalid code (error OR null return — the function returns NULL and logs
  the attempt instead of raising, so the log survives) → inline soft-red
  exactly: "Check the invite code and try again" — nothing else, no extra
  clause about Settings. Rate limit: max **5 failed attempts/hour** per
  caller AND per code value (plus a per-household bucket; N13). Codes are
  reusable and non-expiring. On success: "Joined. Loading shared budget…",
  `household = {household_id: data, role: 'member'}`, straight to the app.
  Button busy label "Joining…".

## 6. Screen 4 — Home

`live.html:103-141`, `live.js:594-730, 1040-1110, 3457-3650`. Sections in DOM
order: hero `#section-week`, stat grid `#section-stats` (Charity card, then
Extra Fund card), `#section-recent`. **Owner's priority order (Nov 3) is:
(1) what's left for budget, (2) what's left for charity, (3) what's left in
Extra Fund, (4) what was spent** — the hero carries (1) and (4); the stat
cards carry (2) and (3). Do not reorder the cards: DOM order is hero →
Charity → Extra Fund → Recent.

### 6.1 Hero — Weekly Budget (`#section-week`)

- White card, 1.5px `#2f6bff` outline, no shadow. Title **Weekly Budget**
  (`h2.hero-title`).
- Kicker line `#weekLabel`: e.g. "Nov 8, 2026 (Sun–Sat)" — `fmtLong(weekStart)
  + " (Sun–Sat)"`; on failure "Week numbers unavailable".
- Big figure `#weeklyAvailable` (tap target — opens the Weekly sheet,
  §12; keyboard Enter/Space): the week's **available** cents from
  compute-week, rendered with `formatCentsHtml` (dollars large, cents in a
  smaller span). Negative → red (`negative` class) and aria-label "Weekly
  Budget, over budget by $X, show breakdown"; otherwise "Weekly Budget, $X
  left this week, show breakdown". The face is numbers-only — no "Over
  budget by $X" sentence and no "Spent $X of $Y room" line on the face.
- Sync button `#homeSyncBtn` (circular, primary blue, refresh icon) sits in
  the hero number row, right of the figure. Admin-only (hidden for members).
  While syncing: disabled, spins (`syncing` class), aria-label "Syncing Bank".
  **While no allowance is set** it turns grey tertiary (`sync-unset`) so
  "Set Your Weekly Allowance" is the hero's only primary control.
- **Set Your Weekly Allowance** button (primary, hidden unless no allowance
  has ever been set AND viewer is admin): shown when
  `households.allowance_set_at IS NULL`. Members see no figure and no
  button in that state. Tap → Settings. (The $375 figure is the DB schema
  default, not a choice — a new sign-up must NOT show an allowance figure
  before one is set. Spent and purchase counts are real and stay visible.)
- Progress bar `#weekProgressBar`: width = charges / (base room + temp room),
  capped at 100%; `over` class (red bar) when charges exceed capacity. The
  progress sentence `#weekProgressText` is always empty in v66 (the sentence
  duplicated the Weekly sheet rows and was removed).
- Spent line: `#heroSpentLine` = "`$X` spent" (server `charges_cents`);
  `#heroUsedPct` = "`N`% used" (or "Over budget" when capacity ≤ 0 and
  charges > 0, "0% used" when no charges). While no allowance is set both
  read `—` / `—` and the bar is 0%.
- Hero stats row: **Weekly allowance** = effective allowance
  (base room + temp, `baseAvailable + tempC`) — NOT the household base;
  **Purchases** = count of week-counted purchase rows this week
  (`kind === 'charge'`, not reversed, not excluded, dated this week).
  Purchases shows **N/A** on load failure, `0` on a loaded empty week.
- `#weekError` inline soft-red box (see §2.4). `#weekEmptyHint` (shown only
  once a load has actually returned empty, never while loading or on
  failure): "No transactions this week yet — the full allowance is still
  available. Add one by hand, or connect a bank account in Settings."
- `#weekBreakdown` (hidden panel behind the hero number; the Weekly sheet
  in §12 is the user-facing surface — the panel's four stored texts are
  Allowance / Spent / Debt / Outgoing; see `live.js:1115-1165` for exact
  wording).

**Where each hero figure comes from (server-computed, never recomputed
locally):** `compute-week` returns `{week_start, base_available_cents,
temp_cents, carried_debt_cents, charges_cents, available_cents, week_locked,
pending_refund_excluded_cents, unlinked_excess_cents}`. The client sends
ONLY `household_id`. The client derives ONLY the display split
`weeklyReconciliation` (outgoing debt = unabsorbed incoming debt + new debt
from spending above room; `filterState.mjs`) and the spent-breakdown lines
(dated vs late charges; `live.js:1115-1160`). Base allowance is read from
`households.base_allowance_cents` (+ `allowance_set_at` for the never-set
state). **Never recompute week math locally.**

### 6.2 Stat cards (`#section-stats`)

Two cards, stacked (single column in v66 — the stacked Home layout, Charity
above Extra Fund, both full-width). Each card face is **Title + signed number
only**, chevron `⌄` bottom-right (flips to `⌃` when expanded), brand blue.
Tap anywhere on the card expands it **in place** (no sheet, no overlay);
tap again, or tap the other card, collapses it. At most one expanded at a
time, Home and Funds together (`expandedFundCard`, `live.js:3530-3600`).
Home expansions show **rows only, no action buttons** (actions belong on the
Funds page).

- **Charity** card (`data-home-card="charity"`, `#homeCharityPrimary`):
  face = **remaining** = committed − given (signed; negative = "ahead by").
  Confirmed zero is `$0.00`, never `—`. Expansion rows (exactly three):
  Available (remaining, signed) / Given / Total (Available + Given =
  Committed). Small line under the rows: "November 2026 onward".
  Aria-label when no activity: "Charity, no charity tracked yet, show
  breakdown"; otherwise "Charity, $X remaining, $Y given, $Z committed,
  show breakdown"; when ahead: "Charity, ahead by $X, show breakdown".
  On load failure face `—`, aria-label "Charity, could not load, show breakdown".
- **Extra Fund** card (`data-home-card="fund"`, `#homeFundPrimary`): face =
  **available** (fund ledger sum, signed). Expansion rows (exactly three):
  "Spendable available" (admin) / "Available to request" (member) /
  Pending (pending releases + held weeks) / Total (Available + Pending).
  Aria-label carries Available + Pending when pending > 0. On load failure
  face `—`, aria-label "Extra Fund, could not load balances, show breakdown".
- If the numbers are not loaded yet when a card is tapped, show an alert
  sheet ("Extra Fund" / "Charity" — "…balances/numbers are not loaded yet.
  Try again in a moment.") and expand nothing.

### 6.3 Recent Transactions (`#section-recent`)

- Heading **Recent Transactions**. The 6 newest transactions (any kind),
  newest first, each row: merchant icon (bank favicon if the card suffix
  maps to a connected institution, else merchant favicon/monogram — see
  §2.1 icons), Title-Cased merchant, signed amount, state pill, relative
  day + card (`••suffix` / "Cash / no card"). Tapping a row jumps to
  Transactions AND expands that row's detail, scrolled into view, briefly
  highlighted (2.5s); all Transactions filters/search are cleared first so
  the row is found; if the row is not in the loaded page, toast: "That
  transaction is not in the loaded list — tap Load more for older ones."
- "See all" quiet link → Transactions. `#homeSyncMsg` result line.
- Empty: "No transactions yet." Failure: soft-red "Could not load recent
  transactions."

## 7. Screen 5 — Transactions

`live.html:199-278`, `live.js:750-1110, 4110-4500`. This is the densest
screen; implement it exactly.

### 7.1 Header and list chrome

- Heading **Transactions**. Header actions (right): **+ Add Transaction**
  (primary; on narrow screens shows "+" only, label "Add Transaction" on
  desktop) → opens the Add popup (§8); **Filters** (tertiary, aria-expanded)
  → opens the filter sheet (§7.3).
- Page links under the header: **Past Weeks** · **Activity** (quiet links).
- Search box (§2.5) + note "Searches loaded transactions."
- Active-filter chips (`#txActiveFilters`): one removable chip per applied
  filter ("Label ×"); tapping a chip clears ONLY that filter and resets the
  page to 100.
- Count line `#txCount`: "`N` transactions · Total shown `$X`" (+ "· of
  loaded transactions — tap Load more for older ones" when older rows
  exist). Total = net spending only: charges + fund charges − refunds
  (refunds as −|amount|); payments, cashback, transfers, income, charity
  never count. On the Charity filter the total is the gifts total. Failure
  text and min>max text per §2.4.
- **Trash** link row (above the list, admin-only, only when trashed rows
  exist): "Trash (N)" → Trash screen (§11).
- List `#txList`: pages of **100** (`txLimit`, initial 100). Fetch asks for
  `txLimit + 1`; the probe row decides whether **Load More** shows — a page
  of exactly 100 with no probe row does NOT show the button. Load More
  raises the limit by 100 and refreshes. **Every filter/search/sort change
  is a new list: the page resets to 100** (`resetTxLimit()` on all 8 chip
  keys, month/card change, search input, Apply, Reset, week-jump).
- Initial list state: `<li>Loading…</li>`; see §2.4 for failure/empty states.
- Excluded rows NEVER appear here — they live only in Trash. The old
  "excluded" status filter is gone; a legacy value falls back to "all".

### 7.2 Transaction rows and detail

- Row line 1: icon, Title-Cased merchant (bold), signed amount (negative
  class when < 0), chevron (rotates when open). Line 2: state pill +
  source pill + "`Today` · ••1005" meta. Row accessible name: merchant +
  amount + day + status + "— show detail".
- Tap the row header (or Enter/Space) toggles the detail panel.
- Detail panel contents, in order: bold merchant + amount + kind label;
  one muted sentence about counting ("Counts toward its week unless
  excluded." / "Outside weekly spending." (charity) / "Kept for the record;
  does not count toward any week." (excluded) / "Reversed; does not count."
  / "Card payment; does not count toward weekly spending." /
  "Cash-back credit; does not count toward weekly spending." /
  "Transfer; does not count toward weekly spending."); labelled rows
  **Week** (Sun–Sat range) / **Date** (long) / **Status** / **Card** /
  **Source** (+ **Refund link** row for refunds: "Linked to a purchase" /
  "Not linked to a purchase yet"); for email-alert rows, a muted line:
  "From an email alert — pending until the bank confirms it." /
  "From an email alert, confirmed by the bank."; then the **Actions**
  button (see §7.4) — one small tertiary button, only when the viewer has
  any action on that row.
- Icons: bank rows show the bank's Google favicon (`google.com/s2/favicons`,
  `sz=128`); manual/CSV/cash rows fall back to the merchant icon. Merchant
  icons: curated keyword→domain map (Trader Joe's, Whole Foods, Home Depot,
  Lowe's, ShopRite, McDonald's, Starbucks, Chipotle, Amazon, Walmart,
  Target, Costco, Apple, CVS, Walgreens, Exxon, Shell, Uber, Lyft, Netflix,
  Spotify — `live.js:113-124`); unmapped or failed loads fall back to a
  brand-coloured monogram tile (white initial on the merchant's brand
  colour, slate `#475569` when unmapped) — never a flat grey box alone.
  Bank logo domains: Amex, BofA, Capital One, Chase, Citi, Discover, PNC,
  TD, US Bank, Wells Fargo (`live.js:75-84`). **Never use Clearbit** (dead
  since Nov 4, 2026).

### 7.3 Filters sheet (`#txFiltersSheet`)

- Bottom sheet (dialog, modal): handle bar, heading **Filters**.
- **Status** select: All transactions / Charity gifts / Pending / Posted /
  Refunds. (Filter values: `all | charity | pending | posted | refunds`.
  `pending` = `state === 'provisional'`; `posted` = `state === 'verified'`;
  `refunds` = `kind === 'refund'`; `charity` = `kind === 'charity'`.)
- **When** group: **Month** select (months present in loaded transactions,
  newest first, "All months" default); **This week** checkbox (current
  Sun–Sat, NY); **From** / **To** date fields **side by side, compact**
  (labels shortened to "From"/"To" — never "From date"/"To date", never
  massive full-width fields).
- **Card / Account** select ("All cards" default; options `••suffix`, plus
  nickname `· Name` only when the suffix maps to exactly one account).
- **Amount** group: **Min** / **Max** side by side (placeholders `$0.00`;
  "Blank = no limit. Refunds count as negative amounts."). Bounds compare
  to the **signed** amount; either end alone works; blank/unparseable = no
  limit; min > max is a validation state ("Minimum amount is above the
  maximum amount — change one of them to see transactions."), not an empty
  result. Bounds apply live (debounced 250ms, not persisted).
- **Sort by** select (Date / Amount) + direction button showing arrow AND
  words: "↓ Newest First" / "↑ Oldest First" / "↓ Largest first" /
  "↑ Smallest first". Amount sort is by **absolute value**. Sort persists
  in localStorage (`hb-tx-sort`); month/card persist (`hb-tx-month`,
  `hb-tx-card`).
- Button row (three-button rule): **Apply** (primary) / **Reset** (pale
  base `.btn`) / **Cancel** (tertiary). Apply commits the sheet-held
  status/week/date values (month, card, bounds, sort already apply live)
  and closes; Reset clears everything to defaults; Cancel restores the
  snapshot taken on open and leaves the list unchanged. Backdrop tap =
  Cancel. Escape closes (focus returns to Filters); Tab trapped inside.
- Filters combine (AND): status + month + card + week + From/To + min/max
  + search. Week filter uses the current NY Sun–Sat.

### 7.4 Transaction Actions sheet (`openTxActionsSheet`, `live.js:3763-3811`)

- Opened from the **Actions** button in a row's detail. Sheet header:
  Cancel (top-left text link), title **Actions**, subtitle "Merchant —
  $X". Rows are tappable list rows (label bold + muted sub-line + `›`).
- Which actions appear is decided by `actionsForTxKind(kind, isAdmin,
  isVerified)` (`filterState.mjs:382-404`) — **the clone must use this exact
  table** (note: the comment above the function still says "Charity (admin
  + verified only)" — stale comment; the code was relaxed Nov 8, 2026 and
  the tests pin the relaxed table):

| kind | Admin | Member |
|---|---|---|
| `charge` | Charity, Extra Fund, Other, Delete | Charity (disabled, sub "Ask the admin to mark this as a gift"), Extra Fund |
| `refund` | Link to Purchase, Other, Delete | — (no actions) |
| `transfer`, `payment`, `cashback`, `fund_charge` | Other, Delete | — (no actions) |
| `charity` | Delete | — (no actions) |
| other kinds | Other, Delete | — |

  Plus the note under the sheet for transfer/payment/cashback/fund_charge:
  "This row does not count toward weekly spending."
- Action sub-lines (exact): Charity (admin, verified): "Counts it as a
  charity gift, out of weekly spending"; Charity (admin, pending): "Counts
  as a charity gift once it posts"; Charity (member): "Ask the admin to mark
  this as a gift"; Link to Purchase (unlinked): "Link this refund to the
  purchase it came from"; (linked): "Change or remove the purchase this
  refund is linked to"; Extra Fund: "Ask for this charge to be covered from
  the fund"; Other: "Change how this transaction counts"; Delete (manual):
  "Permanently deletes this hand-entered row"; Delete (bank/email/file):
  "Moves this row to the Trash".
- **Charity** (`doTxCharity`, `live.js:3813-3832`): confirm sheet "Mark as
  Charity Gift" — pending row: "…this moves the whole transaction out of
  weekly spending. It counts as charity given once it posts. If only part
  of it was a gift, do not mark it here: part-gifts are not supported yet.";
  posted row: "…moves the whole transaction out of weekly spending and
  counts it as charity given. …". Confirm label "Mark as Charity"
  (exception to the minor-words rule). RPC `mark_transaction_charity
  (p_transaction_id)`. Success toast: "Marked as charity gift: $X to
  MERCHANT." Refusals (locked week / fund / posted / charge / November
  2026 / excluded) surface the server message in an alert; missing-RPC
  errors show "Charity isn't live yet — the database step still needs
  approval."
- **Extra Fund** (`doTxExtraFund`, `live.js:3834-3861`): refuses charity
  rows ("Charity gifts cannot be covered by the Extra Fund.") and
  non-charges ("Only a charge can be covered by the Extra Fund. …").
  Sheet "Use Extra Fund": "Ask the admin to cover "MERCHANT" ($X) from the
  Extra Fund?", input Amount ($) prefilled with the charge amount, Confirm
  **Send Request**. Inserts a `fund_requests` row (`status: 'pending'`,
  `transaction_id: row.id`); audits "Extra Fund request created".
- **Link to Purchase** (`doTxLinkRefund`, `live.js:3862-3921`): admin only.
  Already linked → confirm "Unlink Refund" ("This refund is linked to
  LABEL. Unlink it? It will count as an unlinked refund again.", Confirm
  "Unlink") → RPC `unlink_refund (p_refund_id)`; server refuses when a
  restoration entry already exists ("already restored"). Unlinked →
  candidates: same card, charges/fund_charges in the 90 days before the
  refund, not excluded/reversed; merchant-stem match first (`ilike
  %stem%`), fallback to every same-card charge in the window when no name
  matches. Sheet "Link Refund to Purchase" with a Purchase select
  ("Merchant — $X · Day"); no candidates → alert "No matching purchase
  found" ("No charge on the same card in the 90 days before DAY. If the
  purchase was older, on another card, or under a different name, it cannot
  be linked from here."). RPC `link_refund (p_refund_id, p_purchase_id)`;
  server enforces same household, same card, purchase on/before refund,
  refund fits in remaining refund room. Success toast "Refund linked to its
  purchase." + audit.
- **Other** (`doTxReclassify`, `live.js:3922-3941`): sheet "Reclassify
  Transaction" — "Change how this transaction counts. Pick the new type,
  then give a reason."; type select: Charge / Refund / Fund Charge /
  Transfer / Payment / Cashback / Income / Charity; Confirm "Continue".
  Picking Charity routes to `doTxCharity` (guarded path, NOT the raw RPC).
  Then a second sheet for **Reason (required)**; empty reason → alert
  "Reason required". RPC `reclassify_transaction (txn_id, new_kind,
  reason)`. Locked-week refusal surfaces the server message; otherwise
  "Could not reclassify this transaction. Try again."
- **Delete** (`doTxDelete`, `live.js:3942-3970`): manual rows → confirm
  "Delete Transaction" ("…this removes the hand-entered transaction and
  cannot be undone.", Confirm "Delete") → RPC `delete_transaction
  (p_transaction_id)` (permanent). Bank/email/file rows → sheet "Move to
  Trash" ("…this moves it to the Trash. The admin can bring it back from
  the Trash. Give a reason to continue.", input "Reason (required)",
  Confirm "Delete", Cancel "Keep It") → RPC `exclude_transaction (txn_id,
  reason)`; toast exactly **"Moved to trash bin."** Locked-week refusal
  surfaces the server message.

## 8. Screens 6–8 — Add popup (Purchase / Donation / Upload)

`live.html:284-296`, `live.js:4124-4207`. The Transactions header's blue +
button opens an **options popup** (overlay dialog, sheet handle on top).
Options list (admin): **Purchase** (primary) "Add a transaction by hand" /
**Donation** (pale) "Record a gift by hand" / **Upload** (tertiary) "Import
transactions from a file"; then **Cancel** (tertiary). Members see
**Purchase only**. Choosing an option MOVES that form's existing section
into the popup slot (moved, not copied — handlers, validation, draft, CSV
preview stay exactly as inline). Back returns to the options; Cancel or a
successful submit returns to the list. Escape: form → options, options →
list. Tab trapped inside. Backdrop tap closes. A tab switch hides the popup
and returning to Transactions reopens it with its draft intact. Swipe-back
is ignored while the Add popup is open.

### 8.1 Purchase — Add a Transaction by Hand (`#section-manual`)

- Heading **Add a Transaction by Hand**. Note: "Counts as pending until the
  bank confirms it."
- Fields (one row of three on wide screens): **Merchant** (max 80, required),
  **Amount ($)** (number, step 0.01, min 0.01, required), **Date** (date,
  required), **Card suffix** (exactly 4 digits, placeholder "1005",
  required). Inline error `#manualFormError` above the buttons.
- Buttons: **Add Transaction** (primary, submit) + **Cancel** (tertiary).
  Cancel clears the draft AND closes (Back only returns to options and
  keeps the draft). Footnote: "Never enter a full card number."
- Validation (in order, each focuses its field): amount must be a positive
  number ("Amount: enter a positive amount."); suffix exactly 4 digits
  ("Card suffix: enter exactly 4 digits. Never enter a full card number.");
  merchant required; date required; **date must be ≥ 2026-11-01**
  ("Date: transactions start Nov 1, 2026. Pick a date on or after Nov 1, 2026.").
  Money parsing is strict: empty/blank/non-numeric is null, never 0
  (`parseDollarsStrict`, `live.js:52-60`).
- Duplicate warning: if a row already exists with same merchant + amount +
  date, confirm sheet "Possible Duplicate" ("A transaction already exists
  for MERCHANT $X on DATE. Add it again anyway?", Confirm "Add Anyway").
- Insert: `transactions` row, merchant upper-cased, `source: 'manual'`,
  `state: 'provisional'`, `kind: 'charge'`, `dedupe_hash = sha256(date |
  MERCHANT | amount | suffix)`. Double-tap guard disables submit first.
  **Purchases-only: no refund option here** (owner decision Nov 3). Audit
  "Transaction added by hand". No auto-link call after insert (auto-link
  RPCs are service-role-only; a call would 403).
- **OPEN (R5-NEW1):** the submit button reads "Add Transaction" (fixed) —
  no open item here.

### 8.2 Donation — Give to Charity (`#section-charity-gift`)

- Heading **Give to Charity**. Note: "Counts as given at once, never as
  weekly spending. Admin only." **Admin-only** (server-enforced; hidden
  from members).
- Fields: **Organization** (max 80, required), **Amount ($)**,
  **Date**, **Card suffix** (4 digits, placeholder "only if paid by card" —
  optional), **Note (optional)** (max 120). Inline error
  `#charityFormError`. Submit button **Record Gift** (primary; **OPEN
  R5-NEW1 — ship as "Record Gift"**). Footnote: "Leave the card suffix
  blank for a cash gift. Never enter a full card number."
- Validation: positive amount; organization required; date required;
  date must be ≥ 2026-11-01 ("Date: gifts before November 2026 are outside
  the charity period."); suffix if present must be exactly 4 digits.
  Duplicate warning mirrors the manual form ("Record this gift anyway?").
- Submit calls RPC `record_charity_gift (p_household_id, p_merchant,
  p_amount_cents, p_date, p_card_suffix, p_note, p_dedupe_hash,
  p_client_key)` — 8-arg overload, idempotent via `p_client_key` (a retry
  reuses the key and replays the original row; a fresh submit gets a fresh
  key, so real identical gifts stay distinct — the Nov 3 TOIREMORG $2 pair
  ruling: two identical gifts are two real gifts). The dedupe hash carries
  a per-submit nonce so identical gifts do not collide. Gift posts as
  **verified** (Given) at once. Success toast: "Gift recorded: $X to
  MERCHANT." Missing-RPC error → "Charity isn't live yet — the database step
  still needs approval."; admin-only refusal → "Only the admin can record
  charity gifts."

### 8.3 Upload — Import Transactions from a CSV File (`#section-csv`)

- Heading **Import Transactions from a CSV File**. Notes: "Expected columns:
  Date, Description, Amount, Card Ending." / "Preview first — nothing is
  added until you confirm."
- File control: styled **Choose File** button (label for the hidden native
  input, `accept=".csv,text/csv"`); chosen file name beside it ("No file
  selected" default). **Confirm Import** button (primary, disabled until
  there is ≥1 new row; **OPEN R5-NEW1 — ship as "Confirm Import"**).
  `#csvMsg` result line.
- Parse (`parseCsvLive`, `live.js:240-298`): header must include Date,
  Description, Amount (Card Ending optional); quote-aware split; dates
  `YYYY-MM-DD` or `MM/DD/YYYY`; amounts accept `$`, commas, `(…)` negatives;
  suffix = last 4 digits of the Card Ending column else `0000`. Rows before
  2026-11-01 are skipped with an error line; unparseable rows are skipped
  with "Skipped unparseable row: …". File with <2 lines → "CSV needs a header
  row and at least one data row." Missing columns → "Header must include
  Date, Description, and Amount columns." No file / unreadable file → "No
  file reached the app from the picker. Try saving the file to Files first,
  then picking it from Files."
- Preview: "`N` new, `D` duplicate(s) skipped, `E` unparseable row(s)."
  + error lines + numbered rows "`i`. DATE · MERCHANT · $X · ••suffix —
  New / Duplicate, will be skipped". Dedupe key: normalized merchant
  (upper, whitespace-collapsed, punctuation dropped) / date / amount / suffix,
  matched against the **whole history** (paged via `fetchAllPages` — R5-NEW2
  fixed in v66) and within the file. **Nothing is inserted on file pick.**
- Confirm (admin-only gate, toast "Only the admin can import transactions."
  for members): inserts all new rows (`source: 'csv'`, `state:
  'provisional'`, `kind: classifyCsvKind(merchant, amount)` — see §14.3,
  `dedupe_hash = sha256(date | MERCHANT | amount | suffix)`), audits
  "CSV import" ("`N` added, `M` not inserted."), toast "Imported `N`
  transaction(s) as provisional.", clears file/preview, closes popup,
  refreshes. Insert failure → toast "Could not import. Nothing was claimed
  as imported — try again." No auto-link call after import (service-role-only).
- **OPEN:** real-phone CSV tap-through (file saved in Files) is owner-only
  and still owed (R5 §8, SYNTHETIC_PROOFS proof 12). Desktop CSV is
  code-verified only.

## 9. Screen 9 — Funds

`live.html:387-511`, `live.js:1203-1270, 1625-1815, 3530-3650, 4207-4230,
4608-4719`. Entry: tab "Funds". Top: two balance panels side by side
(`#section-fund-balances` grid): **Extra Fund** and **Charity** — same
face as the Home stat cards (Title + Amount only, chevron `⌄` bottom-right)
and the same in-place expansion, except the Funds expansions **include
action buttons** (Home does not).

### 9.1 Balance panels and expansions

- Extra Fund panel (`data-fund-card="fund"`, `#fundSummary`): face = available.
  Expansion rows: Available ("Spendable available" admin / "Available to
  request" member) / Pending / Total. Buttons (admin): **Add Money**
  (primary) / **Spend from Fund** (pale, middle tier) / **Request Money**
  (tertiary). Members see **Request Money** only (tertiary). Tapping a
  button collapses the card and opens the matching form (§9.3).
- Charity panel (`data-fund-card="charity"`, `#charitySummary`): face =
  remaining. Expansion rows: Available / Given / Total + small line
  "November 2026 onward". Buttons (admin): **Record Income** (primary) /
  **Close** (tertiary). Members see **Close** only. "Record Income" opens
  the Charity Income & Rate form; "Close" just collapses.
- Loading faces: "Loading fund balance…" / "Loading charity…". Failure:
  soft-red "Could not load fund balances. Try again." / "Could not load
  charity. Try again." (and cached data cleared).

### 9.2 More card (`#section-fund-more`)

Heading **More**. Three `›` rows (accordion — opening one closes the others;
headers always stay visible):

- **Fund Activity** (admin only; hidden for members) → `#section-fund-activity-more`:
  **Money Added** list (top-ups, admin read-only, newest first, max 50):
  "`$X` · `Mon D, YYYY` · `$Y` covered owed back · `$Z` added to fund ·
  Owed back after `$W` · note". Empty: "No money added yet." Failure:
  soft-red "Could not load money added. Try again."
  **Charity Income** list (admin read-only, newest first, max 50):
  "`Source` · `$X` on `Mon D, YYYY` at `R`% → commits `$Y` · note" +
  " (Reversed — replaced)" for reversed rows; active rows get a **Correct**
  button (opens the income form prefilled, scrolls to it, focuses Source;
  mode line "Correcting an earlier entry — saving reverses it and adds a
  replacement. The old entry stays, marked reversed." + **Cancel
  Correction** button). Empty: "No income recorded yet." Failure:
  "Could not load income. Try again."
- **Review** (admin only; label becomes "Review (N)" when N items need
  review: pending held refunds + pending duplicate pairs + refund-link
  suggestions) → `#section-fund-review-more` (see §9.4).
- **Past Savings Records** (all roles) → `#section-savings-more`: four
  numbers from `savings_ledger` kinds: **Balance** (latest attested
  `actual_balance_cents` — NEVER a sum of movements; "Not recorded yet" if
  none), **Transferred in**, **Withdrawn**, **Interest / adjustments**.
  Below: latest 20 records ("`kind` `$X` · Recorded balance `$Y` ·
  `Mon D, h:mm AM` · note") + "Showing the latest 20 records." when more
  exist. Empty (no rows at all): "No past savings records." (one line
  only). Rows exist but no balance ever recorded: "Past savings records
  exist, but no balance was ever recorded for them — that is a missing
  balance, not $0." **Read-only: no form writes savings anymore**
  (the everyday Savings section is gone; the write path only attests a
  balance via kind `adjustment`, amount 0 — so transfer/withdrawal/
  interest totals stay $0 until a write path for those kinds lands).
  Failure: "Could not load savings. Try again."

### 9.3 Funds forms (one at a time; More card hides while a form is open)

All four forms have a **← Back** button (returns to Funds list) and are
opened via `setFundForm(which)`; swipe-right while a form is open closes
the form. `fundFormOpen`: null = list, `add` / `use` / `ask` / `income`.

- **Add Money** (`#section-fund-add`, admin only): heading **Add Money**.
  Note: "Log cash already in checking — owed back is covered first."
  Fields: **Amount ($)** (required), **Note (optional)** (max 120),
  checkbox "I have already put this money in checking" (unchecked by
  default — required). Preview line `#fundTopupPreview`: "Enter an amount
  to see the split." → "Split: `$X` added to fund · `$Y` covers owed back ·
  Owed back after `$Z`." (client preview via `applyShortfallToRelease`;
  the server split from `add_fund_money` is authoritative). If fund data
  has not loaded: "Fund balance has not loaded yet — the server still
  covers anything owed back first when you save." Inline error
  `#fundTopupError`. Submit **Save Top-Up** (primary; **OPEN R5-NEW1 —
  ship as "Save Top-Up"**). Footnote: "Log each deposit only once."
  RPC `add_fund_money (p_household_id, p_amount_cents, p_note,
  p_client_key)` — idempotent via client key (a retried submit replays
  the same top-up). Success toast: "Top-up saved: `$X` covered owed back,
  `$Y` added to fund." Rule: top-ups cover shortfall FIRST, then the
  remainder increases spendable Available (owner, Nov 3).
- **Use Fund Money** (`#section-fund-use`, admin only): heading **Use Fund
  Money**. Note: "Lowers the fund balance only." Fields: **Amount ($)**,
  **Note (optional)**. Submit **Record It** (primary; **OPEN R5-NEW1 —
  ship as "Record It"**). Errors inline in `#fundAllocateMsg` (soft red).
  RPC `allocate_fund (p_household_id, p_amount_cents, p_note,
  p_override_reason)`; on "insufficient fund" error, a sheet "Fund Is
  Short" ("The fund does not cover `$X`. Record it anyway with a typed
  reason — it will be logged.", input "Reason for overriding", Confirm
  **Record Anyway**) retries with the reason. Success toast: "Fund spending
  recorded."
- **Ask for Fund Money** (`#section-fund-ask`, all roles): heading **Ask for
  Fund Money**. Note: "The admin approves or declines each request."
  Fields: **Amount ($)**, **Note (optional)**. Inline error
  `#fundRequestError`. Submit **Send Request** (primary; **OPEN R5-NEW1 —
  ship as "Send Request"**). Inserts a `fund_requests` row
  (`status: 'pending'`); audits "Extra Fund request created". Below the
  form: disclosure "View activity · Fund requests" → `#fundQueue` list
  (max 50, newest first): "`$X` · STATUS · note" — tap to expand detail:
  Requested / Status / "Fund available now: `$X`" (filled lazily at tap
  time) / Approved (`$X` of `$Y` requested — remainder still unapproved
  and needs a new request, for splits) / Note / Requested datetime /
  status sentence ("Waiting on the admin decision. …" / "Approved — the
  fund balance above already reflects it." / "Split approval — see the
  approved and remaining amounts above." / "Declined by the admin.").
  Pending requests show admin-only **Approve** (primary, small) /
  **Decline** (quiet, small) buttons. Status labels: `split` → "Split —
  `$X` remaining"; otherwise upper-cased status. Empty: "No fund requests yet."
  - Approve: sheet "Approve from the Fund" ("Approve how much of this
    `$X` request? Enter less for a split approval.", input Amount ($)
    prefilled with the full amount, Confirm **Approve**). Reject ≤0 or
    non-numeric ("Invalid amount" alert); reject > requested ("Too much"
    alert — "You cannot approve more than the requested `$X`."). RPC
    `approve_and_allocate (p_request_id, p_amount_cents,
    p_override_reason)`; on "insufficient fund", sheet "Fund Is Short"
    ("The fund does not cover `$X`. You can still approve with a typed
    reason — it will be logged.", input "Reason for overriding", Confirm
    **Approve Anyway**) retries with the reason. Failure: "Could not
    approve this request. Please try again in a moment."
  - Decline: RPC `decline_fund_request (p_request_id)`. Failure: "Could
    not decline this request. Try again."
- **Charity Income & Rate** (`#section-charity-income`, admin only):
  heading **Charity Income & Rate**. Note: "Admin only. Nothing is pulled
  in automatically." Line `#charityRateCurrent`: "Current default rate:
  10%." (rate formatted without trailing zeros). Form **Default rate (%)**
  (0–100) + **Save Default Rate** (primary; **OPEN R5-NEW1 — ship as "Save
  Default Rate"**). Note: "Affects future incomes only." RPC
  `set_charity_default_rate (p_household_id, p_rate_bp)` (percent inputs
  parse as basis points: "10.5" → 1050). Success toast: "Default charity
  rate saved: `R`% for future incomes."
  Sub-heading **Record Income**. Mode line `#charityIncomeMode`: "Adding new
  income." (or the correction text above). Fields: **Source (for example,
  Paycheck)** (max 80), **Amount ($)**, **Date**, **Rate % (blank = default)**
  (0–100), **Note (optional)**. Preview `#charityIncomePreview`: "Enter an
  amount to see what it commits." → "This commits `$X` at `R`% — this entry
  only (the default rate for future incomes is unchanged)." / "…the default
  rate, applied to this entry." Submit **Save Income** (primary; **OPEN
  R5-NEW1 — ship as "Save Income"**) + **Cancel Correction** (tertiary,
  hidden unless correcting; **OPEN R5-NEW1 — ship as "Cancel Correction"**).
  New income → RPC `record_charity_income (p_household_id, p_amount_cents,
  p_income_date, p_source_label, p_rate_bp, p_note)`; correction → RPC
  `correct_charity_income (p_income_id, …)` (append-only reversal +
  replacement). Date must be ≥ 2026-11-01 ("Charity starts November 2026 —
  income before then cannot accrue."). Success toast: "Income saved —
  commits `$X` to charity." / "Income corrected — now commits `$X`. The old
  entry stays, marked reversed."

### 9.4 Review area (`#section-fund-review-more`, admin only)

Sub-sections in order:

1. **Refund Restorations & Held Refunds** — **Restorations** list (max 100,
   newest first): "Week of `Mon D, YYYY` · Restored `$X` · Debt cut `$Y`
   [· Fund +`$Z`]". Empty: "No restorations yet."
   **Held for review** list (max 100): "`$X` · Held for review" (+ pending
   rows get a **Release** button, primary small) / "`$X` · Resolved —
   `note`". Empty: "Nothing held for review." Release: confirm "Release
   Held Refund" ("Release `$X` to spendable surplus? Any amount owed back
   is covered first.", Confirm **Release**) → RPC `resolve_held_refund
   (p_held_id, p_action: 'release', p_note: '')`. Failure: "Could not
   release this held refund. Try again." **OPEN (SYNTHETIC_PROOFS flag 1):**
   two `resolve_held_refund` definitions exist in the repo
   (`merged-audit-held-release-atomic.sql` with a row-count guard vs
   `restoration-snapshots.sql` without); both refuse a second release, but
   the live body is unverified — probe F must settle it. The clone calls
   the RPC; a second release must raise.
2. **Possible Duplicates** (`#dedupeList`, max 100 pending, show first 20):
   each pair is a vertical comparison card: match line ("Match: same amount,
   same date, same card, same source." or "Compare the two records below.");
   flag-reason line (Nov 9 fix): "Flagged as a lookalike — merchant names
   look related: `A` / `B`."; two sides **Keep** / **Possible duplicate**
   (merchant bold, labelled rows Amount / Date / Card / Source / Counts);
   buttons BELOW the comparison: **Same Purchase** (primary, small) /
   **Separate** (tertiary, small); below the buttons a checkbox "Remember
   as same merchant — remembers these two merchant names as the same for
   future review, so similar pairs are treated as the same merchant next
   time." Confirm sheets: "Same Purchase" ("Keep one transaction and
   exclude the other from counts? Neither row is deleted.", Confirm "Same
   Purchase") / "Separate Purchases" ("Keep both transactions and never
   flag this pair again?", Confirm "Separate"). RPC
   `resolve_duplicate_candidate (p_candidate_id, p_action: 'merge' |
   'separate', p_note: '', p_remember_alias: bool)` — never deletes a row.
   Paging: "Showing the first 20 of `N` possible duplicates." + **Show
   More** button (+20 per tap). Empty: "No possible duplicates waiting."
   Failure: "Could not load possible duplicates. Try again."
3. **Resolved Duplicates** (`#dedupeResolvedList`, max 20, newest first):
   "`A` / `B`" + "Merged · `Day` — the duplicate can be restored from
   Trash." / "Kept separate · `Day`." Separate rows get a **Reopen**
   button (tertiary, small) → confirm "Reopen Duplicate Review" ("Show
   this pair in Possible Duplicates again?", Confirm "Reopen") → RPC
   `reopen_duplicate_candidate (p_candidate_id)`. Merged rows have NO
   Reopen button (undo is Trash restore). Empty: "No resolved duplicates."
4. **Refund Links** (`#refundLinkList`): unlinked refunds (kind refund,
   no `original_purchase_id`, not excluded/reversed, max 100) matched
   client-side by `computeRefundSuggestions` (`refundSuggestions.mjs`):
   same card, purchase within 90 days, refund fits in the purchase's
   remaining refund room; aliases + dismissals applied. Each suggestion
   is a comparison card: reason line (exact strings in
   `REFUND_SUGGESTION_REASONS`: "Only one purchase matches — same amount,
   card, and place." / "Same amount, card, and place — more than one
   purchase matches, pick the right one." / "Partial refund — fits in what
   this purchase has left to refund." / "Same amount and card, different
   place — check this is the right purchase before linking."), sides
   **Refund** / **Purchase** (merchant, Amount, Date, Card, Source),
   buttons **Link** (primary, small) / **Dismiss** (tertiary, small).
   Link: confirm "Link Refund" ("Link this `$X` refund from `A` to `B`
   `$Y`?", Confirm "Link Refund") → RPC `link_refund (p_refund_id,
   p_purchase_id)`; server fit-check is the guard; success toast "Refund
   linked to its purchase." + audit. Dismiss: confirm "Dismiss Suggestion"
   ("Hide this suggestion? It will not be shown again.", Confirm "Dismiss")
   → RPC `dismiss_refund_link_suggestion (p_refund_id, p_purchase_id)`.
   Paging: first 20 + "Showing the first 20 of `N` refund link suggestions."
   + **Show More** (+20). Empty states: no unlinked refunds → "No unlinked
   refunds."; unlinked but no suggestions → "No refund links to suggest."
   Failure: "Could not load refund link suggestions. Try again."
   Nothing here links anything by itself — every link is an admin tap.

## 10. Screen 10 — Settings

`live.html:298-385`, `live.js:1269, 1385-1620, 2874-3010, 3249-3400`. Entry:
profile menu → Settings. Heading **Settings** + **← Back** (returns to
`previousView`, or Home after a reload; focus moves to the Settings heading
on entry). Cards in order: Profile, Bank Connection, Email Alerts, Budget
(admin only), Account & Household.

### 10.1 Profile (`#section-profile`)

- Heading **Profile**. Field **Name** (`#profileNameInput`, max 80) +
  **Save Name** (primary; fixed in v66). Field **Email**
  (`#profileEmailInput`) + **Save Email** (primary; fixed in v66).
  Sub-heading **Password** + **Change Password** (tertiary; **OPEN
  R5-NEW1 — ship as "Change Password"**).
- Save Name: empty → toast "Enter a name to save." (error) + focus.
  `supabase.auth.updateUser({data: {full_name: name}})` (metadata only —
  no SQL, no new column). Success toast: "Name saved — it now shows in
  your profile." Menu header shows the first name only. Failure: "Could
  not save your name. Try again."
- Save Email: invalid → toast "Enter a valid email address." (error).
  Same as current → toast "That is already your sign-in email." Otherwise
  `supabase.auth.updateUser({email})`; the sign-in email does NOT change
  until the new address is confirmed. Success toast: "Confirmation sent to
  `email` — your sign-in email stays as it is until you confirm it."
  Failure: "Could not change your email. Try again."
- Change Password: sheet "Change Password" ("Enter a new password for this
  account. Password requirement: at least 8 characters.", input "New
  password" type password with Show/Hide toggle, Confirm **Change
  Password**). Empty/cancel → nothing. <8 chars → alert "Password too
  short". `supabase.auth.updateUser({password})`. Alert "Password changed"
  / "Could not change password".

### 10.2 Bank Connection (`#section-bank`)

- Heading **Bank Connection**. Note: "Look only — it never moves, sends, or
  changes anything."
- Button row: **Connect New Account** (primary) + **Sync Transactions**
  (tertiary). Both hidden for members (admin-only; server enforces 403).
- **Automatic Sync** row: label + switch (`role="switch"`, aria-checked).
  State is server truth (`households.auto_sync_enabled`, written by
  `plaid-webhook-register`); a failed read leaves the switch off. Row
  hidden for members. Turning on registers the webhook on every connected
  item; turning off clears it (Plaid `/item/webhook/update` with an empty
  webhook). Toasts: "Enabling automatic sync…" / "Turning off automatic
  sync…"; no bank yet → "No bank connection yet — connect a bank account
  first." (error); any item fails → "Automatic sync could not be turned
  on/off — `Bank` failed`: reason` (+N more). Nothing was changed; the
  switch stays off/on." (error — a partial success is never claimed);
  success: "Automatic sync on. New transactions will be pulled in on your
  next refresh." / "Automatic sync off." A failed toggle leaves the switch
  where it was.
- `#bankMsg` result; `#bankSyncLine`: "Last synced `Mon D, h:mm AM`" or
  "Not synced yet." (or "Could not load bank accounts." on failure).
- **Connected Accounts** (`#bankAccountsList`): ONE ROW PER ACCOUNT (owner,
  Nov 4). Each row: bank favicon (Google favicon service; brand-coloured
  monogram fallback), account name bold (nickname if set, else Plaid
  account name, else "Account"), meta line "Institution · Plain type ·
  ••mask" (plain types: Credit card / Checking / Savings / Bank account /
  Loan / Investment; unknown types render NOTHING, never a raw Plaid word),
  "Connected `Mon D, YYYY`" line, and — only when that item missed the
  latest sync (its `last_sync_at` older than the household's latest sync
  while others advanced) — red "Sync failed" line. A never-synced item
  shows no failure line. Admin-only **Add nickname** / **Edit nickname**
  (small quiet button) → sheet "Nickname" ("Give this account a short name
  (up to 40 characters). Leave it blank to remove the nickname. The
  nickname is only a label — it never changes bank links, matching, or week
  math.", input Nickname, Confirm **Save**) → RPC `set_account_nickname
  (p_household_id, p_plaid_item_id, p_plaid_account_id, p_card_suffix,
  p_nickname)` (null clears). Nicknames show in the Transactions Card
  filter only when the suffix maps to exactly one account. Admin-only
  **Disconnect** per account (small danger button) → confirm "Disconnect
  Account" ("Disconnect `Name ••mask`? This stops syncing this account
  only. Other accounts on the same bank connection keep syncing. Past
  transactions stay in the list. To sync this account again later,
  reconnect the bank from the Bank Connection card.", Confirm "Disconnect")
  → Edge Function `plaid-account-disconnect`. Items with no accounts at
  all keep the old whole-item Disconnect → confirm "Disconnect Bank" →
  `plaid-disconnect`. Disconnected accounts are simply not listed
  ("Previously connected" is GONE — owner, Nov 4). Empty: "None."
- **Connect New Account** flow: if active connections exist, first a
  confirm "Already Connected?" listing them ("You already have this/these
  bank connection(s): … Connecting the same account again will create a
  duplicate. You do not need to reconnect an account that is already
  syncing — only continue if you are connecting a different account.",
  Confirm **Connect Anyway**; Cancel is the safe path). A failed read fails
  OPEN (never blocks a connection). Then toast "Getting a secure bank
  connection…", Edge Function `plaid-link` → `link_token`; failure toast:
  "Could not start the bank connection: `error`. If it says "not
  configured," the bank connection is not set up on the server yet."
  Plaid Link opens (native Plaid Link SDK in the clone — **NEEDS-LIVE-PROBE
  P2** for exact Link screens). On success: toast "Bank approved — finishing
  the secure connection…", `plaid-exchange` with public token + institution
  name; connected → "Connected. Tap "Sync Transactions" to pull
  transactions."; duplicate → "This bank is already connected — the
  duplicate connection was removed. Past transactions stay."; failure →
  "Connection could not be finished: `error`". On exit with error: "Bank
  connection closed: `message`".
- **Sync Transactions** / Home sync: `runBankSync()` (`live.js:2842-2874`) —
  one sync at a time (guard; a repeat tap while syncing is ignored); both
  sync buttons show progress (Settings button disabled + "Syncing…", Home
  icon spins) until the sync finishes; guard releases in `finally` so a
  failed sync never leaves buttons stuck. Toast "Syncing bank transactions…"
  then the result toast built by `bankSyncToast` (names failed
  connections; reads the API stale flag and `skipped_by_reason` where the
  function returns them). Then `refresh()`. Server truth for connection
  state comes from `plaid_items`/`plaid_accounts` rows only — never
  localStorage.

### 10.3 Email Alerts (`#section-email`)

- Heading **Email Alerts**. Note: "Look only — it never moves, sends, or
  changes anything." Card visible to all members (status lines stay
  visible); Connect / Check / Disconnect are admin-only (hidden for
  members in `showView`; Disconnect buttons rendered admin-only).
- Sub-heading **Connected Email**. Rows: email address bold; if status is
  `error`: "Needs reconnect — access was revoked or expired."; Testing-mode
  warnings: "Email access expires about 7 days after connecting — reconnect
  soon to keep alerts coming." (when `connected_at` is ~7 days old) /
  "Not checked since `datetime` — if new alerts stop arriving, reconnect."
  (stale `last_poll_at`); "Last checked `datetime`"; `last_error` text if
  any. No standalone "Connected" line (it would repeat the heading).
  Empty (admin): "None — connect an email below." Empty (member): "None —
  the admin connects email alerts." `#emailStatusLine`: "No email connected
  yet." or "Could not load email connections."
- Buttons: **Connect Email** (primary; **OPEN R5-NEW1 — ship as "Connect
  Email"**) + **Check Email Now** (tertiary; fixed in v66). `#emailMsg`
  result.
- Connect Email: `gmail-oauth-start` (no household id — the function derives
  it from the caller's admin membership). On 409 (multi-household admin):
  sheet "Choose Household" ("You administer more than one household. Choose
  which household this email connection belongs to.", Household select,
  Confirm **Continue**) then retry with the picked `household_id`. No
  `auth_url` → "Could not start the email connection: `error`. If it says
  "not configured," the email connection is not set up on the server yet."
  Success redirects the whole page to Google (native: system browser /
  ASWebAuthenticationSession — **NEEDS-LIVE-PROBE P3** for exact consent
  screens). Return carries `?gmail=connected` / `?gmail=failed` (see §0.2).
  This never touches the old Apps Script email path.
- Check Email Now: "Checking email…" then `gmail-poll`; the message is
  built by `emailCheckMessage` (surfaces per-connection failures from
  `errors[]` — a top-level-only read used to report false success — and
  the API stale flag). Then `refresh()`.
- Disconnect (per connection, admin-only): confirm "Disconnect Email"
  ("Disconnect `email`? The app will stop checking it. Past transactions
  stay in the list.", Confirm "Disconnect") → `gmail-disconnect`.

### 10.4 Budget (`#settingsCard`, admin only)

- Heading **Budget** + role pill "Admin". Note: "Only the admin can change
  these."
- **Weekly Allowance**: money input (`$` prefix, `#baseAllowanceInput`,
  prefilled from `households.base_allowance_cents`) + **Save Allowance**
  (primary; **OPEN R5-NEW1 — ship as "Save Allowance"**). Empty input is
  NOT 0 ("Enter a valid allowance (empty is not 0)."). Save opens a
  confirm sheet "Change Allowance": "Change the weekly allowance from
  `$OLD` to `$NEW`? This applies from the current week onward (week of
  `Mon D, YYYY`). It does not rewrite closed weeks." (or the "current
  allowance could not be read" variant), Confirm **Change Allowance**
  (**OPEN R5-NEW1 — ship as "Change Allowance"**), Cancel "Keep Current".
  RPC `set_base_allowance (p_household_id, p_cents)`. Toast "Allowance saved."
- **Temporary Allowance**: heading **Temporary Allowance**. Two compact
  fields side by side, symmetrical (same label style, control height 46px,
  border, radius, padding, 4px gap under the label, aligned baselines):
  **New total** (`$` input, capped 200px) + **Weeks** (select 1–4, narrow
  64px). Button **Set New Total** (primary; **OPEN R5-NEW1 — ship as "Set
  New Total"**). Preview line `#tempPreview` (empty until values entered):
  "Base `$B` · New total `$N` · `W` week(s) · `YYYY-MM-DD, …`." (dates are
  the current Sunday plus following Sundays, NY time).
  **The amount is a NEW TOTAL weekly allowance, REPEATING each week for the
  chosen 1–4 weeks — not a total split across weeks** (owner, Nov 4).
  Each week gets its own override row via RPC
  `set_weekly_allowance_override (p_household_id, p_week_start,
  p_allowance_cents)` — never `add_temp_increase`, which cannot represent
  a lower total and must not be used as a fallback. Double-tap guard
  disables the button while saving. Success toast: "Weekly allowance set
  to `$X` for `W` week(s)." Failure: "Could not set the weekly allowance.
  Try again." Invalid: "Enter a valid amount."
- `#settingsMsg` / `#tempMsg` result lines.

### 10.5 Account & Household (`#section-settings-account`)

- Heading **Account & Household**. Note: "Only the admin can share the
  invite code." Line `#householdNameLine`: "Household: `Name`".
- **Members** (`#membersList`): one row per member — person's NAME (never
  the word "Member" as a name; resolution: stored `display_name` → own auth
  metadata name → RPC `email_prefix` → "Household member"), role pill
  (Admin/Member), " (you)" suffix on the signed-in member. Admin sees a
  **Remove** button (small danger) on every OTHER member's row; never on
  their own row; members see no Remove buttons. Remove flow: confirm
  "Remove Member" ("Remove `Name` from the household? They will lose access
  to the household's data.", Confirm "Remove") → RPC
  `remove_household_member (p_user_id)` (server re-checks: admin-only, own
  household only, never yourself, never the last admin). Success toast:
  "`Name` was removed from the household." Failure: "Could not remove
  member". **OPEN (R5 §8):** whether the owner actually removed the test
  member `onbudget-ui-audit-20261103` is unconfirmed — the clone ships the
  flow; the removal itself is an owner tap.
- Invite code (admin only): intro "Members join with the invite code below."
  + monospace code box `#inviteCodeBox` with **Copy** (primary) /
  **Share** (tertiary) buttons. Copy writes the code to the clipboard and
  flips the button to "Copied" for 2s. Share uses the native share sheet
  with text "Join my household on OnBudget with invite code `CODE`"
  (`navigator.share`; falls back to Copy where unavailable). The code is
  NEVER the household UUID. No code set up → "No invite code is set up for
  this household yet." Members never see the box, the intro, or the empty
  line.
- Danger area: **Delete Account** sub-heading; "Deleting removes you from
  this household. If you are the last member, the household is deleted too.
  This cannot be undone." Button **Delete Account** (danger; **OPEN
  R5-NEW1 — ship as "Delete Account"**). TWO-STEP confirmation: "Delete
  Account" → "Delete Everything?" ("This permanently deletes your account
  and, if you are the last member, the whole household. Are you sure?",
  Confirm "Yes, Delete Everything"). Edge Function `delete-account` (no
  household id — derives from the caller). On failure the server restores
  the membership first and the alert names the failing step: "Could not
  delete account. Nothing was deleted — try again. (step: `step`)". On
  success: sign out, clear fields, auth screen, inline "Your account was
  deleted."
- Footer links: Privacy · Terms.

## 11. Screen 11 — Trash

`live.html:526-532`, `live.js:1171-1200`. Own page (owner, Nov 5): heading
**Trash** + **← Back** (→ Transactions; swipe-right also returns to
Transactions). Subtext: "Bank rows you deleted live here. The admin can
bring them back."
- Lists excluded rows only (`excluded === true || state === 'excluded'`),
  from the same load as Transactions. Each row: icon, merchant, amount,
  day + card, and a **Restore** button (primary, small).
- Restore → RPC `restore_transaction (txn_id)`; restores the stored
  `pre_exclusion_state` (provisional/verified/reversed) and clears
  excluded/reason/snapshot. Refuses with an alert when no prior state was
  recorded ("cannot restore: no prior state recorded" — only reachable
  synthetically now; the real household's 23 NULL-snapshot rows were
  deleted Nov 9 per owner decision). Audits "Transaction restored"
  ("`Merchant` returned to the week."). Failure alert: "Could not restore"
  / "Could not restore this transaction. Try again."
- Empty: "Trash is empty." (Note the leading space in the live string —
  trim it in the clone.)
- The Trash link on Transactions is admin-only and hidden when the count
  is 0; the Trash page itself renders from the same `all` list.

## 12. Screen 12 — Past Weeks

`live.html:513-515, 533-554`, `live.js:2230-2300`. Own page: heading **Past
Weeks** + **← Back** (→ Transactions). Subtext: "Closed weeks, read-only. Tap
a week to see its summary and its transactions."
- **Filter by Date** card (`#section-history-filter`): **From** / **To**
  date fields side by side (compact, labels "From"/"To"), buttons **Apply
  Filter** (primary; fixed in v66) / **Clear Date Filter** (tertiary;
  **OPEN R5-NEW1 — ship as "Clear Date Filter"**). The same filter narrows
  BOTH the week list and the Activity list. Period line
  `#historyPeriodLine` (e.g. "Showing …" via `historyPeriodLabel`); count
  line `#historyCountLine` ("Closed weeks: `S` shown of `T` total ·
  Activity: `S` shown of `T` total") — shown only when a filter is active
  or a list is empty; otherwise blank. Apply resets `auditLimit` to 50.
- **Week History** card (`#section-week-history`): closed weeks, newest
  first (max 100), from `week_closes` + `surplus_releases` (read-only —
  the client never recomputes a week). Each week is a tappable block:
  heading "`Mon D, YYYY`" + labelled rows **Carry-in** / **Surplus** /
  **Debt carried out** / **Release** (label varies: "Release" / "Released" /
  "Pending release" / "Held"). Carry-in = the previous closed week's
  outgoing debt (the debt-carry chain); a first week has no carry-in on
  record. Missing figures read **"not recorded"**, never `$0`. Release
  value: released → `released_cents ?? surplus_cents`; pending/held →
  `surplus_cents`; no release row → "not recorded".
- Tapping a week sets the Transactions date filters to that Sun–Sat week,
  clears other Transactions filters, opens Transactions, refreshes, toasts
  "Showing transactions for the week of `Mon D, YYYY`.", and scrolls the
  list into view.
- Empty: "No closed weeks yet." / (filtered) "No closed weeks in the
  selected period." Failure: soft-red "Could not load week history. Try again."

## 13. Screen 13 — Activity

`live.html:517-519, 556-559`, `live.js:2300-2337`. Own page: heading
**Activity** + **← Back** (→ Transactions). Subtext: "Who did what, and when
— not the transaction list." (No second identical heading inside the card —
removed Nov 5.)
- List `#auditList` from `audit_log` (newest first; page size `auditLimit`
  = 50, **Load More Activity** button +50 per tap, hidden when the total
  is reached or on error; a filtered view fetches up to 1000 newest rows
  so the period is not silently cut off). Shares the History date filter
  with Past Weeks (§12).
- Grouped by day (newest day first), day heading "`Mon D, YYYY`". Each
  entry: small coloured dot per type, short bold title, one plain detail
  line, muted "`Actor` · `Mon D, h:mm AM`" (actor is "Admin"/"Member" or
  the name before `@` — never a raw username or UUID). Repeated
  weekly-processing rows collapse into one line with a count (e.g. "Weeks
  processed ×3" → "N weeks closed"); user actions never collapse.
  Display text is translated from stored rows: UUIDs stripped, ISO dates
  → long dates, "`N` cents" → `$X`, "`N` basis points" → `N%`, "as
  provisional" → "as pending", "create_household RPC" → "Household
  created." (`formatAuditDetail`, `live.js:3662-3694`).
- Trailing line when unfiltered and more exist: "More entries exist — tap
  Load more below." Empty: "No audit entries yet." / (filtered) "No entries
  in the selected period." Failure: "Could not load history. Try again."
- **OPEN (R5 N5, carried):** audit text is member-writable in the stored
  rows (display-side translation only). Clone: render the same translated
  text; do not change the stored rows.

## 14. Screen 14 — Weekly sheet (popup)

`openWeeklySheet()` (`live.js:3457-3500`). Opened by tapping the hero
number (or Enter/Space on it); if week data is not loaded, an alert sheet:
"Weekly Budget" / "Weekly numbers are not loaded yet. Try again in a
moment." Opening/closing writes nothing and triggers no sync.
- Title **Weekly Budget**. Message: "Pending transactions are included and
  marked." (+ " Unlinked refunds above this week's spending are not counted
  here." when the 4th row is present).
- Rows, exactly three, in order: **Allowance** (= base room + temp, so
  Allowance − Spent = Balance always, including a temp week) / **Spent**
  (server `charges_cents`) / **Balance** (`available_cents`).
- Fourth row only when non-zero: **Unlinked refunds** (`unlinkedExcessCents`
  — the part of the week's unlinked posted refunds that could NOT be netted
  against this week's charges, so it is invisible in Spent).
- Extra action **Show Transactions** (primary) + Confirm **Close**
  (tertiary — two-button sheet rule, §2.3). "Show Transactions" closes the
  sheet, opens Transactions filtered to the current week (`txWeekOnly =
  true`; other active filters are left alone), refreshes, and focuses the
  Filters button.
- The sheet's rows are also stored as the hero breakdown panels
  (Allowance / Spent / Debt / Outgoing texts, `live.js:1115-1165`) — the
  Debt panel: "`$X` carried over from earlier weeks — it comes off the top
  of this week's allowance before anything else." (or "No carried-over
  overspending: this week starts with the full allowance."); Outgoing:
  "`$X` outgoing debt = `$Y` debt the allowance did not cover plus `$Z`
  new debt from spending above this week's room. It carries into next
  week." (or "No outgoing debt: this week's spending stayed within its
  room."); Spent panel itemises dated charges by source + late charges from
  earlier locked weeks + refunds in the week's list + excluded count.

## 15. Screen 15 — Profile menu (top bar)

`live.html:13-33`, `live.js:3231-3260, 3355-3365`. Top bar (all app screens):
centred title (logo + "nBudget" wordmark — the "O" is the logo image),
profile button right (person icon, white circle). Tap toggles the menu
(Escape closes, outside tap closes, `aria-expanded`).
- Menu header: first name only (first whitespace token; email fallback
  shown unchanged) + role pill (Admin/Member) inline + email below in small
  muted text. The email line is hidden exactly when it would duplicate the
  header (i.e. when the header fell back to the email).
- Rows: **Settings** → Settings screen (focus moves to the Settings
  heading); **Sign Out** (danger row) → sign out (see §4.1).
- No Edit-profile row (profile editing lives in Settings only). The menu
  is NOT part of the scroll lock (§2.2).

---

## 16. Data rules — RPC / Edge Function inventory

Every action calls the same backend as the web app. **Exact params live in
the API client's call sites — cross-referenced below, not re-derived.**
Where a param is only known from one call site, that call site is cited.
Server enforces admin-only on every admin RPC (the client's 33 gates are
presentation only).

### 16.1 Edge Functions (via `callFn`, `live.js:2766-2790`)

`callFn` POSTs `{SUPABASE_URL}/functions/v1/<name>` with the user's JWT +
anon key; a network failure returns `{error: 'network error — check your
connection', status: 0}` instead of throwing; non-OK responses surface
`{...data, error, status}` so 401 (dead session) is distinguishable from a
server failure.

| Function | Purpose | Called from |
|---|---|---|
| `compute-week` | Week numbers for the current week. Body `{household_id}` only. Returns `{week_start, base_available_cents, temp_cents, carried_debt_cents, charges_cents, available_cents, week_locked, pending_refund_excluded_cents, unlinked_excess_cents}` (FINAL-spec contract; no credit/R/X fields; client never sends D, T, R_in). | `refresh()` → `loadWeekNumbers` (~`live.js:594`) |
| `week-close` | Closes due weeks. Body `{household_id}`. Admin only, once per session, skipped when the fingerprint says this week was already checked. Returns `{weeks_closed}`; figures reload once if > 0. **There is no scheduled week-close — admin loads are what close weeks** (`live.js:714-723`). | `refresh()` (~`live.js:724`) |
| `plaid-link` | Returns `link_token` for Plaid Link. Body `{household_id}`. | Connect New Account (`live.js:2795`) |
| `plaid-exchange` | Exchanges public token. Body `{household_id, public_token, institution_name}`. Returns `{connected}` / `{duplicate}` / `{error}`. | Plaid `onSuccess` (`live.js:2810`) |
| `plaid-sync` | Pulls transactions. Body `{household_id}`. Response read by `bankSyncToast` (`stale`, `minutes_since_previous_sync`, `skipped_by_reason`). | `runBankSync` (`live.js:2842`) |
| `plaid-webhook-register` | Registers/clears Plaid webhook per item. Body `{household_id, enabled}`. Returns `{results: [{ok, institution, error}]}`; stored in `households.auto_sync_enabled`. | Auto-sync switch (`live.js:2888`) |
| `plaid-disconnect` | Removes a whole Plaid item. Body `{household_id, plaid_item_id}`. Returns `{disconnected}`. | Whole-item Disconnect (`live.js:1500`) |
| `plaid-account-disconnect` | App-level per-account disconnect (sets `disconnected_at`; last active account on the item removes the Plaid item). Body `{household_id, plaid_item_id, plaid_account_id}`. | Per-account Disconnect (`live.js:1513`) |
| `gmail-oauth-start` | Returns `auth_url` for Google OAuth. Body `{}` (household derived from admin membership) or `{household_id}` on 409 retry. | Connect Email (`live.js:2971`) |
| `gmail-poll` | Checks email now. Body `{household_id}`. Response read by `emailCheckMessage` (`errors[]`, stale flag). | Check Email Now (`live.js:2996`) |
| `gmail-disconnect` | Disconnects an email connection. Body `{household_id, connection_id}`. Returns `{disconnected}`. | Email Disconnect (`live.js:1588`) |
| `delete-account` | Deletes the caller's account (+ household if last member). Body `{}`. Returns `{deleted}` / `{error, step}`. | Delete Account (`live.js:3323`) |

Other live Edge Functions in the repo (not called by `live.js` directly):
`plaid-webhook`, `ingest-amex-alert`, `gmail-oauth-callback` (server-side
callbacks / cron targets). `bootstrap-household` is dead and unused (removed
from the repo; a deployed copy may linger — never call it).

### 16.2 RPCs (via `supabase.rpc`, direct PostgREST, or direct table writes)

| RPC / table op | Purpose | Called from |
|---|---|---|
| `create_household(p_name)` | Creates household; caller becomes admin. Only path to admin. | Household name step (`live.js:2660`) |
| `join_household_by_code(code)` | Joins by invite code; returns household UUID or NULL (invalid). Rate-limited 5 failed/hour per caller + per code. | Join (`live.js:2694`) |
| `list_household_members()` | Returns all members (`user_id, display_name, role, created_at, email_prefix` — no full email). SECURITY DEFINER; direct `household_members` reads only return the caller's own row. | `refresh()` members list (`live.js:496`) |
| `remove_household_member(p_user_id)` | Admin-only; refuses self-removal and last-admin removal. | Members Remove (`live.js:3311`) |
| `set_base_allowance(p_household_id, p_cents)` | Sets base weekly allowance (applies from current week onward; never rewrites closed weeks). | Save Allowance (`live.js:4595`) |
| `set_weekly_allowance_override(p_household_id, p_week_start, p_allowance_cents)` | Per-week new-total override (1 call per week, 1–4 weeks). Never `add_temp_increase`. | Set New Total (`live.js:4550`) |
| `add_fund_money(p_household_id, p_amount_cents, p_note, p_client_key)` | Top-up; server split is authoritative (shortfall first). Idempotent via client key. | Add Money (`live.js:4630`) |
| `allocate_fund(p_household_id, p_amount_cents, p_note, p_override_reason)` | Spend from fund; insufficient-fund error → override with typed reason. | Use Fund Money (`live.js:4665`) |
| `approve_and_allocate(p_request_id, p_amount_cents, p_override_reason)` | Approve (full or split); insufficient-fund error → override with typed reason. | Fund request Approve (`live.js:1240`) |
| `decline_fund_request(p_request_id)` | Decline a fund request. | Fund request Decline (`live.js:1261`) |
| `set_charity_default_rate(p_household_id, p_rate_bp)` | Sets default charity rate (basis points). Future incomes only. | Save Default Rate (`live.js:4335`) |
| `record_charity_income(p_household_id, p_amount_cents, p_income_date, p_source_label, p_rate_bp, p_note)` | Records income; returns `{committed_cents}`. `p_rate_bp` null = default. | Record Income (`live.js:4360`) |
| `correct_charity_income(p_income_id, p_amount_cents, p_income_date, p_source_label, p_rate_bp, p_note)` | Append-only reversal + replacement of an income row. | Correct (`live.js:4360`) |
| `record_charity_gift(p_household_id, p_merchant, p_amount_cents, p_date, p_card_suffix, p_note, p_dedupe_hash, p_client_key)` | Records a gift as verified at once. Single 8-arg overload (BE-1 fixed live Nov 9). | Give to Charity (`live.js:4290`) |
| `mark_transaction_charity(p_transaction_id)` | Marks a charge (pending or posted, unlocked week) as charity; state untouched. | Actions → Charity (`live.js:3813`) |
| `reclassify_transaction(txn_id, new_kind, reason)` | Changes a row's kind; reason required. Locked-week refusal surfaces the server message. | Actions → Other (`live.js:3922`) |
| `delete_transaction(p_transaction_id)` | Permanently deletes a hand-entered row. 35-day locked-week check. | Actions → Delete, manual rows (`live.js:3942`) |
| `exclude_transaction(txn_id, reason)` | Moves a bank/email/file row to Trash (exclusion + reason, never a true erase). 35-day lock. | Actions → Delete, synced rows (`live.js:3942`) |
| `restore_transaction(txn_id)` | Restores a trashed row to its `pre_exclusion_state`. 35-day lock. | Trash Restore (`live.js:1190`) |
| `link_refund(p_refund_id, p_purchase_id)` | Links a refund to a purchase (server fit-check is the guard). | Actions → Link to Purchase; Refund Links → Link (`live.js:3862, 2130`) |
| `unlink_refund(p_refund_id)` | Unlinks a refund; server refuses when a restoration entry exists. | Actions → Link to Purchase, linked rows (`live.js:3862`) |
| `dismiss_refund_link_suggestion(p_refund_id, p_purchase_id)` | Records a dismissal so a suggestion never reappears. | Refund Links → Dismiss (`live.js:2160`) |
| `resolve_duplicate_candidate(p_candidate_id, p_action, p_note, p_remember_alias)` | Merge (excludes the duplicate, never deletes) or Separate (never re-flags). | Possible Duplicates (`live.js:1955`) |
| `reopen_duplicate_candidate(p_candidate_id)` | Reopens a Separate pair into Possible Duplicates. | Resolved Duplicates → Reopen (`live.js:2035`) |
| `resolve_held_refund(p_held_id, p_action, p_note)` | Releases a held refund to spendable surplus (shortfall first). Second release must raise. | Held → Release (`live.js:1840`) |
| `set_account_nickname(p_household_id, p_plaid_item_id, p_plaid_account_id, p_card_suffix, p_nickname)` | Sets/clears (null) an account nickname (≤40 chars, label only). | Nickname sheet (`live.js:1460`) |
| Direct `transactions` insert | Manual add (`source manual, state provisional, kind charge`); CSV import (`source csv, state provisional, kind classifyCsvKind`); fund request rows are inserted into `fund_requests` directly (`status pending`). | Manual form, CSV confirm, fund request forms |
| Direct `audit_log` insert | Append-only audit entries (actor = user id, actor_name = email or role). Failures warn to console only; the action still happened. | `audit()` (`live.js:390-411`) |
| Direct reads (PostgREST) | `households` (name, base_allowance_cents, allowance_set_at, fund_shortfall_cents, auto_sync_enabled, invite_code), `household_members`, `transactions`, `fund_requests`, `fund_ledger`, `surplus_releases`, `week_closes`, `savings_ledger`, `plaid_items_public`, `plaid_accounts`, `email_connections_public`, `charity_income`, `charity_settings`, `restoration_entries`, `held_refunds`, `duplicate_candidates`, `merchant_aliases`, `refund_link_dismissals`, `account_nicknames`, `audit_log`. All reads are paged past 1,000 rows via `fetchAllPages` (1,000-row pages) where the sum matters (B6) — including CSV preview dedupe (R5-NEW2, fixed in v66). | `refresh()` throughout |

### 16.3 Server-computed figures (display, never recompute locally)

- Week numbers: `compute-week` (§6.1). Week-close figures: `week_closes`
  rows. Fund available/pending/total: derived client-side ONLY from
  `fund_ledger` + `surplus_releases` + `households.fund_shortfall_cents`
  sums (the web sums them in `refresh()`; the clone must sum the same
  tables the same way — available = Σ `fund_ledger.amount_cents`; spent =
  |Σ allocation + override_allocation|; pending = Σ pending releases
  (surplus − released, floored at 0); released total = Σ released;
  held = Σ held surplus). Charity committed = Σ per active income row at
  that row's own rate, half-up (`charityCommittedCents`,
  `engine.mjs:322`); Given = Σ verified, unexcluded charity rows.
- **Never recompute locally:** week available/charges/debt/surplus, week
  close outcomes, restoration amounts, refund-link fit (server guard),
  top-up split (server authoritative; client preview is informational
  only), charity committed per row (use `charityCommittedCents` — the
  shared helper — not a local formula).

### 16.4 Member-visible wording differences (complete)

- Fund: admin "Available to use" / "Spendable available"; member "Available
  to request" (hero aria-label, fund expansion, breakdown row).
- Email empty state: admin "None — connect an email below."; member "None —
  the admin connects email alerts."
- Charity action on a charge (member): shown disabled with sub "Ask the
  admin to mark this as a gift".
- Add popup: members see Purchase only (Donation/Upload hidden AND refused
  at the entry point and at CSV confirm).
- Settings: members see status lines but no auto-sync row, no Connect/Check
  Email buttons, no invite code, no Budget card, no fund add/use/income
  forms, no Review area, no Disconnect/Nickname buttons, no Remove buttons,
  no Home sync button, no Trash link.
- Fund request detail (member, pending): "Waiting on the admin decision.
  You can track it here — its status changes when the admin approves or
  declines it."
- Profile menu: role pill shows Admin/Member; first name only in the header.

---

## 17. Money engine (canonical — do not re-derive)

`engine.mjs` is the single formula, shared by the PWA and (as a copy) the
compute-week function. All amounts integer cents. Base allowance is
**$375/week by schema default** (`households.base_allowance_cents` =
37500); the live value is whatever the admin set. Weeks Sunday–Saturday,
America/New_York. Data floor 2026-11-01.

### 17.1 `computeWeek` (`engine.mjs:34-75`)

Inputs B (base allowance), T (temp), D (incoming debt), C (charges).
`carriedDebt = max(0, D − B)`; `baseAvailable = max(0, B − D)`;
`coveredBase = min(C, baseAvailable)`; `overBase = C − coveredBase`;
`coveredTemp = min(overBase, T)`; `newDebt = overBase − coveredTemp`;
`outgoingDebt = carriedDebt + newDebt`; `earnedSurplus = baseAvailable −
coveredBase`; `available = baseAvailable + T − C` (can be negative).
Unknown fields (including any legacy credit fields) are deliberately
IGNORED. There is no credit field in this contract at all.

### 17.2 Counting rules (`engine.mjs:94+`)

- A row counts toward its week only if: not excluded, not reversed, kind
  is `charge`/`fund_charge` (net of linked refunds, floored at 0 for the
  charge part) — charity, payments, cashback, transfers, income never
  count as spending. Card payments are kind `payment`; cashback rows are
  excluded from week math. Provisional ≠ confirmed, but provisional rows
  DO count toward the current week's charges (pending transactions are
  included and marked — Weekly sheet message).
- Purchases count (hero): `kind === 'charge'` and `state !== 'reversed'`
  and not excluded and dated this week.

### 17.3 Refund restoration (FINAL spec + MATH_DECISIONS_N1_N2)

- The old refund-credit model is REMOVED entirely. A refund after its week
  locked is handled by a read-only simulation of every week from the
  purchase week through the **last completed week** (owner ruling on the
  horizon), reducing only that purchase's charge by total refunded so far,
  posting ONE restoration entry in the current week. Incremental; never
  exceeds the refund; never double-restores; credited only after the refund
  POSTS; the temp-increment-covered portion restores nothing; refund beyond
  the charge is HELD for admin review; credits offset recorded shortfall
  first; fund-purchase refunds credit the fund directly; locked history is
  never edited; simulation is idempotent.
- **N1 (owner decision Nov 5, Option A — fund-first, counted once):** a
  refund pays the fund portion back first; the weekly walk counts only the
  *normal* portion of a linked refund. Total benefit of any refund is
  exactly the refund, never more.
- **N2 (owner decision, Option A — compute-week's definition):** debt
  entering week W = the latest stored close before W, minus only the debt
  cuts posted after that close's week and up to and including W.
- Restoration spec cases (9/9 on both `restoration.mjs` copies, R5 §5):
  $475 purchase + $150 refund → $150 surplus; same with later weeks fully
  spent → $50 surplus + $100 debt cut; $300 purchase + full $300 refund →
  $300 restored; $475 purchase with $100 temp + $100 refund → $0
  (temp-covered restores nothing); same + $150 refund → $50; $60 fund
  purchase + $60 refund → fund +$60, surplus unchanged; $35 shortfall +
  $50 restoration → $35 offsets shortfall, $15 spendable; $500 refund vs
  $475 purchase → $475 restores, $25 held; partial refunds $100 then $200
  = exactly a single $300 refund, never more.
- Auto-link rules (`auto_link_refund`): exact full amount, same suffix,
  same normalized merchant, purchase date ≤ refund date and within 90
  days, exactly one candidate, room check with `kind='refund'` filter.
  Two identical purchases → NO auto-link (stays unlinked for admin review).
  The Nordstrom $158.97 refund stays unlinked, correctly — no matching
  purchase exists in the household.

### 17.4 Charity (owner decisions Nov 3, live web only)

- Basis = 10% on whatever comes into the account + whatever is manually
  entered (received basis), from November 2026; no pre-November opening
  owed/given entries. Transfers, refunds, reimbursements, loans, Extra
  Fund top-up deposits must NOT auto-accrue — they need confirmation as
  income first.
- Custom rules at two levels: global default rate (changeable) + per-single-
  transaction override; overrides REPLACE the default (20% total, not
  stacked); global changes are future-only unless explicitly correcting an
  old income; all audited. Per-row committed = half-up rounding of
  amount × rate (`charityCommittedCents`).
- Pending gifts may be marked as charity; they count toward Given only
  once they post (Given = verified charity rows only). Part-gifts are not
  supported. The TOIREMORG $2 pair ruling: the Bank $2 and Email $2 rows
  are two separate real gifts, NOT a double-count — both stay counted.
- Manual refunds are LEFT OUT: the manual form stays purchases-only
  (positive amounts); refunds arrive only via bank/email with the existing
  restoration/held rules.

### 17.5 CSV classification (`classifyCsvKind`, `filterState.mjs:383-398`)

Mirrors the server `canonical.ts` (same patterns, same order): `INTERNAL
TRANSFER` → transfer; negative amount + `CHECK DEPOSIT|MOBILE DEPOSIT|
DEPOSIT` → income; `MOBILE PAYMENT|PAYMENT - THANK YOU|CARD PAYMENT|
PAYMENT: CREDIT|PAYMENT CREDIT|/ PAYMENT|EPAYMENT|E-PAYMENT|ACH PAYMENT`
→ payment; `CASH BACK|CASHBACK|REWARD` → cashback; otherwise negative →
refund, else charge.

---

## 18. Known deltas / do-not-copy

### 18.1 (a) The Nov 9 lists hang — do not copy

The live web lists hung on "Loading…" from ~2:00 PM EST Nov 9 in a test
session (task brief). Root cause is undetermined from the code — nothing
in `live.js` at `872ae11` explains a permanent hang (the lists render from
`refresh()` with error states on failure; `boot()` re-runs `showView` even
on failure). The clone implements correct loading (§2.4): loading state,
then data, or a real error state. Never reproduce a stuck "Loading…".
**NEEDS-LIVE-PROBE P5:** what the live app shows now for the same session,
and whether the hang recurs (parent to verify in the live browser).

### 18.2 (b) R5 audit items still OPEN at v66 — mark each OPEN

R5's base was `e5d693e` (pins v53/v64); this baseline is `872ae11` (PR #60
P2-fixes + PR #61 refund-link, pins v53/v66, tests 746/746). Re-checked
against `872ae11`:

| R5 item | Status at v66 | Spec treatment |
|---|---|---|
| R5-NEW1 / NEW-P2-7 — Title Case for button labels (only 5 of ~35 done) | **OPEN** — verified by grep at `872ae11`: 18 sentence-case labels remain in `live.html` (list below) + ~13 dynamic labels in `live.js`. The test pins only the 5. | **Clone ships the corrected Title Case forms** (§1.4; full list in §18.2 below). Do not copy the web's sentence-case labels. |
| R5-NEW2 — CSV preview dedupe caps at 1000 rows | **FIXED in v66** (PR #60): preview dedupe now pages whole history via `fetchAllPages` (`live.js:2461-2468`); suite carries a 2,500-row dedupe test. | Implement paged dedupe as in v66. |
| N5 — suite never executes SQL/Deno | **OPEN (carried, structural)** — suite asserts SQL only via JS mirrors/regexes; Edge Functions never execute under `node --test`. | Clone builders: run the SYNTHETIC_PROOFS runbooks (§19) against a test household; do not treat the JS suite as proof of server behaviour. |
| Blocking list 1 — Gmail token status unknown, past estimated expiry (probe G) | **OPEN** — no probe since Nov 8, 6:49 PM; token estimated to expire ~Nov 9. | Clone behaviour is unchanged (reconnect flow in §10.3); the token state is an ops item, not a spec item. |
| Blocking list 2 — test-member removal unconfirmed | **OPEN** — fix live since PR #57; no recorded fact shows `onbudget-ui-audit-20261103` removed. | Clone ships the Remove flow (§10.5); removal itself is an owner tap. |
| Blocking list 3 — deployed-function source only partly re-verified after PR #59 | **OPEN** — only C3/C4/B6 markers verified 7:24 AM Nov 9; the full R4 §9 marker set has no post-PR-#59 record, and nothing verified post-PR-#61. | Clone calls the same functions; builders must not assume a marker is live without a probe. |
| Blocking list 4 — all end-to-end launch proof still owed | **OPEN** — webhook-arrival proof (W), synthetic proofs 1–12, Section D, real-phone checks: none run live. | Clone must reproduce the SYNTHETIC_PROOFS runbooks (§19) before claiming parity. |
| R5 §7 — 23 unrestorable rows | **CLOSED by owner decision Nov 9** — the owner decided to delete them permanently rather than repair; deletion verified. (Supersedes R5 §7 "owner decision still owed".) | No clone work. Trash restore still refuses NULL-snapshot rows (§11). |
| R5 §6 — transactions count gap (app 45 vs DB 54, Nov 8) | **OPEN** — still unreconciled. | Clone: record app-vs-DB counts explicitly in proof 11 (§19). |
| R5 §8 owner items | **OPEN** — Gmail reconnect (if probe G shows dead), wife's account delete + re-add (cosmetic), Nordstrom backfill decision (owner approval — NOT run), privacy/terms lawyer review, 23-row decision (closed, above), real-phone checks. | Clone ships the flows; owner actions stay owner actions. |

**R5-NEW1 full remaining-label list (ship the Title Case form in the clone):**

`live.html` (verified at `872ae11`): "Confirm Import" → **Confirm Import**;
"Record Gift" → **Record Gift**; "Load More" → **Load More**;
"Change Password" → **Change Password**; "Connect Email" → **Connect Email**;
"Save Allowance" → **Save Allowance**; "Set New Total" → **Set New Total**;
"Delete Account" → **Delete Account** (×2: Members card is "Delete Account"
button; the danger-area heading is "Delete Account"); "Fund Activity" →
**Fund Activity**; "Past Savings Records" → **Past Savings Records**;
"Save Top-Up" → **Save Top-Up**; "Save Default Rate" → **Save Default Rate**;
"Save Income" → **Save Income**; "Cancel Correction" → **Cancel Correction**;
"Record It" → **Record It**; "Send Request" → **Send Request**;
"Clear Date Filter" → **Clear Date Filter**; "Load More Activity" → **Load
More Activity**. ("↓ Newest First" already reads in Title Case — no change.)

`live.js` dynamic labels (verified in the `872ae11` read): "Clear Search and
Filters" → **Clear Search and Filters** ("and" stays lower — minor word);
"Sign In Again" → **Sign In Again**; "Try Again" → **Try Again**; "Approve
Anyway" → **Approve Anyway**; "Send Reset Link" → **Send Reset Link**;
"Change Password" (sheet confirm) → **Change Password**; "Show Transactions"
→ **Show Transactions**; "Add Money" → **Add Money**; "Spend from Fund" →
**Spend from Fund** ("from" stays lower — minor word); "Request Money" →
**Request Money**; "Record Income" → **Record Income**; "Link to Purchase" →
**Link to Purchase**; "Link Refund" → **Link Refund**; "Fund Charge"
(reclassify option) → **Fund Charge**; "Change Allowance" → **Change
Allowance**; "Record Anyway" → **Record Anyway**; "Send Request" (sheet
confirm) → **Send Request**.

### 18.3 (c) live.js / HANDOFF conflicts — live.js wins

| # | Conflict | Resolution (live.js wins) |
|---|---|---|
| C1 | HANDOFF §7 toast rule: "ALL toasts brand blue (#2f6bff) with white text, error or not (no red toasts, ever)". | **Superseded Nov 4 (owner override):** error toasts are soft red (`#fef2f2`/`#dc2626`/`#fecaca`); success/info stay brand blue. `live.js:3067-3080`, `styles.css:447`. |
| C2 | HANDOFF §3: "Week close: Sunday 00:00 local, idempotent" (reads as scheduled). | **No scheduled week-close exists.** Week-close runs on admin loads, once per session, when due (`live.js:714-723`). |
| C3 | HANDOFF §1/§4 header comment in `live.js:2`: "two accounts only" / "First account creates the household as admin; second joins by ID." | **Stale.** Sign-ups are ON (owner, Nov 2); join is by **invite code**, not UUID (UUID join path removed, N13/P0-1). |
| C4 | HANDOFF §3: "Tests: 46 pass / 0 fail (engine + Gmail suites, re-run Nov 2)". | **Stale.** Suite at `872ae11` is **746/746** (`node --test`). |
| C5 | HANDOFF §2: live pins `live.js?v=8`, `styles.css?v=9`; §4: "Live Edge Functions (15)". | **Stale.** Pins are v66/v53. Function count differs (callFn uses `plaid-account-disconnect`, `plaid-webhook-register`, `gmail-disconnect`, `delete-account`, etc.; `bootstrap-household` is dead). Use §16. |
| C6 | HANDOFF §3: "Fund allocations against the fund balance are still missing (approve/decline is a decision record only)" (also in `live.js:10-12` header comment). | **Stale.** `approve_and_allocate` allocates (with split + override); `allocate_fund` spends. The header comment is wrong; the code is right. |
| C7 | `live.html` household comment: creating a household is "two panels — choice, then an optional naming step." | **Stale.** The name is REQUIRED (`live.js:2647-2656`); a blank name fails. |
| C8 | `filterState.mjs` comment above `actionsForTxKind`: "Charge: Charity (admin + verified only)". | **Stale comment.** The code (relaxed Nov 8, 2026, pinned by tests) offers Charity on ANY charge; members see it disabled. Code wins. |
| C9 | HANDOFF §5: "CSV UI tap-through UNPROVEN … Confirm stayed disabled" (automation limitation). | **Partially stale.** Preview/confirm are code-verified and suite-tested (746/746 incl. a 2,500-row dedupe test); only the **real-phone** tap-through is still owed. Desktop CSV is code-verified only (§8.3). |
| C10 | HANDOFF §1: "A private, shared household budget tracker for exactly two users". | **Superseded in practice.** The data model supports N members (members list, remove-member, invite codes); the household happens to have two. Clone must not hard-code a two-user limit. |

### 18.4 Where live v66 has superseded the base spec (`Household_Budget_Spec_FINAL.pdf`)

- Refund model: the PDF's refund-credit model is REMOVED; refund
  restoration (§17.3) governs. (The PDF's restoration section is the
  surviving part; N1/N2 Option A decisions postdate it.)
- Amex cash-back credits are NOT refunds (excluded by default; admin can
  classify) — matches the PDF's change note.
- Anything the PDF says about UI layout, button treatments, or the demo is
  superseded by live v66 (§1–§2, §15.2). The PDF was not re-read line by
  line for this spec; where a builder finds a PDF/live disagreement not
  listed here, live v66 wins and the builder must note it in PROGRESS.md.
  **NEEDS-LIVE-PROBE P15:** a line-by-line PDF-vs-v66 diff was out of scope
  for this spec — the parent should confirm no PDF rule beyond those listed
  is load-bearing for v1.

---

## 19. NEEDS-LIVE-PROBE list

Behaviour that cannot be determined from the code. Each needs a live run
(browser-capable agent, test household only unless stated) before the clone
can claim parity.

| # | Question | Why the code cannot answer it |
|---|---|---|
| P1 | Does **Charity** actually appear on a **pending** charge's Actions sheet in the live app, and does marking it leave Given unchanged until it posts? | Code + tests say yes (`actionsForTxKind` relaxed Nov 8; `mark_transaction_charity` accepts provisional; Given counts verified only). No live run exists (SYNTHETIC_PROOFS proof 9 BLOCKED). |
| P2 | What are the exact Plaid Link screens (institution picker, account select, error states) the user sees on iOS? | The clone uses the native Plaid Link SDK; the web only hands it a `link_token` (`live.js:2795-2830`). Link UI is Plaid's, not the app's. |
| P3 | What are the exact Google OAuth consent screens (account picker, scope list, error/denied states) for Gmail connect on iOS? | The web redirects to `auth_url` and returns via `?gmail=connected/failed`. Consent UI is Google's. |
| P4 | Is `week_locked` surfaced anywhere in the live UI? | `weekLocked` is stored in `currentWeekData` (`live.js:655`) and never rendered by any code path found. Either no locked indicator exists in v66, or one exists outside `live.js`. |
| P5 | What does the live app show now for the session whose lists hung on "Loading…" since ~2:00 PM EST Nov 9 — and does the hang recur? | Root cause undetermined from code (§18.1). Parent to verify in the live browser. |
| P6 | What does the iOS native share sheet show for the invite code (exact text, title, preview)? | Code supplies `navigator.share({title: 'OnBudget invite code', text: 'Join my household on OnBudget with invite code CODE'})`; the sheet chrome is the OS's. |
| P7 | What is the exact auto-sync switch behaviour when a household has no bank connection (toast only, or also a disabled state)? | Code shows the toast "No bank connection yet — connect a bank account first." when `results` is empty; no live tap exists. |
| P8 | What is the invite code format/length (characters, length)? | Server-generated (`households.invite_code`); the client only displays it. Needed for input validation + share-sheet layout. |
| P9 | What are the exact `reset.html` success/mismatch messages (tail of the file past the code-exchange block)? | The read set for this spec covered `reset.html` only through the session-exchange block; the save handler's messages were not verified. Read the file at `872ae11` before building. |
| P10 | What is the live app's offline behaviour (service-worker fallback page, stale-data display)? | `live-sw.js` is network-first with an offline fallback, but no live offline run exists; P1-46 (HANDOFF §7) notes the live app never registers the service worker in one recorded path. |
| P11 | Does the "Sync failed" per-account line and the >180-min stale footer warning ever fire in the real household, and what do they look like on a phone? | Code paths exist (`live.js:1418, 1425-1435`); no recorded live sighting. Owner-only real-phone check (R5 §8). |
| P12 | What is the exact text/behaviour when `week-close` actually closes a week on an admin load (any toast, any visible change)? | Code reloads week numbers silently when `weeks_closed > 0`; no toast exists in the path. Confirm no user-visible signal is intended. |
| P13 | Does the live app show anything different when the household has >100 transactions and Load More is tapped on a real phone (rendering, scroll position)? | Code-verified only (SYNTHETIC_PROOFS proof 11 BLOCKED); real-phone check owed. |
| P14 | Is email confirmation currently ON or OFF in Supabase Auth settings? | Decides the sign-up success copy (§4.2). Server setting, invisible to the client. |
| P15 | Line-by-line PDF-vs-v66 diff (see §18.4). | Out of scope for this spec; parent to confirm no unlisted PDF rule is load-bearing for v1. |
| P16 | Do the two `resolve_held_refund` definitions (`merged-audit-held-release-atomic.sql` vs `restoration-snapshots.sql`) differ live, i.e. is the atomic body the live one? | Repo-only question; needs probe F (`pg_get_functiondef`). Affects only the second-release refusal path, not the clone's call. |

**Synthetic-proof runbooks the clone must reproduce** (from
`SYNTHETIC_PROOFS_2026-11-09.md`, all BLOCKED on a live run at that time;
mechanisms code-verified — the clone must run them live in the test
household "Simcha House!" `95e1aff3-f664-41bb-be09-70e00f75a141`, never the
real household): 1. Trash restore (excluded/pending/reversed + NULL-snapshot
refusal); 2. Member "admin only" (reclassify, fund action, member removal
refused; member CAN view + request); 3. Merge → restore end-to-end; 4.
Shortfall member-vs-admin; 5. Week-close where the shortfall changes; 6.
Week-close exercising the N1/N2 walk; 7. Per-account disconnect + reconnect
(needs a test Plaid item); 8. Held-refund release + re-release (second MUST
raise); 9. Charity mark from Actions (posted AND pending); 10. Refund
auto-link end-to-end (incl. the two-identical-purchases negative case);
11. Load more past 100 rows (record app-vs-DB counts explicitly); 12. CSV
import retest (desktop; real-phone is owner-only). Plus Section D
acceptance (D1–D8) and probes G, F, H, I, R, C7-L, NEW3-L, W, K, C
(R5 §6).

---

## 20. Screen-by-screen build checklist

Builders tick each box in `PROGRESS.md` as the screen is implemented and
verified against the cited source. A box is ticked only when the behaviour
is demonstrated (test-household run or UI test), not when the code is merely
written.

### Global
- [ ] Baseline pinned: repo `872ae11`, live.js v66 / styles v53; same Supabase project, same RPCs/Edge Functions (§0.4, §16)
- [ ] Design tokens implemented exactly (§1.1–§1.2): palette, hero (white, 1.5px `#2f6bff`, no shadow), card sizing rule, tab bar + `72px + safe-area` bottom padding
- [ ] Button rules (§1.3): two-button = primary first + grey tertiary second; pale `#bfdbfe` ONLY as middle tier of three-button rows; no adjacent duplicates; Back buttons `#3b82f6` bold 700 15px
- [ ] Title Case everywhere (§1.4) incl. all R5-NEW1 corrected labels (§18.2); exceptions "Sign In", "Mark as Charity"
- [ ] Toasts (§2.3): bottom only, 120px offset, 4s auto-dismiss, tap to dismiss, tab switch clears; success/info brand blue, errors soft red
- [ ] Inline `.result` boxes via a single setter (§2.3); field errors inline above buttons with draft preserved
- [ ] Sheets (§2.3): Cancel as top text link only; extra-action primary + Confirm tertiary; Escape/backdrop close; Tab trapped; focus returns to opener; password Show/Hide toggle
- [ ] Navigation (§2.2): Home on EVERY fresh load; tab taps refresh if >30s; swipe-right back with the exact thresholds and ignore-rules; scroll preservation on refresh, scroll-to-top on page change; popup scroll = popup only
- [ ] Loading/empty/error states (§2.4): skeleton → data → real error; `—` only on failure; confirmed zero is `$0.00`; hero Purchases N/A on failure; no stuck "Loading…" (§18.1)
- [ ] All 33 admin role checks reproduced (§0.5); server-side enforcement relied on, never the client gates
- [ ] Search (§2.5): loaded transactions only, merchant/date/amount, 250ms debounce, page reset to 100

### Per screen
- [ ] Loading screen (§3): full-screen mark + "Loading Your Household"; never flashes sign-in or a bare app shell
- [ ] Auth — Sign In (§4.1): fields, in-field eye toggle, Sign In (primary) + Create Account (tertiary), Forgot Password? link, inline "Incorrect email or password", busy "Signing in…", sign-out clears fields
- [ ] Auth — Create Account (§4.2): two-step name panel, name REQUIRED, validation messages + focus, busy "Creating account…", confirmation-dependent success copy (P14)
- [ ] Auth — Forgot Password (§4.3): 3-step sheet, generic success wording, `reset.html` redirect
- [ ] Reset page (§4.4): New/Confirm Password + Show/Hide toggles, Save New Password, code exchange, error copy (P9)
- [ ] Household — Choice (§5.1): Create Household / Or Join a Household + Join As Member, exact messages
- [ ] Household — Name (§5.2): name REQUIRED, `create_household(p_name)`, direct admin set (no membership re-read), join via `join_household_by_code`, exact "Check the invite code and try again", 5/hour rate limit
- [ ] Home — Hero (§6.1): Weekly Budget card, week label, available figure (tap → Weekly sheet), sync button (admin-only; grey while unset), Set Your Weekly Allowance (admin-only, never-set state), progress bar + over state, spent line + % used, Weekly allowance (effective) + Purchases (N/A on failure), empty hint, week error
- [ ] Home — Stat cards (§6.2): Charity above Extra Fund, faces Title + signed number only, chevron flips, expand in place, one-open-at-a-time, rows only (no buttons), exact rows + aria-labels + failure states
- [ ] Home — Recent (§6.3): 6 newest, tap jumps to Transactions + expands + highlights, "See all", empty/failure states
- [ ] Transactions — List (§7.1): header actions, Past Weeks/Activity links, search, filter chips (single-clear), count line + net-spending total, Trash link (admin, count > 0), 100-row paging + probe-row Load More, page reset on every filter/search change, excluded rows never shown
- [ ] Transactions — Rows & detail (§7.2): row layout, pills, icons (Google favicons + brand monogram fallback, never Clearbit), detail panel contents + counting sentences, Cash/no-card label
- [ ] Transactions — Filters (§7.3): Status/Month/This week/From-To/Card/Amount/Sort + direction button, Apply/Reset/Cancel (three-button rule), snapshot restore on Cancel, live month/card/bounds/sort, signed-amount bounds, min>max validation state
- [ ] Transactions — Actions sheet (§7.4): exact action table by kind × role, sub-lines, Charity (pending + posted), Extra Fund, Link to Purchase (incl. unlink + 90-day stem candidates + fallback), Other (incl. Charity reroute + required reason), Delete (permanent vs Trash + exact "Moved to trash bin." toast)
- [ ] Add popup (§8): options list (members: Purchase only), move-not-copy forms, Back/Cancel/Escape/backdrop behaviour, draft preserved on tab switch
- [ ] Add — Purchase (§8.1): fields + validation order + messages, pre-Nov-1 rejection, duplicate warning, provisional charge insert, double-tap guard, purchases-only
- [ ] Add — Donation (§8.2): admin-only, optional suffix, pre-Nov-1 rejection, `record_charity_gift` 8-arg + client-key idempotency + nonce hash, verified at once
- [ ] Add — Upload CSV (§8.3): Choose File, preview with counts + per-row New/Duplicate, whole-history paged dedupe, Confirm Import (admin-only), insert + toast, no auto-link call
- [ ] Funds — Balance panels (§9.1): faces, in-place expansions, exact rows, admin/member button sets (Add Money / Spend from Fund / Request Money; Record Income / Close)
- [ ] Funds — More card (§9.2): Fund Activity (top-ups + charity income + Correct flow), Review (N) count, Past Savings Records (4 numbers, Balance never a sum, read-only)
- [ ] Funds — Add Money (§9.3): shortfall-first preview + server-authoritative split, checkbox required, idempotent client key, exact toast
- [ ] Funds — Use Fund Money (§9.3): insufficient-fund override sheet with typed reason, inline errors
- [ ] Funds — Ask for Fund Money (§9.3): request form + activity disclosure + detail lines + Approve (full/split/override) / Decline flows
- [ ] Funds — Charity Income & Rate (§9.3): default-rate form (future-only), Record Income + correction flow + preview, pre-Nov-1 rejection
- [ ] Funds — Review (§9.4): Restorations + Held (Release, second release must raise — P16), Possible Duplicates (match line + flag reason + Same/Separate + remember-alias + Show More 20), Resolved Duplicates (Reopen for Separate only), Refund Links (reason strings + Link/Dismiss + Show More 20)
- [ ] Settings — Profile (§10.1): Save Name / Save Email (primary) + Change Password (tertiary), metadata-only name save, email-confirmation behaviour, password sheet + 8-char rule
- [ ] Settings — Bank (§10.2): Connect New Account (duplicate warning + Plaid Link + exchange outcomes) + Sync Transactions, Automatic Sync switch (server truth, partial-failure wording), Connected Accounts (one row per account, plain types, Sync failed line, nickname, per-account Disconnect), footer last-sync + stale warning
- [ ] Settings — Email (§10.3): Connected Email rows + Testing-mode warnings, Connect Email (409 household picker + OAuth redirect), Check Email Now (per-connection failures surfaced), Disconnect
- [ ] Settings — Budget (§10.4): Weekly Allowance + confirm sheet (old → new, current-week-onward), Temporary Allowance (new TOTAL repeating 1–4 weeks, preview line, `set_weekly_allowance_override` per week, never `add_temp_increase`)
- [ ] Settings — Account & Household (§10.5): Members list (name resolution, Remove flow + server re-checks), invite code box + Copy (2s "Copied") / Share, Delete Account (two-step confirm, step-naming failure, sign-out + message)
- [ ] Trash (§11): own page, Restore per row, NULL-snapshot refusal, empty state
- [ ] Past Weeks (§12): Filter by Date (shared with Activity), count/period lines, week blocks (Carry-in/Surplus/Debt carried out/Release, "not recorded" never $0), tap-to-week jump
- [ ] Activity (§13): day-grouped audit entries, collapsed weekly-processing rows, translated detail text, Load More Activity (+50), shared date filter
- [ ] Weekly sheet (§14): exactly Allowance/Spent/Balance (+ Unlinked refunds only when non-zero), message variants, Show Transactions (week filter + focus Filters)
- [ ] Profile menu (§15): first-name-only header + role pill, email dedupe rule, Settings / Sign Out, Escape + outside-tap close, excluded from scroll lock

### Money engine & proofs
- [ ] Money engine (§17): `computeWeek` formula + counting rules + restoration (N1/N2 Option A) + 9 restoration spec cases reproduced; charity 10% received-basis + override-replaces + pending-marks-count-on-post; CSV classification table
- [ ] Server-computed figures displayed, never recomputed locally (§16.3)
- [ ] Synthetic proofs 1–12 run live in the test household (§19) with per-proof pass/fail + app-vs-DB counts recorded
- [ ] Section D acceptance pass (D1–D8) disposition recorded
- [ ] NEEDS-LIVE-PROBE items P1–P16 each resolved or explicitly deferred with a named owner

---

*Spec author: CLONE-SPEC (subagent). Baseline `872ae11`, live.js v66 / styles
v53. Screens/forms specified: 26 (§§3–15: Loading, Sign-in, Create-account,
Forgot/Reset, Household choice, Household name, Home, Transactions, Purchase,
Donation, Upload, Funds, Add Money, Use Fund, Ask, Charity Income & Rate,
Settings Profile, Bank, Email, Budget, Account & Household, Trash, Past
Weeks, Activity, Weekly sheet, Profile menu). NEEDS-LIVE-PROBE
items: 16 (P1–P16, §19). live.js/HANDOFF conflicts: 10 (C1–C10, §18.3).
OPEN R5 items carried: R5-NEW1, N5, probes G/F/H/I/R/C7-L/NEW3-L/W/K/C,
count gap (§18.2).*
