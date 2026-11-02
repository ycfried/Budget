-- Household Budget — S3 migration: per-household ingest secrets +
-- replay nonces (audit P1-2). Apply before deploying the rewritten
-- ingest-amex-alert function.
--
-- RESIDUAL RISK — READ BEFORE APPLYING. The ingest function must
-- verify an HMAC, so it needs the secret VALUE, not a hash. That is
-- why household_ingest_secrets stores the value. Consequences:
--   * This table has RLS enabled and NO policy grants to anon or
--     authenticated. Only the service role (Edge Functions) can read
--     it — PostgREST callers get nothing. That is the entire access
--     control, so the parent MUST restrict who holds the service-role
--     / secret key and who can open the SQL editor.
--   * Anyone with the service-role key or SQL-editor access can read
--     these secrets. Moving them to a dedicated vault (e.g. Supabase
--     Vault) is a parent follow-up; it is out of scope for this
--     code-only workstream and is NOT claimed to be done here.
--   * NEVER store a real secret value in this file, in chat, or in
--     any repo file. Secrets are set only via the rotate function
--     below (admin caller, value passed as an argument, never
--     returned) or directly by the parent in the SQL editor.
--   * Rotate after any suspected exposure, and rotate when moving
--     from the old single shared INGEST_SECRET to per-household
--     secrets (the old shared secret must then be removed from Edge
--     Function secrets so it cannot be replayed against any household).

create table if not exists household_ingest_secrets (
  household_id uuid primary key references households(id) on delete cascade,
  secret text not null,
  created_at timestamptz not null default now(),
  rotated_at timestamptz not null default now()
);

create table if not exists ingest_nonces (
  household_id uuid not null references households(id) on delete cascade,
  nonce text not null,
  used_at timestamptz not null default now(),
  primary key (household_id, nonce)
);

alter table household_ingest_secrets enable row level security;
alter table ingest_nonces enable row level security;
-- Deliberately NO policies for anon/authenticated on either table:
-- service-role Edge Functions bypass RLS; every other caller is denied.

-- Rotation: admin-only, write-only (never returns the secret).
-- The caller must be an admin of the household; members get an
-- exception. Old nonces are NOT cleared on rotation: a nonce is bound
-- to a signature made with the old secret, so it cannot verify under
-- the new secret anyway, and clearing the table would reopen replay
-- of old signed payloads if the old secret were ever restored.
create or replace function public.rotate_household_ingest_secret(
  p_household_id uuid, p_new_secret text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id
                   and user_id = auth.uid()
                   and role = 'admin') then
    raise exception 'admin only';
  end if;
  if p_new_secret is null or length(p_new_secret) < 32 then
    raise exception 'secret must be at least 32 characters';
  end if;
  insert into household_ingest_secrets (household_id, secret, rotated_at)
    values (p_household_id, p_new_secret, now())
  on conflict (household_id)
    do update set secret = excluded.secret, rotated_at = now();
end;
$$;

revoke execute on function public.rotate_household_ingest_secret(uuid, text) from public;
grant execute on function public.rotate_household_ingest_secret(uuid, text) to authenticated;
