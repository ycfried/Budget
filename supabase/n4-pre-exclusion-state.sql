-- =====================================================================
-- N4 migration — stored pre-exclusion state.
-- CANONICAL FILE for exclude_transaction + restore_transaction
-- (P1-M3, Nov 8, 2026). The merged restore (snapshot + reversed +
-- refund checks, admin-only) was recorded applied live Nov 5, 2026;
-- this file is the corrected canonical copy — see the restore
-- function's header for the column corrections vs the investigation
-- doc. Do NOT apply supabase/05-transaction-mutation-rpcs.sql in
-- full (reintroduces the N4 date bug, loses refund checks, loses
-- reversed-row handling). Do NOT apply this file's restore as-is
-- before the live probe in the P1 batch report confirms which body
-- is live now.
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
  v_now date;
  v_cur_week date;
  v_tx_week date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- P1-M2 (Nov 8, 2026): a locked week's transactions are immutable
  -- through the mutation RPCs — the same 35-day rule as
  -- mark_transaction_charity (r13-charity.sql). Locked-week
  -- corrections go through restoration, never a direct edit.
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := v_row.date - extract(dow from v_row.date)::int;
  if v_cur_week > v_tx_week + 35 then
    raise exception 'week is locked: a locked-week transaction cannot be changed here';
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
--   MERGED version (Nov 5, 2026; P1-M3 canonical, Nov 8, 2026):
--   N4's snapshot restore + live's reversed-restore + live's refund
--   checks, admin-only throughout (the only callers are admin-only
--   already, and spec A7 requires admin-only mutations).
--   Accepts state 'excluded' OR 'reversed'; restores the stored
--   pre_exclusion_state; clears excluded / reason / snapshot.
--
--   CORRECTIONS vs SQL_RESTORE_SHORTFALL_INVESTIGATION.md §7 (the
--   doc's verbatim SQL references columns that DO NOT EXIST in the
--   schema — live or repo — and would fail every restore at runtime:
--   refund_of_transaction_id, source_transaction_id, excluded_at,
--   excluded_by, excluded_reason, exclusion_note. None appears in
--   supabase/schema.sql or in the live 21-column probe of Nov 7).
--   The refund check now uses the real linkage column
--   original_purchase_id (P0-1); the UPDATE clears only real
--   columns. If the live body still matches the doc verbatim, it
--   must be replaced with THIS file — probe first, see the
--   live-apply order in the P1 batch report.
--
--   Deliberate (kept from the doc): NO date fallback for a NULL
--   snapshot — raises 'cannot restore: no prior state recorded'
--   instead. The N4 date fallback is the exact bug N4 was written
--   to kill (a pending row restored as posted after midnight). A
--   pre-N4 excluded row needs re-exclude/re-restore, or a one-off
--   fallback added explicitly. Do NOT silently re-add the fallback.
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
  v_original_kind text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if v_row.state <> 'excluded' and v_row.state <> 'reversed' then
    raise exception 'transaction is not excluded or reversed';
  end if;
  if v_row.pre_exclusion_state is null then
    raise exception 'cannot restore: no prior state recorded';
  end if;
  -- Refund check (live's rule, via the real linkage column): a
  -- linked refund restores only while its original purchase still
  -- exists. Unlinked refunds (original_purchase_id null) restore
  -- without this check.
  if v_row.kind = 'refund' and v_row.original_purchase_id is not null then
    select kind into v_original_kind from transactions where id = v_row.original_purchase_id;
    if v_original_kind is null then
      raise exception 'cannot restore refund: original transaction is missing';
    end if;
  end if;
  v_state := v_row.pre_exclusion_state;
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
