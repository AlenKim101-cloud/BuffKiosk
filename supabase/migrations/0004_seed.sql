-- ============================================================
-- Mama Siti Eats — 0004_seed.sql
-- Seed the 6 categories, business settings, and meal-images
-- storage bucket. Run AFTER 0001–0003.
--
-- NOTE: no sample meals are seeded. Real meals are added by the
-- admin (or by you via SQL) — acceptance criterion #12 forbids
-- presenting sample data as real business data.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The six menu categories (idempotent on slug)
-- ------------------------------------------------------------
insert into public.categories (name, slug, sort_order, is_active) values
  ('Breakfast',  'breakfast',   1, true),
  ('Lunch',      'lunch',       2, true),
  ('Supper',     'supper',      3, true),
  ('Main Meals', 'main-meals',  4, true),
  ('Drinks',     'drinks',      5, true),
  ('Snacks',     'snacks',      6, true)
on conflict (slug) do update
  set name = excluded.name,
      sort_order = excluded.sort_order;

-- ------------------------------------------------------------
-- 2. Business settings (public-readable defaults)
-- ------------------------------------------------------------
insert into public.business_settings (key, value) values
  ('business_name',       'Mama Siti Eats'),
  ('location',            'Royalton, Eldoret'),
  ('whatsapp_number',     '254717565027'),
  ('opening_hours',       'To be confirmed'),  -- replace once the business confirms
  ('pickup_enabled',      'true'),
  ('delivery_enabled',    'false'),            -- flip to 'true' only after the business confirms
  ('default_delivery_fee','0')
on conflict (key) do nothing;

-- ------------------------------------------------------------
-- 3. Storage bucket for meal images (publicly readable URLs)
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'meal-images', 'meal-images', true,
  5242880,  -- 5 MB
  array['image/jpeg', 'image/png', 'image/webp', 'image/avif']
)
on conflict (id) do nothing;

-- Only admins may write to the bucket; everyone may read images
drop policy if exists "meal_images_public_read" on storage.objects;
create policy "meal_images_public_read"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'meal-images');

drop policy if exists "meal_images_admin_insert" on storage.objects;
create policy "meal_images_admin_insert"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'meal-images' and public.is_admin());

drop policy if exists "meal_images_admin_update" on storage.objects;
create policy "meal_images_admin_update"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'meal-images' and public.is_admin());

drop policy if exists "meal_images_admin_delete" on storage.objects;
create policy "meal_images_admin_delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'meal-images' and public.is_admin());
