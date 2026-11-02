-- Household Budget — savings movement write path (decision 13, Nov 2, 2026).
-- WHY: the savings display already sums transfer_in / withdrawal /
-- interest kinds, but the only live write path was attest_savings
-- (kind 'adjustment', amount 0). This RPC records a real movement.
-- Movements are manual records of what the owner observed — they do
-- not move money, do not change the fund, and are never spending or
-- income. Admin only, audit-logged. Amounts are positive cents; the
-- kind gives the direction (the display takes abs() for withdrawals).
-- Apply via the SQL Editor (like the other supabase/*.sql files);
-- no function redeploy is involved.
create or replace function public.record_savings_entry(p_household_id uuid, p_kind text, p_amount_cents integer, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_kind not in ('transfer_in', 'withdrawal', 'interest') then
    raise exception 'unknown savings kind: % (expected transfer_in, withdrawal, or interest)', p_kind;
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  insert into savings_ledger (household_id, kind, amount_cents, attested_by, note, actual_balance_cents)
    values (p_household_id, p_kind, p_amount_cents, auth.uid(), coalesce(p_note, ''), null);
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Savings movement recorded',
            'Savings ' || p_kind || ': ' || p_amount_cents::text || ' cents.');
end;
$$;
revoke execute on function public.record_savings_entry(uuid, text, integer, text) from public;
grant execute on function public.record_savings_entry(uuid, text, integer, text) to authenticated;
