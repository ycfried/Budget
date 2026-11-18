-- merged-audit-fund-request-kind-guard.sql — Merged audit A16
-- CANONICAL DEFINITION of validate_fund_request_txn() (P1-B6, Nov 8,
-- 2026). PREPARED FOR OWNER-APPROVED APPLY — but this file itself
-- was NEVER APPLIED LIVE, and must NOT be applied without a fresh
-- re-probe: the live trigger body already CONTAINS the kind guard
-- (read-only probe, Nov 8, 2026, R3 §3 P1-B6), so the guard reached
-- live by an earlier path and this file's "not applied yet" framing
-- above the LIVE STATE paragraph is stale (R4-BE-2, Nov 9, 2026).
-- Do NOT apply from a merge: the parent applies it via the approved
-- browser SQL run only after a probe shows the guard absent.
-- LIVE STATE (Nov 8, 2026, read-only probe, R3 §3 P1-B6): the live
-- trigger body CONTAINS the kind guard — the guard reached live
-- earlier, so the Nov 4 probe that found it ABSENT is superseded
-- and the old "guard is absent, apply this file" note below is
-- stale as a live-state claim (P2-NEW4). This file itself was NOT
-- among the six files applied Nov 8, 6:52–7:31 PM. One
-- pg_get_functiondef re-probe closes this definitively; do NOT
-- re-apply this file without that probe, and if the probe shows
-- the guard absent, apply this file (owner approval) to install it.
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
