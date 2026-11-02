-- Server-side sync: hourly safety-net cron job (prepared Nov 2, 2026).
--
-- What this does: once an hour, for every household row, POST to
-- plaid-sync with the service-key bearer, so connected banks are
-- pulled even if no Plaid webhook arrived and the app is closed.
-- plaid-sync's cursor logic makes duplicate triggers safe, and its
-- in-code auth accepts the service-key bearer (server path).
--
-- OWNER STEP (one paste, in the SQL Editor): replace
-- PASTE_SERVICE_KEY_HERE below with the service_role key (API Keys
-- page: Reveal on the masked service_role row, then Copy) and run
-- this file. The key then lives only in this job definition inside
-- the project's own database. NEVER commit a filled-in copy of this
-- file to the repo.
--
-- Caveats (say plainly): the Free project pauses after 1 week idle,
-- and a paused project runs nothing, including cron. Pro ($25/mo)
-- never pauses. Frequency is hourly, not 5-minute (approved
-- recommendation: banks post only a few times a day).
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
