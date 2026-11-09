# OnBudget Native iOS — App Store Plan (v1)

> Branch: `ios-clone-v66/notify-store` · Baseline: live web **v66**,
> `origin/main` `872ae11` (Merge PR #61). Companion document:
> `APNS_DESIGN.md` (notifications v1). Sources read:
> `docs/privacy.md` + `docs/terms.md` and the published pages
> https://ycfried.github.io/Budget/privacy.html and
> https://ycfried.github.io/Budget/terms.html (verified live Nov 9,
> 2026), `live.js` `deleteAccountFlow` (~line 3323),
> `supabase/functions/delete-account/index.ts`,
> `HANDOFF.md` §§1–5, `FULL_AUDIT_2026-11-09_R5.md` §9.
>
> Status: **plan only**. Nothing here submits anything. Every item
> that needs the owner is listed in §8.

## 1. App name — FLAG: clearance NOT verified

- **App name: `OnBudget`.**
- **FLAG — do not skip this.** The name check is crowded: no App Store
  app is literally named OnBudget, but a San Diego company literally
  named OnBudget sold a budgeting tool, and **USPTO status is NOT
  verified**. Before investing in the name — before the bundle id is
  final, before screenshots and the store listing are built around
  it — run the clearance at **tmsearch.uspto.gov** (owner item, §8).
  If the clearance fails, the fallback is a rename before submission,
  not after: the bundle id, the APNs topic, and the store listing all
  carry the name.
- **Subtitle (30 characters max):** `Weekly Household Budget`
  (23 characters). States the job in plain words; no claim the app
  cannot back up.
- **Keywords (100 characters max, comma-separated, no spaces):**
  `budget,household,weekly budget,family budget,expense tracker,allowance,savings,shared budget`
  (92 characters). No competitor names, no "free" (Apple rejects
  "free" in keywords/metadata), no keyword stuffing.
- **Category:** Finance (primary). No secondary category in v1 — the
  app is a budget tracker, nothing else.
- **Price:** Free. No in-app purchases, no subscriptions in v1.
- **Age rating:** 4+. No objectionable content, no user-generated
  content shared beyond the household, no payments.
- **Copyright:** `© 2026 Yehoshua Friedman` (owner to confirm the
  exact line).
- **Support URL:** https://ycfried.github.io/Budget/ (the landing
  page). **Marketing URL:** same, or omit in v1.
  Owner to confirm both before submission; if a custom domain lands
  later, these URLs change with it (§2.5).

## 2. App Privacy labels

Apple's rule: the labels must match what the app actually collects,
and must match the privacy policy. The table below is the v1
declaration. "Linked" means tied to the user's identity/account;
"Tracking" means shared with third parties for advertising or data
brokering — **nothing in OnBudget is used for tracking**.

### 2.1 Label table

| Apple category | Data type | Collected? | Linked to identity? | Used for tracking? | Purpose |
|---|---|---|---|---|---|
| Contact Info | Email Address | Yes | Yes | No | App Functionality (sign-in; the account identifier) |
| Contact Info | Name | Yes | Yes | No | App Functionality (display name in the household; required at sign-up since v60) |
| Purchases | Purchase History | Yes | Yes | No | App Functionality (merchant, amount, date, card suffix — the budget itself) |
| Financial Info | Other Financial Info | Yes | Yes | No | App Functionality (bank transactions and balances pulled read-only through Plaid; the encrypted Plaid access token is stored server-side) |
| Financial Info | Payment Info | No | — | — | The app never sees bank usernames, passwords, or full card numbers. Card numbers appear only as a last-4 suffix. |
| Identifiers | User ID | Yes | Yes | No | App Functionality (Supabase auth id — the account) |
| Identifiers | Device ID | Yes | Yes | No | App Functionality (APNs device token, for push notifications — see §2.3) |
| Usage Data | Product Interaction | No | — | — | No analytics SDK in v1. |
| Diagnostics | Crash Data / Performance Data | No | — | — | No crash-reporting SDK in v1. If one is ever added, this table and the policy change first. |
| Location | — | No | — | — | Never collected. |
| Contacts | — | No | — | — | Never collected. |
| Photos or Videos | — | No | — | — | Never collected. |
| Browsing / Search History | — | No | — | — | Never collected. |
| Sensitive Info | — | No | — | — | Never collected. |
| Health & Fitness | — | No | — | — | Never collected. |

### 2.2 What "shared with third parties" means here

- **Plaid (bank linking).** The user types bank credentials into
  Plaid's own Link window; OnBudget never sees them. Plaid returns
  an access token (stored encrypted server-side) and transaction
  data. That is data shared with Plaid for App Functionality, not
  tracking. Plaid is a data processor for the app's core job.
