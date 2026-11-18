-- Refund-link suggestion dismissals (Nov 9, 2026) — Review area
-- "Refund Links" section (live.js). A dismissed (refund, purchase)
-- pair must not reappear on refresh, so dismissals are stored, not
-- just hidden in the client.
--
-- WHAT THIS FILE DOES:
--   * refund_link_dismissals: one row per dismissed suggestion
--     pair. A pair is dismissed once: the unique constraint makes
--     a repeat dismiss a no-op, not a duplicate row.
--   * dismiss_refund_link_suggestion RPC (admin-only, SECURITY
--     DEFINER): records the dismissal with an audit row. It does
--     NOT link or unlink anything, and it does NOT delete the
--     refund or the purchase. There is deliberately no undismiss
--     RPC: a wrongly dismissed pair can still be linked by hand
--     from Actions → Link to Purchase on the refund row.
--
-- Apply via the Supabase SQL editor. Additive only; re-running is
-- safe (IF NOT EXISTS guards; the RPC is CREATE OR REPLACE).

create table if not exists refund_link_dismissals (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  refund_id uuid not null references transactions(id) on delete cascade,
  purchase_id uuid not null references transactions(id) on delete cascade,
  dismissed_by uuid,
  dismissed_at timestamptz not null default now(),
  unique (refund_id, purchase_id)
);
create index if not exists refund_link_dismissals_household_idx
  on refund_link_dismissals (household_id);

alter table refund_link_dismissals enable row level security;
drop policy if exists "members read own refund link dismissals" on refund_link_dismissals;
create policy "members read own refund link dismissals"
  on refund_link_dismissals for select
  using (household_id in (select household_id from household_members where user_id = auth.uid()));
grant select on refund_link_dismissals to authenticated;

create or replace function public.dismiss_refund_link_suggestion(
  p_refund_id uuid, p_purchase_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref transactions%rowtype;
  v_pur transactions%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_ref from transactions where id = p_refund_id;
  if not found then raise exception 'refund not found'; end if;
  select * into v_pur from transactions where id = p_purchase_id;
  if not found then raise exception 'purchase not found'; end if;
  if v_ref.household_id <> v_pur.household_id then raise exception 'refund and purchase are in different households'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_ref.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if v_ref.kind <> 'refund' then raise exception 'not a refund'; end if;
  insert into refund_link_dismissals (household_id, refund_id, purchase_id, dismissed_by)
    values (v_ref.household_id, p_refund_id, p_purchase_id, auth.uid())
    on conflict (refund_id, purchase_id) do nothing;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_ref.household_id, auth.uid(), 'admin', 'Refund link suggestion dismissed',
            'Dismissed the suggested link between refund ' || p_refund_id::text
            || ' (' || coalesce(v_ref.merchant, '') || ' ' || coalesce(v_ref.amount_cents, 0)::text
            || ' cents) and purchase ' || p_purchase_id::text
            || ' (' || coalesce(v_pur.merchant, '') || ' ' || coalesce(v_pur.amount_cents, 0)::text
            || ' cents). Nothing was linked or deleted.');
end;
$$;
revoke execute on function public.dismiss_refund_link_suggestion(uuid, uuid) from public;
grant execute on function public.dismiss_refund_link_suggestion(uuid, uuid) to authenticated;
