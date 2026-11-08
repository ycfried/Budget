-- Delete-account FK migration — PREPARED ONLY, DO NOT APPLY
-- without the owner's explicit approval ("fix everything", Nov 3).
--
-- WHY (Round 3, bug 9): a non-last member's deletion failed
-- partway — membership removed, auth account orphaned — because
-- deleting an auth user is blocked by every history row that
-- references them, and most of those references have no ON DELETE
-- action (Postgres default NO ACTION). Any user with any history
-- hits this: fund_requests.requested_by / decided_by,
-- savings_ledger.attested_by, audit_log.actor,
-- fund_ledger.created_by, temp_increases.created_by,
-- fund_topups.created_by, charity_income.created_by,
-- weekly_allowance_overrides.created_by (P1-B7, Nov 8, 2026 — the
-- ninth reference; deleting an admin who set a temporary allowance
-- failed the auth delete). Only household_members.user_id already
-- cascades. After the household itself is deleted its rows cascade
-- away, which is exactly why the orphaned account's retry succeeded
-- once the household was gone. This migration re-points every one
-- of those references to ON DELETE SET NULL, so deleting a user
-- nulls their references instead of failing — history rows stay
-- (audit text, amounts, dates all remain; only the link to the
-- deleted account clears, and the display text in actor_name /
-- notes is untouched).
--
-- The four NOT NULL columns (fund_requests.requested_by,
-- savings_ledger.attested_by, temp_increases.created_by,
-- weekly_allowance_overrides.created_by) are also relaxed to
-- nullable: nothing in the app reads those columns for display
-- (requests render amount/status/note; savings render
-- kind/amount/date/note; overrides render week/amount), and a
-- request, attestation, or override by a deleted account is a real
-- state, not a missing value.
--
-- SAFETY: constraint changes only; no row is updated or deleted
-- by this file. Every block looks its constraint up by definition
-- (any name) and re-adds it under the conventional name only if
-- that name is not already present, so re-running is a no-op.
-- If any block fails, the whole transaction rolls back and
-- nothing changes — diagnose, do not force.

begin;
-- Relax the four NOT NULL user references first.
alter table fund_requests alter column requested_by drop not null;
alter table savings_ledger alter column attested_by drop not null;
alter table temp_increases alter column created_by drop not null;
alter table weekly_allowance_overrides alter column created_by drop not null;

do $$
declare
  c text;
