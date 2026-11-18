# OnBudget — SQL apply runbook

How a prepared SQL file in `supabase/` goes from branch-only to live,
and how the apply is verified. Live database changes always go to the
owner first (standing rule); nothing here is applied by a merge.

## 0. Rules

- Apply **one file at a time**, in the order the file's own header
  states. Never apply a file bannered SUPERSEDED / DO NOT APPLY.
- Never commit a filled-in copy of a file that takes a pasted secret
  (e.g. `server-sync-cron.sql`).
- The parent (not a branch agent) runs the apply in the Supabase SQL
  editor, with the owner present for the approval, and records the
  per-file verification below in HANDOFF.md.

## 1. Syntax check — rollback dry-run (every file, before the real apply)

The node test suite **cannot execute SQL** (P2-N5): the tests assert a
JS mirror of the intended semantics plus regexes over the SQL text.
A SQL edit that breaks behaviour but keeps the regexes would still
pass the suite. So before any real apply, validate the file against
the live database **without persisting anything**:

1. In the SQL editor, paste:
   ```sql
   begin;
   -- <paste the whole file contents here>
   rollback;
   ```
2. It must return **no error**. This checks parsing, name resolution
   (`transactions`, `household_members`, …), and function-body
   validity — the exact class of break the mirror tests cannot see.
3. Only then run the file a second time **without** the `begin;` /
   `rollback;` wrapper, as the real apply.

If the dry-run errors, stop: fix the file on the branch, re-run the
suite, and repeat the dry-run. Never "fix it live" by editing the
pasted text — the repo file is the record of what is live.

## 2. Post-apply verification (every file)

- Re-run the file's own STEP 0 / verification queries (read-only).
  They are the file's contract; if any fails, the apply is not done.
- Record the result (query output + time) in HANDOFF.md next to the
  file's apply note.

## 3. P2-N5 live-syntax check — `supabase/refund-linking.sql`

The refund-linking matcher (`auto_link_refund`,
`link_refunds_to_purchase`, `link_refund`, `unlink_refund`) is the
case that motivated this runbook: its behaviour is pinned in-branch
only by the JS mirror in `test/p0-fixes-audit-2026-11-08.test.mjs`
plus the agreement pins in `test/p2-engine.test.mjs`. The mirror
cannot prove the shipped SQL links a real refund. At apply time:

1. **Dry-run** per §1 (rollback) — catches syntax errors.
2. **Apply** the file (Step 1 in its header).
3. **Existence check** (read-only):
   ```sql
   select proname from pg_proc where proname in
     ('auto_link_refund', 'link_refunds_to_purchase', 'link_refund', 'unlink_refund');
   ```
   Expect all four rows.
4. **Synthetic-household smoke test** — on a synthetic household
   only, never the live household. Create (or reuse) a synthetic
   household with one posted charge and one unlinked posted refund
   for the same merchant, card suffix, and exact amount inside 90
   days, then:
   ```sql
   select public.auto_link_refund('<refund-uuid>');
   -- Expect: the purchase id (not NULL).
   select original_purchase_id from transactions where id = '<refund-uuid>';
   -- Expect: the purchase id.
   select public.auto_link_refund('<refund-uuid>');
   -- Expect: NULL (already linked — second call links nothing).
   ```
   Then delete the synthetic rows/household. If any step returns the
   wrong value, stop: the SQL does not behave as the mirror promises,
   even though the suite passed — report it as a P2-N5 failure, do
   not work around it live.
5. **Negative check** (same synthetic household): a second identical
   purchase must make `auto_link_refund` return NULL (exactly-one
   rule — never guess between lookalikes).

What remains live-only after this check: the deployed Edge Functions
calling the linker after insert (plaid-sync, ingest-amex-alert,
gmail-poll) — a real refund arriving end-to-end is proven only by a
real ingestion, not by any in-branch test.

## 4. Files this runbook does NOT cover

- Edge Function deploys (GitHub auto-deploy on merge; verify the
  deployed source contains the expected markers after deploy).
- Backups/restores — see `docs/BACKUP.md`.
