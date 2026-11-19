# STAGE — App Store Launch Package

> Prepared Nov 17–18, 2026. Free + invite-only, under Mats Sellei's Apple Developer account.
> The owner tells Mats "make it live" — Mats follows the checklist in §5. Nothing here has been
> submitted to the App Store; this is preparation only. Renamed from OnBudget to STAG, then to STAGE, Nov 18,
> 2026 (S logo kept; repositioned as a tracking tool for guided spending, saving, and giving).
>
> App: "STAGE" (App Store Connect id 6833583721, still listed as "OnBudget: Family Budget" —
> Mats renames it at submission), bundle `com.onbudget.ios`,
> team H38376B6RX (Mats). Current build: TestFlight 1.0.0 (42) (build 43). The launch build will
> be 1.0.0 (43) (build 44: STAG rename + invite-only fix + Plaid webhooks + other-bank email +
> charity auto-accrual), once build 44 lands.

## 1. Invite-only audit — what was found and fixed

The app is published as **invite-only**: nobody may use it without an invite code from a
household owner. The audit found the join path was already airtight, but household **creation**
was wide open — the last way in without a code.

### What was already airtight (verified from the repo SQL + deploy records)

| Path | State |
|---|---|
| Join by invite code — `join_household_by_code(code)` | **Code-only.** Accepts only a 6-character code from the unambiguous alphabet (no 0/O/1/I/L). The legacy household-UUID path was removed Nov 2, 2026 (owner decision 11). Rate-limited: max 5 failed attempts/hour per caller, per code value, and per household. Unknown code logs the attempt and returns NULL. Joining always creates role `member`, never admin. A caller already in a household is refused. (Live version: `signup-display-name.sql`, applied live Nov 8, 2026.) |
| Direct membership insert (RLS) | **Closed.** The policy "users join as member for themselves" was dropped by `01-invite-codes.sql`. A direct client insert into `household_members` now fails RLS for everyone. |
| Direct household insert (RLS) | **Closed.** RLS is enabled on `households` and there is no INSERT policy at all — a direct client insert fails. |
| Other household-creation paths | **None.** No Edge Function inserts into `household_members` or `households` (checked: compute-week, delete-account, gmail-disconnect, plaid-sync, etc. only read or delete). `bootstrap-household` was removed from the repo and `config.toml` Nov 2 — see the lingering-copy check in §6. |
| Sign-up | **ON, with email confirmation ON** (owner decisions Nov 2 / Nov 12). Sign-up collects First Name + Last Name (separate fields, build 43) and stores the display name as "First L.". |

### What was open — and is now closed (this package)

**The hole:** any signed-in user could call `create_household(p_name)` and get a whole household
of their own, no invitation needed. The native app offered it as "Create Household (I Am the
Owner)" on the post-sign-up screen. A stranger could download the app, sign up, create a
household, connect their own bank, and use the full app — that is not invite-only.

**The fix (branch `invite-only-launch`, commit `c9c1c7b`, from build-42 tip `aef4e9e`):**
- **Server:** `supabase/invite-only-close-household-creation.sql` — revokes EXECUTE on
  `create_household(text)` from `authenticated` (plus a guarded revoke for the no-arg overload
  if it exists anywhere). After it is applied, the only way into any household is a valid invite
  code via `join_household_by_code`. The file documents the owner-only dashboard path for making
  a household in future, and the one-line re-grant that reverses it.
- **Native app:** `HouseholdViews.swift` is now join-only — the Create button and the whole
  name panel (`HouseholdNamePanel`) are removed; "Join as Member" is the primary action. The
  `createHousehold` RPC wrapper was removed from `OnBudgetKit`, and its kit test was removed.
- **Tests:** `testPlaidSandboxConnect` is skipped with a dated reason (it needed an admin
  household it created itself). Plaid Link opening was proven in earlier simulator runs and the
  live Amex connection is proven in production; re-prove manually on TestFlight with the test
  admin account if the Link flow ever changes. The dead Plaid-drive helpers were removed.
- **What was intentionally left:** `AuthValidation.householdNameError` (a pure validator, now
  unused — harmless, may be reused); the audit-formatting rules for old "Created via
  create_household RPC" audit rows (historical rows still need them); the frozen web app's
  Create button (live.js is frozen at v69 — after the SQL revoke it will fail with an error,
  which is the intended invite-only behaviour; remove it if the web app is ever unfrozen).

**Merge order:** merge `invite-only-launch` **after build 43 lands** (it is based on the build-42
tip; build 43 is in flight on `ios-clone-testflight`). Rebase onto the build-43 tip, run the
simulator (kit + smoke must be green; UI will show the known 429 gate plus the Plaid skip),
then upload as the launch build. The SQL file is applied separately via the dashboard (§6).

## 2. Sign-up flow verification

