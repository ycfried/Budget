# OnBudget native iOS clone — progress

Clone basis: **live web v66** — `origin/main` at `872ae11` (PR #61,
refund-link-and-merge). The clone states it is based on v66; later live
web updates become native v2.

Branch: `ios-clone` (integration branch, from `origin/main` 872ae11). Sub-branches use the `ios-clone-v66/*` prefix (scaffold, spec, apiclient, notify-store) — note: git forbids a branch sharing a prefix with sub-branches, so `ios-clone-v66` itself can never exist as a branch; `ios-clone` is the integration line.
See `README.md` for branch rules. Never touch `main`, never touch web
files / SQL / Edge Functions, never touch the old `ios-native-rebuild`
branch.

## Integration (Nov 9, 2026)
- Merged into `ios-clone`: `ios-clone-v66/scaffold` (154d051), `ios-clone-v66/spec` (6fb6086), `ios-clone-v66/notify-store` (49da7d0). Tip: cce426d.
- `ios-clone-v66/apiclient` still running; merge into `ios-clone` when it lands.
- **CI BLOCKED (not green):** the simulator workflow file is in a local-only commit f548055 on the scaffold worktree — GitHub refused the push (`OAuth App ... without 'workflow' scope`; the gh token has only `gist, read:org, repo`). Unblock: in a browser session run `gh auth refresh --scopes workflow`, then from `/tmp/ios-clone-scaffold` run `git push origin ios-clone-v66/scaffold`. Do NOT claim CI green until that run passes.

## Milestones

- [x] **Scaffold** — project skeleton, design tokens (CI workflow file written, NOT yet green — see blocker above)
  - [x] `OnBudget.xcodeproj` — app target `OnBudget`, test target `OnBudgetTests`
  - [x] `OnBudgetKit` Swift package — design tokens, Title Case, toast spec, configuration
  - [x] Smoke tests (Xcode target + package target)
  - [x] App icon set generated from the original circular logo (`Assets/source-logo.jpg`)
  - [ ] GitHub Actions simulator workflow green on `macos-15-intel` — BLOCKED on token scope (see above)
- [x] **Clone spec** — `CLONE_SPEC.md` (26 screens, 1,965 lines; 16 NEEDS-LIVE-PROBE items; 10 live.js/HANDOFF conflicts resolved live.js-wins)
- [x] **Notifications + App Store prep** — `docs/APNS_DESIGN.md` + `docs/APP_STORE_PLAN.md` (v1 set: Week Closed, New Purchase, Fund Request Waiting; server design only, no SQL applied)
- [x] **API client** — Supabase client on the live backend (merged from `ios-clone-v66/apiclient`, b0e52e8): Auth REST, PostgREST reads (101-row paging + whole-history helper), 26 typed RPCs, 12 Edge Functions, Codable models, error mapping. 57/57 package tests pass locally (Swift 6.1.2 on Linux; CI not yet green — see blocker above). Manifest fix by coordinator: swift-tools 5.9 → 6.0 (`.iOS(.v18)` needs PackageDescription 6.0) + `Sendable` fixes in Models/SupabaseClient.
- [x] **Auth** — sign-in / sign-up / household join, same flows as web v66 (merged from `ios-clone-v66/auth-home`, 6731fc7): AppViewModel, Auth/Household/Home views, shared views, formatting. 62/62 package tests at merge (57 + 5 new select-shape tests). Open: reset deep link `onbudget://reset-password` needs Supabase redirect-URL allow-list + Xcode URL type; tab bar ships 4 tabs — web has 3 + Settings via profile menu (fix agent running).
- [x] **Home** — stacked Charity above Extra Fund, one-open-at-a-time (merged with Auth above)
- [ ] **Transactions** — list, detail, manual add, trash/restore (builder running, `ios-clone-v66/transactions`)
- [x] **Funds** — Extra Fund, top-ups (shortfall-first), fund requests (merged from `ios-clone-v66/funds`, f84d1f8): FundsView/ViewModel/Forms, CharityIncomeForm, TemporaryAllowanceView, ReviewView (+ Swift port of `refundSuggestions.mjs`), TrashView. 73/73 package tests at merge (62 + 11 new decode tests). The builder found + fixed the narrow-select decode bug in 12 more reads (every real row failed decoding) — HEAD's wider lists won the merge over its narrower ones. Open: `householdName` has the same latent bug (API-client owner); one-open-at-a-time is local to FundsView, needs shared state with Home (integration item).
- [x] **Charity** — 10% on received income, per-transaction overrides (merged with Funds above)
- [x] **Review** — possible duplicates, refund links, resolved pairs (merged with Funds above)
- [ ] **Settings / Members / Profile** — incl. invite code, remove member (builder running, `ios-clone-v66/settings`)
- [ ] **Notifications** — week close, new purchase, fund request awaiting approval
- [ ] **App Store** — privacy labels, privacy policy link, account deletion, screenshots, listing

## Watch items (web-side, affect the clone)
- **BOTH LIVE DEFECTS NOW FIXED LIVE (PR #62 merged ~4:57 PM Nov 9, main 5770f1f, live.js v67):** merge records `pre_exclusion_state`; held refunds aligned on `'held'` (function, week-close insert, `unlink_refund` guard, live.js rendering; second-release refusal preserved). SQL applied live 4:51–4:54 PM and verified; Pages build success; tests 765/765. **Clone basis stays v66, but the clone already builds these flows to the intended behaviour, so no clone change is needed — the flows now work against the live server.** Week-close deployed-source marker check ('held' in deployed body) still owed on the web side. Web is now v67; per the checkpoint rule later web updates are native v2, but these two P0 fixes are the flagged exception the clone follows.
- Synthetic proofs NOT RUN: 4/5/6 (need admin sign-in — owner taps the test-mailbox reset link), 12 (CSV — needs a file), 7 BLOCKED (Plaid needs real bank credentials). Loading hang (~2:00–2:33 PM Nov 9) cleared on its own — transient, no fix.
- **Integration items (coordinator pass after wave 2 lands):** wire Funds tab + Trash link into the app shell; share `expandedCard` state across Home + Funds (one-open-at-a-time spans both); resolve any pbxproj conflicts from the remaining builders.

## Notes

- Builds run **only** via GitHub Actions (no Xcode on the Linux VM).
  The simulator script pins Xcode 16.4 when the runner image carries it;
  if it does not, it falls back to the default Xcode provided it is 16.x
  or newer, and says so in the log. Deviation from the proven
  `ios-native-rebuild` script, which hard-failed without Xcode 16.4.
- Simulator runtime: prefers iOS 18.5, else the newest available iOS
  runtime on the runner.
- App icon: generated from the original circular logo at
  `ios-clone/Assets/source-logo.jpg` (the rejected hand-made
  `onbudget-logo.svg` was NOT used). The circle sits inside the
  squircle mask with white corners — no clipping at icon sizes.
- **Never test against the real household
  `647d1f23-606f-43af-92e5-1de2f1f34377` or the owner's account.**
  Scaffold needs no backend data; later work tests against synthetic /
  test data only, until proven.
- No secrets in the repo. The Supabase URL + publishable anon key in
  `OnBudgetKit/Sources/OnBudgetKit/Configuration.swift` are client keys
  designed to ship (same values as web `config.js`). The service-role
  key must NEVER appear here.
