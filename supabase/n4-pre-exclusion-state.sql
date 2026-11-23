-- =====================================================================
-- N4 migration — stored pre-exclusion state.
-- CANONICAL FILE for exclude_transaction + restore_transaction
-- (P1-M3, Nov 8, 2026). The merged restore (snapshot + reversed +
-- refund checks, admin-only) was recorded applied live Nov 5, 2026;
-- this file is the corrected canonical copy — see the restore
-- function's header for the column corrections vs the investigation
-- doc. Do NOT apply supabase/05-transaction-mutation-rpcs.sql in
-- full (reintroduces the N4 date bug, loses refund checks, loses
-- reversed-row handling). APPLIED LIVE Nov 8, 2026 and again
-- Nov 9, 2026, step 1 (R4 §2; R4-BE-2, Nov 9, 2026 — the "do not
-- apply as-is before the live probe" warning this header carried
-- before is spent: the probe happened, and the file is verified
-- live — column exists; restore has the locked-week check, the
-- auto_link_refund re-offer, and original_purchase_id).
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
--     migration have a NULL snapshot and restore is REFUSED for
--     them ('cannot restore: no prior state recorded') — there is
--     deliberately NO date fallback in the body: the date rule is
--     the exact bug N4 was written to kill (a pending row restored
--     as posted after midnight). Re-exclude/re-restore CANNOT fix
--     a NULL snapshot (re-exclude preserves the original snapshot,
--     NULL included — see exclude below), so the real remedies are
--     (a) a one-off owner-approved repair that sets
--     pre_exclusion_state from evidence for that row and then
--     restores it, or (b) accepting the row as unrestorable
--     (permanently excluded) with Trash UI copy saying so. The
--     23 rows live with NULL snapshots (recorded Nov 8, 2026)
--     are a known limitation, owner decision pending — no
--     backfill, no silent repair. (P2-NEW2, Nov 8, 2026: this
--     header previously promised a date fallback and a
--     re-exclude/re-restore remedy; both were wrong.)
--   * Restore clears the snapshot (NULL) and the reason, as before.
-- Nothing else changes: same signatures, same admin-only checks,
-- same 'transaction is not excluded' guard, same audit rows.
--
-- F-4 (build 61 audit, Nov 23, 2026): exclude_transaction now has
-- a linked-refund guard — a live refund linked to the row is
-- re-pointed at the sole surviving live purchase with the same
-- dedupe_hash when exactly one exists, and otherwise the exclude
-- REFUSES with a clear message (the Nov 20 Walmart failure must
-- not be possible from the app). restore_transaction restores, with
-- the purchase, any refund the system auto-excluded with it
-- (auto_link_refund's arrival-direction rule, refund-linking.sql).
--
-- F-14 (build 61 audit, Nov 23, 2026): exclude_transaction now
-- accepts a service_role caller (plaid-sync's removed[] path routes
-- through it for the snapshot + audit + locked-week check; the
-- admin check is skipped for service_role only, EXECUTE is granted
-- to service_role below). Authenticated callers are unchanged.
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
  v_refund record;
  v_surv_count integer;
  v_surv_id uuid;
  v_repointed integer := 0;
  v_is_service boolean := (auth.role() = 'service_role');
begin
  if auth.uid() is null and not v_is_service then raise exception 'not authenticated'; end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  -- F-14: the service-role sync path (plaid-sync removed[]) routes
  -- through this RPC for its snapshot + audit + locked-week check.
  -- A service-role caller is trusted server code (it already holds
  -- the service key); the admin check below is skipped for it, the
  -- same pattern as accrue_charity_for_transaction
  -- (charity-auto-accrue.sql). An authenticated caller must still
  -- be an admin of the row's household.
  if not v_is_service and not exists (select 1 from household_members
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
  -- F-4 (build 61 audit, Nov 23, 2026) — linked-refund guard: the
  -- Nov 20 Walmart failure (a refund left linked to an excluded
  -- charge) must not be possible from the app's Exclude action.
  -- For every LIVE refund linked to this row (kind='refund', not
  -- excluded, not reversed): re-point it at the SOLE surviving live
  -- purchase with the same dedupe_hash when exactly one exists
  -- (the duplicate-exclude case — the refund's money belongs to
  -- the surviving purchase), and REFUSE the exclude otherwise,
  -- with a clear message telling the admin to handle the refund
  -- first. Re-pointing and refusing both happen in this same
  -- statement, so the refund can never be stranded mid-exclude.
  -- A refund that is already excluded/reversed does not block.
  for v_refund in
    select id, merchant, amount_cents from public.transactions
     where original_purchase_id = txn_id
       and kind = 'refund'
       and excluded is not true
       and state not in ('excluded', 'reversed')
  loop
    v_surv_count := 0;
    v_surv_id := null;
    if v_row.dedupe_hash is not null and v_row.dedupe_hash <> '' then
      select count(*), (array_agg(id))[1] into v_surv_count, v_surv_id
        from public.transactions
       where household_id = v_row.household_id
         and id <> txn_id
         and kind in ('charge', 'fund_charge')
         and excluded is not true
         and state not in ('excluded', 'reversed')
         and dedupe_hash = v_row.dedupe_hash;
    end if;
    if v_surv_count = 1 then
      update public.transactions
         set original_purchase_id = v_surv_id
       where id = v_refund.id;
      v_repointed := v_repointed + 1;
    else
      raise exception 'cannot exclude: a live refund (% % cents) is linked to this transaction — re-point the refund to its surviving purchase or exclude the refund first',
        v_refund.merchant, v_refund.amount_cents;
    end if;
  end loop;
  update transactions
    set excluded = true, state = 'excluded',
        exclude_reason = coalesce(reason, ''),
        pre_exclusion_state = case
          when v_row.state <> 'excluded' then v_row.state
          else v_row.pre_exclusion_state
        end
    where id = txn_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(),
            case when v_is_service then 'system (plaid-sync)' else 'admin' end,
            'Transaction excluded',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents excluded'
            || case when reason is not null and btrim(reason) <> ''
                    then ' — reason: ' || reason else ' — no reason given' end
            || case when v_repointed > 0
                    then ' (' || v_repointed::text || ' linked refund(s) re-pointed to the surviving purchase)'
                    else '' end || '.');
end;
$$;
revoke execute on function public.exclude_transaction(uuid, text) from public;
grant execute on function public.exclude_transaction(uuid, text) to authenticated;
grant execute on function public.exclude_transaction(uuid, text) to service_role;

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
--   pre-N4 excluded row with a NULL snapshot cannot be fixed by
--   re-exclude/re-restore (re-exclude preserves the NULL snapshot);
--   see the file header for the real remedies (one-off
--   owner-approved repair, or accept as unrestorable). Do NOT
--   silently re-add the fallback.
--
--   P2-NEW1 (Nov 8, 2026): restore now has the same 35-day locked-
--   week check as exclude/reclassify (P1-M2) — a locked week's
--   transactions are immutable through the mutation RPCs, and
--   restoring an excluded row re-enters it into compute-week's
--   live recompute for that week while week_closes keeps the
--   stored close. CHOICE: raise by default, with a documented
--   escape hatch — NOT a second bypass RPC (that would defeat
--   the lock) and NOT "restore is the sanctioned locked-week
--   path" (that would leave the P1-M2 hole open in reverse: any
--   locked-week row excluded before the week locked could be
--   re-entered at will). The sanctioned locked-week restore is a
--   ONE-OFF OWNER-APPROVED SQL REPAIR, run in the SQL editor
--   only, with an audit row, never from the app:
--     update transactions set excluded = false,
--       state = pre_exclusion_state, exclude_reason = '',
--       pre_exclusion_state = null
--       where id = '<txn-uuid>' and state = 'excluded'
--         and pre_exclusion_state is not null;
--     insert into audit_log (household_id, actor, actor_name,
--       action, detail) values ('<household-uuid>', auth.uid(),
--       'admin', 'Transaction restored (locked-week repair)',
--       'Restored <merchant> <amount> cents to its locked week
--        by owner-approved one-off repair.');
--   The repair refuses NULL snapshots by its own WHERE clause, so
--   it cannot silently resurrect one of the 23 unrestorable rows.
--   P2-N7 (Nov 8, 2026): after a successful restore, the row is
--   re-offered to the refund linker best-effort (below) so a
--   restored refund/purchase pair links without waiting for a
--   re-delivery. Linking never fails the restore.
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
  v_now date;
  v_cur_week date;
  v_tx_week date;
  v_restored_refunds integer := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- P2-NEW1 (Nov 8, 2026): same 35-day locked-week check as
  -- exclude/reclassify (P1-M2). A locked-week restore re-enters
  -- the row into compute-week's live recompute while week_closes
  -- keeps the stored close, so it raises here; the sanctioned
  -- locked-week path is the one-off owner-approved SQL repair
  -- documented in this function's header above.
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := v_row.date - extract(dow from v_row.date)::int;
  if v_cur_week > v_tx_week + 35 then
    raise exception 'week is locked: a locked-week transaction cannot be changed here';
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
  -- F-4 (owner-agreed, Nov 23, 2026): a refund that followed this
  -- purchase into exclusion (auto-excluded by auto_link_refund with
  -- exclude_reason 'Purchase excluded; ...' and its link to this
  -- purchase preserved) comes back WITH the purchase, to its own
  -- snapshotted state — restoring the purchase lets the refund
  -- count again. Only refunds the system excluded for exactly this
  -- reason are touched; a refund an admin excluded by hand stays
  -- excluded until the admin restores it.
  update transactions
     set excluded = false, state = pre_exclusion_state,
         exclude_reason = '', pre_exclusion_state = null
   where original_purchase_id = txn_id
     and kind = 'refund'
     and excluded = true
     and state = 'excluded'
     and pre_exclusion_state is not null
     and exclude_reason like 'Purchase excluded;%';
  get diagnostics v_restored_refunds = row_count;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Transaction restored',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents restored to the week as '
            || case when v_state = 'provisional' then 'pending' else 'posted' end
            || case when v_restored_refunds > 0
                    then ' (' || v_restored_refunds::text || ' linked refund(s) excluded with it restored too)'
                    else '' end || '.');
  -- P2-N7 (Nov 8, 2026): a restored row can become linkable (it was
  -- excluded when its pair arrived, or its counterpart arrived while
  -- it was in Trash). Offer it to the refund linker best-effort:
  -- a refund links to its purchase, a purchase picks up an earlier
  -- unlinked refund. The linker is SECURITY DEFINER-safe to call
  -- from here (same pattern as approve_fund_request calling
  -- approve_and_allocate), and a linking failure must never fail
  -- the restore, so errors are swallowed deliberately.
  begin
    if v_row.kind = 'refund' then
      perform public.auto_link_refund(txn_id);
    elsif v_row.kind in ('charge', 'fund_charge') then
      perform public.link_refunds_to_purchase(txn_id);
    end if;
  exception when others then
    null;
  end;
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
--   -- F-4: exclude a purchase with a live linked refund REFUSES
--   -- (as admin; throwaway purchase + linked refund):
--   select exclude_transaction('<purchase-with-refund>', 'test');
--     -- expect: ERROR 'cannot exclude: a live refund ... is linked
--     -- to this transaction'
--   -- F-4: exclude a DUPLICATE purchase whose refund can re-point
--   -- to the surviving identical purchase SUCCEEDS, and the refund
--   -- now points at the survivor:
--   select exclude_transaction('<duplicate-purchase>', 'duplicate');
--   select original_purchase_id from transactions
--    where id = '<refund>';  -- expect: the survivor's id
-- =====================================================================
