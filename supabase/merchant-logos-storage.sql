-- Merchant logos bucket (build 94, owner Nov 25, 2026).
--
-- The BP logo disappeared because the live Google favicon fetch
-- failed once and the in-memory-only loader gave up, leaving the
-- "B" monogram. Logos now persist in TWO layers so a known logo
-- can never disappear again:
--   1. On-device disk cache (the phone) — the app saves each
--      downloaded logo under Library/Caches/merchant-icons/.
--   2. This Supabase Storage bucket (the platform) — the app
--      uploads a logo fetched from Google in the background,
--      best-effort, so every device in the household can fetch
--      it without depending on Google's favicon service.
--
-- File key: the merchant's CURATED domain, e.g. bp.com.png — so
-- "BP" and "BP FDMS CAT" share one file. The key comes from the
-- same domain TransactionIconLookup already resolves; no new
-- key scheme, no auto-guess.
--
-- Public read: logos are brand marks, any device downloads them
-- without auth. Authenticated write: any signed-in household
-- member's phone can be the first to see a merchant, so
-- admin-only write is wrong. PNG only — this bucket holds logos.
-- Upsert needs UPDATE too (the app uploads with x-upsert: true).

insert into storage.buckets (id, name, public)
values ('merchant-logos', 'merchant-logos', true)
on conflict (id) do update set public = true;

drop policy if exists "Public read merchant logos" on storage.objects;
create policy "Public read merchant logos"
  on storage.objects for select
  using (bucket_id = 'merchant-logos');

drop policy if exists "Authenticated upload merchant logos" on storage.objects;
create policy "Authenticated upload merchant logos"
  on storage.objects for insert
  with check (bucket_id = 'merchant-logos' and storage.extension(name) = 'png');

drop policy if exists "Authenticated update merchant logos" on storage.objects;
create policy "Authenticated update merchant logos"
  on storage.objects for update
  using (bucket_id = 'merchant-logos' and storage.extension(name) = 'png')
  with check (bucket_id = 'merchant-logos' and storage.extension(name) = 'png');
