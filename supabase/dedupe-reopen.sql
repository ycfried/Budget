-- Reopen a duplicate review (Nov 9, 2026) — the "slightly better
-- merging system" follow-up to dedupe-review-queue.sql.
--
-- WHY: 'separate' was permanent — the detector skips any pair that
-- already has a candidate row in any status, so a pair marked
-- Separate by mistake could never be reviewed again. A merged pair
-- already has its undo: the duplicate row sits excluded in Trash
-- and restore_transaction brings it back. A separate pair had no
-- undo at all.
--
-- WHAT THIS FILE DOES: one RPC, reopen_duplicate_candidate
-- (admin-only, SECURITY DEFINER). It moves a 'separate' candidate
-- back to 'pending' with an audit row, so the pair shows in
-- Possible Duplicates again. It refuses 'merged' candidates (their
-- undo is Trash restore, not reopen — reopening a merged pair
-- would re-present a pair whose duplicate is already excluded)
-- and 'pending' candidates (nothing to reopen). The duplicate and
-- canonical rows themselves are untouched.
--
-- Apply via the Supabase SQL editor. Additive only; re-running is
-- safe (the RPC is CREATE OR REPLACE).

create or replace function public.reopen_duplicate_candidate(p_candidate_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cand duplicate_candidates%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_cand from duplicate_candidates where id = p_candidate_id for update;
  if not found then raise exception 'duplicate candidate not found'; end if;
  if v_cand.status = 'pending' then raise exception 'duplicate candidate is already pending'; end if;
  if v_cand.status = 'merged' then raise exception 'a merged pair is undone from Trash, not by reopening'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_cand.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  update duplicate_candidates
    set status = 'pending', resolved_at = null, resolved_by = null, resolution_note = null
    where id = p_candidate_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_cand.household_id, auth.uid(), 'admin', 'Duplicate review reopened',
            'Reopened the duplicate review for ' || v_cand.canonical_transaction_id::text
            || ' and ' || v_cand.duplicate_transaction_id::text
            || ' (' || coalesce(v_cand.merchant_a, '') || ' / ' || coalesce(v_cand.merchant_b, '')
            || '). The pair shows in Possible Duplicates again.');
end;
$$;
revoke execute on function public.reopen_duplicate_candidate(uuid) from public;
grant execute on function public.reopen_duplicate_candidate(uuid) to authenticated;
