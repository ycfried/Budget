-- Server-side sync: hourly safety-net cron job + 5-minute email check
-- (prepared Nov 2, 2026; email job added Nov 2, 2026).
--
-- What this does:
-- (1) once an hour, for every household row, POST to plaid-sync with
-- the service-key bearer, so connected banks are pulled even if no
-- Plaid webhook arrived and the app is closed. plaid-sync's cursor
-- logic makes duplicate triggers safe, and its in-code auth accepts
-- the service-key bearer (server path).
-- (2) every 5 minutes, for every household row, POST to gmail-poll
-- with the service-key bearer, so Amex Large Purchase alerts are
-- picked up automatically without anyone tapping "Check email now".
-- gmail-poll accepts the same server path (bearer + household_id);
-- it only fetches messages it hasn't already processed, so the
-- 5-minute polls are cheap Gmail reads, not full re-downloads.
--
-- OWNER STEP (one key, pasted in TWO spots, in the SQL Editor):
-- replace BOTH PASTE_SERVICE_KEY_HERE placeholders below with the
-- service_role key (API Keys page: Reveal on the masked service_role
-- row, then Copy) and run this file. The key then lives only in
-- these job definitions inside the project's own database. NEVER
-- commit a filled-in copy of this file to the repo.
--
-- Caveats (say plainly): the Free project pauses after 1 week idle,
-- and a paused project runs nothing, including cron. Pro ($25/mo)
-- never pauses. And while the Gmail connection stays unverified
-- (Testing mode), its refresh token expires after about 7 days, so
-- the automatic check quietly stops until the admin reconnects —
-- roughly a weekly reconnect until the app is verified.
--
-- Requires: pg_cron + pg_net (both verified installed Nov 2, 2026:
-- pg_cron 1.6.4, pg_net 0.20.4).

select cron.schedule(
  'hourly-plaid-sync',
  '0 * * * *',
  $$
  select net.http_post(
    url := 'https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/plaid-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer PASTE_SERVICE_KEY_HERE'
    ),
    body := jsonb_build_object('household_id', h.id)
  ) from households h;
  $$
);

select cron.schedule(
  'five-minute-gmail-poll',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/gmail-poll',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer PASTE_SERVICE_KEY_HERE'
    ),
    body := jsonb_build_object('household_id', h.id)
  ) from households h;
  $$
);
