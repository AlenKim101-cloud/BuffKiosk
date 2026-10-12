-- ============================================================
-- Mama Siti Eats — 0002_rls.sql
-- Row Level Security: public read-only menu, admin-only everything else
-- Run AFTER 0001_schema.sql
-- ============================================================

-- ------------------------------------------------------------
-- Helper: is the current user an active admin?
-- SECURITY DEFINER so policies can read admin_profiles without
-- recursion through its own RLS.
-- ------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.admin_profiles
    where id = auth.uid()
      and is_active = true
  );
$$;

revoke execute on function public.is_admin() from public;
grant  execute on function public.is_admin() to anon, authenticated;

-- ------------------------------------------------------------
-- Enable RLS on every exposed table
-- ------------------------------------------------------------
alter table public.categories       enable row level security;
alter table public.meals            enable row level security;
alter table public.orders          enable row level security;
alter table public.order_items     enable row level security;
alter table public.admin_profiles  enable row level security;
alter table public.business_settings enable row level security;

-- ------------------------------------------------------------
-- categories: public reads active ones, admins manage all
-- ------------------------------------------------------------
drop policy if exists "categories_public_read" on public.categories;
create policy "categories_public_read"
  on public.categories for select
  to anon, authenticated
  using (is_active = true or public.is_admin());

drop policy if exists "categories_admin_all" on public.categories;
create policy "categories_admin_all"
  on public.categories for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ------------------------------------------------------------
-- meals: public reads published meals in active categories,
-- admins manage everything (drafts, prices, archival)
-- ------------------------------------------------------------
drop policy if exists "meals_public_read" on public.meals;
create policy "meals_public_read"
  on public.meals for select
  to anon, authenticated
  using (
    is_published = true
    and exists (
      select 1 from public.categories c
      where c.id = meals.category_id
        and c.is_active = true
    )
    or public.is_admin()
  );

drop policy if exists "meals_admin_all" on public.meals;
create policy "meals_admin_all"
  on public.meals for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ------------------------------------------------------------
-- orders: NO client-side access at all.
-- Rows are created only by the create_order() SECURITY DEFINER
-- function (which runs with owner privileges and bypasses RLS).
-- Admins may read and update.
-- ------------------------------------------------------------
drop policy if exists "orders_admin_read" on public.orders;
create policy "orders_admin_read"
  on public.orders for select
  to authenticated
  using (public.is_admin());

drop policy if exists "orders_admin_update" on public.orders;
create policy "orders_admin_update"
  on public.orders for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ------------------------------------------------------------
-- order_items: same pattern — no client access, admin read
-- ------------------------------------------------------------
drop policy if exists "order_items_admin_read" on public.order_items;
create policy "order_items_admin_read"
  on public.order_items for select
  to authenticated
  using (public.is_admin());

-- ------------------------------------------------------------
-- admin_profiles: users can read their OWN profile (needed by
-- the dashboard to show who is logged in); admins can read all.
-- Nobody can insert/update through the client — provisioning is
-- done from the SQL editor / service role only, so a user can
-- never grant themselves admin.
-- ------------------------------------------------------------
drop policy if exists "admin_profiles_own_read" on public.admin_profiles;
create policy "admin_profiles_own_read"
  on public.admin_profiles for select
  to authenticated
  using (id = auth.uid());

drop policy if exists "admin_profiles_admin_read" on public.admin_profiles;
create policy "admin_profiles_admin_read"
  on public.admin_profiles for select
  to authenticated
  using (public.is_admin());

-- ------------------------------------------------------------
-- business_settings: public read (WhatsApp number, hours, pickup/
-- delivery flags are shown on the site); admins update
-- ------------------------------------------------------------
drop policy if exists "settings_public_read" on public.business_settings;
create policy "settings_public_read"
  on public.business_settings for select
  to anon, authenticated
  using (true);

drop policy if exists "settings_admin_update" on public.business_settings;
create policy "settings_admin_update"
  on public.business_settings for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "settings_admin_insert" on public.business_settings;
create policy "settings_admin_insert"
  on public.business_settings for insert
  to authenticated
  with check (public.is_admin());

-- ------------------------------------------------------------
-- Tighten default grants: anon/authenticated should not have
-- blanket write access even before policies are considered
-- ------------------------------------------------------------
revoke insert, update, delete on public.orders, public.order_items from anon, authenticated;
revoke insert, update, delete on public.admin_profiles from anon, authenticated;
grant  select on public.categories, public.meals, public.business_settings to anon, authenticated;
grant  select on public.orders, public.order_items, public.admin_profiles to authenticated;
