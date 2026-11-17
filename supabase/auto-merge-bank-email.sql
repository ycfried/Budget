-- Auto-merge Bank+Email duplicates (build 30, task I).
-- Applied via the Supabase SQL editor. Additive only; re-running is
-- safe (CREATE OR REPLACE RPCs; merges are idempotent — a pair with
-- any duplicate_candidates row is never merged twice).
--
-- WHAT IT IS: the approved provisional-merge take. When a bank row
-- (source 'plaid') and an email row (source 'amex_alert') are the
-- SAME purchase, they merge automatically: the bank row is kept and
-- stays counted, the email row is excluded (never deleted) with a
-- merged candidate record + audit entry, no manual review. The
-- email row is the alert; the bank row is the real purchase.
--
-- WHEN IT RUNS:
--   (a) At ingestion: plaid-sync calls try_auto_merge_bank_email
--       (best-effort, service-role) after inserting a NEW bank row.
--       The reverse direction needs no merge call: gmail-poll /
--       ingest-amex-alert skip the insert when a covering bank row
--       already exists (findCoveringBankRow in canonical.ts, same
--       eligibility rules), so the purchase is counted once via the
--       bank row.
--   (b) As a pass over the CURRENT pending queue:
--       auto_merge_pending_bank_email_duplicates(p_household_id)
--       walks every status='pending' duplicate candidate in the
--       household and merges the eligible Bank+Email pairs. This is
--       the pass that resolves the three flagged Amazon pairs
--       ($6.35, $79.99, $19.07 — see §4).
--
-- ELIGIBILITY (conservative — ALL must hold, mirrored in
-- canonical.ts autoMergeEligible; keep the two in step):
--   * one row source 'plaid' (bank), the other 'amex_alert'
--     (email). NEVER two bank rows, NEVER two email rows.
--   * same household, same signed amount_cents, same kind.
--   * dates within 2 days, either direction.
--   * card_suffix equal, or either side '0000' (unknown suffix,
--     not a different card — same rule as plaid-sync step 3b).
--   * neither row already excluded — EXCEPT the pending-queue pass
--     (§4), which un-excludes a bank row that was itself excluded,
--     because the merge decision keeps the bank row as THE row (the
--     $79.99 / $19.07 pairs arrive exactly like that: bank Excluded,
--     email Counted). The un-exclude is guarded: it never fires
--     when another merged candidate already lists that bank row as
--     its duplicate.
--   * merchant names related (squash-based, build 40 — STANDING
--     RULE, owner Nov 16, 2026): identical squashes, one squash
--     contains the other, a confirmed merchant_aliases pair, or
--     both map to the same merchant_rules display name. The squash
--     (UPPER + strip every non-alphanumeric) means slight spelling
--     differences — punctuation, case, whitespace — never block a
--     merge when date + amount + Email/Bank already match. No
--     fuzzy matching.
--
-- CRITICAL SAFEGUARDS:
--   (1) A pair with ANY duplicate_candidates row (any status) is
--       never auto-merged again. A pair the owner already resolved
--       as Separate stays separate forever; an already-merged pair
--       is never merged twice. The pending-queue pass only visits
--       status='pending' rows, and try_auto_merge checks for any
--       candidate row before merging.
--   (2) TOIREMORG NEVER merges: any pair where either merchant
--       contains 'TOIREMORG' (any spelling, normalized) is refused
--       outright — owner ruling Nov 3: the $2 bank "TOIREMORG" and
--       $2 email "TOIREMORG CHARITY" rows are TWO real gifts, not a
--       duplicate. This check is explicit and separate from the
--       merchant-relatedness check, so it survives any future
--       loosening of that check.
--   (3) Ambiguity refuses: if more than one email row could match
--       a bank row, nothing merges — the pair is left for manual
--       review (try_auto_merge records a pending 'auto-merge-
--       ambiguous' candidate so it surfaces in Review instead of
--       vanishing).
--
-- MERGE SEMANTICS (same as resolve_duplicate_candidate 'merge'):
-- the duplicate (email) row gets excluded=true AND state='excluded'
-- (so restore_transaction can bring it back), exclude_reason names
-- the bank row; the candidate row is the permanent link record.
-- Nothing is ever deleted.
--
-- DEPENDS ON: dedupe-review-queue.sql (duplicate_candidates,
-- merchant_aliases) and merchant-rules.sql (merchant_rules,
-- merchant_rule_match). If either table is missing the functions
-- fail loudly instead of merging on a guess.

