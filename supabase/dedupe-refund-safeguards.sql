-- Dedupe + refund-link safeguards (Nov 20, 2026 — Royal Farms + Walmart).
--
-- ROOT CAUSES (traced in code, not guessed):
--
-- (1) ROYAL FARMS $7.63 missed entirely. The pair had the SAME
--     dedupe_hash (identical merchant/date/amount/card), yet neither
--     the auto-merge fired nor a duplicate candidate was created.
--     Two independent holes, and the pair needed both to fail:
--       (a) The bank-first guard (gmail-poll / ingest-amex-alert
--           findCoveringBankRow) SHOULD have skipped the email
--           insert — on the current repo code it catches this exact
--           shape (pinned by a test in supabase/tests/auto-merge
--           .test.mjs). It did not fire live, so the deployed
--           gmail-poll is either older than the Nov 12 guard deploy
--           or the guard call failed transiently (findCoveringBankRow
--           swallows every error into a null return). That half
--           needs a live deploy/log check — it cannot be proven
--           from the repo. The owner-facing fix below does not
--           depend on answering it.
--       (b) PROVABLE: flagLookalikes never flags identical merchant
--           names. merchantsRelated() returns false when the
--           squashed names are equal (canonical.ts, pinned by a
--           test: identical names are "not lookalikes", the hash
--           is supposed to catch them), and flagLookalikes only
--           adds alias / same-rule-display evidence. ROYAL FARMS
--           vs ROYAL FARMS, with no alias and no rule, is therefore
--           never flagged — while Amazon (AMAZON vs AMAZON
--           MARKEPLACE NA PA), Toiremorg $1 (TOIREMORG vs TOIREMORG
--           CHARITY) and the other backlog pairs all had different
--           spellings, so the substring check caught them. The
--           identical-spelling pair was the one case the detector
--           was blind to, and it was exactly the case the guard
--           had already missed. This file does NOT change
--           merchantsRelated (pinned) — the fix is in
--           flagLookalikes itself (canonical.ts): identical names
--           across sources (Bank+Email) now flag. Same-source
--           identical rows stay unflagged (two real identical
--           purchases).
-- (2) WALMART REFUND linked to the wrong charge. The +$24.16 refund
--     (dad1d6d3) auto-linked to charge 5814fdab when that was the
--     only live charge (Nov 17). The duplicate resolution later
--     excluded 5814fdab and kept e714f189 live — but NO exclusion
--     path moves refund links: merge_bank_email_pair,
--     resolve_duplicate_candidate 'merge' and exclude_transaction
--     all exclude a row without touching original_purchase_id, and
--     link_refunds_to_purchase only links refunds whose
--     original_purchase_id IS NULL, so the refund could never
--     re-link. The refund kept restoring an already-excluded
--     purchase. (The removed[] LINK path in plaid-sync already
--     re-points refund links — this file extends that precedent to
--     every other exclusion path.)
--
-- WHAT THIS FILE ADDS (additive only; re-running is safe):
--   * repoint_refund_links(p_from_id, p_to_id) — move live refunds
--     linked to an excluded purchase onto a surviving purchase
--     (merge case), or unlink them (p_to_id NULL) so they can
--     re-link later instead of restoring nothing. A refund moves
--     only when it fits the target (same household, live charge,
--     room left); otherwise it is unlinked, never left dangling.
--     One audit row per refund moved or unlinked.
--   * merge_bank_email_pair — revised: after excluding the email
--     row, re-points its live linked refunds to the kept bank row.
--   * resolve_duplicate_candidate — revised 'merge' branch: after
--     excluding the duplicate row, re-points its live linked
--     refunds to the kept canonical row.
--   * exclude_transaction — revised: REFUSES to exclude a purchase
--     that has a live refund linked to it (raise with a clear
--     message). Merge paths never call this RPC — they move the
--     link themselves — so the block only affects the manual Trash
--     path. This is the owner rule Nov 20: linked rows must not
--     be breakable by excluding one side.
--   * repair_dangling_refund_links(p_household_id) — finds live
--     refunds whose original_purchase_id points at an excluded,
--     reversed or missing purchase and repairs them: re-link to a
--     unique live twin (same normalized merchant, exact amount,
--     same card, 90-day window, room left — the auto_link_refund
--     rules), otherwise unlink. One row per refund repaired.
--   * backstop_bank_email_pairs(p_household_id) — the periodic
--     sweep: (1) exact-hash Bank+Email pairs, both live, no
--     candidate yet — merge when bank_email_merge_check says ok
--     (same conservative rule as try_auto_merge_bank_email,
--     including the TOIREMORG refusal), otherwise create a pending
--     candidate; ambiguous (one bank row, several live email rows
--     sharing its hash) creates candidates and merges nothing;
--     (2) lookalike Bank+Email pairs (related merchant incl.
--     identical, same amount/kind, within 2 days, card equal or
--     unknown, both live, no candidate) — pending candidate only,
--     never merged; (3) repair dangling refund links. Idempotent:
--     any pair with a candidate row is skipped, merged pairs get a
--     'merged' candidate, and re-runs find nothing new. Returns
--     one row per action taken. Run it manually, from a pg_cron
--     job, or via the plaid-sync hook (best-effort RPC at the end
--     of a successful hourly sync — see
--     supabase/functions/plaid-sync/index.ts).
--
-- WHAT IT DOES NOT CHANGE: the dedupe rules, the TOIREMORG
-- never-merge rule (a TOIREMORG pair gets a pending candidate for
-- human review, never an auto-merge), the refund-restoration
-- model, or any owner decision. No rows are deleted anywhere.
--
-- DEPENDS ON (all applied live already — verify in STEP 0):
--   dedupe-review-queue.sql (duplicate_candidates),
--   auto-merge-bank-email.sql (bank_email_merge_check,
--   merge_bank_email_pair, merchants_related_for_merge),
--   merchant-rules.sql (merchant_rule_key),
--   refund-linking.sql (_same_normalized_merchant),
--   n4-pre-exclusion-state.sql (exclude_transaction).
--
-- APPLY: via the Supabase SQL editor, in order. DO NOT apply to
-- the live database without the owner decision — this file is the
-- prepared migration; the parent reports its path.
-- STEP 0 — VERIFY LIVE FIRST (read-only): the functions below must
--   exist live with the bodies in the repo (merge_bank_email_pair,
--   resolve_duplicate_candidate, exclude_transaction). If a live
--   probe shows any drifted, stop and reconcile before applying —
--   this file replaces those three bodies wholesale.
--   select proname from pg_proc where proname in
--     ('merge_bank_email_pair', 'resolve_duplicate_candidate',
--      'exclude_transaction', 'bank_email_merge_check',
--      'merchants_related_for_merge', '_same_normalized_merchant');

