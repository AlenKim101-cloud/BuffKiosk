-- ============================================================
-- Mama Siti Eats — 0001_schema.sql
-- Tables, constraints, indexes, updated_at triggers
-- Run this FIRST in the Supabase SQL editor (or `supabase db push`)
-- ============================================================

-- gen_random_uuid() lives in pgcrypto on older PG; Supabase has it enabled by default
create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- updated_at helper
-- ------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ------------------------------------------------------------
-- categories
-- ------------------------------------------------------------
create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  slug        text not null unique,
  description text,
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

drop trigger if exists categories_set_updated_at on public.categories;
create trigger categories_set_updated_at
  before update on public.categories
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- meals
-- ------------------------------------------------------------
create table if not exists public.meals (
  id           uuid primary key default gen_random_uuid(),
  category_id  uuid not null references public.categories (id),
  name         text not null,
  slug         text not null unique,
  description  text,
  price        numeric(10,2) not null default 0 check (price >= 0),
  image_url    text,
  is_available boolean not null default true,
  is_published boolean not null default false,
  is_featured  boolean not null default false,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists meals_category_idx      on public.meals (category_id);
create index if not exists meals_public_menu_idx   on public.meals (is_published, is_available) where is_published;
create index if not exists meals_featured_idx      on public.meals (is_featured) where is_featured;

drop trigger if exists meals_set_updated_at on public.meals;
create trigger meals_set_updated_at
  before update on public.meals
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- orders
-- ------------------------------------------------------------
create table if not exists public.orders (
  id                uuid primary key default gen_random_uuid(),
  order_number      text not null unique,
  -- optional client-supplied token so a double-tapped checkout
  -- cannot create two orders (see create_order)
  client_token      text,
  customer_name     text not null check (char_length(customer_name) between 2 and 120),
  customer_phone    text not null check (char_length(customer_phone) between 9 and 20),
  fulfilment_type   text not null default 'pickup'
                      check (fulfilment_type in ('pickup', 'delivery')),
  delivery_location text,
  customer_notes    text,
  status            text not null default 'pending_whatsapp'
                      check (status in (
                        'pending_whatsapp', 'placed', 'confirmed',
                        'preparing', 'ready', 'completed', 'cancelled'
                      )),
  subtotal          numeric(10,2) not null default 0 check (subtotal >= 0),
  delivery_fee      numeric(10,2) not null default 0 check (delivery_fee >= 0),
  total_amount      numeric(10,2) not null default 0 check (total_amount >= 0),
  whatsapp_status   text not null default 'not_opened'
                      check (whatsapp_status in (
                        'not_opened', 'awaiting_confirmation',
                        'customer_contacted', 'confirmed', 'failed'
                      )),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  confirmed_at      timestamptz
);

create index if not exists orders_created_at_idx  on public.orders (created_at desc);
create index if not exists orders_status_idx      on public.orders (status);
create index if not exists orders_phone_idx       on public.orders (customer_phone);
create unique index if not exists orders_client_token_uidx
  on public.orders (client_token) where client_token is not null;

drop trigger if exists orders_set_updated_at on public.orders;
create trigger orders_set_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- order_items  (name + price snapshotted at order time)
-- ------------------------------------------------------------
create table if not exists public.order_items (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references public.orders (id) on delete cascade,
  -- nullable: meal may be deleted later, snapshot keeps history intact
  meal_id    uuid references public.meals (id) on delete set null,
  meal_name  text not null,
  unit_price numeric(10,2) not null check (unit_price >= 0),
  quantity   integer not null check (quantity > 0),
  line_total numeric(10,2) not null check (line_total >= 0),
  created_at timestamptz not null default now()
);

create index if not exists order_items_order_idx on public.order_items (order_id);

-- ------------------------------------------------------------
-- admin_profiles  (links auth.users to a privileged role)
-- ------------------------------------------------------------
create table if not exists public.admin_profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  role         text not null default 'admin' check (role in ('admin', 'manager')),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

-- ------------------------------------------------------------
-- business_settings (key/value, public-readable)
-- ------------------------------------------------------------
create table if not exists public.business_settings (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);

drop trigger if exists business_settings_set_updated_at on public.business_settings;
create trigger business_settings_set_updated_at
  before update on public.business_settings
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- order number sequence
-- ------------------------------------------------------------
create sequence if not exists public.order_number_seq;
