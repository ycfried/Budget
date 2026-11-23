# Test households — canonical (build 64, Nov 23, 2026)

Two test households grew up side by side and were both being used
for different things. From build 64 on, there is ONE canonical
test household. The other is noted for retirement — nothing is
deleted here, and no live-household data is ever touched.

## Canonical: Proof Household 2

- **Invite code:** `Q6GFME`
- **UUID:** not recorded in the repo — record it here the next time
  it is read from the dashboard (do NOT query the live project for
  it from this repo; read it where it already exists).
- **Use:** the CI simulator UI-test household. The simulator suite
  (`ios-clone/OnBudgetUITests/OnBudgetUITests.swift`) signs up
  fresh synthetic accounts into this household and proves the
  flows end to end. This is the household the automated proof
  runs against, so it is the canonical one.

## For retirement: Goldstein Household

- **Invite code:** `XPKVGJ`
- **UUID:** `95e1aff3-f664-41bb-be09-70e00f75a141`
- **Use (historical):** the video/screens household and the
  household referenced in SQL verification steps across
  `supabase/*.sql` (e.g. "as admin, on the TEST household" steps
  that name this id).
- **Retirement plan:** do NOT delete the household or its data.
  Move the video/screens tests to Proof Household 2 when they
  next run, and update the SQL verification steps to name Proof
  Household 2 (invite `Q6GFME`) instead of Goldstein when each
  file is next edited. Until a file is updated, its steps still
  work — Goldstein remains a valid test household; it is simply
  no longer the canonical one.

## Rules

1. **Test households only.** Every test, verification step, and
   simulator run uses a test household. The live household
   (`647d1f23-606f-43af-92e5-1de2f1f34377`) is never a test target.
2. **Fresh synthetic accounts.** UI tests sign up new accounts;
   never reuse a real person's credentials or a live-household
   member's account for testing.
3. **No data deletion.** Retiring a test household means "stop
   using it for new tests", never deleting its rows.
4. **One canonical household.** A new test that needs a household
   uses Proof Household 2. If a second household is ever needed
   again, it is documented here first, with its purpose, before
   it is used.
