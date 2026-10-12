-- ============================================================
-- Mama Siti Eats — 0003_functions.sql
-- Server-side order creation and order-number generation.
-- Run AFTER 0001_schema.sql and 0002_rls.sql
-- ============================================================

-- ------------------------------------------------------------
-- Order number generator: MS-YYMMDD-XXXX
-- e.g. MS-261012-0042
-- ------------------------------------------------------------
create or replace function public.generate_order_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seq integer;
begin
  -- sequence value for today, wrapped so it never exceeds 9999
  v_seq := (nextval('public.order_number_seq') % 10000);
  return 'MS-'
       || to_char(now() at time zone 'Africa/Nairobi', 'YYMMDD')
       || '-'
       || lpad(v_seq::text, 4, '0');
end;
$$;

-- ------------------------------------------------------------
-- create_order: the ONLY way orders enter the database.
--
-- Called by the website via:
--   supabase.rpc('create_order', { p_items: [...], ... })
--
-- Security / correctness properties:
--   * SECURITY DEFINER — runs with owner rights, so anon can
--     submit orders without having insert grants on orders.
--   * Prices, availability and publication are read FRESH from
--     the database. The browser's prices are never trusted.
--   * Order + items are inserted in one transaction: all-or-nothing.
--   * Optional p_client_token dedupes a double-tapped checkout.
--   * Returns the authoritative totals computed in the database.
-- ------------------------------------------------------------
create or replace function public.create_order(
  p_customer_name   text,
  p_customer_phone  text,
  p_fulfilment_type text default 'pickup',
  p_delivery_location text default null,
  p_customer_notes  text default null,
  p_client_token    text default null,
  p_items           jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id       uuid;
  v_order_number   text;
  v_subtotal       numeric(10,2) := 0;
  v_delivery_fee   numeric(10,2) := 0;
  v_item           jsonb;
  v_meal           record;
  v_qty            integer;
  v_existing       record;
  v_delivery_enabled text;
begin
  -- ---------- input validation ----------
  if p_customer_name is null or char_length(trim(p_customer_name)) < 2 then
    raise exception 'Please provide your name.';
  end if;

  if p_customer_phone is null
     or p_customer_phone !~ '^(\+?254|0)[0-9]{9}$' then
    raise exception 'Please provide a valid Kenyan phone number.';
  end if;

  if p_fulfilment_type not in ('pickup', 'delivery') then
    raise exception 'Invalid fulfilment type.';
  end if;

  select value into v_delivery_enabled
  from public.business_settings where key = 'delivery_enabled';

  if p_fulfilment_type = 'delivery' then
    if coalesce(v_delivery_enabled, 'false') <> 'true' then
      raise exception 'Delivery is not available yet. Please choose pickup.';
    end if;
    if p_delivery_location is null or char_length(trim(p_delivery_location)) < 3 then
      raise exception 'Please provide a delivery location.';
    end if;
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'Your cart is empty.';
  end if;

  if jsonb_array_length(p_items) > 30 then
    raise exception 'Too many items in one order.';
  end if;

  -- ---------- duplicate-submission guard ----------
  if p_client_token is not null then
    select id, order_number, subtotal, delivery_fee, total_amount
      into v_existing
    from public.orders where client_token = p_client_token;

    if found then
      return jsonb_build_object(
        'order_id',     v_existing.id,
        'order_number', v_existing.order_number,
        'subtotal',     v_existing.subtotal,
        'delivery_fee', v_existing.delivery_fee,
        'total_amount', v_existing.total_amount,
        'duplicate',    true
      );
    end if;
  end if;

  -- ---------- resolve items against the DB (authoritative prices) ----------
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_qty := nullif(v_item->>'quantity', '')::integer;

    if v_qty is null or v_qty < 1 or v_qty > 100 then
      raise exception 'Invalid quantity for an item in your cart.';
    end if;

    select m.id, m.name, m.price
      into v_meal
    from public.meals m
    join public.categories c on c.id = m.category_id
    where m.id = (v_item->>'meal_id')::uuid
      and m.is_published = true
      and m.is_available = true
      and c.is_active = true;

    if not found then
      raise exception 'An item in your cart is no longer available.';
    end if;

    v_subtotal := v_subtotal + (v_meal.price * v_qty);
  end loop;

  -- ---------- delivery fee from settings ----------
  if p_fulfilment_type = 'delivery' then
    select coalesce(nullif(value, '')::numeric, 0)
      into v_delivery_fee
    from public.business_settings where key = 'default_delivery_fee';
  end if;

  -- ---------- insert order + items atomically ----------
  v_order_number := public.generate_order_number();

  insert into public.orders (
    order_number, client_token, customer_name, customer_phone,
    fulfilment_type, delivery_location, customer_notes,
    status, whatsapp_status, subtotal, delivery_fee, total_amount
  ) values (
    v_order_number, p_client_token,
    trim(p_customer_name), p_customer_phone,
    p_fulfilment_type,
    nullif(trim(coalesce(p_delivery_location, '')), ''),
    nullif(trim(coalesce(p_customer_notes, '')), ''),
    'pending_whatsapp', 'not_opened',
    v_subtotal, v_delivery_fee, v_subtotal + v_delivery_fee
  )
  returning id into v_order_id;

  insert into public.order_items (
    order_id, meal_id, meal_name, unit_price, quantity, line_total
  )
  select
    v_order_id,
    m.id,
    m.name,
    m.price,
    (item->>'quantity')::integer,
    m.price * (item->>'quantity')::integer
  from jsonb_array_elements(p_items) item
  join public.meals m on m.id = (item->>'meal_id')::uuid;

  return jsonb_build_object(
    'order_id',      v_order_id,
    'order_number',  v_order_number,
    'subtotal',      v_subtotal,
    'delivery_fee',  v_delivery_fee,
    'total_amount',  v_subtotal + v_delivery_fee,
    'status',        'pending_whatsapp',
    'duplicate',     false
  );
end;
$$;

-- ------------------------------------------------------------
-- mark_whatsapp_opened: the site calls this AFTER window.open()
-- to the wa.me link. It only records that we LAUNCHED WhatsApp —
-- it does not claim the customer sent anything.
-- ------------------------------------------------------------
create or replace function public.mark_whatsapp_opened(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.orders
  set whatsapp_status = 'awaiting_confirmation'
  where id = p_order_id
    and whatsapp_status = 'not_opened';
end;
$$;

-- ------------------------------------------------------------
-- Grants: anonymous customers can submit orders (and nothing else)
-- ------------------------------------------------------------
revoke all on function public.create_order(text, text, text, text, text, text, jsonb) from public;
revoke all on function public.mark_whatsapp_opened(uuid) from public;
revoke all on function public.generate_order_number() from public;

grant execute on function public.create_order(text, text, text, text, text, text, jsonb) to anon, authenticated;
grant execute on function public.mark_whatsapp_opened(uuid) to anon, authenticated;
-- generate_order_number is internal; create_order runs as owner so it can call it
grant execute on function public.generate_order_number() to service_role;
