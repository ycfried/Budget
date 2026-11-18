-- Household Budget — Extra Fund ledger + week closes (live slice).
-- WHY: the fund card showed requests but no balances, and every week
-- wrongly started at $0 because debt/credit never chained. These tables
-- are the fund's books (spec A4/A5): week_closes records each closed
-- week's outgoing debt/credit, surplus_releases tracks surplus from
-- "pending 7 days" to released, and fund_ledger is the fund's signed
-- ledger (available = sum of all rows, never negative by construction
-- except through a logged override).
--
-- FIN-REFUND-001 (still OPEN, owner-deferred): a week with excess
-- refunds, no debt, and no charges gets a surplus_release with status
-- 'held' — it NEVER auto-releases until the owner rules. Nothing here
-- invents that policy.
--
-- RLS pattern follows the rest of the live schema: members read their
-- own household's rows; writes go through SECURITY DEFINER RPCs
-- (allocations) or the admin-only week-close Edge Function, which
-- writes with the caller's JWT under these household-level policies.

create table if not exists week_closes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  week_start date not null,
  surplus_cents integer not null default 0,
  outgoing_debt_cents integer not null default 0,
  outgoing_credit_cents integer not null default 0,
  created_at timestamptz not null default now(),
  unique (household_id, week_start)
);

create table if not exists surplus_releases (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  week_start date not null,
  surplus_cents integer not null default 0,
  release_date date not null,
  status text not null default 'pending' check (status in ('pending', 'released', 'held')),
  released_cents integer not null default 0,
  created_at timestamptz not null default now(),
  unique (household_id, week_start)
);

create table if not exists fund_ledger (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  kind text not null check (kind in ('release', 'allocation', 'override_allocation', 'adjustment', 'reversal')),
  amount_cents integer not null,
  week_start date,
  request_id uuid references fund_requests(id) on delete set null,
  note text not null default '',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table households add column if not exists fund_shortfall_cents integer not null default 0;

alter table week_closes enable row level security;
alter table surplus_releases enable row level security;
alter table fund_ledger enable row level security;

grant select, insert, update on week_closes to authenticated;
grant select, insert, update on surplus_releases to authenticated;
grant select, insert on fund_ledger to authenticated;
grant update on fund_ledger to authenticated;

create policy "members read own week closes"
  on week_closes for select
  using (household_id in (select household_id from household_members where user_id = auth.uid()));
create policy "members write own week closes"
  on week_closes for insert with check (household_id in (select household_id from household_members where user_id = auth.uid()));
create policy "members update own week closes"
  on week_closes for update using (household_id in (select household_id from household_members where user_id = auth.uid()));

create policy "members read own surplus releases"
  on surplus_releases for select
  using (household_id in (select household_id from household_members where user_id = auth.uid()));
create policy "members write own surplus releases"
  on surplus_releases for insert with check (household_id in (select household_id from household_members where user_id = auth.uid()));
create policy "members update own surplus releases"
  on surplus_releases for update using (household_id in (select household_id from household_members where user_id = auth.uid()));

create policy "members read own fund ledger"
  on fund_ledger for select
  using (household_id in (select household_id from household_members where user_id = auth.uid()));
create policy "members write own fund ledger"
  on fund_ledger for insert with check (household_id in (select household_id from household_members where user_id = auth.uid()));

-- Allocation RPCs: admin-only, balance-checked, audit-logged.
-- approve_and_allocate: approve a member request AND move the money in
-- one step (the old approve_fund_request RPC recorded only the decision
-- and left the balance untouched — the audit's "approving visibly does
-- nothing" finding). amount may be less than requested (split).
-- allocate_fund: direct admin spending from the fund, no request.
-- Both refuse when amount > available UNLESS an override reason is
-- given, in which case the entry is kind 'override_allocation' and the
-- reason is logged. The fund may go negative ONLY via an override.
--
-- DO NOT RE-APPLY THE approve_and_allocate DEFINITION BELOW
-- (P1-B1, Nov 8, 2026). It is the WEAK version: no household-row
-- lock, no over-approval check, no linked-transaction household
-- check, it OVERWRITES fund_allocation_cents instead of
-- accumulating, and it records no decided_by / decided_at /
-- remainder_cents. The CANONICAL definition is
-- supabase/approve-ambiguity-fix.sql. Apply that file instead.
-- (The allocate_fund definition below is unaffected by this banner.)

create or replace function public.approve_and_allocate(p_request_id uuid, p_amount_cents integer, p_override_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req fund_requests%rowtype;
  v_available integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  select * into v_req from fund_requests where id = p_request_id;
  if not found then raise exception 'request not found'; end if;
  if v_req.status <> 'pending' then raise exception 'request is not pending'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_req.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  select coalesce(sum(amount_cents), 0) into v_available
    from fund_ledger where household_id = v_req.household_id;
  if p_amount_cents > v_available and (p_override_reason is null or btrim(p_override_reason) = '') then
    raise exception 'insufficient fund: available % cents', v_available;
  end if;
  insert into fund_ledger (household_id, kind, amount_cents, week_start, request_id, note, created_by)
    values (v_req.household_id,
            case when p_amount_cents > v_available then 'override_allocation' else 'allocation' end,
            -p_amount_cents, null, p_request_id,
            case when p_amount_cents > v_available then 'Override: ' || p_override_reason else coalesce(v_req.note, '') end,
            auth.uid());
  update fund_requests
    set status = case when p_amount_cents = v_req.amount_cents then 'approved' else 'split' end
    where id = p_request_id;
  if v_req.transaction_id is not null then
    update transactions set fund_allocation_cents = p_amount_cents where id = v_req.transaction_id;
  end if;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_req.household_id, auth.uid(), 'admin', 'Extra Fund request approved',
            'Request ' || p_request_id::text || ' approved for ' || p_amount_cents::text || ' cents'
            || case when p_amount_cents > v_available then ' (override: ' || p_override_reason || ')' else '' end || '.');
end;
$$;
revoke execute on function public.approve_and_allocate(uuid, integer, text) from public;
grant execute on function public.approve_and_allocate(uuid, integer, text) to authenticated;

create or replace function public.allocate_fund(p_household_id uuid, p_amount_cents integer, p_note text, p_override_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_available integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  select coalesce(sum(amount_cents), 0) into v_available
    from fund_ledger where household_id = p_household_id;
  if p_amount_cents > v_available and (p_override_reason is null or btrim(p_override_reason) = '') then
    raise exception 'insufficient fund: available % cents', v_available;
  end if;
  insert into fund_ledger (household_id, kind, amount_cents, week_start, request_id, note, created_by)
    values (p_household_id,
            case when p_amount_cents > v_available then 'override_allocation' else 'allocation' end,
            -p_amount_cents, null, null,
            case when p_amount_cents > v_available then 'Override: ' || p_override_reason || ' — ' || coalesce(p_note, '')
                 else coalesce(p_note, '') end,
            auth.uid());
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Extra Fund spending recorded',
            'Fund spending ' || p_amount_cents::text || ' cents'
            || case when p_amount_cents > v_available then ' (override: ' || p_override_reason || ')' else '' end || '.');
end;
$$;
revoke execute on function public.allocate_fund(uuid, integer, text, text) from public;
grant execute on function public.allocate_fund(uuid, integer, text, text) to authenticated;
