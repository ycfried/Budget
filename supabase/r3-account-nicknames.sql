-- R3 account nicknames — PREPARED ONLY, DO NOT APPLY without owner approval.
-- Nicknames are bound to stable Plaid ids (plaid_item_id + plaid_account_id),
-- never to a card suffix alone. card_suffix is stored only as a display hint
-- so the Transactions filter can show "••1005 · Everyday" — the key is the
-- Plaid account id, and a suffix shared by two accounts never maps to a
-- nickname in the filter (the UI drops ambiguous suffixes).
-- Writes go through the RPC only (admin-only, SECURITY DEFINER), following
-- the dedupe RPC pattern; there is no direct client write policy.
begin;
create table if not exists public.account_nicknames (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  plaid_item_id text not null,
  plaid_account_id text not null,
  card_suffix char(4),
  nickname text not null check (char_length(nickname) between 1 and 40),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, plaid_item_id, plaid_account_id)
);
alter table public.account_nicknames enable row level security;
drop policy if exists "members read own nicknames" on public.account_nicknames;
create policy "members read own nicknames"
  on public.account_nicknames for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
grant select on public.account_nicknames to authenticated;
create or replace function public.set_account_nickname(
  p_household_id uuid, p_plaid_item_id text, p_plaid_account_id text,
  p_card_suffix text, p_nickname text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if p_nickname is null or btrim(p_nickname) = '' then
    delete from public.account_nicknames
     where household_id = p_household_id
       and plaid_item_id = p_plaid_item_id
       and plaid_account_id = p_plaid_account_id;
    return;
  end if;
  insert into public.account_nicknames
    (household_id, plaid_item_id, plaid_account_id, card_suffix, nickname)
  values (p_household_id, p_plaid_item_id, p_plaid_account_id,
          nullif(btrim(p_card_suffix), ''), left(btrim(p_nickname), 40))
  on conflict (household_id, plaid_item_id, plaid_account_id)
  do update set nickname = excluded.nickname,
                card_suffix = excluded.card_suffix,
                updated_at = now();
end;
$$;
grant execute on function public.set_account_nickname(uuid, text, text, text, text) to authenticated;
commit;
