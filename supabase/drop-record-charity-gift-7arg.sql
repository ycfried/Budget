-- R4-BE-1 live cleanup (Nov 9, 2026) — run once in the Supabase SQL
-- editor, owner approval required. Drops ONLY the stale 7-arg
-- record_charity_gift overload (live oid 18701, pre-idempotency, no
-- replay protection), resurrected by the Nov 9 P2 step-4 apply of
-- supabase/r13-charity.sql. The 8-arg idempotent overload (oid 18506)
-- is untouched, and the live app calls it exclusively (live.js:4015
-- always sends p_client_key). No other statement belongs in this file.

drop function if exists public.record_charity_gift(uuid, text, integer, date, text, text, text);

-- Verification (read-only, run after applying — expect exactly ONE row,
-- the 8-arg overload):
--   select oid, proname, pg_get_function_identity_arguments(oid)
--     from pg_proc where proname = 'record_charity_gift';
--   -- expected: one row, args
--   -- (uuid, text, integer, date, text, text, text, text)