-- 1. Merchant relatedness for merge purposes (SQL mirror of
-- canonical.ts merchantsRelated + alias + rule-display checks).
-- STANDING RULE (owner, Nov 16, 2026 — build 40): same date +
-- same amount + similar merchant + one Email + one Bank = the SAME
-- transaction and must auto-merge (bank row kept). Slight spelling
-- differences — punctuation (apostrophe), case, whitespace, minor
-- variation — must NOT prevent the merge. So the comparison uses
-- the SQUASH (UPPER + strip every non-alphanumeric), not the key
-- (which keeps internal punctuation): "Cocoaccino's" squashes to
-- "COCOACCINOS", same as "Cocoaccinos", but their keys
-- ("COCOACCINO'S" vs "COCOACCINOS") never matched, so the pair
-- never merged. No fuzzy matching: squash equality / substring
-- only. TOIREMORG never merges and ambiguity refuses — those
-- safeguards are separate and unchanged.
create or replace function public.merchants_related_for_merge(
  p_household_id uuid, p_merchant_a text, p_merchant_b text)
returns boolean
language sql
stable
set search_path = public
as $$
  select
    -- identical (squashed) names
    public.merchant_rule_squash(p_merchant_a) = public.merchant_rule_squash(p_merchant_b)
    -- one contains the other (squashed, min length 4, as in canonical.ts)
    or (length(public.merchant_rule_squash(p_merchant_a)) >= 4
        and length(public.merchant_rule_squash(p_merchant_b)) >= 4
        and (position(public.merchant_rule_squash(p_merchant_b) in public.merchant_rule_squash(p_merchant_a)) > 0
             or position(public.merchant_rule_squash(p_merchant_a) in public.merchant_rule_squash(p_merchant_b)) > 0))
    -- confirmed alias pair, either order (squashed)
    or exists (select 1 from public.merchant_aliases a
                where a.household_id = p_household_id
                  and ((public.merchant_rule_squash(a.name_a) = public.merchant_rule_squash(p_merchant_a)
                        and public.merchant_rule_squash(a.name_b) = public.merchant_rule_squash(p_merchant_b))
                       or (public.merchant_rule_squash(a.name_a) = public.merchant_rule_squash(p_merchant_b)
                           and public.merchant_rule_squash(a.name_b) = public.merchant_rule_squash(p_merchant_a))))
    -- both map to the same rule display name
    or exists (select 1
                 from public.merchant_rule_match(p_household_id, p_merchant_a) ma
                 join public.merchant_rule_match(p_household_id, p_merchant_b) mb
                   on ma.display_name = mb.display_name)
$$;

-- 2. Shared eligibility check. Returns 'ok' or the refusal reason.
-- p_bank_id must be the plaid row, p_email_id the amex_alert row.
-- p_allow_excluded_bank: true only for the pending-queue pass (§4),
-- where an excluded bank row is un-excluded as part of the merge.
create or replace function public.bank_email_merge_check(
  p_bank_id uuid, p_email_id uuid, p_allow_excluded_bank boolean)
returns text
language plpgsql
stable
set search_path = public
as $$
declare
  v_bank public.transactions%rowtype;
  v_email public.transactions%rowtype;