-- ---------------------------------------------------------------------
-- 1. repoint_refund_links(p_from_id, p_to_id) — move or unlink live
-- refunds linked to an excluded purchase. Returns how many refunds
-- were moved or unlinked. Service-role only: called from the merge /
-- exclude paths below and from plaid-sync (removed[] reversal).
-- ---------------------------------------------------------------------
create or replace function public.repoint_refund_links(p_from_id uuid, p_to_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref record;
  v_to public.transactions%rowtype;
  v_linked_total integer;
  v_fits boolean;
  v_moved integer := 0;
begin
  if p_from_id is null then return 0; end if;
  if p_to_id is not null then
    select * into v_to from public.transactions where id = p_to_id;
    if not found
       or v_to.excluded is true
       or v_to.state in ('excluded', 'reversed')
       or v_to.kind not in ('charge', 'fund_charge') then
      -- Target is gone or not a live purchase: fall through to
      -- unlinking. A refund is never left pointing at the
      -- excluded row.
      p_to_id := null;
    end if;
  end if;
  for v_ref in
    select * from public.transactions
     where original_purchase_id = p_from_id
       and kind = 'refund'
       and excluded is not true
       and state not in ('excluded', 'reversed')
     order by created_at asc
  loop
    v_fits := false;
    if p_to_id is not null and v_to.household_id = v_ref.household_id then
      -- The refund must fit in what the target has left to refund
      -- (same room check as link_refund).
      select coalesce(sum(abs(x.amount_cents)), 0) into v_linked_total
        from public.transactions x
       where x.original_purchase_id = p_to_id
         and x.kind = 'refund'
         and x.excluded is not true and x.state not in ('excluded', 'reversed');
      if abs(v_ref.amount_cents) + v_linked_total <= v_to.amount_cents then
        v_fits := true;
      end if;
    end if;
    if v_fits then
      update public.transactions set original_purchase_id = p_to_id where id = v_ref.id;
      insert into public.audit_log (household_id, actor, actor_name, action, detail)
      values (v_ref.household_id, null, 'system (refund-link guard)', 'Refund link moved',
              'Moved refund ' || v_ref.id::text || ' (' || coalesce(v_ref.merchant, '') || ' '
              || coalesce(v_ref.amount_cents, 0)::text
              || ' cents) from excluded purchase ' || p_from_id::text
              || ' to surviving purchase ' || p_to_id::text || '.');
    else
      update public.transactions set original_purchase_id = null where id = v_ref.id;
      insert into public.audit_log (household_id, actor, actor_name, action, detail)
      values (v_ref.household_id, null, 'system (refund-link guard)', 'Refund link removed',
              'Unlinked refund ' || v_ref.id::text || ' (' || coalesce(v_ref.merchant, '') || ' '
              || coalesce(v_ref.amount_cents, 0)::text
              || ' cents) from excluded purchase ' || p_from_id::text
              || ' - no surviving purchase to move it to, so it can re-link later.');
    end if;
    v_moved := v_moved + 1;
  end loop;
  return v_moved;
end;
$$;
revoke execute on function public.repoint_refund_links(uuid, uuid) from public;
revoke execute on function public.repoint_refund_links(uuid, uuid) from authenticated;
revoke execute on function public.repoint_refund_links(uuid, uuid) from anon;
grant execute on function public.repoint_refund_links(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------
-- 2. merge_bank_email_pair — REVISED (Nov 20, 2026). Body is the
-- repo version from supabase/auto-merge-bank-email.sql verbatim
-- plus the refund-link guard at the end of the email-row exclusion.
-- Keep this copy in step with that file.
-- ---------------------------------------------------------------------
create or replace function public.merge_bank_email_pair(
  p_bank_id uuid, p_email_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bank public.transactions%rowtype;
  v_email public.transactions%rowtype;
begin
  select * into v_bank from public.transactions where id = p_bank_id for update;
  select * into v_email from public.transactions where id = p_email_id for update;
  if not found then raise exception 'merge pair: row not found'; end if;
  -- Keep the bank row counted: if it was excluded (pending-queue
  -- pass only), bring it back to its prior state (or 'verified'
  -- when no prior state was recorded), not forced 'verified' — a
  -- pending bank row keeps its state.
  update public.transactions
     set excluded = false,
         state = case when state = 'excluded' then coalesce(pre_exclusion_state, 'verified') else state end,
         pre_exclusion_state = null
   where id = p_bank_id and (excluded or state = 'excluded');
  update public.transactions
     set excluded = true,
         state = 'excluded',
         pre_exclusion_state = case when v_email.state <> 'excluded' then v_email.state else v_email.pre_exclusion_state end,
         exclude_reason = 'Auto-merged into bank row ' || p_bank_id::text
           || ' (' || coalesce(v_bank.merchant, '') || '); same purchase, email alert kept as evidence, not deleted.'
   where id = p_email_id;
  -- Refund-link guard (Nov 20, 2026 — Walmart case): a refund may
  -- already link to the email row — it was the only live charge
  -- when the refund arrived. Excluding it without moving the link
  -- strands the refund on an excluded purchase, where it restores
  -- nothing. Move live linked refunds to the kept bank row.
  perform public.repoint_refund_links(p_email_id, p_bank_id);
  insert into public.duplicate_candidates
    (household_id, canonical_transaction_id, duplicate_transaction_id, reason,
     merchant_a, merchant_b, status, resolution_note, resolved_at)
  values
    (v_bank.household_id, p_bank_id, p_email_id, coalesce(p_reason, 'auto-merge'),
     v_bank.merchant, v_email.merchant, 'merged',
     'Auto-merged Bank+Email duplicate (build 30): bank row kept, email row excluded as evidence, not deleted.', now())
  on conflict (canonical_transaction_id, duplicate_transaction_id) do nothing;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (v_bank.household_id, null, 'system (auto-merge)', 'Duplicate merged',
          'Auto-merged email row ' || p_email_id::text || ' (' || coalesce(v_email.merchant, '')
          || ' ' || coalesce(v_email.amount_cents, 0)::text || ' cents) into bank row '
          || p_bank_id::text || ' (' || coalesce(v_bank.merchant, '') || ' '
          || coalesce(v_bank.amount_cents, 0)::text
          || ' cents). Email row excluded, not deleted.');
  return p_email_id;
end;
$$;
revoke execute on function public.merge_bank_email_pair(uuid, uuid, text) from public;
revoke execute on function public.merge_bank_email_pair(uuid, uuid, text) from authenticated;
revoke execute on function public.merge_bank_email_pair(uuid, uuid, text) from anon;
grant execute on function public.merge_bank_email_pair(uuid, uuid, text) to service_role;

-- ---------------------------------------------------------------------
-- 3. resolve_duplicate_candidate — REVISED (Nov 20, 2026). Body is
-- the repo version from supabase/dedupe-review-queue.sql verbatim
-- plus the refund-link guard in the 'merge' branch. Keep this copy
-- in step with that file.
-- ---------------------------------------------------------------------
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
    update transactions set excluded = true, state = 'excluded',
      pre_exclusion_state = case
        when v_dup.state <> 'excluded' then v_dup.state
        else v_dup.pre_exclusion_state
      end
      where id = v_cand.duplicate_transaction_id;
    -- Refund-link guard (Nov 20, 2026 — Walmart case): a refund
    -- may link to the duplicate row. Move live linked refunds to
    -- the kept canonical row so the refund restores the purchase
    -- that is actually counted.
    perform public.repoint_refund_links(v_cand.duplicate_transaction_id, v_cand.canonical_transaction_id);

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

-- ---------------------------------------------------------------------
-- 4. exclude_transaction — REVISED (Nov 20, 2026). Body is the
-- canonical version from supabase/n4-pre-exclusion-state.sql
-- verbatim plus the refund-link block before the exclusion UPDATE.
-- Keep this copy in step with that file. Do NOT apply
-- supabase/05-transaction-mutation-rpcs.sql in full (it would
-- reintroduce the N4 date bug and lose this guard).
-- ---------------------------------------------------------------------
create or replace function public.exclude_transaction(txn_id uuid, reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row transactions%rowtype;
  v_now date;
  v_cur_week date;
  v_tx_week date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- P1-M2 (Nov 8, 2026): a locked week's transactions are immutable
  -- through the mutation RPCs — the same 35-day rule as
  -- mark_transaction_charity (r13-charity.sql). Locked-week
  -- corrections go through restoration, never a direct edit.
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := v_row.date - extract(dow from v_row.date)::int;
  if v_cur_week > v_tx_week + 35 then
    raise exception 'week is locked: a locked-week transaction cannot be changed here';
  end if;
  -- Refund-link guard (Nov 20, 2026 — owner rule: linked rows must
  -- not be breakable): a purchase with a live refund linked to it
  -- cannot be excluded here — the refund would be stranded on an
  -- excluded purchase and restore nothing. Trash or unlink the
  -- refund first (unlink_refund), or re-link it to the surviving
  -- purchase, then exclude. Merge paths never call this RPC — they
  -- move the link themselves — so this block only affects the
  -- manual Trash path.
  if exists (select 1 from public.transactions r
              where r.original_purchase_id = txn_id
                and r.kind = 'refund'
                and r.excluded is not true
                and r.state not in ('excluded', 'reversed')) then
    raise exception 'this purchase has a linked refund - trash or unlink the refund first, then exclude';
  end if;
  update transactions
    set excluded = true, state = 'excluded',
        exclude_reason = coalesce(reason, ''),
        pre_exclusion_state = case
          when v_row.state <> 'excluded' then v_row.state
          else v_row.pre_exclusion_state
        end
    where id = txn_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Transaction excluded',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents excluded'
            || case when reason is not null and btrim(reason) <> ''
                    then ' — reason: ' || reason else ' — no reason given' end || '.');
end;
$$;
revoke execute on function public.exclude_transaction(uuid, text) from public;
grant execute on function public.exclude_transaction(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. repair_dangling_refund_links(p_household_id) — repair live
-- refunds whose original_purchase_id points at an excluded, reversed
-- or missing purchase (the Walmart breakage, already fixed by hand
-- live, and any future one the guards miss). For each: re-link to a
-- unique live twin (auto_link_refund rules — same normalized
-- merchant, exact amount, same card, purchase within 90 days before
-- the refund, room left), otherwise unlink so the refund can
-- re-link later instead of restoring nothing. One row per refund.
-- ---------------------------------------------------------------------
create or replace function public.repair_dangling_refund_links(p_household_id uuid)
returns table (refund_id uuid, action text, detail text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref record;
  v_twin_id uuid;
  v_twin_count integer;
begin
  for v_ref in
    select r.* from public.transactions r
     where r.household_id = p_household_id
       and r.kind = 'refund'
       and r.excluded is not true
       and r.state not in ('excluded', 'reversed')
       and r.original_purchase_id is not null
       and not exists (select 1 from public.transactions p
                        where p.id = r.original_purchase_id
                          and p.excluded is not true
                          and p.state not in ('excluded', 'reversed'))
     order by r.created_at asc
  loop
    select count(*), (array_agg(t.id))[1] into v_twin_count, v_twin_id
      from public.transactions t
     where t.household_id = v_ref.household_id
       and t.kind in ('charge', 'fund_charge')
       and t.excluded is not true
       and t.state not in ('excluded', 'reversed')
       and t.card_suffix = v_ref.card_suffix
       and public._same_normalized_merchant(t.merchant, v_ref.merchant)
       and t.amount_cents = -v_ref.amount_cents
       and t.date <= v_ref.date
       and t.date >= v_ref.date - interval '90 days'
       and (select coalesce(sum(abs(x.amount_cents)), 0) from public.transactions x
             where x.original_purchase_id = t.id
               and x.kind = 'refund'
               and x.excluded is not true and x.state not in ('excluded', 'reversed')) < t.amount_cents;
    if v_twin_count = 1 and v_twin_id is not null then
      update public.transactions set original_purchase_id = v_twin_id where id = v_ref.id;
      insert into public.audit_log (household_id, actor, actor_name, action, detail)
      values (v_ref.household_id, null, 'system (refund-link guard)', 'Refund link moved',
              'Re-linked refund ' || v_ref.id::text || ' (' || coalesce(v_ref.merchant, '') || ' '
              || coalesce(v_ref.amount_cents, 0)::text
              || ' cents) from its excluded purchase to live twin ' || v_twin_id::text || '.');
      refund_id := v_ref.id;
      action := 'refund-relinked';
      detail := 'Re-linked to unique live twin ' || v_twin_id::text || '.';
      return next;
    else
      update public.transactions set original_purchase_id = null where id = v_ref.id;
      insert into public.audit_log (household_id, actor, actor_name, action, detail)
      values (v_ref.household_id, null, 'system (refund-link guard)', 'Refund link removed',
              'Unlinked refund ' || v_ref.id::text || ' (' || coalesce(v_ref.merchant, '') || ' '
              || coalesce(v_ref.amount_cents, 0)::text
              || ' cents) from its excluded purchase - no unique live twin, so it can re-link later.');
      refund_id := v_ref.id;
      action := 'refund-unlinked';
      detail := 'No unique live twin - unlinked so it can re-link later.';
      return next;
    end if;
  end loop;
end;
$$;
revoke execute on function public.repair_dangling_refund_links(uuid) from public;
revoke execute on function public.repair_dangling_refund_links(uuid) from authenticated;
revoke execute on function public.repair_dangling_refund_links(uuid) from anon;
grant execute on function public.repair_dangling_refund_links(uuid) to service_role;

-- ---------------------------------------------------------------------
-- 6. backstop_bank_email_pairs(p_household_id) — the periodic sweep
-- (Nov 20, 2026 — Royal Farms). Catches Bank+Email pairs the
-- ingestion guards missed, plus dangling refund links. Idempotent
-- and safe to re-run: pairs with any candidate row are skipped,
-- merges use the approved bank_email_merge_check, TOIREMORG pairs
-- never merge (they get a pending candidate for human review),
-- lookalikes are flagged, never merged. One row per action taken.
-- Run manually from the SQL editor, from a pg_cron job, or via the
-- plaid-sync hook (hourly, best-effort).
-- ---------------------------------------------------------------------
create or replace function public.backstop_bank_email_pairs(p_household_id uuid)
returns table (bank_id uuid, email_id uuid, refund_id uuid, action text, detail text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pair record;
  v_check text;
  v_email_count integer;
  v_rep record;
begin
  -- Step 1: exact-hash Bank+Email pairs, both live, no candidate yet.
  for v_pair in
    select b.id as bank_id, e.id as email_id, b.dedupe_hash as bank_hash
      from public.transactions b
      join public.transactions e
        on e.household_id = b.household_id
       and e.dedupe_hash = b.dedupe_hash
       and e.source = 'amex_alert'
       and e.id <> b.id
     where b.household_id = p_household_id
       and b.source = 'plaid'
       and b.excluded is not true and b.state not in ('excluded', 'reversed')
       and e.excluded is not true and e.state not in ('excluded', 'reversed')
       and not exists (select 1 from public.duplicate_candidates c
                        where (c.canonical_transaction_id = b.id and c.duplicate_transaction_id = e.id)
                           or (c.canonical_transaction_id = e.id and c.duplicate_transaction_id = b.id))
     order by b.created_at asc, e.created_at asc
     limit 100
  loop
    -- Re-check live state now (the loop query is a snapshot — an
    -- earlier iteration in this same run may have merged one side).
    if exists (select 1 from public.transactions t
                where t.id in (v_pair.bank_id, v_pair.email_id)
                  and (t.excluded is true or t.state in ('excluded', 'reversed'))) then
      continue;
    end if;
    if exists (select 1 from public.duplicate_candidates c
                where (c.canonical_transaction_id = v_pair.bank_id and c.duplicate_transaction_id = v_pair.email_id)
                   or (c.canonical_transaction_id = v_pair.email_id and c.duplicate_transaction_id = v_pair.bank_id)) then
      continue;
    end if;
    -- Ambiguity (same rule as try_auto_merge_bank_email): one bank
    -- row matching several live email rows must merge none of them
    -- — which email belongs to which bank row cannot be known.
    -- Count ALL live email rows sharing the hash, not just the
    -- candidate-free ones, so the count is stable across
    -- iterations in this run.
    select count(*) into v_email_count
      from public.transactions e2
     where e2.household_id = p_household_id
       and e2.source = 'amex_alert'
       and e2.dedupe_hash = v_pair.bank_hash
       and e2.excluded is not true and e2.state not in ('excluded', 'reversed');
    if v_email_count > 1 then
      insert into public.duplicate_candidates
        (household_id, canonical_transaction_id, duplicate_transaction_id, reason,
         merchant_a, merchant_b, status, resolution_note)
      values (p_household_id, v_pair.bank_id, v_pair.email_id, 'backstop-ambiguous',
              (select merchant from public.transactions where id = v_pair.bank_id),
              (select merchant from public.transactions where id = v_pair.email_id),
              'pending',
              'Backstop: more than one live email row shares this bank row hash - needs a human decision.')
      on conflict (canonical_transaction_id, duplicate_transaction_id) do nothing;
      bank_id := v_pair.bank_id; email_id := v_pair.email_id; refund_id := null;
      action := 'candidate-created';
      detail := 'Backstop: ambiguous exact-hash pair - candidate created, nothing merged.';
      return next;
      continue;
    end if;
    v_check := public.bank_email_merge_check(v_pair.bank_id, v_pair.email_id, false);
    if v_check = 'ok' then
      perform public.merge_bank_email_pair(v_pair.bank_id, v_pair.email_id, 'backstop-exact-hash');
      bank_id := v_pair.bank_id; email_id := v_pair.email_id; refund_id := null;
      action := 'merged';
      detail := 'Backstop: exact-hash Bank+Email pair merged (bank row kept).';
      return next;
    else
      insert into public.duplicate_candidates
        (household_id, canonical_transaction_id, duplicate_transaction_id, reason,
         merchant_a, merchant_b, status, resolution_note)
      values (p_household_id, v_pair.bank_id, v_pair.email_id, 'backstop-lookalike',
              (select merchant from public.transactions where id = v_pair.bank_id),
              (select merchant from public.transactions where id = v_pair.email_id),
              'pending',
              'Backstop: exact-hash pair did not pass the merge check (' || v_check || ') - needs a human decision.')
      on conflict (canonical_transaction_id, duplicate_transaction_id) do nothing;
      bank_id := v_pair.bank_id; email_id := v_pair.email_id; refund_id := null;
      action := 'candidate-created';
      detail := 'Backstop: exact-hash pair failed the merge check - candidate created.';
      return next;
    end if;
  end loop;

  -- Step 2: lookalike Bank+Email pairs (related merchant including
  -- identical, same amount and kind, within 2 days, card equal or
  -- unknown, both live, no candidate yet, hash differs so step 1
  -- did not already handle them). Flagged for review only — never
  -- merged here.
  for v_pair in
    select b.id as bank_id, e.id as email_id
      from public.transactions b
      join public.transactions e
        on e.household_id = b.household_id
       and e.source = 'amex_alert'
       and e.amount_cents = b.amount_cents
       and e.kind = b.kind
       and abs(e.date - b.date) <= 2
       and (e.card_suffix = b.card_suffix or e.card_suffix = '0000' or b.card_suffix = '0000')
       and e.id <> b.id
     where b.household_id = p_household_id
       and b.source = 'plaid'
       and b.excluded is not true and b.state not in ('excluded', 'reversed')
       and e.excluded is not true and e.state not in ('excluded', 'reversed')
       and b.dedupe_hash is distinct from e.dedupe_hash
       and public.merchants_related_for_merge(b.household_id, b.merchant, e.merchant)
       and not exists (select 1 from public.duplicate_candidates c
                        where (c.canonical_transaction_id = b.id and c.duplicate_transaction_id = e.id)
                           or (c.canonical_transaction_id = e.id and c.duplicate_transaction_id = b.id))
     order by b.created_at asc, e.created_at asc
     limit 100
  loop
    if exists (select 1 from public.transactions t
                where t.id in (v_pair.bank_id, v_pair.email_id)
                  and (t.excluded is true or t.state in ('excluded', 'reversed'))) then
      continue;
    end if;
    if exists (select 1 from public.duplicate_candidates c
                where (c.canonical_transaction_id = v_pair.bank_id and c.duplicate_transaction_id = v_pair.email_id)
                   or (c.canonical_transaction_id = v_pair.email_id and c.duplicate_transaction_id = v_pair.bank_id)) then
      continue;
    end if;
    insert into public.duplicate_candidates
      (household_id, canonical_transaction_id, duplicate_transaction_id, reason,
       merchant_a, merchant_b, status, resolution_note)
    values (p_household_id, v_pair.bank_id, v_pair.email_id, 'backstop-lookalike',
            (select merchant from public.transactions where id = v_pair.bank_id),
            (select merchant from public.transactions where id = v_pair.email_id),
            'pending',
            'Backstop: lookalike Bank+Email pair - needs a human decision.')
    on conflict (canonical_transaction_id, duplicate_transaction_id) do nothing;
    bank_id := v_pair.bank_id; email_id := v_pair.email_id; refund_id := null;
    action := 'candidate-created';
    detail := 'Backstop: lookalike Bank+Email pair - candidate created.';
    return next;
  end loop;

  -- Step 3: repair dangling refund links.
  for v_rep in select * from public.repair_dangling_refund_links(p_household_id) loop
    bank_id := null; email_id := null; refund_id := v_rep.refund_id;
    action := v_rep.action; detail := 'Backstop: ' || v_rep.detail;
    return next;
  end loop;
end;
$$;
revoke execute on function public.backstop_bank_email_pairs(uuid) from public;
revoke execute on function public.backstop_bank_email_pairs(uuid) from authenticated;
revoke execute on function public.backstop_bank_email_pairs(uuid) from anon;
grant execute on function public.backstop_bank_email_pairs(uuid) to service_role;

-- =====================================================================
-- VERIFICATION (run on TEST data only, after applying — never on the
-- live household until the owner approves this file):
--   -- Royal-Farms shape: one live Plaid row + one live amex_alert
--   -- row, same dedupe_hash, no candidate. The backstop must merge
--   -- them (bank kept) and return one 'merged' row:
--   select * from backstop_bank_email_pairs('<test-household-uuid>');
--   -- Re-run: must return zero rows (idempotent — the merged
--   -- candidate now blocks the pair).
--   select * from backstop_bank_email_pairs('<test-household-uuid>');
--   -- Walmart shape: a live refund linked to an excluded charge
--   -- with one live twin. The backstop must return one
--   -- 'refund-relinked' row pointing at the twin:
--   select * from repair_dangling_refund_links('<test-household-uuid>');
--   -- Trash guard: excluding a charge with a live linked refund
--   -- must raise 'this purchase has a linked refund':
--   select exclude_transaction('<test-charge-uuid>', 'test');
-- =====================================================================
