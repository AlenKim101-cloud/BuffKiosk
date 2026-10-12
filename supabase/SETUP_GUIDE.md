# Mama Siti Eats — Supabase Setup Guide

This folder generates the complete backend described in the
*Database, Backend and Admin Dashboard* PRD: schema, security rules,
order logic, seed data, and a verification pass.

```
supabase/migrations/
  0001_schema.sql     tables, constraints, indexes, updated_at triggers
  0002_rls.sql        row-level security (public reads menu, nothing else)
  0003_functions.sql  create_order RPC + order numbers + WhatsApp tracking
  0004_seed.sql       6 categories, business settings, image bucket
  0005_verify.sql     tests the security model, rolls everything back
```

## 1. Create the Supabase project

1. Go to <https://supabase.com/dashboard> → **New project**.
2. Name it `mama-siti-eats`, pick the region closest to Kenya
   (Africa South is ideal if offered on your plan; otherwise EU West).
3. Save the database password somewhere safe — you won't need it for
   the website, only for direct psql access.

## 2. Run the migrations

In the dashboard: **SQL Editor** → **New query** → paste each file
in order (0001 → 0005) → **Run**. Each must succeed before the next.

Prefer the CLI? These files are standard migration format:

```bash
supabase link --project-ref <your-project-ref>
supabase db push
```

## 3. Verify before building anything

Run `0005_verify.sql` and read the `NOTICE` output. You should see
only `PASS ...` lines. The script works by switching roles
(`anon` → `authenticated`) inside a transaction that always rolls
back, so it proves:

- anonymous users can read categories but **no orders**
- anonymous users cannot modify the menu
- `create_order` computes totals from **database prices**
- a repeated `client_token` does **not** create a second order
- unavailable meals are rejected at checkout
- admins can read orders and manage the menu

## 4. Provision the admin account

SQL alone can't create the login — that's Supabase Auth:

1. **Authentication → Users → Add user** → enter your email and a
   strong password → check **Auto Confirm User** → Add.
2. Copy the new user's UUID.
3. In the SQL editor, run (swap in your UUID and name):

```sql
insert into public.admin_profiles (id, display_name, role, is_active)
values ('<AUTH-USER-UUID>', 'Mama Siti', 'admin', true);
```

There is deliberately **no public registration path** —
`admin_profiles` has no client insert policy, so nobody can promote
themselves. To add a second admin later, repeat steps 1–3.

## 5. Configure secrets for the frontends

In both the website's and the dashboard's `.env`:

```bash
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<anon public key>       # Settings → API
```

Never put the `service_role` key in either app — it bypasses RLS.

## 6. Website integration cheat-sheet

**Fetch the menu** (respects RLS automatically — anon only ever
sees published meals in active categories):

```ts
const { data: categories } = await supabase
  .from('categories').select('*').order('sort_order');

const { data: meals } = await supabase
  .from('meals').select('*, categories(name, slug)')
  .eq('is_available', true)
  .order('sort_order');
```

**Place an order** — send only IDs and quantities; the database
prices the order:

```ts
const token = crypto.randomUUID();   // keep in state; reuse on retry

const { data, error } = await supabase.rpc('create_order', {
  p_customer_name:   name,
  p_customer_phone:  phone,          // 0712345678 or +254...
  p_fulfilment_type: 'pickup',
  p_delivery_location: null,
  p_customer_notes:  notes || null,
  p_client_token:    token,
  p_items: cart.map(i => ({ meal_id: i.id, quantity: i.qty })),
});
// data => { order_number: 'MS-261012-0042', total_amount: 300, ... }
```

**Open WhatsApp** with the returned reference:

```ts
const text = encodeURIComponent(
  `*New Order ${data.order_number}*\n` +
  `Name: ${name}\nPhone: ${phone}\n\n` +
  cart.map(i => `${i.qty} x ${i.name} @ KES ${i.price}`).join('\n') +
  `\n\nTotal: KES ${data.total_amount}\nPickup`
);
window.open(`https://wa.me/254717565027?text=${text}`, '_blank');
await supabase.rpc('mark_whatsapp_opened', { p_order_id: data.order_id });
```

If `window.open` throws or the window is null (popup blocker), show
the order reference + a copy-the-message fallback and a Retry button.
`mark_whatsapp_opened` only records that WhatsApp was *launched* —
the order stays `pending_whatsapp` until staff confirm it in the
dashboard. That satisfies acceptance criteria G/12 in both PRDs.

## 7. Go-live checklist

- [ ] `0005_verify.sql` prints only PASS
- [ ] Admin user created + `admin_profiles` row inserted
- [ ] `business_settings`: `whatsapp_number` = `254717565027`
- [ ] Real meals entered (unpublished drafts are hidden from the site)
- [ ] At least one meal has an image uploaded to `meal-images`
- [ ] `delivery_enabled` stays `false` until the business confirms delivery
- [ ] Test an order on a real phone: checkout → WhatsApp opens with
      the right reference → order appears in dashboard as
      *pending WhatsApp confirmation* → confirm → complete
