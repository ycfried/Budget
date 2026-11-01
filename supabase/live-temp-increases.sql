-- Household Budget — temporary weekly increases (live slice).
-- WHY: the engine takes a per-week temporary increment T, but the live
-- app had no way to set it — compute-week defaulted T to 0. This adds
-- a temp_increases table (one row per admin grant, never edited) and
-- an admin-only RPC to add one. The live app sums the rows for the
-- current week and passes T to compute-week on every dashboard load,
-- so the allowance math reflects grants without redeploying
-- compute-week itself. Granted to authenticated only, never public.
-- RLS: members may read their household's rows; writes go only
-- through the RPC (admin-checked, audit-logged).

create table if not exists temp_increases (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  week_start date not null,
  amount_cents integer not null check (amount_cents > 0),
  note text not null default '',
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

alter table temp_increases enable row level security;

-- Table grants (lesson from Nov 1: RLS policies alone do not grant
-- table access — authenticated needs SELECT here or every read fails
-- with "permission denied for table" before RLS is even consulted).
grant select on temp_increases to authenticated;

create policy "members read own temp increases"
  on temp_increases for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));

create or replace function public.add_temp_increase(p_household_id uuid, p_week_start date, p_amount_cents integer, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'increase must be positive'; end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  insert into temp_increases (household_id, week_start, amount_cents, note, created_by)
    values (p_household_id, p_week_start, p_amount_cents, coalesce(p_note, ''), auth.uid());
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Temporary increase added', 'Temporary increase ' || p_amount_cents::text || ' cents for week ' || p_week_start::text || '.');
end;
$$;
revoke execute on function public.add_temp_increase(uuid, date, integer, text) from public;
grant execute on function public.add_temp_increase(uuid, date, integer, text) to authenticated;
