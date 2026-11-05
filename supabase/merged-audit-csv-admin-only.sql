-- merged-audit-csv-admin-only.sql — Merged audit A16
-- PREPARED FOR OWNER-APPROVED APPLY — NOT APPLIED BY THIS BRANCH.
-- Do NOT apply from a merge: the parent applies it via the approved
-- browser SQL run after the owner has seen this exact file.
--
-- WHY: live policies (probe Nov 4, 2026, 10:12–10:18 PM) allow any
-- household member to INSERT transactions with source 'manual' or
-- 'csv' in state 'provisional'. The CSV import UI already refuses
-- non-admins, but that is client-only: a member could still insert
-- a bulk CSV row directly. Manual single-row entry is member-
-- allowed BY DESIGN and stays that way.
--
-- WHAT THIS DOES: replaces the member INSERT policy so that
-- source='manual' stays member-allowed, but source='csv' requires
-- the caller to be an admin of the household. State must still be
-- 'provisional', and the household must still be the caller's own.
-- No other policy or grant changes. Member SELECT/INSERT grants on
-- transactions are unchanged (live: SELECT+INSERT only, no
-- UPDATE/DELETE — already correct).
drop policy if exists "members insert own transactions" on transactions;

create policy "members insert own transactions"
  on transactions for insert
  with check (
    household_id in (select household_id from household_members
                     where user_id = auth.uid())
    and source in ('manual', 'csv')
    and state = 'provisional'
    and (source = 'manual'
         or exists (select 1 from household_members
                    where household_id = transactions.household_id
                      and user_id = auth.uid()
                      and role = 'admin'))
  );

-- Verification (synthetic household only): a member CSV insert must
-- fail; a member manual insert and an admin CSV insert must succeed.
