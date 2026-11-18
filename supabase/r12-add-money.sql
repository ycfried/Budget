-- R12 Add Money — APPLIED LIVE Nov 3, 2026 (R12 chain: A1 grants,
-- dedupe, R3 nicknames, R12, R13, Amazon merge — all six files
-- applied in order via the SQL editor and verified. R4-BE-2,
-- Nov 9, 2026 — the "PREPARED ONLY" header this file carried
-- before is stale). Do NOT re-apply blindly: add_fund_money is
-- idempotent on the client key, but re-apply only if a live probe
-- shows the live body has drifted from this file, and reconcile
-- first.
--
-- What it adds: logging cash the admin already deposited into checking
-- as Extra Fund money. The admin-only RPC add_fund_money is the only
-- write path; it touches only the fund tables and the audit log:
--   * fund_topups — one row per top-up (the auditable record), with
--     the shortfall-first split stored on the row itself;
--   * fund_ledger — one 'adjustment' row, but ONLY for the part that
--     actually becomes spendable fund money (see split below);
--   * households.fund_shortfall_cents — reduced by the covered part;
--   * audit_log — one row stating the full split.
-- It never changes weekly allowance, spending, debt, locked weeks, or
-- any transaction row, and no bank sync ever calls it: a deposit that
-- arrives by bank sync does NOT become fund money on its own. The
-- client must send the same client key when retrying one submit, so
-- a double-tap or a retried request can never double-credit: a replay
-- returns the stored split and moves no money.
--
-- The split (owner decision, Nov 3, 2026: shortfall first):
--   covered = min(owed back, top-up); added = top-up - covered.
--   Example: owes $40 + $100 top-up -> covered $40, added $60, owes $0.
--   Example: owes $150 + $100 top-up -> covered $100, added $0, owes $50.
-- A top-up fully absorbed by the shortfall therefore adds no ledger
-- row (there is no new spendable money to record), but its fund_topups
-- row and audit row still record the whole top-up and the split.
-- The fund summary needs no change: Available is the ledger sum, so
-- only the spendable part ever raises it.
begin;
create table if not exists public.fund_topups (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  client_key text not null,
  amount_cents integer not null check (amount_cents > 0),
  shortfall_covered_cents integer not null default 0 check (shortfall_covered_cents >= 0),
  fund_added_cents integer not null default 0 check (fund_added_cents >= 0),
  shortfall_after_cents integer not null default 0 check (shortfall_after_cents >= 0),
  note text not null default '',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (household_id, client_key)
);
alter table public.fund_topups enable row level security;
drop policy if exists "members read own fund topups" on public.fund_topups;
create policy "members read own fund topups"
  on public.fund_topups for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
grant select on public.fund_topups to authenticated;

create or replace function public.add_fund_money(
  p_household_id uuid, p_amount_cents integer, p_note text, p_client_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shortfall integer;
  v_covered integer;
  v_added integer;
  v_after integer;
  v_key text;
  v_existing fund_topups%rowtype;
  v_note text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- Serialize concurrent top-ups against the same household row so
  -- two simultaneous saves cannot both cover the same shortfall.
  select fund_shortfall_cents into v_shortfall
    from public.households where id = p_household_id for update;
  if not found then raise exception 'household not found'; end if;
  v_shortfall := coalesce(v_shortfall, 0);
  v_key := nullif(btrim(coalesce(p_client_key, '')), '');
  if v_key is not null then
    select * into v_existing from public.fund_topups
     where household_id = p_household_id and client_key = v_key;
    if found then
      -- Idempotent replay: return the stored split, move no money.
      return jsonb_build_object(
        'amount_cents', v_existing.amount_cents,
        'shortfall_covered_cents', v_existing.shortfall_covered_cents,
        'fund_added_cents', v_existing.fund_added_cents,
        'shortfall_after_cents', v_existing.shortfall_after_cents,
        'replayed', true);
    end if;
  else
    -- No key supplied (no client should do this): still record the
    -- top-up once, under a fresh key, so the row stays unique.
    v_key := gen_random_uuid()::text;
  end if;
  v_covered := least(v_shortfall, p_amount_cents);
  v_added := p_amount_cents - v_covered;
  v_after := v_shortfall - v_covered;
  v_note := left(btrim(coalesce(p_note, '')), 120);
  insert into public.fund_topups
    (household_id, client_key, amount_cents, shortfall_covered_cents,
     fund_added_cents, shortfall_after_cents, note, created_by)
  values (p_household_id, v_key, p_amount_cents, v_covered,
          v_added, v_after, v_note, auth.uid());
  if v_added > 0 then
    insert into public.fund_ledger (household_id, kind, amount_cents, note, created_by)
    values (p_household_id, 'adjustment', v_added,
            'Manual top-up: ' || p_amount_cents::text || ' cents total; '
            || v_covered::text || ' cents covered shortfall; '
            || v_added::text || ' cents added to fund.'
            || case when v_note <> '' then ' Note: ' || v_note else '' end,
            auth.uid());
  end if;
  if v_covered > 0 then
    update public.households set fund_shortfall_cents = v_after where id = p_household_id;
  end if;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Extra Fund top-up recorded',
          'Manual top-up ' || p_amount_cents::text || ' cents: '
          || v_covered::text || ' cents covered shortfall, '
          || v_added::text || ' cents added to fund, '
          || v_after::text || ' cents owed back after.'
          || case when v_note <> '' then ' Note: ' || v_note else '' end);
  return jsonb_build_object(
    'amount_cents', p_amount_cents,
    'shortfall_covered_cents', v_covered,
    'fund_added_cents', v_added,
    'shortfall_after_cents', v_after,
    'replayed', false);
end;
$$;
revoke execute on function public.add_fund_money(uuid, integer, text, text) from public;
grant execute on function public.add_fund_money(uuid, integer, text, text) to authenticated;
commit;
