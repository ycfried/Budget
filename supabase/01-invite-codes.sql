-- =====================================================================
-- S1 migration 01 — Invite codes + code-based household join
-- Deploy order: FIRST of the five S1 files (01..05).
-- Depends on: schema.sql, schema-inserts.sql, create-household-rpc.sql
--   (households, household_members, audit_log already exist).
-- Does NOT depend on 02..05; safe to deploy alone.
--
-- What this fixes (audit):
--   P0-1  Stranger self-registers and joins by pasting a published
--         household UUID: the old policy "users join as member for
--         themselves" (schema-inserts.sql) let ANY authenticated user
--         insert a membership row for ANY household_id, no invite,
--         no approval, no expiry. That policy is DROPPED below, so
--         direct membership inserts are closed. Joining is now only
--         possible through join_household_by_code(), which refuses
--         a caller who already belongs to any household.
--   P1-25 Joining a second household was allowed; boot then picked
--         arbitrarily. join_household_by_code() refuses a second
--         membership outright (no switcher is built here — that is
--         a product decision for the parent, not this migration).
--   P1-36 Share-household-ID exposed a bare UUID. The invite code
--         below is the shareable secret instead; the UUID is no
--         longer meant to be shared (see MIGRATION NOTE at the end).
--
-- Design (per the S1 brief, NOT per the audit's stricter proposal):
--   * A 6-character code from an unambiguous alphabet (no 0/O/1/I/L,
--     so a code read aloud or typed by hand cannot be confused).
--   * The code is REUSABLE and has NO expiry in this migration.
--     The audit's correct fix calls for single-use, expiring,
--     admin-approved invites. This migration deliberately does NOT
--     implement that: the brief specifies a household-level code.
--     Residual risk is documented in INTERFACE.md and in the final
--     report — the parent must decide whether reusable codes are
--     acceptable or whether a single-use invite table is still owed.
--   * During transition, join_household_by_code() ALSO accepts a
--     legacy household UUID, so existing clients/flows keep working
--     until the parent declares the cutover (see MIGRATION NOTE).
--
-- No secrets, tokens, or keys appear in this file. Invite codes are
-- join secrets, not credentials: they are stored in plaintext by
-- design (like a room code) and must still never be published in a
-- public repo — that publication is exactly what caused P0-1.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Column + unique index
-- ---------------------------------------------------------------------
alter table households
  add column if not exists invite_code text;

-- Unique index (not a CHECK): Postgres unique indexes permit multiple
-- NULLs, so households created before this migration do not collide
-- with each other; the backfill in §3 fills them in.
create unique index if not exists households_invite_code_key
  on households (invite_code);

-- ---------------------------------------------------------------------
-- 2. Code generator: 6 chars, unambiguous alphabet, collision retry
-- ---------------------------------------------------------------------
-- Alphabet (32 chars): A-Z minus I, L, O, plus digits 2-9 minus 0, 1.
--   ABCDEFGHJKMNPQRSTUVWXYZ23456789
-- 32^6 = ~1.07 billion possible codes; with a handful of households
-- a collision is negligible, but the loop below retries anyway and
-- fails loudly instead of ever returning a duplicate.
create or replace function public.generate_invite_code()
returns text
language plpgsql
-- Not SECURITY DEFINER: it only reads households.invite_code and is
-- called from SECURITY DEFINER functions (which run as the owner) or
-- by the deployer during the backfill. No grant to authenticated:
-- clients must never mint codes directly.
set search_path = public
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text;
  v_attempt integer := 0;
  v_i integer;
begin
  loop
    v_attempt := v_attempt + 1;
    if v_attempt > 100 then
      raise exception 'could not generate a unique invite code after 100 attempts';
    end if;
    v_code := '';
    for v_i in 1..6 loop
      v_code := v_code || substr(v_alphabet, floor(random() * 32)::integer + 1, 1);
    end loop;
    if not exists (select 1 from households where invite_code = v_code) then
      return v_code;
    end if;
    -- Collision: loop and try again.
  end loop;
end;
$$;
revoke execute on function public.generate_invite_code() from public;
-- Intentionally NOT granted to authenticated (see comment above).

-- ---------------------------------------------------------------------
-- 3. Backfill existing households, one row at a time
-- ---------------------------------------------------------------------
-- A single UPDATE ... SET invite_code = generate_invite_code() is NOT
-- used on purpose: within one statement, whether a later row's
-- generator call sees earlier rows' new codes is an implementation
-- subtlety not worth betting uniqueness on. This loop assigns codes
-- row by row, so every generator call sees all previously assigned
-- codes (same transaction, sequential statements).
do $$
declare
  v_row record;
begin
  for v_row in
    select id from households where invite_code is null order by created_at, id
  loop
    update households
      set invite_code = generate_invite_code()
      where id = v_row.id and invite_code is null;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. create_household() — full replacement: now sets an invite code
-- ---------------------------------------------------------------------
-- Identical to supabase/create-household-rpc.sql except for the one
-- added line that assigns invite_code. Behaviour otherwise unchanged:
-- caller must be authenticated, must not already belong to any
-- household, becomes admin of exactly one new household, one audit
-- row, returns the new id.
create or replace function public.create_household()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from household_members where user_id = auth.uid()) then
    raise exception 'already in a household';
  end if;
  insert into households (name, base_allowance_cents, invite_code)
    values ('Household', 37500, generate_invite_code())
    returning id into new_id;
  insert into household_members (household_id, user_id, role)
    values (new_id, auth.uid(), 'admin');
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (new_id, auth.uid(), 'admin', 'Household created',
            'Created via create_household RPC; creator is admin.');
  return new_id;
