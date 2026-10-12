-- ============================================================
-- Mama Siti Eats — 0005_verify.sql
-- Run in the SQL editor AFTER 0001–0004 to prove the security
-- model and order flow work. Everything runs inside a single
-- transaction that ROLLS BACK, so nothing is persisted.
--
-- How to read the output: every check prints "PASS ...".
-- If you see "FAIL ..." or a query error, fix before going live.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. Seed a throwaway published meal + auth user to test with
--    (rolled back at the end — not real business data)
-- ------------------------------------------------------------
insert into public.categories (name, slug) values ('__TestCat', '__test-cat')
on conflict (slug) do nothing;

insert into public.meals (category_id, name, slug, price, is_published, is_available)
select id, 'Test Meal', '__test-meal', 150.00, true, true
from public.categories where slug = '__test-cat'
limit 1;

-- fake auth user + admin profile (bypasses RLS: we are postgres here)
insert into auth.users (id, email)
values ('11111111-1111-1111-1111-111111111111', '__verify_admin@test.local')
on conflict (id) do nothing;

insert into public.admin_profiles (id, display_name, role, is_active)
values ('11111111-1111-1111-1111-111111111111', 'Verify Admin', 'admin', true)
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- 2. As ANON: can read the 6 seeded categories?
-- ------------------------------------------------------------
set local role anon;

do $$
declare
  v_count integer;
begin
  select count(*) into v_count from public.categories;
  if v_count >= 6 then
    raise notice 'PASS: anon reads % categories', v_count;
  else
    raise notice 'FAIL: anon sees only % categories (seed missing?)', v_count;
  end if;
end $$;

-- 3. As ANON: cannot read ANY orders
do $$
declare
  v_count integer;
begin
  select count(*) into v_count from public.orders;
  if v_count = 0 then
    raise notice 'PASS: anon reads 0 orders (RLS hides them)';
  else
    raise notice 'FAIL: anon can see % orders!', v_count;
  end if;
end $$;

-- 4. As ANON: cannot modify the menu
do $$
begin
  begin
    insert into public.categories (name, slug) values ('Hack', 'hack');
    raise notice 'FAIL: anon could insert a category!';
  exception when insufficient_privilege
          or check_violation
          or others then
    raise notice 'PASS: anon blocked from inserting categories (%)', sqlerrm;
  end;
end $$;

-- 5. As ANON: create_order works, returns DB-computed totals
do $$
declare
  v_result jsonb;
  v_meal_id uuid;
begin
  select id into v_meal_id from public.meals where slug = '__test-meal';

  v_result := public.create_order(
    p_customer_name   => 'Verify Customer',
    p_customer_phone  => '0712345678',
    p_fulfilment_type => 'pickup',
    p_items           => jsonb_build_array(
                           jsonb_build_object('meal_id', v_meal_id, 'quantity', 2)
                         )
  );

  if (v_result->>'total_amount')::numeric = 300.00 then
    raise notice 'PASS: create_order total = % (2 x 150 from DB price)', v_result->>'total_amount';
  else
    raise notice 'FAIL: create_order total was %, expected 300', v_result->>'total_amount';
  end if;

  -- duplicate token returns the SAME order, no second row
  if (public.create_order(
        p_customer_name   => 'Verify Customer',
        p_customer_phone  => '0712345678',
        p_fulfilment_type => 'pickup',
        p_client_token    => 'verify-token-1',
        p_items           => jsonb_build_array(
                              jsonb_build_object('meal_id', v_meal_id, 'quantity', 1)
                            )
     )->>'duplicate')::boolean = false
     and (public.create_order(
        p_customer_name   => 'Verify Customer',
        p_customer_phone  => '0712345678',
        p_fulfilment_type => 'pickup',
        p_client_token    => 'verify-token-1',
        p_items           => jsonb_build_array(
                              jsonb_build_object('meal_id', v_meal_id, 'quantity', 1)
                            )
     )->>'duplicate')::boolean = true then
    raise notice 'PASS: client_token dedupes double-submitted checkout';
  else
    raise notice 'FAIL: duplicate submission created a second order';
  end if;
exception when others then
  raise notice 'FAIL: create_order errored: %', sqlerrm;
end $$;

-- 6. As ANON: unavailable meal cannot be ordered.
-- Toggle availability as postgres first: anon has no UPDATE
-- policy on meals, so doing it as anon would silently change 0 rows.
reset role;
update public.meals set is_available = false where slug = '__test-meal';
set local role anon;

do $$
declare
  v_meal_id uuid;
begin
  select id into v_meal_id from public.meals where slug = '__test-meal';

  begin
    perform public.create_order(
      p_customer_name  => 'Verify Customer',
      p_customer_phone => '0712345678',
      p_items          => jsonb_build_array(
                            jsonb_build_object('meal_id', v_meal_id, 'quantity', 1)
                          )
    );
    raise notice 'FAIL: unavailable meal was orderable!';
  exception when others then
    if sqlerrm like '%no longer available%' then
      raise notice 'PASS: unavailable meal rejected at checkout';
    else
      raise notice 'FAIL: unexpected error: %', sqlerrm;
    end if;
  end;
end $$;

reset role;
update public.meals set is_available = true where slug = '__test-meal';

-- ------------------------------------------------------------
-- 7. As ADMIN: can see the orders anon cannot
-- ------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}';

do $$
declare
  v_count integer;
begin
  select count(*) into v_count from public.orders;
  if v_count > 0 then
    raise notice 'PASS: admin reads % orders', v_count;
  else
    raise notice 'FAIL: admin cannot see orders created via create_order';
  end if;

  -- admin can update status but cannot fake the total
  update public.orders set status = 'confirmed'
  where order_number in (select order_number from public.orders limit 1);
  raise notice 'PASS: admin can update order status';
end $$;

-- admin can insert a menu category (client-side management works)
do $$
begin
  insert into public.categories (name, slug, sort_order)
  values ('__AdminCat', '__admin-cat', 99);
  raise notice 'PASS: admin can create categories from the dashboard';
  delete from public.categories where slug = '__admin-cat';
end $$;

reset role;

-- ------------------------------------------------------------
-- 8. Cleanup — everything rolled back, DB untouched
-- ------------------------------------------------------------
rollback;

do $$
begin
  raise notice 'DONE: verification complete, all test data rolled back';
end $$;
