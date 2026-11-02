-- =====================================================================
-- S1 migration 05 — Transaction mutation RPCs (admin-only, audited)
-- Deploy order: FIFTH of the five S1 files (01..05).
-- Depends on: schema.sql (transactions, household_members,
--   audit_log) and 02-rls-hardening.sql (which revoked direct member
--   UPDATE on transactions — these SECURITY DEFINER RPCs are the
--   replacement write path, and are unaffected by that revoke).
--
-- What this fixes (audit):
--   P0-3  Exclude / restore / reclassify were direct client
--         .update() calls gated only by UI hiding. They now go
--         through admin-checked RPCs that validate same-household
--         membership, enforce the admin role server-side, and write
--         an audit row with the reason. The UI workstream must
--         switch live.js exclude/restore/remove handlers to these
--         RPCs at the same deploy; until it does, those buttons
--         fail (direct UPDATE is revoked by 02) — flagged in
--         INTERFACE.md.
--   Spec A7: only the admin can exclude a transaction, with a
--         reason; a transaction can be split between normal and
--         fund only by the admin (split itself is approve_and_
--         allocate in 04, not here); reclassification is admin-only.
--
-- Shared rules for all three RPCs:
--   * caller must be authenticated AND an admin of the transaction's
--     household (membership in that household is implied by the
--     admin check — an admin of household A cannot mutate household
--     B's rows, because the check is scoped to the row's household).
--   * every mutation writes exactly one audit_log row (actor identity
--     is then forced server-side by the 04 trigger).
--   * the delete path is NOT duplicated here: delete_transaction()
--     (04, admin + source='manual' only) already exists and is the
--     only delete path. "Remove from budget" for bank rows is
--     exclude_transaction(), not a delete.
-- =====================================================================

-- Common shape note: argument names follow the S1 interface contract
-- exactly (txn_id, reason / new_kind), so other workstreams' RPC
-- calls match. Positional calls work regardless of names.

-- ---------------------------------------------------------------------
-- exclude_transaction(txn_id uuid, reason text) returns void
--   Sets excluded = true AND state = 'excluded', stores the reason
--   in exclude_reason, and audits with the reason.
--   Reason handling (flagged ambiguity — see INTERFACE.md): the
--   brief requires the audit row to carry the reason but does not
--   say a blank reason must be rejected, while spec A7 says
--   exclusion needs a reason. This RPC ACCEPTS a blank reason and
--   stores/audits it verbatim rather than inventing a rejection the
--   brief did not specify; the parent should rule whether blank
--   reasons must raise. Re-excluding an already-excluded row is
--   allowed (idempotent retry: updates the reason and audits again)
--   rather than raising, so a retried tap cannot wedge the UI.
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
        exclude_reason = coalesce(reason, '')
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
--   Reverses an exclusion: excluded = false, exclude_reason cleared,
--   state restored. Raises if the row is not currently excluded, so
--   a restore call cannot invent a state on a live row.
--   RESTORE TARGET STATE (flagged ambiguity — see INTERFACE.md):
--   the schema stores NO pre-exclusion state, so there is nothing
--   to restore TO. This RPC mirrors the existing live.js rule
--   (documented choice in live.js restore handler): a transaction
--   dated before today (America/New_York, the household timezone
--   per spec A2) restores to 'verified' (posted), dated today or
--   later restores to 'provisional' (pending). A restored pending
--   row still becomes verified once the bank confirms it. If the
--   parent wants a stored pre-exclusion state instead, that needs a
--   new column + an exclude-time snapshot — not built here, because
--   the brief's signature (txn_id only) carries no state argument.
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
  v_state := case when v_row.date < v_today then 'verified' else 'provisional' end;
  update transactions
    set excluded = false, state = v_state, exclude_reason = ''
    where id = txn_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Transaction restored',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents restored to the week as '
            || case when v_state = 'provisional' then 'pending' else 'posted' end || '.');
end;
$$;
revoke execute on function public.restore_transaction(uuid) from public;
grant execute on function public.restore_transaction(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- reclassify_transaction(txn_id uuid, new_kind text, reason text)
-- returns void
--   Changes kind (charge / refund / fund_charge — the values the
--   transactions CHECK constraint already allows; anything else
--   raises here with a clear message before the constraint fires).
--   Writes an audit row with old -> new kind and the reason.
--   Deliberately NOT restricted by state or source: the brief does
--   not scope reclassification, and an excluded row's kind may
--   legitimately need correcting before it is restored. The reason
--   is recorded in the audit detail (there is no reclassify_reason
--   column on transactions, and adding one was not in scope).
-- ---------------------------------------------------------------------
create or replace function public.reclassify_transaction(txn_id uuid, new_kind text, reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row transactions%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if new_kind is null or new_kind not in ('charge', 'refund', 'fund_charge', 'payment', 'cashback') then
    raise exception 'invalid kind: must be charge, refund, fund_charge, payment, or cashback';
  end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  update transactions set kind = new_kind where id = txn_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Transaction reclassified',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents reclassified from '
            || v_row.kind || ' to ' || new_kind
            || case when reason is not null and btrim(reason) <> ''
                    then ' — reason: ' || reason else ' — no reason given' end || '.');
end;
$$;
revoke execute on function public.reclassify_transaction(uuid, text, text) from public;
grant execute on function public.reclassify_transaction(uuid, text, text) to authenticated;

-- =====================================================================
-- VERIFICATION (commented — run manually after deploy, on test data):
--   -- As a NON-admin member, all three raise 'admin only':
--   select exclude_transaction('<txn>', 'test');
--   select restore_transaction('<excluded-txn>');
--   select reclassify_transaction('<txn>', 'refund', 'test');
--   -- As an admin, exclude sets both flags + reason + audit row:
--   select exclude_transaction('<txn>', 'duplicate');
--   select excluded, state, exclude_reason from transactions
--     where id = '<txn>';  -- true, 'excluded', 'duplicate'
--   select action, detail from audit_log where household_id =
--     '<household>' order by created_at desc limit 1;
--     -- 'Transaction excluded' ... 'reason: duplicate'
--   -- Restore of a past-dated row -> 'verified', excluded false:
--   select restore_transaction('<txn>');
--   select excluded, state from transactions where id = '<txn>';
--     -- false, 'verified' (if date < today NY) else 'provisional'
--   -- Restore of a non-excluded row raises:
--   select restore_transaction('<live-txn>');
--     -- expect: 'transaction is not excluded'
--   -- Bad kind raises before any write:
--   select reclassify_transaction('<txn>', 'gift', 'test');
--     -- expect: 'invalid kind'
--   -- Cross-household attempt (admin of A, txn of B) raises
--   -- 'admin only' — the check is scoped to the row's household.
-- =====================================================================
