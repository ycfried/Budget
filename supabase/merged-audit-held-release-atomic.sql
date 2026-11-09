-- merged-audit-held-release-atomic.sql — Merged audit B10
-- CANONICAL DEFINITION of resolve_held_refund (P1-B4, Nov 8, 2026).
-- APPLIED LIVE Nov 8, 2026, 6:52–7:31 PM (R3 §2, recorded) and
-- verified: the live body contains the households FOR UPDATE
-- shortfall line and no decline/spend branches (marker checks:
-- elsif 0, decline 0, spend 0). The "NOT APPLIED BY THIS BRANCH"
-- note this header carried before is stale — P2-NEW4, Nov 8, 2026.
-- Do NOT re-apply blindly: re-apply only if a live probe shows the
-- live body has drifted from this file, and reconcile first.
-- P1-B4 follow-up (Nov 8, 2026): the households row is now locked
-- before the shortfall read (see the release branch), closing the
-- shortfall race the first atomic version kept.
--
-- WHY: resolve_held_refund (from restoration-snapshots.sql) selects
-- the held row, checks status='pending', then updates it without a
-- status condition. Two concurrent releases can both pass the
-- check and both post fund-ledger rows — a double release. This
-- replacement keeps every existing semantic (admin-only, release =
-- shortfall-first then fund_ledger kind='release' with no 7-day
-- pending; write_off/resolve = close with no money moved; audit
-- rows for both) and adds exactly two guards:
--   1. the row is locked (SELECT ... FOR UPDATE) for the whole RPC
--      transaction, so a second release for the same household row
--      blocks until the first commits;
--   2. the resolving UPDATE is conditional on status='pending'
--      and its row count is checked — if another run already
--      resolved it, this run raises 'held refund already resolved'
--      instead of posting money a second time.
-- A replayed release is therefore an error, never a second credit;
-- the client already shows an error toast on RPC failure.
create or replace function public.resolve_held_refund(p_held_id uuid, p_action text, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row held_refunds%rowtype;
  v_note text;
  v_shortfall integer;
  v_applied integer;
  v_to_fund integer;
  v_updated integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from held_refunds where id = p_held_id for update;
  if not found then raise exception 'held refund not found'; end if;
  if v_row.status <> 'pending' then raise exception 'held refund is not pending'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if p_action = 'release' then
    -- P1-B4 follow-up (Nov 8, 2026): lock the households row before
    -- reading the shortfall. The plain select + absolute update below
    -- raced a concurrent release (or week-close) for a DIFFERENT held
    -- row in the same household — both could read the same shortfall
    -- and the second write would clobber the first. FOR UPDATE
    -- serializes all shortfall writers for this household, the same
    -- pattern as approve_and_allocate's household-row lock.
    select fund_shortfall_cents into v_shortfall from households where id = v_row.household_id for update;
    if not found then raise exception 'household not found'; end if;
    v_shortfall := coalesce(v_shortfall, 0);
    v_applied := least(v_shortfall, v_row.held_cents);
    v_to_fund := v_row.held_cents - v_applied;
    if v_to_fund > 0 then
      insert into fund_ledger (household_id, kind, amount_cents, note, created_by)
        values (v_row.household_id, 'release', v_to_fund,
                'Held refund ' || p_held_id::text || ' released to spendable surplus.', auth.uid());
    end if;
    if v_applied > 0 then
      update households set fund_shortfall_cents = v_shortfall - v_applied where id = v_row.household_id;
    end if;
    v_note := nullif(btrim(coalesce(p_note, '')), '');
    if v_note is null then v_note := 'release'; end if;
    update held_refunds
      set status = 'resolved', resolved_at = now(), resolution_note = v_note
      where id = p_held_id and status = 'pending';
    get diagnostics v_updated = row_count;
    if v_updated = 0 then raise exception 'held refund already resolved'; end if;
    insert into audit_log (household_id, actor, actor_name, action, detail)
      values (v_row.household_id, auth.uid(), 'admin', 'Held refund released',
              'Held refund ' || p_held_id::text || ' released to spendable surplus: '
              || v_to_fund::text || ' cents to the fund, '
              || v_applied::text || ' cents offset shortfall.');
    return;
  end if;
  if p_action not in ('write_off', 'resolve') then
    raise exception 'unknown action: % (expected write_off, resolve, or release)', p_action;
  end if;
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if v_note is null then v_note := p_action; end if;
  update held_refunds
    set status = 'resolved', resolved_at = now(), resolution_note = v_note
    where id = p_held_id and status = 'pending';
  get diagnostics v_updated = row_count;
  if v_updated = 0 then raise exception 'held refund already resolved'; end if;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Held refund resolved',
            'Held refund ' || p_held_id::text || ' resolved via ' || p_action
            || ' (' || v_note || '). No money was moved.');
end;
$$;
revoke execute on function public.resolve_held_refund(uuid, text, text) from public;
grant execute on function public.resolve_held_refund(uuid, text, text) to authenticated;

-- Verification (synthetic household only): create a held refund
-- (refund beyond charge), release it once — queue + fund balance
-- must reconcile exactly (shortfall first, remainder to fund) —
-- then release it again: the second call must raise, and the fund
-- balance must not move a second time.