begin
  -- fund_requests.requested_by -> SET NULL
  select conname into c from pg_constraint
   where conrelid = 'fund_requests'::regclass and contype = 'f'
     and pg_get_constraintdef(oid) like '%(requested_by) REFERENCES auth.users%';
  if c is not null then execute 'alter table fund_requests drop constraint ' || quote_ident(c); end if;
  if not exists (select 1 from pg_constraint where conname = 'fund_requests_requested_by_fkey') then
    execute 'alter table fund_requests add constraint fund_requests_requested_by_fkey foreign key (requested_by) references auth.users(id) on delete set null';
  end if;
  -- fund_requests.decided_by -> SET NULL
  select conname into c from pg_constraint
   where conrelid = 'fund_requests'::regclass and contype = 'f'
     and pg_get_constraintdef(oid) like '%(decided_by) REFERENCES auth.users%';
  if c is not null then execute 'alter table fund_requests drop constraint ' || quote_ident(c); end if;
  if not exists (select 1 from pg_constraint where conname = 'fund_requests_decided_by_fkey') then
    execute 'alter table fund_requests add constraint fund_requests_decided_by_fkey foreign key (decided_by) references auth.users(id) on delete set null';
  end if;
  -- savings_ledger.attested_by -> SET NULL
  select conname into c from pg_constraint
   where conrelid = 'savings_ledger'::regclass and contype = 'f'
     and pg_get_constraintdef(oid) like '%(attested_by) REFERENCES auth.users%';
  if c is not null then execute 'alter table savings_ledger drop constraint ' || quote_ident(c); end if;
  if not exists (select 1 from pg_constraint where conname = 'savings_ledger_attested_by_fkey') then
    execute 'alter table savings_ledger add constraint savings_ledger_attested_by_fkey foreign key (attested_by) references auth.users(id) on delete set null';
  end if;
  -- audit_log.actor -> SET NULL
  select conname into c from pg_constraint
   where conrelid = 'audit_log'::regclass and contype = 'f'
     and pg_get_constraintdef(oid) like '%(actor) REFERENCES auth.users%';
  if c is not null then execute 'alter table audit_log drop constraint ' || quote_ident(c); end if;
  if not exists (select 1 from pg_constraint where conname = 'audit_log_actor_fkey') then
    execute 'alter table audit_log add constraint audit_log_actor_fkey foreign key (actor) references auth.users(id) on delete set null';
  end if;
  -- fund_ledger.created_by -> SET NULL
  select conname into c from pg_constraint
   where conrelid = 'fund_ledger'::regclass and contype = 'f'
     and pg_get_constraintdef(oid) like '%(created_by) REFERENCES auth.users%';
  if c is not null then execute 'alter table fund_ledger drop constraint ' || quote_ident(c); end if;
  if not exists (select 1 from pg_constraint where conname = 'fund_ledger_created_by_fkey') then
    execute 'alter table fund_ledger add constraint fund_ledger_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null';
  end if;
  -- temp_increases.created_by -> SET NULL
  select conname into c from pg_constraint
   where conrelid = 'temp_increases'::regclass and contype = 'f'
     and pg_get_constraintdef(oid) like '%(created_by) REFERENCES auth.users%';
  if c is not null then execute 'alter table temp_increases drop constraint ' || quote_ident(c); end if;
  if not exists (select 1 from pg_constraint where conname = 'temp_increases_created_by_fkey') then
    execute 'alter table temp_increases add constraint temp_increases_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null';
  end if;
  -- fund_topups.created_by -> SET NULL
  select conname into c from pg_constraint
   where conrelid = 'fund_topups'::regclass and contype = 'f'
     and pg_get_constraintdef(oid) like '%(created_by) REFERENCES auth.users%';
  if c is not null then execute 'alter table fund_topups drop constraint ' || quote_ident(c); end if;
  if not exists (select 1 from pg_constraint where conname = 'fund_topups_created_by_fkey') then
    execute 'alter table fund_topups add constraint fund_topups_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null';
  end if;
  -- charity_income.created_by -> SET NULL
  select conname into c from pg_constraint
   where conrelid = 'charity_income'::regclass and contype = 'f'
     and pg_get_constraintdef(oid) like '%(created_by) REFERENCES auth.users%';
  if c is not null then execute 'alter table charity_income drop constraint ' || quote_ident(c); end if;
  if not exists (select 1 from pg_constraint where conname = 'charity_income_created_by_fkey') then
    execute 'alter table charity_income add constraint charity_income_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null';
  end if;
  -- weekly_allowance_overrides.created_by -> SET NULL (P1-B7, Nov 8,
  -- 2026: the ninth reference — an admin who set a temporary
  -- allowance blocked the auth delete until this was re-pointed).
  select conname into c from pg_constraint
   where conrelid = 'weekly_allowance_overrides'::regclass and contype = 'f'
     and pg_get_constraintdef(oid) like '%(created_by) REFERENCES auth.users%';
  if c is not null then execute 'alter table weekly_allowance_overrides drop constraint ' || quote_ident(c); end if;
  if not exists (select 1 from pg_constraint where conname = 'weekly_allowance_overrides_created_by_fkey') then
    execute 'alter table weekly_allowance_overrides add constraint weekly_allowance_overrides_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null';
  end if;
end $$;
commit;

-- Verification (read-only): every re-pointed reference must show
-- ON DELETE SET NULL.
select conrelid::regclass as table_name, conname,
       pg_get_constraintdef(oid) as definition
  from pg_constraint
 where contype = 'f'
   and pg_get_constraintdef(oid) like '%REFERENCES auth.users%'
   and conrelid::regclass::text in
     ('fund_requests', 'savings_ledger', 'audit_log', 'fund_ledger',
      'temp_increases', 'fund_topups', 'charity_income',
      'weekly_allowance_overrides')
 order by table_name, conname;
