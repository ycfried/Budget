-- P2-B4 — Sunday week_start guard (Nov 8, 2026, R3).
-- PREPARED FOR OWNER-APPROVED APPLY — NOT APPLIED BY THIS BRANCH.
-- Do NOT apply from a merge: the parent applies it via the approved
-- browser SQL run after the owner has seen this exact file.
--
-- PROBLEM: set_weekly_allowance_override and add_temp_increase
-- accepted any week_start, but compute-week and week-close look
-- overrides/temp increases up by exact Sunday (weekStartOf), so a
-- non-Sunday row silently never matched — a no-op the admin would
-- never notice. The RPCs now raise on a non-Sunday week_start
-- (see weekly-allowance-override.sql and live-temp-increases.sql);
-- this file adds the durable table-level CHECKs so no write path —
-- RPC, direct SQL, or future function — can ever store one.
--
-- WHY A CHECK IS SAFE HERE (repo evidence, checked Nov 8, 2026):
--   * Every writer derives week_start from weekStartOf(), which
--     returns a Sunday by construction: compute-week and week-close
--     build candidate weeks from weekStartOf(t.date); live.js builds
--     override weeks from the NY Sunday; the RPCs now raise on
--     anything else.
--   * No legitimate non-Sunday row exists in the repo: the only
--     Monday-based week_start in supabase/*.sql is in
--     transfer-backfill.sql, and that file is 100% commented
--     investigation queries (date_trunc('week') Monday grouping for
--     analysis) — it writes nothing, to no table.
--   * fund_ledger.week_start and restoration_entries.week_start are
--     NOT covered here: they are written by approve_and_allocate /
--     week-close with their own week derivation, and the audit named
--     only week_closes plus the two RPC tables. Do not extend this
--     file to them without checking their writers first.
--
-- STEP 0 — VERIFY LIVE FIRST (read-only; expect 0 rows each — a
-- non-zero count means a live row the CHECK would reject, so STOP
-- and reconcile before applying):
--   select count(*) from week_closes where extract(dow from week_start) <> 0;
--   select count(*) from temp_increases where extract(dow from week_start) <> 0;
--   select count(*) from weekly_allowance_overrides where extract(dow from week_start) <> 0;
--
-- STEP 1 — Apply this file in the SQL editor, in order. Each block
-- is idempotent (IF NOT EXISTS guard); re-running is a no-op.
-- P2-B13 NOTE: this guard covers the week_closes WRITE side only.
-- compute-week's unvalidated week_start INPUT (a garbage string
-- reaches weekStartOf and 500s) is NOT fixed by a CHECK — that
-- belongs to the Edge Functions workstream (validate
-- ^\d{4}-\d{2}-\d{2}$ in compute-week/index.ts, 400 otherwise).

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'week_closes_week_start_sunday'
  ) then
    alter table week_closes
      add constraint week_closes_week_start_sunday
      check (extract(dow from week_start) = 0);
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'temp_increases_week_start_sunday'
  ) then
    alter table temp_increases
      add constraint temp_increases_week_start_sunday
      check (extract(dow from week_start) = 0);
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'weekly_allowance_overrides_week_start_sunday'
  ) then
    alter table weekly_allowance_overrides
      add constraint weekly_allowance_overrides_week_start_sunday
      check (extract(dow from week_start) = 0);
  end if;
end;
$$;

-- VERIFICATION (run after applying, read-only):
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--    where conname in ('week_closes_week_start_sunday',
--     'temp_increases_week_start_sunday',
--     'weekly_allowance_overrides_week_start_sunday');
--     -- expect 3 rows, each check (extract(dow from week_start) = 0)
