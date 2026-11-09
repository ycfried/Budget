-- Dedupe review queue: database foundation for the forward fix to
-- email/bank double ingestion (Nov 3 Amazon $10.59 case).
--
-- WHY: email alerts and Plaid rows share no ID, and the canonical
-- hash only normalizes case/spacing — so a merchant spelled
-- differently on each side ("AMAZON" vs "AMAZON MARKEPLACE NA PA")
-- defeats the hash bridge and inserts a second row. Exact-hash and
-- provider-ID merges keep working; this file adds the safety net
-- for lookalike pairs that neither mechanism catches.
--
-- WHAT THIS FILE DOES (database only — no behavior change yet):
--   * duplicate_candidates: one row per lookalike pair flagged for
--     admin review. Status 'pending' / 'merged' / 'separate'.
--     A pair is never flagged twice: the detector must skip any
--     pair that already has a candidate row in any status.
--   * merchant_aliases: admin-confirmed merchant-name pairs
--     (e.g. AMAZON = AMAZON MARKEPLACE NA PA). Aliases alone merge
--     nothing; a future same-alias + same-date + same-amount +
--     same-suffix pair may auto-merge only under a separately
--     approved rule. Until then, aliases are evidence for review.
--   * resolve_duplicate_candidate RPC (admin-only, SECURITY
--     DEFINER): 'merge' keeps the canonical row and marks the
--     duplicate row excluded (never deleted) with an audit record;
--     'separate' keeps both rows and marks the pair reviewed.
--     Optionally records the merchant alias when merging.
--
-- WHAT IT DELIBERATELY DOES NOT DO:
--   * No detection hooks: plaid-sync / gmail-poll do not yet write
--     candidates (follow-up change, with tests: confirmed
--     duplicate, two real identical purchases, ambiguous pair).
--   * UI (this branch): live.js/live.html add an admin-only
--     "Possible duplicates" card on the Money tab, same pattern as
--     the restoration panel. It stays inert (shows a load error,
--     never an empty list) until this file is applied live.
--   * No auto-merge: lookalikes always wait for an admin decision
--     until an alias rule is separately approved.
--   * No write access for members: reads are household-member
--     scoped; the only write path is the admin-only RPC below.
--
-- Apply via the Supabase SQL editor. Additive only; re-running is
-- safe (IF NOT EXISTS guards; the RPC is CREATE OR REPLACE).

-- 1. Lookalike pairs awaiting an admin decision.
create table if not exists duplicate_candidates (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  canonical_transaction_id uuid not null references transactions(id) on delete cascade,
  duplicate_transaction_id uuid not null references transactions(id) on delete cascade,
  reason text not null default 'lookalike',
  merchant_a text not null,
  merchant_b text not null,
  status text not null default 'pending' check (status in ('pending', 'merged', 'separate')),
  resolution_note text,
  resolved_by uuid,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique (canonical_transaction_id, duplicate_transaction_id)
);
create index if not exists duplicate_candidates_household_status_idx
  on duplicate_candidates (household_id, status);

-- 2. Admin-confirmed merchant aliases (evidence, not an auto-merge).
create table if not exists merchant_aliases (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  name_a text not null,
  name_b text not null,
  confirmed_by uuid,
  created_at timestamptz not null default now(),
  unique (household_id, name_a, name_b)
);
create index if not exists merchant_aliases_household_idx
  on merchant_aliases (household_id);

-- 3. Household-member reads only.
alter table duplicate_candidates enable row level security;
alter table merchant_aliases enable row level security;
drop policy if exists "members read own duplicate candidates" on duplicate_candidates;
create policy "members read own duplicate candidates"
  on duplicate_candidates for select
  using (household_id in (select household_id from household_members where user_id = auth.uid()));
drop policy if exists "members read own merchant aliases" on merchant_aliases;
create policy "members read own merchant aliases"
  on merchant_aliases for select
  using (household_id in (select household_id from household_members where user_id = auth.uid()));
grant select on duplicate_candidates to authenticated;
grant select on merchant_aliases to authenticated;

