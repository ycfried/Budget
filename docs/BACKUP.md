# Household Budget — Backup procedure (S4, docs only)

> Status: **this document is the deliverable. No backup has been run yet,
> and no backup is claimed to exist.** The parent/owner must run the
> procedure below before anyone says "we have backups." This doc is not
> executed by the app and touches no live data.

## Why a nightly export (Free tier)

The Supabase Free tier does not guarantee point-in-time restore for this
project. The safety net is therefore a nightly export the owner controls,
plus a restore test (below) done once before go-live and repeated after
any schema change.

## What to export, nightly

1. **Full database dump** — every table in the `public` schema, including:
   households, household_members, transactions, fund_requests, fund_ledger,
   surplus_releases, week_closes, savings_ledger, audit_log, plaid_items,
   plaid_accounts, temp_increases, and any other project tables added later.
   (Auth users live in Supabase Auth, not in `public` — see note below.)
2. **Storage-less config notes** — a short dated note recording: the
   project URL and region, the list of deployed Edge Functions and their
   versions, the Auth settings that matter (email confirmation on/off,
   redirect URLs including `live.html` and `reset.html`), and the RLS /
   migration files applied, by filename. There is no app file storage
   (Storage buckets) in this project, so there is nothing else to copy.
3. **What is NOT in the dump, by design:** Supabase Auth users/passwords,
   Plaid access tokens (encrypted tokens live in Edge Function secrets /
   the Plaid vault flow, never in the database), and any Edge Function
   secret values. Never paste a secret into the backup note. If the live
   project were ever lost, users would re-register / re-link their bank;
   the backup restores the household's *data*, not its credentials.

## How (two supported routes — pick one and stick to it)

### Route A — Supabase dashboard / SQL editor (no CLI)

1. Dashboard → Database → Backups (or SQL editor) → run a full export of
   the `public` schema and download the resulting SQL file.
2. If the dashboard offers only a partial export, export table-by-table
   from the SQL editor (`COPY` / `SELECT` exports) until every table in
   §"What to export" is covered, and record any table that could not be
   exported in the run note.

### Route B — Supabase CLI (from a machine the owner trusts)

1. `supabase link --project-ref <project-ref>` (owner only; never commit
   the resulting config or any key).
2. `supabase db dump -f backup-YYYY-MM-DD.sql` for the schema + data dump
   of the `public` schema. Verify the file is non-empty and contains a
   `COPY` / `INSERT` section for every table in §"What to export".
3. Do not run any dump command against the live project with a write flag,
   and never pipe a dump into a live database (see restore-test rules).

## Where the export is stored

- Store each nightly file under a dated name (`backup-YYYY-MM-DD.sql`)
  in storage the owner controls and the app cannot reach — e.g. an
  encrypted local drive or a private cloud folder with access limited to
  the owner. Keep at least the last 30 nightly files.
- After each run, record in the run note: date/time, file name, file size,
  and a row-count check (below). A backup with no run note counts as
  "not verified."

## Row-count verification (every run, 2 minutes)

After exporting, compare counts for at least these tables between the live
project and the export file (count the exported rows per table, or restore
to the throwaway project in §"Restore test" and count there):

- households, household_members, transactions, fund_requests, fund_ledger,
  surplus_releases, week_closes, savings_ledger, audit_log, plaid_items.

If any count differs by more than rows created *during* the export window,
re-run the export and note the discrepancy. Do not silently accept a
short export.

## Restore-test procedure (once before go-live, then after schema changes)

1. **Create a throwaway Supabase project** (Free tier is fine). Never
   restore over the live project.
2. Apply the project's schema/migration files to the throwaway project
   first, then load the backup SQL file into it.
3. Verify: (a) every table from §"What to export" exists, (b) row counts
   match the run note, (c) a spot check opens — e.g. the latest week_closes
   row and a recent transaction read back with the right amounts.
4. Record the test date, the backup file tested, and PASS/FAIL in the run
   note. A restore test that was never run means "restore unproven,"
   however good the exports look.
5. **Delete the throwaway project** after the test so no second copy of
   household data lingers.
6. **Restoring over the live project requires explicit owner approval,**
   in writing, naming the backup file and the reason. There is no
   automatic or scheduled restore, ever.

## Schedule

Nightly, at a quiet hour in America/New_York, run by the owner (or by a
scheduled job the owner approves — that job is out of scope for this doc
and must never hold a service key in client code). If a night is missed,
note it; a gap in nightly files is itself a finding, not something to
paper over with a backdated file.