end;
$$;
revoke execute on function public.create_household() from public;
grant execute on function public.create_household() to authenticated;

-- ---------------------------------------------------------------------
-- 5. Close the direct-join hole (P0-1), then add the RPC join path
-- ---------------------------------------------------------------------
-- Dropping this policy means a direct client insert into
-- household_members now fails RLS for everyone (the table-level
-- INSERT grant from fix-grants.sql remains, but no policy permits
-- the row). The UI join handler in live.js MUST switch to
-- join_household_by_code() at the same deploy — until it does, the
-- old join button will fail. That UI change is a dependent
-- workstream's job, flagged in INTERFACE.md; it is not done here
-- because this workstream owns SQL only.
drop policy if exists "users join as member for themselves" on household_members;

-- join_household_by_code(code text) returns uuid
--   * Accepts a 6-character invite code (case-insensitive, surrounding
--     whitespace ignored) OR a legacy household UUID (transition only).
--   * Refuses if the caller already belongs to ANY household
--     (raise exception — matches create_household() behaviour and
--     closes P1-25 for this path).
--   * Inserts role='member' (never 'admin' — a join must never mint
--     an admin) and writes one audit_log row, then returns the
--     household uuid.
--   * Unknown code / unknown UUID / malformed input all raise the
--     same generic 'invalid invite code' error, so an attacker cannot
--     distinguish "no such code" from "malformed input". (Whether a
--     UUID exists is NOT leaked either: a well-formed but unknown
--     UUID raises the identical message.)
create or replace function public.join_household_by_code(code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_input text;
  v_household_id uuid;
  v_as_uuid uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  v_input := upper(btrim(coalesce(code, '')));
  if v_input = '' then
    raise exception 'invalid invite code';
  end if;
  if exists (select 1 from household_members where user_id = auth.uid()) then
    raise exception 'already in a household';
  end if;

  -- Path 1: 6-character invite code from the unambiguous alphabet.
  if v_input ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$' then
    select id into v_household_id from households where invite_code = v_input;
  else
    -- Path 2 (TRANSITION ONLY — see MIGRATION NOTE): legacy UUID.
    -- A non-UUID string that is not a code lands here and fails the
    -- cast, which is intentionally mapped to the generic error.
    begin
      v_as_uuid := v_input::uuid;
    exception when invalid_text_representation then
      v_as_uuid := null;
    end;
    if v_as_uuid is not null then
      select id into v_household_id from households where id = v_as_uuid;
    end if;
  end if;

  if v_household_id is null then
    raise exception 'invalid invite code';
  end if;

  insert into household_members (household_id, user_id, role)
    values (v_household_id, auth.uid(), 'member');
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_household_id, auth.uid(), 'member', 'Household joined',
            'Joined via invite code (or legacy household id during transition).');
  return v_household_id;
end;
$$;
revoke execute on function public.join_household_by_code(text) from public;
grant execute on function public.join_household_by_code(text) to authenticated;

-- =====================================================================
-- MIGRATION NOTE — UUID JOIN PATH REMOVAL (parent decision, NOT done
-- here): after every client has moved to invite codes, remove Path 2
-- (the legacy-UUID branch) from join_household_by_code() and rotate
-- any household UUID that was ever published (notably the owner
-- household UUID published in the public repo per audit P0-1 — a
-- published UUID stays usable as a join secret until Path 2 is
-- removed, and ideally the exposed household's join path is rotated
-- regardless). Do NOT remove Path 2 in this file: the brief reserves
-- the cutover decision to the parent, and removing it early would
-- break any client still joining by UUID.
-- Also still owed outside this file (parent / dashboard action, not
-- SQL): disable open sign-ups in Supabase Auth now that both
-- accounts exist, and remove household UUIDs from the public repo
-- (audit P0-1). SQL alone cannot close those two doors.
-- =====================================================================

-- =====================================================================
-- VERIFICATION (commented — run manually after deploy, do NOT run
-- blindly against production data; use a throwaway household):
--   -- Code shape + uniqueness:
--   select invite_code, length(invite_code) = 6,
--          invite_code ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$'
--     from households;
--   select count(*), count(distinct invite_code) from households
--    where invite_code is not null;  -- counts must match
--   -- No household left without a code:
--   select count(*) from households where invite_code is null;  -- 0
--   -- Generator exists and returns the right shape:
--   select generate_invite_code();  -- owner/deployer only; must fail
--     -- for authenticated (no grant) — that failure is expected.
--   -- Join refuses a second household (as a user already in one):
--   select join_household_by_code('ABCDEF');  -- expect exception
--     -- 'already in a household'
--   -- Join with an unknown code (as a fresh user):
--   select join_household_by_code('ZZZZZZ');  -- expect exception
--     -- 'invalid invite code'
--   -- Direct membership insert is now blocked (P0-1 closed):
--   insert into household_members (household_id, user_id, role)
--     values ('<some-household-uuid>', auth.uid(), 'member');
--     -- expect: new row violates row-level security policy
-- =====================================================================
