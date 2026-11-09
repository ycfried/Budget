# OnBudget native iOS clone — progress

Clone basis: **live web v66** — `origin/main` at `872ae11` (PR #61,
refund-link-and-merge). The clone states it is based on v66; later live
web updates become native v2.

Branch: `ios-clone-v66` (this scaffold lives on `ios-clone-v66/scaffold`).
See `README.md` for branch rules. Never touch `main`, never touch web
files / SQL / Edge Functions, never touch the old `ios-native-rebuild`
branch.

## Milestones

- [x] **Scaffold** — project skeleton, design tokens, CI proof (this branch)
  - [x] `OnBudget.xcodeproj` — app target `OnBudget`, test target `OnBudgetTests`
  - [x] `OnBudgetKit` Swift package — design tokens, Title Case, toast spec, configuration
  - [x] Smoke tests (Xcode target + package target)
  - [x] App icon set generated from the original circular logo (`Assets/source-logo.jpg`)
  - [x] GitHub Actions simulator workflow, green on `macos-15-intel`
- [ ] **API client** — Supabase client on the live backend (sibling branch `ios-clone-v66/apiclient`)
- [ ] **Auth** — sign-in / sign-up / household join, same flows as web v66
- [ ] **Home** — stacked Charity above Extra Fund, one-open-at-a-time
- [ ] **Transactions** — list, detail, manual add, trash/restore
- [ ] **Funds** — Extra Fund, top-ups (shortfall-first), fund requests
- [ ] **Charity** — 10% on received income, per-transaction overrides
- [ ] **Review** — possible duplicates, refund links, resolved pairs
- [ ] **Settings / Members / Profile** — incl. invite code, remove member
- [ ] **Notifications** — week close, new purchase, fund request awaiting approval
- [ ] **App Store** — privacy labels, privacy policy link, account deletion, screenshots, listing

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