- **Supabase (hosting).** Database, sign-in, and Edge Functions.
  All household data lives there. App Functionality.
- **Google (email alerts, optional).** Gmail sign-in + read-only
  access to Amex Large Purchase alert emails only. App Functionality.
- **Apple (push, optional).** The APNs device token and notification
  content go to Apple to deliver the notification. App Functionality.
- **Nobody else.** No ads, no data brokers, no analytics vendors, no
  model training on household data. The published policy already says
  this ("We do not sell your data, to anyone, ever"), and the labels
  must keep saying it.

### 2.3 The device-token line (new in v1 — read this)

The published privacy policy does **not** mention push notifications
or device tokens. Its "Nothing else" line currently reads: "no
location, no contacts, no photos, no advertising identifiers." A
device token is none of those, but App Store review (Guideline 5.1.1)
compares the labels, the policy, and the binary — and a token that
is collected but not disclosed in the policy is a rejection risk.

**Required pre-submission edit (rides on the already-owed lawyer
review, §8):** add a short paragraph to the policy, in the same plain
voice, before the first submission:

> **Notifications (optional):** if you allow notifications, your
> device's push token is stored so the app can send you a heads-up
> when a week closes, a new purchase comes in, or a fund request is
> waiting. The token identifies your device only for delivering those
> messages. It is never sold, never shared with advertisers, and it
> is deleted when you turn notifications off in your device settings
> or delete your account.

Do not submit with the labels declaring a Device ID while the policy
says nothing about it.

### 2.4 Plaid data is NOT used for tracking — state it plainly

In App Store Connect, for every data type above, answer:
**"Is this data used for tracking purposes?" — No.** Plaid
transaction data is used only to show the household its own
purchases. It is never used to build an advertising profile, never
shared with a data broker, and never sold. The same statement belongs
in the review notes (§7) so the reviewer does not have to infer it.

### 2.5 URLs

- **Privacy Policy URL:** https://ycfried.github.io/Budget/privacy.html
- **Terms of Use URL:** https://ycfried.github.io/Budget/terms.html
- Both are published and reachable (verified Nov 9, 2026). Both pages
  still carry a "Draft — lawyer review is still owed" banner; the
  lawyer review must land before submission, and the banner must come
  off. If a custom domain is bought later, update both URLs in App
  Store Connect and in the app's Settings links at the same time —
  the in-app links and the store listing must never disagree.

## 3. Account deletion — exact client wiring

App Store Guideline 5.1.1(v) requires account deletion inside the
app. The backend already exists (`delete-account` Edge Function);
the native client only has to wire it the way the web app does.

**Web reference** — `live.js`, `deleteAccountFlow()` (~line 3323):

1. Two-step confirmation:
   - `Delete Account` — "Delete your account and remove yourself
     from this household? If you are the last member, the household
     is deleted too. This cannot be undone." (button: `Delete Account`)
   - `Delete Everything?` — "This permanently deletes your account
     and, if you are the last member, the whole household. Are you
     sure?" (button: `Yes, Delete Everything`)
2. `callFn('delete-account', {})` — POST to
   `/functions/v1/delete-account` with the user JWT, empty body.
3. On `{ deleted: true }`: `supabase.auth.signOut()`, clear local
   state, show the sign-in screen with "Your account was deleted."
4. On failure (`{ error, step }`): show "Could not delete account.
   Nothing was deleted — try again." and keep the user signed in.
   Nothing is deleted on failure — the server restores the membership
   first (the function is built so a half-delete cannot happen).

**Native wiring (Settings → Delete Account):**

1. Settings → `Delete Account` row (destructive treatment — same
   soft-red treatment as the web's Delete button, never a plain
   blue button).
2. First confirm (native alert): title `Delete Account`, message
   identical to the web's first step, buttons `Cancel` /
   `Delete Account` (destructive).
3. Second confirm (native alert): title `Delete Everything?`,
   message identical to the web's second step, buttons `Cancel` /
   `Yes, Delete Everything` (destructive).
4. Call `POST {supabaseURL}/functions/v1/delete-account` with
   `Authorization: Bearer <user JWT>`, empty JSON body.
5. On success (`{ deleted: true }`):
   - Best-effort unregister the push token (§3 of `APNS_DESIGN.md`).
   - Clear the local session and any cached household data.
   - Sign out and navigate to the sign-in screen with the message
     `Your account was deleted.`
6. On failure: show `Could not delete account. Nothing was deleted —
   try again.` (append the `step` only in a debug log, never in the
   user-facing message) and stay signed in, on Settings.
