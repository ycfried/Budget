-- =====================================================================
-- N4 migration — stored pre-exclusion state (NOT YET APPLIED LIVE)
-- Replaces the date-reconstruction rule in restore_transaction()
-- (reaudit N4): a pending refund restored after midnight used to
-- come back as 'verified' (posted) with no bank confirmation,
-- because restore guessed the state from the transaction date.
--
-- What changes:
--   * New nullable column transactions.pre_exclusion_state, holding
--     the state the row had immediately before it was excluded
--     ('provisional', 'verified', or 'reversed' — never 'excluded').
--   * exclude_transaction() snapshots v_row.state into that column
--     when the row is not already excluded. Re-excluding an
--     already-excluded row keeps the ORIGINAL snapshot (it does not
--     overwrite it with 'excluded'), so a retried tap cannot clobber
--     the restore target.
--   * restore_transaction() reads the snapshot instead of
--     reconstructing from the date. Rows excluded BEFORE this
--     migration have a NULL snapshot and keep the old date rule as
--     a fallback (before today -> 'verified', else 'provisional'),
--     so already-excluded rows still restore.
--   * Restore clears the snapshot (NULL) and the reason, as before.
-- Nothing else changes: same signatures, same admin-only checks,
-- same 'transaction is not excluded' guard, same audit rows.
--
-- No secrets, tokens, or keys appear in this file.
-- =====================================================================

alter table transactions
  add column if not exists pre_exclusion_state text;

-- The snapshot is a prior state, never 'excluded' itself. NULL means
-- "excluded before this migration" (date fallback applies).
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'transactions_pre_exclusion_state_check'
  ) then
    alter table transactions
      add constraint transactions_pre_exclusion_state_check
      check (pre_exclusion_state is null
             or pre_exclusion_state in ('provisional', 'verified', 'reversed'));
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- exclude_transaction(txn_id uuid, reason text) returns void
--   Same as supabase/05-transaction-mutation-rpcs.sql, plus the
--   pre-exclusion snapshot (see header). Blank reasons stay allowed
--   (owner decision 4); re-exclude stays idempotent.
-- ---------------------------------------------------------------------
create or replace function public.exclude_transaction(txn_id uuid, reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row transactions%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  update transactions
    set excluded = true, state = 'excluded',
        exclude_reason = coalesce(reason, ''),
        pre_exclusion_state = case
          when v_row.state <> 'excluded' then v_row.state
          else v_row.pre_exclusion_state
        end
    where id = txn_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Transaction excluded',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents excluded'
            || case when reason is not null and btrim(reason) <> ''
                    then ' — reason: ' || reason else ' — no reason given' end || '.');
end;
$$;
revoke execute on function public.exclude_transaction(uuid, text) from public;
grant execute on function public.exclude_transaction(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- restore_transaction(txn_id uuid) returns void
--   Same as supabase/05-transaction-mutation-rpcs.sql, except the
--   restore target comes from the stored snapshot (N4 fix). The
--   date rule survives ONLY as the fallback for rows excluded
--   before this migration (snapshot NULL).
-- ---------------------------------------------------------------------
create or replace function public.restore_transaction(txn_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row transactions%rowtype;
  v_state text;
  v_today date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if v_row.state <> 'excluded' then
    raise exception 'transaction is not excluded';
  end if;
  v_today := (now() at time zone 'America/New_York')::date;
  v_state := coalesce(
    v_row.pre_exclusion_state,
    case when v_row.date < v_today then 'verified' else 'provisional' end);
  update transactions
    set excluded = false, state = v_state, exclude_reason = '',
        pre_exclusion_state = null
    where id = txn_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Transaction restored',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents restored to the week as '
            || case when v_state = 'provisional' then 'pending' else 'posted' end || '.');
end;
$$;
revoke execute on function public.restore_transaction(uuid) from public;
grant execute on function public.restore_transaction(uuid) to authenticated;

-- =====================================================================
-- VERIFICATION (commented — run manually after deploy, do NOT run
-- blindly against production data; use a throwaway transaction):
--   -- Column exists:
--   select column_name from information_schema.columns
--    where table_name = 'transactions'
--      and column_name = 'pre_exclusion_state';  -- 1 row
--   -- Exclude snapshots the prior state (as admin, throwaway row):
--   select exclude_transaction('<txn-uuid>', 'test');
--   select state, excluded, pre_exclusion_state from transactions
--    where id = '<txn-uuid>';
--     -- expect: state 'excluded', excluded true,
--     -- pre_exclusion_state = the row's prior state (not 'excluded')
--   -- Restore returns the snapshot, not the date rule:
--   select restore_transaction('<txn-uuid>');
--   select state, excluded, pre_exclusion_state from transactions
--    where id = '<txn-uuid>';
--     -- expect: state = prior state, excluded false,
--     -- pre_exclusion_state null
-- =====================================================================
