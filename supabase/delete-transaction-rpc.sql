-- Household Budget — delete_transaction RPC (Nov 1, 2026).
-- WHY: the live app needs a delete option, but deleting must stay
-- honest. A hand-entered (manual) purchase can be truly deleted —
-- it exists only in this app. A bank / email-alert / file row cannot
-- be erased: the bank would re-sync it on the next pull, so the app
-- must exclude those rows instead (the UI's "Remove" button does
-- that directly; this RPC refuses them). So this RPC:
--   * admin only (a member cannot delete the household's record);
--   * refuses any row whose source is not 'manual';
--   * hard-deletes the row and writes an audit row first, so the
--     deletion itself stays in the append-only audit log.
-- Granted to authenticated only, never to public.
-- MATH-NEW1 (Nov 9, 2026): locked-week 35-day check added — the same
-- rule as exclude/restore/reclassify (n4-pre-exclusion-state.sql) and
-- mark_transaction_charity. Deleting a not-yet-adjusted manual row in
-- a locked week would remove its pending late charge from the current
-- week's figures via latePart while the stored close keeps it, so the
-- delete refuses here like every other mutation RPC. Apply this file
-- live to land the fix (CREATE OR REPLACE, idempotent, no other
-- change); the copy in 04-admin-rpcs.sql §5 is kept identical in-repo.
create or replace function public.delete_transaction(p_transaction_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  hid uuid;
  src text;
  merch text;
  amt integer;
  tx_date date;
  v_now date;
  v_cur_week date;
  v_tx_week date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select household_id, source, merchant, amount_cents, date
    into hid, src, merch, amt, tx_date from transactions where id = p_transaction_id;
  if hid is null then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = hid and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- MATH-NEW1 (Nov 9, 2026): a locked week's transactions are immutable
  -- through the mutation RPCs — the same 35-day rule as
  -- exclude/restore/reclassify (P1-M2). Locked-week corrections go
  -- through restoration, never a direct edit or delete.
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := tx_date - extract(dow from tx_date)::int;
  if v_cur_week > v_tx_week + 35 then
    raise exception 'week is locked: a locked-week transaction cannot be changed here';
  end if;
  if src <> 'manual' then
    raise exception 'only hand-entered purchases can be deleted; bank records must be removed from the budget instead';
  end if;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (hid, auth.uid(), 'admin', 'Transaction deleted',
            merch || ' ' || amt::text || ' cents (manual entry) deleted by admin.');
  delete from transactions where id = p_transaction_id;
end;
$$;
revoke execute on function public.delete_transaction(uuid) from public;
grant execute on function public.delete_transaction(uuid) to authenticated;