7. What the server does (already built — do not re-implement):
   revokes the household's Plaid items and Gmail grants when the
   household is being deleted, deletes memberships, deletes the auth
   user, and deletes the household itself when the deleter is its
   last member. If other members remain, the household and its data
   stay for them. The published privacy policy (§"Deleting your
   account") already describes exactly this.

**Review-note line for 5.1.1(v):** "Account deletion is in Settings →
Delete Account, with a two-step confirmation. It deletes the account
and, if the user is the last member, the household."

## 4. Screenshots plan

- **Required sizes (App Store Connect, v1):**
  - iPhone **6.9"** (iPhone 16 Pro Max class, 1320 × 2868) — required.
  - iPhone **6.5"** (1242 × 2688) — required.
  - iPad **13"** (2064 × 2752 portrait) — required if the app runs on
    iPad (it does — the owner uses an iPad; the native app must not
    be iPhone-only unless that is an explicit decision).
  - App Preview video: none in v1.
- **Screens (6–8 per size, same set across sizes):**
  1. Home — current week, allowance and what's left (the first
     screenshot; it is the app's job in one screen).
  2. Transactions — purchases list with a merchant icon and amount.
  3. Add a purchase — the manual-add form (shows the app is usable
     without a bank connection).
  4. Funds — Extra Fund card with Available / Pending / Total.
  5. Fund request — a pending request awaiting approval (admin view).
  6. Past Weeks — a closed week (shows the week-close story).
  7. Settings — profile, connections, Delete Account row (shows
     account deletion exists; optional as a screenshot, required
     as a working screen).
  8. Sign-in — only if a slot remains; never first.
- **Rules (non-negotiable):**
  - Screenshots show the **real app running with test data** — never
    mock UI, never Figma, never a design comp. (This is the same rule
    the owner set for the Harbor Wash video work: real screens, real
    flows.)
  - Test data only: a synthetic/test household, plausible fake
    merchants and amounts, test member names. **Never the live
    household, never the owner's real purchases, never real card
    suffixes, never a real invite code.**
  - No status-bar tricks: real time/battery is fine; do not fake a
    9:41 clock.
  - One screenshot set per device size, taken on real devices or the
    simulator at the exact pixel size — no upscaling, no cropping
    that cuts a card.
  - Owner signs off on the set (§8) before upload — he sees the
    screenshots on a real device first.

## 5. Metadata plan

- **Name:** `OnBudget` (§1 flag applies).
- **Subtitle:** `Weekly Household Budget`.
- **Keywords:** `budget,household,weekly budget,family budget,expense tracker,allowance,savings,shared budget` (92/100 chars).
- **Description outline** (write the full text at listing time,
  ~2,500–4,000 characters max, plain language, no hype):
  1. One paragraph — what it is: a shared weekly budget for a
     household. One allowance, one week, both people see the same
     numbers.
  2. Weekly allowance — set one amount per week; what's left is
     always on Home; overspending carries as debt into next week,
     honestly, instead of disappearing.
  3. Extra Fund — unspent money waits 7 days, then lands in the
     Extra Fund; fund spending is admin-approved, members can ask
     from inside the app.
  4. Bank + email, read-only — connect a bank through Plaid and the
     purchases appear by themselves; Amex Large Purchase alerts can
     add a purchase before the bank reports it. Read-only: the app
     cannot move money.
  5. Built for two — one household, one invite code, admin and member
     roles; charity at 10% on money received, tracked on its own
     card (only if this is still true at submission — confirm
     against v66 behaviour, do not promise a feature that changed).
  6. Privacy close — no ads, no data sold, delete your account in
     Settings.
- **What's New (v1.0):** `First release.` Nothing more.
- **Review notes** (see §7) — filled in at submission time, not now.
- **App icon:** the existing OnBudget mark (`brand/` in the repo).
  Confirm the 1024 × 1024 master renders cleanly with no transparency
  and no rounded corners baked in (Apple masks it). Owner sign-off.

## 6. TestFlight plan

### 6.1 Internal testers first (up to 100, App Store Connect users)

Gate — all true before the first internal build goes out:

- [ ] Build installs on iPhone + iPad from TestFlight, signs in with
  a test account, and shows Home with test-household data.
- [ ] Every v1 screen renders (Home, Transactions, Funds, Settings,
  sign-in/sign-up, join-by-invite-code).
- [ ] Push token registers (production APNs — TestFlight builds use
  the production endpoint) and each of the three notifications
  arrives from the test household (see `APNS_DESIGN.md` §10).
- [ ] Account deletion works end-to-end on a throwaway test account
  (deleted account cannot sign back in; last-member household is
  gone).
- [ ] No crash on launch, sign-in, sync, or week close.
- [ ] Privacy labels submitted in App Store Connect and matching
  §2.1.

Internal testing is where the owner and the builders shake the app
down. Feedback goes through TestFlight feedback / the build channel,
not the live household.

### 6.2 External group (up to 10,000 — requires Beta App Review)

Gate — all true before the external group is invited:

- [ ] Internal gate (§6.1) fully passed, with the fixes in a new
  build.
- [ ] Screenshots (§4) uploaded for all three sizes.
- [ ] Privacy policy + terms URLs live and lawyer-reviewed (§2.5).
- [ ] Beta App Review passed (Apple reviews the build the same way
  as a store submission — §7 applies here too).
- [ ] Test information filled in: a test account (throwaway test
  household, credentials in the review notes only — never in the
  repo), and a note that sign-ups are open so the reviewer can also
  create their own account.

External testers are real users outside the build team; nothing about
the build may depend on the live household, and no live-household data
may appear in any screenshot or test account.

## 7. Review-risk notes

| Guideline | Risk | Why v1 passes / what to do |
|---|---|---|
| **4.2 Minimum Functionality** | The classic rejection for a wrapped website. | The native app is a real native SwiftUI app — an exact clone of the live web app's screens and behaviour, built on the same Supabase backend (same auth, RPCs, Edge Functions, Plaid/Gmail flows). It is **not** a `WKWebView` wrapping `live.html`. No web view in the app loads the PWA. State this in the review notes: "Native SwiftUI app; no web wrapper." If any screen is a web view in the submitted build, this plan is wrong and the submission must wait. |
| **5.1.1 Data Collection & Storage** | Labels/policy/binary mismatch. | Labels (§2.1) match the policy (§2.3 edit included) and the binary. The device-token paragraph must be in the policy before submission. Plaid data declared as Financial Info / Purchase History, tracking = No. |
| **5.1.1(v) Account Deletion** | Missing or broken in-app deletion. | Wired per §3 (Settings → Delete Account → two-step confirm → `delete-account` function → sign-out). Test it on a throwaway account before submission and say so in the review notes. |
| **3.1.1 In-App Purchase** | Reviewer mistakes Plaid Link or any payment for a purchase. | Nothing is bought in the app. No subscriptions, no consumables, no paid features. **Plaid Link is account linking, not a purchase:** the user connects their own bank account so the app can read transactions; no digital good or service is sold, no money moves through the app, and Plaid charges nothing to the user inside the app. State this in one line of the review notes so the reviewer does not have to guess. |
| **2.1 App Completeness** | Placeholder content, dead buttons, demo data in the review build. | The submitted build must be the real app with working sign-up (sign-ups are open — owner decision Nov 2, 2026), working bank/email connect, and no placeholder screens. Test data lives only in TestFlight test households, never in the review build. Provide a throwaway test account in the review notes so the reviewer lands in a populated household immediately, and note that they can also sign up fresh. |
| **5.2.3 / 4.0 — name** | "OnBudget" conflicts with an existing mark. | §1 flag: run the USPTO clearance first. A rejection on the name after submission costs a rename, a new bundle id, and a new APNs key binding. |
| **2.3.7 / 2.3.10** | Accurate metadata. | Screenshots are the real app (§4); the description promises only what v66 does; no "best" / "#1" claims; no other platform's store badges. |

**Review-notes draft (paste at submission time, adapt to the build):**

> OnBudget is a native SwiftUI household budget app (not a web
> wrapper). Sign-ups are open — you can create an account, or use the
> test account below to open a populated test household. Bank
> connection uses Plaid Link (account linking only — no purchase, no
> money movement, read-only transactions). Account deletion is in
> Settings → Delete Account (two-step confirmation). No data is used
> for tracking; no ads; no data sold. Test account: [throwaway test
> household credentials — review notes only, never in the repo].

## 8. Owner items (App Store)

1. **Apple Developer Program — $99/year, owner's account and payment.**
   Without it there is no App ID, no TestFlight, no submission.
   (Also listed in `APNS_DESIGN.md` §9.)
2. **Name/trademark clearance for "OnBudget"** — check
   **tmsearch.uspto.gov** (owner). The name check is crowded and
   USPTO status is NOT verified. Settle this before the bundle id
   is final.
3. **APNs .p8 key + key id + team id** — owner's Apple Developer
   account (see `APNS_DESIGN.md` §5.3/§9). Needed for push; the .p8
   downloads once.
4. **Lawyer review of privacy/terms** — already owed on the web side.
   Must land before submission, including the new device-token
   paragraph (§2.3) and removal of the "Draft" banner from both
   published pages.
5. **Screenshots sign-off** — owner reviews the screenshot set on a
   real device before upload (§4).
6. **Support URL / copyright line confirmation** — §1. (Defaults are
   given; the owner confirms or replaces them.)
7. **TestFlight external group** — who is invited, decided by the
   owner at §6.2 time. Internal testing needs no decision now.
