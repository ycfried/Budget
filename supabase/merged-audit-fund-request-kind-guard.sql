-- merged-audit-fund-request-kind-guard.sql — Merged audit A16
-- CANONICAL DEFINITION of validate_fund_request_txn() (P1-B6, Nov 8,
-- 2026). PREPARED FOR OWNER-APPROVED APPLY — NOT APPLIED BY THIS
-- BRANCH. Do NOT apply from a merge: the parent applies it via the
-- approved browser SQL run after the owner has seen this exact file.
-- LIVE PROBE (Nov 4, 2026, 10:12–10:18 PM, read-only): the trigger
-- trg_fund_request_validate EXISTS live, but its function body
-- contains NO 'kind' mention — the guard is ABSENT live and is
-- still needed. Apply this file (owner approval) to install it.
--
-- SCOPE, EXACT: a linked fund request (transaction_id not null)
-- requires the linked transaction's kind to be 'charge'. The
-- unlinked fund-form path (transaction_id null) is UNTOUCHED —
-- it never reaches the kind check. Existing status and household
-- checks are preserved verbatim. 'charge'-only is intended (P1-B6):
-- a fund_charge is already paid from the fund, so a request against
-- it would double-pay; refund/transfer/payment/income/cashback/
-- charity rows are not weekly spending, so there is nothing for
-- the fund to cover. The client gates the same way (doTxExtraFund
-- refuses non-charge rows before sending), so this trigger is
-- defence in depth for a stale or direct caller.
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