begin
  select * into v_bank from public.transactions where id = p_bank_id;
  if not found then return 'bank row not found'; end if;
  select * into v_email from public.transactions where id = p_email_id;
  if not found then return 'email row not found'; end if;
  if v_bank.source <> 'plaid' then return 'bank row is not plaid'; end if;
  if v_email.source <> 'amex_alert' then return 'email row is not amex_alert'; end if;
  if v_bank.household_id <> v_email.household_id then return 'different households'; end if;
  if v_bank.amount_cents <> v_email.amount_cents then return 'amount differs'; end if;
  if v_bank.kind <> v_email.kind then return 'kind differs'; end if;
  if abs(v_bank.date - v_email.date) > 2 then return 'dates more than 2 days apart'; end if;
  if v_bank.card_suffix <> v_email.card_suffix
     and v_bank.card_suffix <> '0000' and v_email.card_suffix <> '0000' then
    return 'card suffix differs';
  end if;
  -- Safeguard (2): TOIREMORG never merges, any spelling.
  if position('TOIREMORG' in public.merchant_rule_key(v_bank.merchant)) > 0
     or position('TOIREMORG' in public.merchant_rule_key(v_email.merchant)) > 0 then
    return 'toiremorg pair never auto-merges';
  end if;
  -- Safeguard (1): any prior candidate row blocks auto-merge.
  if exists (select 1 from public.duplicate_candidates c
              where (c.canonical_transaction_id = p_bank_id and c.duplicate_transaction_id = p_email_id)
                 or (c.canonical_transaction_id = p_email_id and c.duplicate_transaction_id = p_bank_id)) then
    return 'pair already resolved';
  end if;
  if not p_allow_excluded_bank
     and (v_bank.excluded or v_bank.state = 'excluded') then
    return 'bank row excluded';
  end if;
  if v_email.excluded or v_email.state = 'excluded' then return 'email row excluded'; end if;
  if not public.merchants_related_for_merge(v_bank.household_id, v_bank.merchant, v_email.merchant) then
    return 'merchants not related';
  end if;
  return 'ok';
end;
$$;