The full flow for a new user (from the native code + CI evidence):

1. Auth screen: email + password (min 8 chars) → **Create Account** (no server call yet).
2. Name step: First Name + Last Name (both required, max 40 chars) → **Create Account** → the
   app calls sign-up with `full_name` = "First L." and `redirectTo` = `onbudget://email-confirmed`.
3. **Check Your Email** (persistent state, not a toast): "Account created. Check your email to
   confirm it, then sign in." The confirmation link opens the app via the `onbudget://` URL
   scheme (registered in Info.plist; `onOpenURL` handles `onbudget://email-confirmed`). The
   screen notes the email is confirmed either way — the user then just signs in.
4. Sign in → Household screen (join-only after this launch) → enter the 6-character invite code
   → **Join as Member** → Home (Weekly Budget card).

**Evidence it works:** the simulator UI tests (`signUpAndJoinTestHousehold`) exercise exactly
this flow against the live backend — sign up, confirm (via Admin API in CI), join with a code,
Home renders — and the flow passed end-to-end in the Nov 12–13 green run on the email-gate fix
branch (run 43361862118). Since then the only failure mode in CI is the 429 gate (the tests'
many throwaway sign-ups trip Supabase's per-hour email cap). The deep-link handler and URL
scheme are in the shipped code. **Not yet proven live with a real inbox:** clicking the
confirmation link from a real email and then joining (the UI tests confirm accounts via the
Admin API, not by email).
That step is standard Supabase behaviour and the reviewer will do it — a pre-check with a
throwaway email is recommended before submission (§6), but it is not a blocker.

**Friction to expect:** the user must leave the app to confirm email, then come back and sign
in (two steps, standard); the confirmation email can land in spam; the invite code is typed by
hand (6 chars, unambiguous alphabet — no 0/O/1/I/L — so it reads aloud cleanly).

## 3. The 429 email-gate branch — assessment (not a launch blocker)

Branch `native-fix-uitest-email-gate` (tip `99796ed`) exists and is **not merged**. It is purely
test infrastructure: it probes Supabase's per-hour email cap before sign-up in the UI tests and
skips the test instead of failing when the cap (HTTP 429 `over_email_send_rate_limit`) is active,
and it raises the simulator job timeout to 60 minutes. Root cause: with "Confirm email" ON, the
UI tests' many throwaway sign-ups in one hour trip Supabase's per-hour email cap.

**Assessment:** this does **not** block real sign-ups at invite-only volume. The cap is only
tripped by dozens of sign-ups in an hour (CI test volume). Real invite-only volume is a handful
of sign-ups a day at most. A real user signing up will get their confirmation email. **Do not
merge it as part of the launch.** Merge it after build 43 for CI hygiene, using the existing
merge notes: revert the temp workflow retarget (`d4054fd`), carry the 60-minute timeout, keep
the skip allowance. Until then, simulator UI runs keep showing the 429 gate — that is expected
and does not affect the launch build.

## 4. App Store listing materials

Copy these into App Store Connect (App Store tab). Name and bundle are already set.

- **Name:** STAGE (fallback if taken: "STAGE: Spend, Track, Give", 25 chars)
- **Subtitle (30 chars max):** Spend, Save, Track & Give (25 chars — owner revised Nov 18; supersedes
  "Spend, Save & Give Tracked". His earlier full wording "Spend, Save & Give Tracked and Guided"
  is 37 chars, over Apple's 30-char cap.)
- **Category:** Finance
- **Price:** Free (no in-app purchases, no subscription)
- **Privacy Policy URL:** https://getstag.us/privacy
- **Terms URL:** https://getstag.us/terms
- **Support URL:** https://getstag.us/
- **Age rating:** 4+ (no objectionable content)

**Keywords (100 chars max, comma-separated, no spaces):**
`stage,spending,saving,giving,tracking,weekly,charity,money,finance,tzedaka` (74 chars)

**Description:**
> STAGE is a simple tracking tool for guided spending, saving, and giving, shared by two people.
> Each week you get a set amount to spend. You can see what's left, what you've spent, what
> you've given, and what's saved — all in one place.
>
> How it works: you and one other person share one record. Money you spend comes off the week.
> A share of what comes in is set aside for giving. Leftover money becomes savings. If a week
> goes over, the overspend is tracked and paid back a little at a time.
>
> Your bank and email connect read-only so purchases appear on their own, or you can add them by
> hand. Everything is shared between the two members, so everyone sees the same numbers.
>
> STAGE is free and invite-only for now: you join with an invite code from the record owner.

**App icon:** comes from the build (Xcode `AppIcon.appiconset` includes the 1024×1024 icon). No
separate upload — verify it renders correctly in App Store Connect after the launch build lands.

**Screenshots — MUST be captured from the launch build, do not fabricate:**
App Store requires real screenshots for each device family the app supports (iPhone + iPad).
Capture from the launch build on a simulator or device at native resolution — the owner's
WhatsApp screenshots show the real UI but are compressed and the wrong size, and mockups must
never be used for the store.

| Size | Resolution | Screens needed |
|---|---|---|
| iPhone 6.5" | 1284 × 2778 | Home, Funds, Transactions (min. 1, up to 10) |
| iPhone 5.5" | 1242 × 2208 | Same three screens |
| iPad 12.9" | 2048 × 2732 | Same three screens |

How to capture: run the launch build in the iOS Simulator at the matching device size and take
screenshots (Cmd+S), or take them on a real iPhone/iPad running the TestFlight build. Use the
test household ("Simcha House!") so no real household data appears — check each shot for
amounts/names before uploading.

**App Privacy (nutrition labels) — draft for Mats to confirm, not final:**
Apple requires the account holder to declare what the app collects. Draft answers (verify
before submitting): Financial Info (transaction history — linked to the user, used for app
functionality, collected via Plaid read-only and manual entry); **Emails or Text Messages**
(transaction alert emails — the app reads only transaction alert emails from the connected
bank via Gmail read-only, e.g. Amex Large Purchase alerts; it extracts amount, merchant, card
last-4, and date into a provisional purchase, stores the Gmail message ID for dedupe, and does
NOT store the email body or subject — the email is read, parsed, and discarded); Contact Info
(email address and name — account); Identifiers (user ID). Data is **not** used for tracking,
**not** sold to third parties, and **not** used for third-party advertising. No data is
collected for tracking purposes. Mats (account holder) must confirm these answers — he is the
one attesting to them. (Nov 18: the "Emails or Text Messages" category was missing from the
first draft — Mats/Claude caught it. The live privacy policy at getstag.us/privacy now covers
it; the policy HTML was stale OnBudget draft until PR #96 fixed it.)

## 5. Review notes draft (paste into App Store Connect → App Review Information)

> STAGE is a free, invite-only tracking tool for guided spending, saving, and giving, shared by
> two people.
>
> Sign-up is invite-only: after creating an account and confirming email, the only way in is an
> invite code from a record owner. To review the app, please sign up with any email, confirm
> it, and join our test record with invite code **XPKVGJ** (record "Simcha House!"). You
> will join as a member and see the Home, Funds, and Transactions screens with real data.
>
> Bank connection (Plaid, read-only) and email connection (Gmail, read-only) are both optional —
> the app is fully usable without connecting either, and the test record already has data.
> No payment, subscription, or purchase is needed anywhere in the app.
>
> Privacy policy: https://getstag.us/privacy
> The app handles bank transactions (read-only via Plaid) and email alerts (read-only via Gmail);
> both are optional, read-only, and covered by the privacy policy.

Notes for Mats: the reviewer joins the **test** household with code **XPKVGJ** — never the live
household's code. The reviewer's fresh account will sit in the test household as a member; the
owner can remove it afterwards from the test household (signed in as the test admin). If review
asks anything about data handling, point to the privacy policy above and loop in the owner.

## 6. "Make it live" checklist for Mats

Do these in order. Steps 1–4 are preparation (some need the owner/agent); steps 5–9 are the
App Store Connect actions only Mats can do as account holder.

**Preparation (before submission):**
1. [ ] Build 44 lands on `ios-clone-testflight` and uploads to TestFlight (in progress — STAG rename + invite-only fix + Plaid webhooks + other-bank email + charity auto-accrual).
2. [ ] Confirm the launch build (1.0.0 (43)) is in TestFlight and the app icon (S logo) renders.
3. [ ] Apply `supabase/invite-only-close-household-creation.sql` via the Supabase dashboard SQL
    editor (paste the whole file, run it), then verify with:
    `select has_function_privilege('authenticated','public.create_household(text)','execute');`
    — expect `false`. (If it is still `true`, the revoke did not land — do not submit until it
    reads `false`.)
4. [ ] Dashboard checks (read-only, SQL editor): (a) confirm the deployed
    `join_household_by_code` is the code-only version —
    `select pg_get_functiondef(oid) from pg_proc where proname='join_household_by_code';`
    — it must contain the 6-character regex and must NOT contain any UUID branch; (b) confirm
    the test household's code is still `XPKVGJ` —
    `select invite_code from households where id='95e1aff3-f664-41bb-be09-70e00f75a141';`
    (c) check the Functions list for a lingering `bootstrap-household` copy (removed from the
    repo Nov 2) and **delete it if present** — it creates households without a code.
5. [ ] Capture the App Store screenshots from the launch build (§4 table) and check each for
    real household data (use the test household only).

**Mats — App Store Connect (account holder only):**
6. [ ] Open App Store Connect → **STAGE** (still listed as "OnBudget: Family Budget" — rename it
    to STAGE) → App Store tab. Confirm the launch build is there (from TestFlight) and the app
    icon renders.
7. [ ] Fill in / confirm the listing from §4: subtitle, description, keywords, category
    (Finance), support URL, privacy policy URL. Confirm **Pricing: Free**, no in-app purchases.
8. [ ] Upload the screenshots from step 5 (iPhone 6.5", iPhone 5.5", iPad 12.9").
9. [ ] Fill in **App Privacy** from the §4 draft (confirm the answers first — you are attesting
    to them) and the age rating (4+).
10. [ ] Paste the **review notes** from §5 into App Review Information, with the invite code
    **XPKVGJ**. Add a contact Apple can reach if review has questions.
11. [ ] **Submit for Review.** Review typically takes 1–3 days for updates; a first submission
    may take longer and Apple may ask about privacy/data handling (the app touches bank accounts
    and email) — answer from the privacy policy and loop in the owner.
12. [ ] When approved, **release it** (choose manual release so the moment is yours, then tap
    Release — or automatic release if it should go live the moment Apple approves).

**After it is live:**
- TestFlight stays the fast channel: every new build still lands there within minutes, and the
  App Store version follows after review (1–3 days). The owner tests on TestFlight first.
- The **.p8 push key is NOT needed for publication** — the app works fully without push. It is
  still owed by Mats before notifications can deliver: send the .p8 file + Key ID, enable Push
  on the App ID (`com.onbudget.ios`), and regenerate the "OnBudget App Store" provisioning
  profile; then set the Supabase secrets `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
  `APNS_BUNDLE_ID` and verify push delivery live.

## 7. Still owed before Mats can submit (summary)

| # | Item | Blocks submission? |
|---|---|---|
| 1 | Merge `invite-only-launch` after build 43 + upload launch build | **Yes** — the launch build must contain the join-only UI |
| 2 | Apply the SQL revoke via dashboard + verify it reads `false` | **Yes** — otherwise creation is still open live |
| 3 | Verify deployed `join_household_by_code` is code-only (dashboard) | **Yes** (5-minute check; repo says it is, confirm live) |
| 4 | Delete lingering `bootstrap-household` function copy if present | **Yes** if it exists (check first) |
| 5 | Capture App Store screenshots from the launch build | **Yes** — the store needs them |
| 6 | Confirm test-household code is still `XPKVGJ` (dashboard) | **Yes** (1-minute check; the review notes depend on it) |
| 7 | Recommended: live end-to-end sign-up check with a throwaway email (confirm link → join with XPKVGJ → Home) | No — the reviewer does this; a pre-check just catches issues first |
| 8 | .p8 push key from Mats | **No** — not needed for publication, only for push delivery |
| 9 | Merge the 429 email-gate branch (`native-fix-uitest-email-gate`) | **No** — test-only; merge after build 43 for CI hygiene |
| 10 | App Privacy answers (§4 draft) confirmed by Mats | **Yes** — he attests to them at submission |

## 8. What was verified vs what was not (honest list)

**Verified (evidence in hand):**
- The join path is code-only + rate-limited in the repo SQL, and the deploy record says it was
  applied live Nov 8, 2026 (`signup-display-name.sql` header).
- RLS has no direct insert path into `households` or `household_members` (schema + the dropped
  join policy).
- No Edge Function creates households or memberships (grep of `supabase/functions`).
- `create_household` was the only creation path, and it was open to any authenticated user —
  now revoked (SQL) and removed from the UI (native), on branch `invite-only-launch` c9c1c7b.
- The edited Swift files balance (braces/parens/brackets) and contain no remaining references
  to the create path (except intentional comments and the historical audit-formatting rules).
- Email confirmation flow: URL scheme `onbudget` registered, `onOpenURL` handles
  `onbudget://email-confirmed`, persistent "Check Your Email" state in the app.
- App icon 1024×1024 is in the Xcode asset; privacy/terms pages exist and are live.

**NOT verified (needs a live check by the parent/owner, with browser or dashboard access):**
- That the deployed `join_household_by_code` body matches the repo (no UUID branch) — dashboard
  `pg_get_functiondef` check (§6 step 4a).
- That the SQL revoke actually landed (`has_function_privilege` = false) — after applying §6
  step 3.
- That no `bootstrap-household` function copy lingers deployed — dashboard Functions list (§6
  step 4c).
- That `XPKVGJ` is the current Simcha House! code — dashboard read (§6 step 4b).
- A live end-to-end sign-up with a real inbox (confirm link → join → Home).
- The kit tests and simulator run for the `invite-only-launch` branch — no Swift toolchain on
  this machine; they must run in CI after the branch merges (the branch is small and
  review-clean, but the run is still owed before the launch upload).
- Anything on the owner's devices — only he confirms the join-only screen on his phone/iPad.
