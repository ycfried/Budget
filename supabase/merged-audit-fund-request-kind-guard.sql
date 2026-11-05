-- merged-audit-fund-request-kind-guard.sql — Merged audit A16
-- PREPARED FOR OWNER-APPROVED APPLY — NOT APPLIED BY THIS BRANCH.
-- Do NOT apply from a merge: the parent applies it via the approved
-- browser SQL run after the owner has seen this exact file.
--
-- WHY: the server trigger validate_fund_request_txn() checks only
-- status=pending and transaction-household equality, never kind.
-- Client gating is the only kind check today, so a linked fund
-- request against a refund/transfer/payment row could be approved
-- against money that is not a charge. This guard closes it server-side.
--
-- LIVE PROBE (Nov 4, 2026, 10:12–10:18 PM, read-only): the trigger
-- trg_fund_request_validate EXISTS live, but its function body
-- contains NO 'kind' mention — the guard is ABSENT live and is
-- still needed. This file replaces only that function body; the
-- trigger itself is re-created idempotently below.
--
-- SCOPE, EXACT: a linked fund request (transaction_id not null)
-- requires the linked transaction's kind to be 'charge'. The
-- unlinked fund-form path (transaction_id null) is UNTOUCHED —
-- it never reaches the kind check. Existing status and household
-- checks are preserved verbatim.
create or replace function public.validate_fund_request_txn()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_kind text;
begin
  if TG_OP = 'INSERT' and NEW.status <> 'pending' then
    raise exception 'fund requests must be created as pending';
  end if;
  if TG_OP = 'INSERT' then
    if NEW.transaction_id is not null then
      if not exists (
        select 1 from transactions t
         where t.id = NEW.transaction_id
           and t.household_id = NEW.household_id
      ) then
        raise exception 'fund request transaction belongs to a different household';
      end if;
      select kind into v_kind from transactions where id = NEW.transaction_id;
      if v_kind is distinct from 'charge' then
        raise exception 'fund request transaction must be a charge';
      end if;
    end if;
  elsif NEW.transaction_id is distinct from OLD.transaction_id then
    if NEW.transaction_id is not null then
      if not exists (
        select 1 from transactions t
         where t.id = NEW.transaction_id
           and t.household_id = NEW.household_id
      ) then
        raise exception 'fund request transaction belongs to a different household';
      end if;
      select kind into v_kind from transactions where id = NEW.transaction_id;
      if v_kind is distinct from 'charge' then
        raise exception 'fund request transaction must be a charge';
      end if;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_fund_request_validate on fund_requests;
create trigger trg_fund_request_validate
  before insert or update on fund_requests
  for each row execute function public.validate_fund_request_txn();

-- Verification (synthetic household only): a fund request linked to
-- a transfer/payment/refund row must be rejected; a request linked
-- to a charge row and an unlinked request must still succeed.