-- 3. Merge one pair. Caller must have run bank_email_merge_check
-- (or pass p_checked := true after doing so). The bank row is kept;
-- the email row is excluded with the merged candidate + audit
-- record. Returns the merged email row id.
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
  -- pass only — see §4), bring it back to its prior state (or
  -- 'verified' when no prior state was recorded), not forced
  -- 'verified' — a pending bank row keeps its state.
  update public.transactions
     set excluded = false,
         state = case when state = 'excluded' then coalesce(pre_exclusion_state, 'verified') else state end,
         pre_exclusion_state = null
   where id = p_bank_id and (excluded or state = 'excluded');
  update public.transactions
     set excluded = true,
         state = 'excluded',
         -- Build 30 fix (coordinator): snapshot the prior state
         -- like exclude_transaction does — without it,
         -- restore_transaction refuses the row ('cannot restore:
         -- no prior state recorded') and the merged row is
         -- unrestorable from Trash.
         pre_exclusion_state = case when v_email.state <> 'excluded' then v_email.state else v_email.pre_exclusion_state end,
         exclude_reason = 'Auto-merged into bank row ' || p_bank_id::text
           || ' (' || coalesce(v_bank.merchant, '') || '); same purchase, email alert kept as evidence, not deleted.'
   where id = p_email_id;
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
-- Dashboard / service-role only: never callable by a signed-in
-- client (the client merges through resolve_duplicate_candidate).
revoke execute on function public.merge_bank_email_pair(uuid, uuid, text) from public;
revoke execute on function public.merge_bank_email_pair(uuid, uuid, text) from authenticated;
revoke execute on function public.merge_bank_email_pair(uuid, uuid, text) from anon;
grant execute on function public.merge_bank_email_pair(uuid, uuid, text) to service_role;

-- 4. Ingestion-time entry point: try to auto-merge a NEW bank row
-- against its email alert row. Called by plaid-sync (service role,
-- best-effort) right after inserting a bank row. Returns a short
-- result string — 'merged:<email-id>', 'no-match', 'ambiguous',
-- or 'blocked: <reason>'. Never raises for an ineligible pair.
create or replace function public.try_auto_merge_bank_email(
  p_bank_txn_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bank public.transactions%rowtype;
  v_match record;
  v_count integer;
  v_check text;
begin
  select * into v_bank from public.transactions where id = p_bank_txn_id;
  if not found then return 'not-found'; end if;
  if v_bank.source <> 'plaid' then return 'not-bank-row'; end if;
  if v_bank.excluded or v_bank.state = 'excluded' then return 'blocked: bank row excluded'; end if;
  -- Candidate email rows: same household + amount + kind + date
  -- within 2 days. The merchant/card checks run per candidate in
  -- bank_email_merge_check; count the CHECK-PASSING ones, not the
  -- raw matches, so an unrelated same-amount row cannot make a
  -- genuine pair look ambiguous.
  select count(*) into v_count
    from public.transactions e
   where e.household_id = v_bank.household_id
     and e.source = 'amex_alert'
     and e.amount_cents = v_bank.amount_cents
     and e.kind = v_bank.kind
     and abs(e.date - v_bank.date) <= 2
     and public.bank_email_merge_check(p_bank_txn_id, e.id, false) = 'ok';
  if v_count = 0 then return 'no-match'; end if;
  if v_count > 1 then
    -- Ambiguous: refuse to guess. Surface the first matching pair
    -- in Review as a pending candidate so a human decides.
    select e.id into v_match
      from public.transactions e
     where e.household_id = v_bank.household_id
       and e.source = 'amex_alert'
       and e.amount_cents = v_bank.amount_cents
       and e.kind = v_bank.kind
       and abs(e.date - v_bank.date) <= 2
       and public.bank_email_merge_check(p_bank_txn_id, e.id, false) = 'ok'
     order by e.created_at asc limit 1;
    insert into public.duplicate_candidates
      (household_id, canonical_transaction_id, duplicate_transaction_id, reason,
       merchant_a, merchant_b, status, resolution_note)
    values (v_bank.household_id, p_bank_txn_id, v_match.id, 'auto-merge-ambiguous',
            v_bank.merchant,
            (select merchant from public.transactions where id = v_match.id),
            'pending',
            'Auto-merge refused: more than one email row matches this bank row; needs a human decision.')
    on conflict (canonical_transaction_id, duplicate_transaction_id) do nothing;
    return 'ambiguous';
  end if;
  select e.id into v_match
    from public.transactions e
   where e.household_id = v_bank.household_id
     and e.source = 'amex_alert'
     and e.amount_cents = v_bank.amount_cents
     and e.kind = v_bank.kind
     and abs(e.date - v_bank.date) <= 2
     and public.bank_email_merge_check(p_bank_txn_id, e.id, false) = 'ok'
   order by e.created_at asc limit 1;
  perform public.merge_bank_email_pair(p_bank_txn_id, v_match.id, 'auto-merge');
  return 'merged:' || v_match.id::text;
end;
$$;
revoke execute on function public.try_auto_merge_bank_email(uuid) from public;
revoke execute on function public.try_auto_merge_bank_email(uuid) from authenticated;
revoke execute on function public.try_auto_merge_bank_email(uuid) from anon;
grant execute on function public.try_auto_merge_bank_email(uuid) to service_role;

-- 5. Pending-queue pass: walk every status='pending' duplicate
-- candidate in the household and auto-merge the eligible Bank+Email
-- pairs. Run from the SQL editor (dashboard) after applying this
-- file. Returns one row per visited candidate: the candidate id,
-- the outcome ('merged' / 'skipped: <reason>'), and the kept bank
-- row id when merged.
--
-- THE THREE AMAZON PAIRS (Nov 15, real household — verify live
-- after running, see BUILD30_SERVER_DEPLOY.md):
--   * $6.35, Nov 15, both Counted — currently double-counting.
--     Merge excludes the email row; exactly one counted row left.
--   * $79.99, Bank Nov 14 Excluded / Email Nov 13 Counted.
--     Merge keeps the BANK row: the bank row is un-excluded and
--     the email row excluded — exactly one counted row, the bank's.
--   * $19.07, Bank Nov 13 Excluded / Email Nov 12 Counted.
--     Same as $79.99: bank row kept and counted, email excluded.
-- All three are amount + card + 2-day + merchant-related
-- (AMAZON / AMAZON MARKEPLACE NA PA) Bank+Email pairs with no
-- prior resolution, so this pass merges all three. If any pair is
-- NOT pending, or its kinds/card differ, it comes back 'skipped'
-- with the reason instead of merging on a guess — that is the
-- designed outcome, and the parent then resolves it by hand in
-- Review.
create or replace function public.auto_merge_pending_bank_email_duplicates(
  p_household_id uuid)
returns table (candidate_id uuid, outcome text, kept_bank_row_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cand record;
  v_bank_id uuid;
  v_email_id uuid;
  v_check text;
  v_bank public.transactions%rowtype;
begin
  for v_cand in
    select * from public.duplicate_candidates
     where household_id = p_household_id and status = 'pending'
     order by created_at asc
  loop
    -- Identify the bank row and the email row regardless of which
    -- side the candidate recorded as canonical.
    select id into v_bank_id from public.transactions
     where id in (v_cand.canonical_transaction_id, v_cand.duplicate_transaction_id)
       and source = 'plaid' limit 1;
    select id into v_email_id from public.transactions
     where id in (v_cand.canonical_transaction_id, v_cand.duplicate_transaction_id)
       and source = 'amex_alert' limit 1;
    if v_bank_id is null or v_email_id is null then
      candidate_id := v_cand.id;
      outcome := 'skipped: not a Bank+Email pair';
      kept_bank_row_id := null;
      return next;
      continue;
    end if;
    -- Safeguard (1) for the pair itself is the candidate's own
    -- pending status; but a DIFFERENT candidate row may already
    -- link this pair (merged/separate) — bank_email_merge_check
    -- catches that, because this pending row is itself a candidate
    -- row for the pair. So the check below runs with the pending
    -- row temporarily invisible: delete-then-check would lose the
    -- row, so instead check everything EXCEPT the prior-candidate
    -- rule here, and let the check function handle the rest.
    -- Practical approach: run the full check, but treat ONLY the
    -- 'pair already resolved' refusal as ignorable when the only
    -- candidate rows for the pair are this pending one.
    v_check := public.bank_email_merge_check(v_bank_id, v_email_id, true);
    if v_check = 'pair already resolved' then
      if not exists (select 1 from public.duplicate_candidates c
                      where c.id <> v_cand.id
                        and ((c.canonical_transaction_id = v_bank_id and c.duplicate_transaction_id = v_email_id)
                             or (c.canonical_transaction_id = v_email_id and c.duplicate_transaction_id = v_bank_id))) then
        v_check := 'ok';
      end if;
    end if;
    if v_check <> 'ok' then
      candidate_id := v_cand.id;
      outcome := 'skipped: ' || v_check;
      kept_bank_row_id := null;
      return next;
      continue;
    end if;
    -- Guard the un-exclude: if ANOTHER merged candidate already
    -- lists this bank row as its duplicate, the bank row was
    -- excluded as a duplicate of a third row — un-excluding it
    -- would resurrect a double-count. Refuse instead.
    if exists (select 1 from public.duplicate_candidates c
                where c.status = 'merged'
                  and c.duplicate_transaction_id = v_bank_id) then
      candidate_id := v_cand.id;
      outcome := 'skipped: bank row already merged away elsewhere';
      kept_bank_row_id := null;
      return next;
      continue;
    end if;
    -- Merge, then retire THIS pending candidate row: the merge
    -- itself inserts a 'merged' candidate for the pair, and the
    -- unique pair constraint forbids a second one — so delete the
    -- pending row first (it is superseded by the merged record).
    delete from public.duplicate_candidates where id = v_cand.id;
    perform public.merge_bank_email_pair(v_bank_id, v_email_id, 'auto-merge-pending-queue');
    candidate_id := v_cand.id;
    outcome := 'merged';
    kept_bank_row_id := v_bank_id;
    return next;
  end loop;
end;
$$;
-- Dashboard-run only (postgres in the SQL editor bypasses grants);
-- service_role may call it for a scripted pass. Never a client RPC.
revoke execute on function public.auto_merge_pending_bank_email_duplicates(uuid) from public;
revoke execute on function public.auto_merge_pending_bank_email_duplicates(uuid) from authenticated;
revoke execute on function public.auto_merge_pending_bank_email_duplicates(uuid) from anon;
grant execute on function public.auto_merge_pending_bank_email_duplicates(uuid) to service_role;