-- 4. Admin-only resolution. Merge = link + exclude, never delete:
-- the duplicate row is flagged excluded (out of week math and lists
-- that hide excluded rows) and the candidate row itself is the
-- permanent link record between the two transactions.
create or replace function public.resolve_duplicate_candidate(
  p_candidate_id uuid, p_action text, p_note text, p_remember_alias boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cand duplicate_candidates%rowtype;
  v_dup transactions%rowtype;
  v_canon transactions%rowtype;
  v_note text;
  v_na text;
  v_nb text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  -- P2-B9 (Nov 8, 2026): lock the candidate row for the whole RPC
  -- transaction. The status check below ('pending') followed by the
  -- merge/separate update is a check-then-write: without the lock,
  -- two concurrent resolutions could both pass the check and both
  -- write audit rows (and both exclude the duplicate). The lock
  -- serializes resolutions of the same candidate; a second caller
  -- blocks until the first commits, then sees status <> 'pending'
  -- and raises.
  select * into v_cand from duplicate_candidates where id = p_candidate_id for update;
  if not found then raise exception 'duplicate candidate not found'; end if;
  if v_cand.status <> 'pending' then raise exception 'duplicate candidate is not pending'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_cand.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  select * into v_dup from transactions where id = v_cand.duplicate_transaction_id;
  if not found then raise exception 'duplicate transaction not found'; end if;
  select * into v_canon from transactions where id = v_cand.canonical_transaction_id;
  if not found then raise exception 'canonical transaction not found'; end if;
  if v_dup.household_id <> v_cand.household_id or v_canon.household_id <> v_cand.household_id then
    raise exception 'candidate transactions belong to another household';
  end if;
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if p_action = 'merge' then
    -- Deep audit Nov 5: must also set state='excluded' (as
    -- exclude_transaction does) — restore_transaction refuses any
    -- row whose state is not 'excluded', so a merge-only flag made
    -- a merged row unrestorable from Trash.
    update transactions set excluded = true, state = 'excluded' where id = v_cand.duplicate_transaction_id;
    if v_note is null then v_note := 'merge'; end if;
    update duplicate_candidates
      set status = 'merged', resolved_at = now(), resolved_by = auth.uid(), resolution_note = v_note
      where id = p_candidate_id;
    insert into audit_log (household_id, actor, actor_name, action, detail)
      values (v_cand.household_id, auth.uid(), 'admin', 'Duplicate merged',
              'Merged duplicate ' || v_cand.duplicate_transaction_id::text
              || ' (' || coalesce(v_dup.merchant, '') || ' ' || coalesce(v_dup.amount_cents, 0)::text
              || ' cents) into canonical ' || v_cand.canonical_transaction_id::text
              || ' (' || coalesce(v_canon.merchant, '') || ' ' || coalesce(v_canon.amount_cents, 0)::text
              || ' cents). Duplicate excluded, not deleted. Note: ' || v_note);
    if p_remember_alias then
      v_na := upper(regexp_replace(btrim(v_cand.merchant_a), '\s+', ' ', 'g'));
      v_nb := upper(regexp_replace(btrim(v_cand.merchant_b), '\s+', ' ', 'g'));
      if v_na > v_nb then
        insert into merchant_aliases (household_id, name_a, name_b, confirmed_by)
          values (v_cand.household_id, v_nb, v_na, auth.uid())
          on conflict (household_id, name_a, name_b) do nothing;
      else
        insert into merchant_aliases (household_id, name_a, name_b, confirmed_by)
          values (v_cand.household_id, v_na, v_nb, auth.uid())
          on conflict (household_id, name_a, name_b) do nothing;
      end if;
    end if;
    return;
  end if;
  if p_action = 'separate' then
    if v_note is null then v_note := 'separate'; end if;
    update duplicate_candidates
      set status = 'separate', resolved_at = now(), resolved_by = auth.uid(), resolution_note = v_note
      where id = p_candidate_id;
    insert into audit_log (household_id, actor, actor_name, action, detail)
      values (v_cand.household_id, auth.uid(), 'admin', 'Duplicate kept separate',
              'Kept ' || v_cand.canonical_transaction_id::text || ' and '
              || v_cand.duplicate_transaction_id::text
              || ' as separate purchases. Note: ' || v_note);
    return;
  end if;
  raise exception 'unknown action: % (expected merge or separate)', p_action;
end;
$$;
revoke execute on function public.resolve_duplicate_candidate(uuid, text, text, boolean) from public;
grant execute on function public.resolve_duplicate_candidate(uuid, text, text, boolean) to authenticated;
