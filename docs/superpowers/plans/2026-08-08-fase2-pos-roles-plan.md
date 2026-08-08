# Fase 2: Punto de venta y roles — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the demo checkout into a real Stripe checkout, add an in-store POS
screen, and add admin/vendedor roles — per
`docs/superpowers/specs/2026-08-08-fase2-pos-roles-design.md`.

**Architecture:** 4 new SQL migrations (roles, cost masking, sales tables,
sale RPCs) applied to the live Supabase project; 3 Supabase Edge Functions
(invite-vendedor, create-checkout-session, stripe-webhook); frontend changes
to `app/js/admin.js` (3 new tabs, role gating) and `app/js/catalog.js` (real
checkout).

**Tech Stack:** Supabase (Postgres + Auth + Edge Functions/Deno), vanilla JS
ES modules (no bundler), Stripe Checkout (hosted page) + Stripe Node SDK via
`npm:stripe` in Deno, Netlify static hosting.

## Global Constraints

- This repo has **no test framework, no build step, no package.json** — it's
  a static site (vanilla JS ES modules) deployed as-is to Netlify. Do not
  introduce one for this phase. "Tests" in this plan mean, per layer:
  - **SQL/RPC:** a verification query run via the Supabase MCP
    `execute_sql` tool (or `psql`/dashboard SQL editor if MCP unavailable),
    with an expected result written out.
  - **Edge Functions:** a `curl` invocation with the expected JSON/HTTP
    response written out.
  - **Frontend:** an explicit manual browser verification (open the page,
    click X, expect Y). Use the `webapp-testing` skill if available for
    browser automation; otherwise do it by hand and report what you saw.
- Supabase project: `iatyvxljzrcdfmmtesig`. Apply migrations with the
  Supabase MCP `apply_migration` tool (search for it via ToolSearch if not
  loaded — the server id changes between reconnects, so look it up by name,
  don't hardcode a tool id from a prior session).
- Netlify site: `195763a4-3546-4fc2-9a65-451f1ccdea09`
  (https://lemus-store.netlify.app). Deploy with the Netlify MCP
  `netlify-deploy-services-updater` tool, `operation: "deploy-site"`, which
  returns a shell command to run via Bash.
- All UI copy is in Spanish (Mexico), currency MXN, matching the existing
  app. Follow existing code conventions: vanilla template-literal HTML
  rendering, `escapeHtml()` for any user-entered text, `showToast()` for
  user feedback, `supabase-client.js`'s exported `supabase`/`fmt`.
- Never commit real secrets (Stripe keys, service role key) to the repo.
  Edge Function secrets are set via the Supabase Dashboard or CLI, never in
  code.
- Founding admin account: `ricardo.cabreraflo@gmail.com`
  (`6c22a4d2-dcdf-4dab-a688-2bcd4396734a`) — the only account that exists
  in the project today.

---

## File Structure

New files:
- `supabase/migrations/0007_profiles_roles.sql`
- `supabase/migrations/0008_admin_only_writes.sql`
- `supabase/migrations/0009_sales.sql`
- `supabase/migrations/0010_sale_functions.sql`
- `supabase/functions/invite-vendedor/index.ts`
- `supabase/functions/create-checkout-session/index.ts`
- `supabase/functions/stripe-webhook/index.ts`

Modified files:
- `app/js/admin.js` — role fetching, tab visibility, cost masking, 3 new
  tab controllers (Vender, Pedidos, Usuarios), remove self-signup, switch
  reads to `products_view`.
- `app/admin.html` — remove signup toggle button, add markup for 3 new
  tabs, add `data-role-*` attributes to tab buttons, add a "Costo" column
  toggle.
- `app/js/catalog.js` — real checkout flow, switch reads to
  `products_view`, handle `?checkout=success`/`?checkout=cancel`.
- `app/index.html` — contact fields (name/phone/email) in the cart drawer.

---

### Task 1: Migration 0007 — roles (`profiles` table + `is_admin()`)

**Files:**
- Create: `supabase/migrations/0007_profiles_roles.sql`

**Interfaces:**
- Produces: table `public.profiles(id, email, role, created_at)`; function
  `public.is_admin() returns boolean` — used by every later migration in
  this plan and by both Edge Functions that check role.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0007_profiles_roles.sql
-- Roles: every account gets a profile row tagging it admin or vendedor.
-- New accounts are created only via the invite-vendedor Edge Function
-- (admin-only) — there is no public self-registration anymore (see
-- migration 0008 for the products/taxonomy write policies, and the
-- admin.js change that removes the signup UI).

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role text not null check (role in ('admin', 'vendedor')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.profiles where id = auth.uid() and role = 'admin'
  );
$$;

grant execute on function public.is_admin() to anon, authenticated;

drop policy if exists "read own or admin reads all" on public.profiles;
create policy "read own or admin reads all" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

-- No insert/update/delete policy: profiles rows are created only by the
-- invite-vendedor Edge Function (service role, bypasses RLS) and by the
-- backfill below.

insert into public.profiles (id, email, role)
select id, email, 'admin'
from auth.users
where email = 'ricardo.cabreraflo@gmail.com'
on conflict (id) do nothing;
```

- [ ] **Step 2: Apply the migration**

Use the Supabase MCP `apply_migration` tool: `project_id: "iatyvxljzrcdfmmtesig"`,
`name: "profiles_roles"`, `query: <contents of the file above>`.

- [ ] **Step 3: Verify**

Run via `execute_sql` (project_id `iatyvxljzrcdfmmtesig`):

```sql
select id, email, role from public.profiles;
```

Expected: exactly one row —
`6c22a4d2-dcdf-4dab-a688-2bcd4396734a | ricardo.cabreraflo@gmail.com | admin`.

```sql
select proname, prosecdef, provolatile from pg_proc where proname = 'is_admin';
```

Expected: one row, `prosecdef = true` (security definer), `provolatile = 's'` (stable).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0007_profiles_roles.sql
git commit -m "Add profiles table and is_admin() for role-based access"
```

---

### Task 2: Migration 0008 — admin-only writes + cost masking

**Files:**
- Create: `supabase/migrations/0008_admin_only_writes.sql`

**Interfaces:**
- Consumes: `public.is_admin()` (Task 1).
- Produces: view `public.products_view` (same columns as `products`, plus
  `cost_price` nulled out for non-admins) — used by `catalog.js` and
  `admin.js` in later tasks instead of querying `products` directly for
  reads. Write policies on `products`, `product_lines`, `categories`,
  `promotions`, `stock_transfers` now require `is_admin()`.
  `transfer_stock(...)` (existing RPC from Fase 1) gets an explicit
  admin-only guard.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0008_admin_only_writes.sql
-- Vendedor (and anonymous catalog visitors) must never be able to read
-- cost_price, and only admin can edit products/taxonomy/promotions or run
-- traspasos — vendedor only sells and views.

-- --- Cost price masking ---
-- Column-level revoke blocks reading cost_price directly off the base
-- table (including via a REST call that bypasses the app's UI). The view
-- below is the only way anyone reads it — and it nulls it out unless
-- is_admin() is true for the caller.
revoke select (cost_price) on public.products from anon, authenticated;

create or replace view public.products_view as
select
  id, code, name, product_line_id, category_id, price,
  stock_online, stock_fisica, published_online, created_at, updated_at,
  case when public.is_admin() then cost_price else null end as cost_price
from public.products;

grant select on public.products_view to anon, authenticated;

-- --- Admin-only writes ---
drop policy if exists "authenticated write" on public.products;
drop policy if exists "admin write" on public.products;
create policy "admin write" on public.products for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "authenticated write" on public.product_lines;
drop policy if exists "admin write" on public.product_lines;
create policy "admin write" on public.product_lines for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "authenticated write" on public.categories;
drop policy if exists "admin write" on public.categories;
create policy "admin write" on public.categories for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "authenticated write" on public.promotions;
drop policy if exists "admin write" on public.promotions;
create policy "admin write" on public.promotions for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "authenticated insert" on public.stock_transfers;
drop policy if exists "admin insert" on public.stock_transfers;
create policy "admin insert" on public.stock_transfers for insert
  to authenticated with check (public.is_admin());

-- --- Guard transfer_stock() itself ---
-- The Fase 1 function is `security invoker` (default), so its internal
-- UPDATE on products already runs under the new admin-only RLS policy —
-- but an RLS-filtered UPDATE just matches 0 rows silently instead of
-- raising an error. Without this explicit check, a vendedor calling this
-- RPC directly would get a "successful" response, a bogus stock_transfers
-- audit row, and no actual stock movement. Re-create with a loud guard.
create or replace function public.transfer_stock(
  p_product_id uuid,
  p_from text,
  p_to text,
  p_quantity integer,
  p_note text default null
) returns void
language plpgsql
as $$
declare
  v_from_stock integer;
begin
  if not public.is_admin() then
    raise exception 'Solo el admin puede hacer traspasos';
  end if;
  if p_from = p_to then
    raise exception 'El origen y destino deben ser distintos';
  end if;
  if p_from not in ('online', 'fisica') or p_to not in ('online', 'fisica') then
    raise exception 'Ubicación inválida';
  end if;
  if p_quantity <= 0 then
    raise exception 'La cantidad debe ser mayor a cero';
  end if;

  if p_from = 'online' then
    select stock_online into v_from_stock from public.products where id = p_product_id for update;
  else
    select stock_fisica into v_from_stock from public.products where id = p_product_id for update;
  end if;

  if v_from_stock is null then
    raise exception 'Producto no encontrado';
  end if;
  if v_from_stock < p_quantity then
    raise exception 'No hay suficiente stock en % (% disponibles)', p_from, v_from_stock;
  end if;

  if p_from = 'online' then
    update public.products set stock_online = stock_online - p_quantity where id = p_product_id;
  else
    update public.products set stock_fisica = stock_fisica - p_quantity where id = p_product_id;
  end if;

  if p_to = 'online' then
    update public.products set stock_online = stock_online + p_quantity where id = p_product_id;
  else
    update public.products set stock_fisica = stock_fisica + p_quantity where id = p_product_id;
  end if;

  insert into public.stock_transfers (product_id, from_location, to_location, quantity, note, created_by)
  values (p_product_id, p_from, p_to, p_quantity, p_note, auth.uid());
end;
$$;

alter function public.transfer_stock(uuid, text, text, integer, text) set search_path = public;
```

- [ ] **Step 2: Apply the migration**

`apply_migration`, `project_id: "iatyvxljzrcdfmmtesig"`,
`name: "admin_only_writes"`, `query: <file above>`.

- [ ] **Step 3: Verify**

```sql
select cost_price from public.products_view limit 3;
```

Expected: `cost_price` is `null` for all 3 rows (no authenticated admin
session in a direct SQL call, so `is_admin()` evaluates false — this
confirms the masking defaults closed; the "admin sees it" path is verified
in Task 5's manual browser check).

```sql
select grantee, privilege_type from information_schema.column_privileges
where table_name = 'products' and column_name = 'cost_price';
```

Expected: no row for `anon` or `authenticated` (only `postgres`/`service_role`
if any).

```sql
select proname, prosecdef from pg_proc where proname = 'transfer_stock';
```

Expected: one row (function replaced successfully).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0008_admin_only_writes.sql
git commit -m "Restrict product/taxonomy writes and cost_price reads to admin"
```

---

### Task 3: Migration 0009 — `sales` + `sale_items`

**Files:**
- Create: `supabase/migrations/0009_sales.sql`

**Interfaces:**
- Consumes: `public.is_admin()` (Task 1).
- Produces: tables `public.sales`, `public.sale_items`; view
  `public.sale_items_view` (cost masked like `products_view`). Task 4's
  RPCs write to these tables; Task 12/13/15's frontend reads them.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0009_sales.sql
-- One table for both sales channels — see the design doc for the field
-- rationale. No insert/update policies: rows are only ever written by the
-- security-definer RPCs in migration 0010, which apply their own checks.

create table if not exists public.sales (
  id                          uuid primary key default gen_random_uuid(),
  channel                     text not null check (channel in ('online', 'fisica')),
  status                      text not null check (status in ('pagado', 'entregado', 'completada', 'revisar_sin_stock')),
  customer_name               text,
  customer_phone              text,
  customer_email              text,
  payment_method              text not null check (payment_method in ('stripe', 'efectivo')),
  stripe_checkout_session_id  text unique,
  stripe_payment_intent_id    text,
  total                       numeric(10, 2) not null default 0 check (total >= 0),
  created_by                  uuid references auth.users(id),
  delivered_by                uuid references auth.users(id),
  delivered_at                timestamptz,
  created_at                  timestamptz not null default now()
);

create index if not exists sales_channel_status_idx on public.sales (channel, status);
create index if not exists sales_created_at_idx on public.sales (created_at desc);

alter table public.sales enable row level security;

drop policy if exists "authenticated read" on public.sales;
create policy "authenticated read" on public.sales for select to authenticated using (true);

create table if not exists public.sale_items (
  id                uuid primary key default gen_random_uuid(),
  sale_id           uuid not null references public.sales(id) on delete cascade,
  product_id        uuid references public.products(id) on delete set null,
  product_name      text not null,
  quantity          integer not null check (quantity > 0),
  unit_price        numeric(10, 2) not null check (unit_price >= 0),
  unit_cost_price   numeric(10, 2) not null check (unit_cost_price >= 0)
);

create index if not exists sale_items_sale_idx on public.sale_items (sale_id);

alter table public.sale_items enable row level security;

drop policy if exists "authenticated read" on public.sale_items;
create policy "authenticated read" on public.sale_items for select to authenticated using (true);

create or replace view public.sale_items_view as
select
  id, sale_id, product_id, product_name, quantity, unit_price,
  case when public.is_admin() then unit_cost_price else null end as unit_cost_price
from public.sale_items;

grant select on public.sale_items_view to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sales'
  ) then
    alter publication supabase_realtime add table public.sales;
  end if;
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sale_items'
  ) then
    alter publication supabase_realtime add table public.sale_items;
  end if;
end;
$$;
```

- [ ] **Step 2: Apply the migration**

`apply_migration`, `project_id: "iatyvxljzrcdfmmtesig"`, `name: "sales"`,
`query: <file above>`.

- [ ] **Step 3: Verify**

```sql
select count(*) from public.sales;
select count(*) from public.sale_items_view;
```

Expected: both `0` (tables exist and are empty, view resolves without error).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0009_sales.sql
git commit -m "Add sales and sale_items tables for POS + online orders"
```

---

### Task 4: Migration 0010 — sale RPCs

**Files:**
- Create: `supabase/migrations/0010_sale_functions.sql`

**Interfaces:**
- Consumes: `public.sales`, `public.sale_items` (Task 3).
- Produces:
  - `public.create_sale_fisica(p_items jsonb) returns uuid` — `p_items` is
    a JSON array of `{"product_id": "<uuid>", "quantity": <int>}`. Granted
    to `authenticated` (both roles). Used by Task 8 (Vender tab).
  - `public.mark_sale_delivered(p_sale_id uuid) returns void` — granted to
    `authenticated`. Used by Task 12 (Pedidos tab).
  - `public.record_online_sale(p_stripe_checkout_session_id text, p_stripe_payment_intent_id text, p_customer_name text, p_customer_phone text, p_customer_email text, p_items jsonb) returns uuid`
    — granted **only** to `service_role`. Called by the `stripe-webhook`
    Edge Function (Task 10), never from the browser.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0010_sale_functions.sql

-- ---------- Venta física (POS) ----------
create or replace function public.create_sale_fisica(p_items jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale_id uuid;
  v_item record;
  v_stock integer;
  v_price numeric(10,2);
  v_cost numeric(10,2);
  v_name text;
  v_total numeric(10,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión para vender';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Agrega al menos un producto';
  end if;

  insert into public.sales (channel, status, payment_method, total, created_by)
  values ('fisica', 'completada', 'efectivo', 0, auth.uid())
  returning id into v_sale_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then
      raise exception 'Cantidad inválida';
    end if;

    select stock_fisica, price, cost_price, name
      into v_stock, v_price, v_cost, v_name
      from public.products where id = v_item.product_id for update;

    if v_stock is null then
      raise exception 'Producto no encontrado';
    end if;
    if v_stock < v_item.quantity then
      raise exception 'No hay suficiente stock física de "%" (% disponibles)', v_name, v_stock;
    end if;

    update public.products set stock_fisica = stock_fisica - v_item.quantity where id = v_item.product_id;

    insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_sale_id, v_item.product_id, v_name, v_item.quantity, v_price, v_cost);

    v_total := v_total + v_price * v_item.quantity;
  end loop;

  update public.sales set total = v_total where id = v_sale_id;

  return v_sale_id;
end;
$$;

revoke all on function public.create_sale_fisica(jsonb) from public;
grant execute on function public.create_sale_fisica(jsonb) to authenticated;

-- ---------- Marcar pedido en línea como entregado ----------
create or replace function public.mark_sale_delivered(p_sale_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;

  select status into v_status from public.sales where id = p_sale_id for update;
  if v_status is null then
    raise exception 'Pedido no encontrado';
  end if;
  if v_status <> 'pagado' then
    raise exception 'Este pedido no está pendiente de entrega';
  end if;

  update public.sales
    set status = 'entregado', delivered_by = auth.uid(), delivered_at = now()
    where id = p_sale_id;
end;
$$;

revoke all on function public.mark_sale_delivered(uuid) from public;
grant execute on function public.mark_sale_delivered(uuid) to authenticated;

-- ---------- Registrar venta en línea (llamada solo por el webhook) ----------
create or replace function public.record_online_sale(
  p_stripe_checkout_session_id text,
  p_stripe_payment_intent_id text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_items jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale_id uuid;
  v_item record;
  v_stock integer;
  v_price numeric(10,2);
  v_cost numeric(10,2);
  v_name text;
  v_total numeric(10,2) := 0;
  v_oversold boolean := false;
begin
  -- Idempotencia: Stripe puede reenviar el mismo evento más de una vez.
  select id into v_sale_id from public.sales where stripe_checkout_session_id = p_stripe_checkout_session_id;
  if v_sale_id is not null then
    return v_sale_id;
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Sin productos en el pedido';
  end if;

  insert into public.sales (
    channel, status, customer_name, customer_phone, customer_email,
    payment_method, stripe_checkout_session_id, stripe_payment_intent_id, total
  ) values (
    'online', 'pagado', p_customer_name, p_customer_phone, p_customer_email,
    'stripe', p_stripe_checkout_session_id, p_stripe_payment_intent_id, 0
  ) returning id into v_sale_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  loop
    select stock_online, price, cost_price, name
      into v_stock, v_price, v_cost, v_name
      from public.products where id = v_item.product_id for update;

    if v_stock is null then
      v_oversold := true;
      insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
      values (v_sale_id, v_item.product_id, '(producto ya no existe)', v_item.quantity, 0, 0);
      continue;
    end if;

    if v_stock < v_item.quantity then
      v_oversold := true;
      update public.products set stock_online = 0 where id = v_item.product_id;
    else
      update public.products set stock_online = stock_online - v_item.quantity where id = v_item.product_id;
    end if;

    insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_sale_id, v_item.product_id, v_name, v_item.quantity, v_price, v_cost);

    v_total := v_total + v_price * v_item.quantity;
  end loop;

  update public.sales
    set total = v_total, status = case when v_oversold then 'revisar_sin_stock' else 'pagado' end
    where id = v_sale_id;

  return v_sale_id;
end;
$$;

revoke all on function public.record_online_sale(text, text, text, text, text, jsonb) from public;
grant execute on function public.record_online_sale(text, text, text, text, text, jsonb) to service_role;
```

- [ ] **Step 2: Apply the migration**

`apply_migration`, `project_id: "iatyvxljzrcdfmmtesig"`,
`name: "sale_functions"`, `query: <file above>`.

- [ ] **Step 3: Verify**

```sql
select
  p.proname,
  p.prosecdef,
  array_agg(distinct r.rolname) filter (where has_function_privilege(r.oid, p.oid, 'EXECUTE')) as can_execute
from pg_proc p
cross join pg_roles r
where p.proname in ('create_sale_fisica', 'mark_sale_delivered', 'record_online_sale')
  and r.rolname in ('anon', 'authenticated', 'service_role')
group by p.proname, p.prosecdef;
```

Expected: `create_sale_fisica` and `mark_sale_delivered` show
`{authenticated}` in `can_execute` (not `anon`); `record_online_sale` shows
`{service_role}` only.

Then exercise it end-to-end against a real product (use any product id from
`select id, name, stock_fisica from public.products limit 1;`):

```sql
select public.create_sale_fisica(
  jsonb_build_array(jsonb_build_object('product_id', '<paste-a-real-id>', 'quantity', 1))
);
```

This runs as the `postgres`/service role via the SQL tool, so `auth.uid()`
is null and the function should raise `Debes iniciar sesión para vender` —
that's the expected (correct) result here; it confirms the guard works.
Real success-path testing happens in Task 8/11 through the browser, where
`auth.uid()` is a real logged-in user.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0010_sale_functions.sql
git commit -m "Add create_sale_fisica, mark_sale_delivered, record_online_sale RPCs"
```

---

### Task 5: Frontend — roles infrastructure in the admin panel

**Files:**
- Modify: `app/admin.html:44-45` (remove signup toggle), `app/admin.html:57-63` (tab `data-role-*` attributes), `app/admin.html:131-148` (Costo column)
- Modify: `app/js/admin.js:1-24` (add role state), `app/js/admin.js:44-49` (tab click gating), `app/js/admin.js:53-112` (auth flow), `app/js/admin.js:590` and `catalog-data.js` reads (switch to `products_view`)

**Interfaces:**
- Produces: module-level `let CURRENT_ROLE = null;` (`'admin'` or
  `'vendedor'`) in `admin.js`, set right after login. Later tasks (7, 8, 12)
  read `CURRENT_ROLE` to decide what to render/allow.

- [ ] **Step 1: Remove the self-signup UI**

In `app/admin.html`, delete this line (the "create account" toggle):

```html
    <button type="button" id="mode-toggle" style="background:none;border:none;color:var(--ink-soft);font-size:0.85rem;text-decoration:underline;cursor:pointer;padding:0;">¿Primera vez? Crea tu cuenta</button>
```

- [ ] **Step 2: Remove the signup code path in admin.js**

Replace lines 68-107 of `app/js/admin.js` (the `authMode`/`modeToggle`
block and the signup branch inside the submit handler) with:

```javascript
document.getElementById('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const email = document.getElementById('login-email').value.trim();
  const password = document.getElementById('login-password').value;
  const errEl = document.getElementById('login-error');
  errEl.textContent = '';

  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    errEl.textContent = 'No se pudo iniciar sesión. Revisa tu correo y contraseña.';
    return;
  }
  refreshAuthUI();
});

logoutBtn.addEventListener('click', async () => {
  await supabase.auth.signOut();
  refreshAuthUI();
});
```

Also remove the now-unused `login-success` paragraph from `app/admin.html`
(`<p class="form-error" id="login-success" ...></p>`) since there's no more
"check your email" message to show here.

- [ ] **Step 3: Fetch the current user's role after login**

Add near the top of `app/js/admin.js` (after the existing `let` declarations
around line 13):

```javascript
let CURRENT_ROLE = null; // 'admin' | 'vendedor'
```

Replace `refreshAuthUI` (lines 53-66) with:

```javascript
async function refreshAuthUI() {
  const { data: { session } } = await supabase.auth.getSession();
  if (session) {
    const { data: profile, error } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', session.user.id)
      .single();
    if (error || !profile) {
      showToast('Tu cuenta no tiene un rol asignado. Contacta al admin.', true);
      await supabase.auth.signOut();
      loginView.hidden = false;
      adminView.hidden = true;
      logoutBtn.hidden = true;
      return;
    }
    CURRENT_ROLE = profile.role;
    loginView.hidden = true;
    adminView.hidden = false;
    logoutBtn.hidden = false;
    applyRoleVisibility();
    await loadEverything();
    subscribeRealtime();
  } else {
    CURRENT_ROLE = null;
    loginView.hidden = false;
    adminView.hidden = true;
    logoutBtn.hidden = true;
  }
}
```

- [ ] **Step 4: Add `data-role-*` attributes to every tab button and gate them**

In `app/admin.html`, replace the tab row (lines 57-63) with:

```html
  <div class="tab-row" role="tablist">
    <button class="tab-btn" data-tab="inventory" type="button" aria-selected="true" data-role-admin data-role-vendedor>Inventario</button>
    <button class="tab-btn" data-tab="sell" type="button" aria-selected="false" data-role-admin data-role-vendedor>Vender</button>
    <button class="tab-btn" data-tab="orders" type="button" aria-selected="false" data-role-admin data-role-vendedor>Pedidos</button>
    <button class="tab-btn" data-tab="transfers" type="button" aria-selected="false" data-role-admin>Traspasos</button>
    <button class="tab-btn" data-tab="promotions" type="button" aria-selected="false" data-role-admin>Promociones</button>
    <button class="tab-btn" data-tab="taxonomy" type="button" aria-selected="false" data-role-admin>Líneas y categorías</button>
    <button class="tab-btn" data-tab="reports" type="button" aria-selected="false" data-role-admin>Reportes</button>
    <button class="tab-btn" data-tab="users" type="button" aria-selected="false" data-role-admin>Usuarios</button>
  </div>
```

(The `tab-sell`, `tab-orders`, `tab-users` `<section>` panels themselves are
added in Tasks 8, 12, 7 — this step only wires the buttons and visibility
logic so those later tasks have somewhere to hook in.)

In `app/js/admin.js`, add this function (near the tabs section, after line
49) and call it from `refreshAuthUI` (already wired in Step 3):

```javascript
function applyRoleVisibility() {
  document.querySelectorAll('.tab-btn').forEach(btn => {
    const allowed = btn.hasAttribute(`data-role-${CURRENT_ROLE}`);
    btn.hidden = !allowed;
  });
  const activeBtn = document.querySelector('.tab-btn[aria-selected="true"]');
  if (!activeBtn || activeBtn.hidden) {
    const firstVisible = document.querySelector('.tab-btn:not([hidden])');
    if (firstVisible) firstVisible.click();
  }
}
```

- [ ] **Step 5: Hide the Costo column and edit affordances for vendedor**

In `app/admin.html`, add an id to the Costo header cell (line 137):

```html
            <th id="col-cost-header">Costo</th>
```

In `app/js/admin.js`, modify `rowHtml` (lines 179-198) to make the cost
cell and the delete button conditional, and disable inputs for vendedor:

```javascript
function rowHtml(p) {
  const low = p.stock_online <= 1 || p.stock_fisica <= 1;
  const readOnly = CURRENT_ROLE !== 'admin';
  const dis = readOnly ? 'disabled' : '';
  return `
    <tr data-id="${p.id}" class="${low ? 'low-stock' : ''}">
      <td style="min-width:180px;">${lineCategoryCellHtml(p)}</td>
      <td><input class="cell-input" data-field="code" value="${p.code ? escapeHtml(p.code) : ''}" placeholder="—" ${dis}></td>
      <td><input class="cell-input name-input" data-field="name" value="${escapeHtml(p.name)}" ${dis}></td>
      ${CURRENT_ROLE === 'admin' ? `<td><input class="cell-input" data-field="cost_price" type="number" min="0" step="0.01" value="${p.cost_price}"></td>` : ''}
      <td><input class="cell-input" data-field="price" type="number" min="0" step="0.01" value="${p.price}" ${dis}></td>
      <td><input class="cell-input" data-field="stock_online" type="number" min="0" step="1" value="${p.stock_online}" ${dis}></td>
      <td><input class="cell-input" data-field="stock_fisica" type="number" min="0" step="1" value="${p.stock_fisica}" ${dis}></td>
      <td style="text-align:center;"><input type="checkbox" data-field="published_online" ${p.published_online ? 'checked' : ''} ${dis}></td>
      <td><span class="save-pill" data-role="save-pill">Guardado</span></td>
      <td>
        ${CURRENT_ROLE === 'admin' ? `<button class="icon-mini danger" data-role="delete" type="button" aria-label="Eliminar ${escapeHtml(p.name)}">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
        </button>` : ''}
      </td>
    </tr>`;
}
```

Also toggle the header cell and the "Agregar producto" form in
`renderTable` — add this line at the top of `renderTable` (before it
touches `admin-tbody`, around line 200):

```javascript
document.getElementById('col-cost-header').hidden = CURRENT_ROLE !== 'admin';
document.getElementById('add-form').hidden = CURRENT_ROLE !== 'admin';
```

- [ ] **Step 6: Switch product reads to `products_view`**

In `app/js/admin.js:590`, change:

```javascript
  const { data, error } = await supabase.from('products').select('*').order('name');
```
to:
```javascript
  const { data, error } = await supabase.from('products_view').select('*').order('name');
```

(Writes stay on `.from('products')` at lines 249, 270, 291 — unchanged;
`products_view` is read-only.)

In `app/js/catalog.js:246`, change:

```javascript
      supabase.from('products').select('*').eq('published_online', true).order('name'),
```
to:
```javascript
      supabase.from('products_view').select('*').eq('published_online', true).order('name'),
```

- [ ] **Step 7: Manual verification**

1. Deploy nothing yet — run locally or via the existing Netlify deploy
   (see Task 14) once this and later tasks land together, OR test against
   the live Supabase project with a local static server
   (`npx serve app` or similar) pointed at the real `config.js` keys.
2. Log in as `ricardo.cabreraflo@gmail.com`. Expect: all 8 tabs visible,
   Costo column visible and editable, delete buttons visible.
3. (After Task 7 gives you a way to create a vendedor account) log in as a
   vendedor. Expect: only Inventario / Vender / Pedidos tabs visible; in
   Inventario, no Costo column, all fields disabled, no "Agregar producto"
   form, no delete buttons.
4. Confirm the login screen no longer shows "¿Primera vez? Crea tu cuenta".

- [ ] **Step 8: Commit**

```bash
git add app/admin.html app/js/admin.js app/js/catalog.js
git commit -m "Add role-based access to the admin panel, remove public signup"
```

---

### Task 6: Edge Function — `invite-vendedor`

**Files:**
- Create: `supabase/functions/invite-vendedor/index.ts`

**Interfaces:**
- Consumes: `public.profiles` (Task 1).
- Produces: `POST /functions/v1/invite-vendedor` with JSON body
  `{ "email": string }` and an `Authorization: Bearer <admin JWT>` header.
  Returns `{ "ok": true, "email": "..." }` on success, `{ "error": "..." }`
  with a 4xx/5xx status otherwise. Used by Task 7's Usuarios tab.

- [ ] **Step 1: Write the function**

```typescript
// supabase/functions/invite-vendedor/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });

  try {
    const authHeader = req.headers.get('Authorization') || '';
    const callerClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user }, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !user) return json({ error: 'No autenticado' }, 401);

    const { data: profile } = await callerClient
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single();
    if (!profile || profile.role !== 'admin') {
      return json({ error: 'Solo el admin puede invitar vendedores' }, 403);
    }

    const { email } = await req.json();
    if (!email || typeof email !== 'string' || !email.includes('@')) {
      return json({ error: 'Correo inválido' }, 400);
    }

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: invited, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(email);
    if (inviteErr) return json({ error: inviteErr.message }, 400);

    const { error: profileErr } = await admin
      .from('profiles')
      .insert({ id: invited.user.id, email, role: 'vendedor' });
    if (profileErr) {
      return json({ error: 'Cuenta invitada, pero no se pudo asignar el rol: ' + profileErr.message }, 500);
    }

    return json({ ok: true, email });
  } catch (err) {
    return json({ error: String(err) }, 500);
  }
});
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected into every
Edge Function's environment by Supabase — no secret to configure for this
one.

- [ ] **Step 2: Deploy**

Use the Supabase MCP `deploy_edge_function` tool: `project_id:
"iatyvxljzrcdfmmtesig"`, `name: "invite-vendedor"`, `entrypoint_path:
"index.ts"`, `verify_jwt: true` (only logged-in users should reach it; the
function itself further checks `role === 'admin'`), `files: [{ name:
"index.ts", content: <code above> }]`.

- [ ] **Step 3: Verify with curl**

Get a fresh access token by signing in as the admin via the Supabase Auth
REST API (replace `<ANON_KEY>` with the value from `app/js/config.js` and
supply the real admin password):

```bash
curl -s -X POST 'https://iatyvxljzrcdfmmtesig.supabase.co/auth/v1/token?grant_type=password' \
  -H "apikey: <ANON_KEY>" -H "Content-Type: application/json" \
  -d '{"email":"ricardo.cabreraflo@gmail.com","password":"<REAL_PASSWORD>"}' | jq -r .access_token
```

Then call the function:

```bash
curl -s -X POST 'https://iatyvxljzrcdfmmtesig.supabase.co/functions/v1/invite-vendedor' \
  -H "Authorization: Bearer <TOKEN_FROM_ABOVE>" -H "apikey: <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"email":"vendedor-prueba@example.com"}'
```

Expected: `{"ok":true,"email":"vendedor-prueba@example.com"}`. Then verify
via `execute_sql`: `select * from public.profiles where email =
'vendedor-prueba@example.com';` — expect one row, `role = 'vendedor'`.

Also confirm the 403 path: retry the same curl with no `Authorization`
header (or an anon-key-only call) — expect
`{"error":"No autenticado"}` with status 401.

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/invite-vendedor/index.ts
git commit -m "Add invite-vendedor Edge Function"
```

---

### Task 7: Frontend — Usuarios tab (invite vendedores)

**Files:**
- Modify: `app/admin.html` (add `<section id="tab-users">` after the Reportes section, around line 292)
- Modify: `app/js/admin.js` (Usuarios tab controller + `loadEverything` wiring)

**Interfaces:**
- Consumes: `invite-vendedor` Edge Function (Task 6), `public.profiles`
  (Task 1), `CURRENT_ROLE` (Task 5).

- [ ] **Step 1: Add the tab markup**

In `app/admin.html`, insert after the `</section>` that closes
`tab-reports` (right before `</main>`):

```html
  <!-- ---------- Usuarios ---------- -->
  <section class="tab-panel" id="tab-users" hidden>
    <div class="grid-head"><h2>Invitar vendedor</h2></div>
    <form class="add-form" id="invite-form" style="grid-template-columns: 1fr auto;">
      <div class="field">
        <label for="invite-email">Correo del vendedor</label>
        <input class="cell-input" id="invite-email" type="email" required placeholder="empleado@correo.com">
      </div>
      <div class="submit-cell"><button class="btn btn-primary btn-sm" type="submit">Invitar</button></div>
    </form>
    <p class="form-error" id="invite-error"></p>

    <div class="grid-head"><h2>Vendedores</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <thead><tr><th>Correo</th><th>Invitado</th></tr></thead>
        <tbody id="users-tbody"></tbody>
      </table>
    </div>
  </section>
```

- [ ] **Step 2: Add the controller**

In `app/js/admin.js`, add near the Reports tab section (after
`renderReports`, around line 585):

```javascript
// ---------- Users tab ----------

let VENDEDORES = [];

async function loadVendedores() {
  if (CURRENT_ROLE !== 'admin') return;
  const { data, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('role', 'vendedor')
    .order('created_at', { ascending: false });
  if (error) { console.error(error); return; }
  VENDEDORES = data;
}

function renderUsers() {
  const tbody = document.getElementById('users-tbody');
  if (VENDEDORES.length === 0) {
    tbody.innerHTML = `<tr><td colspan="2" style="color:var(--ink-soft);">Sin vendedores todavía.</td></tr>`;
    return;
  }
  tbody.innerHTML = VENDEDORES.map(v => `
    <tr>
      <td>${escapeHtml(v.email)}</td>
      <td>${new Date(v.created_at).toLocaleDateString('es-MX')}</td>
    </tr>`).join('');
}

document.getElementById('invite-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const errEl = document.getElementById('invite-error');
  errEl.textContent = '';
  const email = document.getElementById('invite-email').value.trim();
  if (!email) return;

  const { data, error } = await supabase.functions.invoke('invite-vendedor', { body: { email } });
  if (error || data?.error) {
    errEl.textContent = data?.error || error.message || 'No se pudo invitar';
    return;
  }
  showToast(`Invitación enviada a ${email}`);
  e.target.reset();
  await loadVendedores();
  renderUsers();
});
```

- [ ] **Step 3: Wire into `loadEverything`**

In `app/js/admin.js`, inside `loadEverything` (around line 604, after
`await loadTransfers();`), add:

```javascript
    await loadVendedores();
```

and inside the render calls further down (around line 617, after
`renderReports();`), add:

```javascript
    renderUsers();
```

- [ ] **Step 4: Manual verification**

1. Log in as admin, open the Usuarios tab.
2. Invite a real test email you control. Expect a toast confirming the
   invite and the new row appearing in the table.
3. Check that email's inbox for the Supabase invite link, follow it, set a
   password, and confirm you land in the admin panel with vendedor-level
   access (per Task 5's role gating).
4. As that vendedor, confirm the Usuarios tab button is not visible at all.

- [ ] **Step 5: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Add Usuarios tab for inviting vendedor accounts"
```

---

### Task 8: Frontend — Vender tab (POS física)

**Files:**
- Modify: `app/admin.html` (add `<section id="tab-sell">` after `tab-inventory`, around line 149)
- Modify: `app/js/admin.js` (Vender tab controller)

**Interfaces:**
- Consumes: `public.create_sale_fisica(jsonb)` RPC (Task 4), `PRODUCTS`
  (already loaded by `loadEverything`), `CURRENT_ROLE`.

- [ ] **Step 1: Add the tab markup**

In `app/admin.html`, insert right after the `</section>` that closes
`tab-inventory` (before the Traspasos section):

```html
  <!-- ---------- Vender (POS física) ---------- -->
  <section class="tab-panel" id="tab-sell" hidden>
    <div class="grid-head"><h2>Nueva venta en tienda</h2></div>
    <form class="add-form" id="sell-add-form" style="grid-template-columns: 2fr 1fr auto;">
      <div class="field">
        <label for="sell-product">Producto</label>
        <select class="cell-input" id="sell-product" required></select>
      </div>
      <div class="field">
        <label for="sell-qty">Cantidad</label>
        <input class="cell-input" id="sell-qty" type="number" min="1" step="1" value="1" required>
      </div>
      <div class="submit-cell"><button class="btn btn-primary btn-sm" type="button" id="sell-add-btn">Agregar</button></div>
    </form>

    <div class="table-wrap" style="margin-top:16px;">
      <table class="admin-table">
        <thead><tr><th>Producto</th><th>Cantidad</th><th>Precio</th><th>Subtotal</th><th></th></tr></thead>
        <tbody id="sell-cart-tbody"></tbody>
      </table>
    </div>

    <div class="stat-row" style="margin-top:16px;">
      <div class="stat-tile"><strong id="sell-total">$0.00</strong><span>Total</span></div>
    </div>
    <div class="add-form" style="grid-template-columns: 1fr auto; margin-top:12px;">
      <div class="field">
        <label for="sell-cash">Efectivo recibido (opcional, solo para calcular cambio)</label>
        <input class="cell-input" id="sell-cash" type="number" min="0" step="0.01">
      </div>
      <div class="submit-cell" style="align-items:flex-end;">
        <span id="sell-change" style="color:var(--ink-soft);font-size:0.9rem;"></span>
      </div>
    </div>
    <p class="form-error" id="sell-error"></p>
    <button class="btn btn-primary" type="button" id="sell-confirm-btn" style="margin-top:12px;">Confirmar venta</button>
  </section>
```

- [ ] **Step 2: Add the controller**

In `app/js/admin.js`, add after the Inventory tab section (after
`document.getElementById('admin-published-filter')...` line, around line
308):

```javascript
// ---------- Vender tab (POS física) ----------

let SELL_CART = []; // [{ product_id, quantity }]

function refreshSellProductOptions() {
  const sel = document.getElementById('sell-product');
  const current = sel.value;
  sel.innerHTML = PRODUCTS
    .filter(p => p.stock_fisica > 0)
    .map(p => `<option value="${p.id}">${p.code ? escapeHtml(p.code) + ' — ' : ''}${escapeHtml(p.name)} (Física: ${p.stock_fisica})</option>`)
    .join('');
  if (current && PRODUCTS.some(p => p.id === current)) sel.value = current;
}

document.getElementById('sell-add-btn').addEventListener('click', () => {
  const productId = document.getElementById('sell-product').value;
  const qty = Math.round(Number(document.getElementById('sell-qty').value) || 0);
  if (!productId || qty <= 0) return;
  const existing = SELL_CART.find(i => i.product_id === productId);
  if (existing) existing.quantity += qty;
  else SELL_CART.push({ product_id: productId, quantity: qty });
  renderSellCart();
});

function renderSellCart() {
  const tbody = document.getElementById('sell-cart-tbody');
  if (SELL_CART.length === 0) {
    tbody.innerHTML = `<tr><td colspan="5" style="color:var(--ink-soft);">Carrito vacío.</td></tr>`;
  } else {
    tbody.innerHTML = SELL_CART.map((item, idx) => {
      const p = productById(item.product_id);
      const subtotal = (p?.price || 0) * item.quantity;
      return `<tr>
        <td>${escapeHtml(p?.name || '—')}</td>
        <td>${item.quantity}</td>
        <td>${fmt.format(p?.price || 0)}</td>
        <td>${fmt.format(subtotal)}</td>
        <td><button class="icon-mini danger" type="button" data-idx="${idx}" aria-label="Quitar">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6l12 12M18 6L6 18"/></svg>
        </button></td>
      </tr>`;
    }).join('');
    tbody.querySelectorAll('button[data-idx]').forEach(btn => {
      btn.addEventListener('click', () => {
        SELL_CART.splice(Number(btn.dataset.idx), 1);
        renderSellCart();
      });
    });
  }
  const total = SELL_CART.reduce((s, item) => s + (productById(item.product_id)?.price || 0) * item.quantity, 0);
  document.getElementById('sell-total').textContent = fmt.format(total);
  updateSellChange();
}

function updateSellChange() {
  const total = SELL_CART.reduce((s, item) => s + (productById(item.product_id)?.price || 0) * item.quantity, 0);
  const cash = Number(document.getElementById('sell-cash').value) || 0;
  const changeEl = document.getElementById('sell-change');
  changeEl.textContent = cash > 0 ? `Cambio: ${fmt.format(Math.max(0, cash - total))}` : '';
}
document.getElementById('sell-cash').addEventListener('input', updateSellChange);

document.getElementById('sell-confirm-btn').addEventListener('click', async () => {
  const errEl = document.getElementById('sell-error');
  errEl.textContent = '';
  if (SELL_CART.length === 0) { errEl.textContent = 'Agrega al menos un producto.'; return; }

  const { error } = await supabase.rpc('create_sale_fisica', {
    p_items: SELL_CART.map(i => ({ product_id: i.product_id, quantity: i.quantity })),
  });
  if (error) { errEl.textContent = error.message; return; }

  showToast('Venta registrada');
  SELL_CART = [];
  document.getElementById('sell-cash').value = '';
  renderSellCart();
  await reloadProducts();
  renderTable();
  refreshSellProductOptions();
  refreshTransferProductOptions();
  renderStats();
});
```

- [ ] **Step 3: Wire into `loadEverything`**

In `app/js/admin.js`, inside `loadEverything`, after `refreshTransferProductOptions();`
(around line 610), add:

```javascript
    refreshSellProductOptions();
```

- [ ] **Step 4: Manual verification**

1. Log in (admin or, once Task 7 is done, a vendedor). Open the Vender tab.
2. Pick a product with `stock_fisica > 0`, add it with quantity 1, confirm
   the cart row and total look right.
3. Click "Confirmar venta". Expect a success toast, the cart to clear, and
   the product's `stock_fisica` in the Inventario tab to have gone down by
   1.
4. Verify via `execute_sql`: `select * from public.sales where channel =
   'fisica' order by created_at desc limit 1;` — expect one row, `status =
   'completada'`, `payment_method = 'efectivo'`, `created_by` = your user
   id. `select * from public.sale_items where sale_id = '<that id>';` —
   expect one row matching the product/qty/price.
5. Try to oversell (add quantity greater than `stock_fisica`) — expect the
   error message from the RPC surfaced in `#sell-error`, and confirm
   nothing was deducted (`stock_fisica` unchanged, no new `sales` row).

- [ ] **Step 5: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Add Vender tab for in-store cash sales"
```

---

### Task 9: Edge Function — `create-checkout-session`

**Files:**
- Create: `supabase/functions/create-checkout-session/index.ts`

**Interfaces:**
- Produces: `POST /functions/v1/create-checkout-session` with JSON body
  `{ "items": [{"product_id": string, "quantity": number}], "customer_name":
  string, "customer_phone": string, "customer_email": string }`. Returns
  `{ "url": "<stripe checkout url>" }` on success, `{ "error": "..." }`
  otherwise. The Stripe Checkout Session's `metadata.cart` is a JSON string
  of `[{product_id, quantity}]` — Task 10's webhook parses this exact shape.
  Used by Task 11's catalog checkout.

- [ ] **Step 1: Write the function**

```typescript
// supabase/functions/create-checkout-session/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const SITE_URL = Deno.env.get('SITE_URL') ?? 'https://lemus-store.netlify.app';

const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2024-06-20' });
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });

  try {
    const { items, customer_name, customer_phone, customer_email } = await req.json();

    if (!Array.isArray(items) || items.length === 0) {
      return json({ error: 'El carrito está vacío' }, 400);
    }
    if (!customer_name || !customer_phone || !customer_email) {
      return json({ error: 'Faltan tus datos de contacto' }, 400);
    }

    const ids = items.map((i: { product_id: string }) => i.product_id);
    const { data: products, error: prodErr } = await supabase
      .from('products')
      .select('id, name, price, stock_online, published_online')
      .in('id', ids);
    if (prodErr) throw prodErr;

    const lineItems = [];
    for (const item of items) {
      const p = products.find((x: { id: string }) => x.id === item.product_id);
      const qty = Number(item.quantity) || 0;
      if (!p || !p.published_online) {
        return json({ error: 'Un producto de tu carrito ya no está disponible.' }, 409);
      }
      if (qty <= 0 || qty > p.stock_online) {
        return json({ error: `Solo quedan ${p.stock_online} de "${p.name}" — actualiza tu carrito.` }, 409);
      }
      lineItems.push({
        quantity: qty,
        price_data: {
          currency: 'mxn',
          unit_amount: Math.round(p.price * 100),
          product_data: { name: p.name },
        },
      });
    }

    const cartMetadata = JSON.stringify(
      items.map((i: { product_id: string; quantity: number }) => ({ product_id: i.product_id, quantity: i.quantity }))
    );
    if (cartMetadata.length > 500) {
      return json({ error: 'Carrito con demasiados productos distintos para procesar de una vez.' }, 400);
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      line_items: lineItems,
      success_url: `${SITE_URL}/index.html?checkout=success`,
      cancel_url: `${SITE_URL}/index.html?checkout=cancel`,
      customer_email,
      metadata: { cart: cartMetadata, customer_name, customer_phone, customer_email },
    });

    return json({ url: session.url });
  } catch (err) {
    return json({ error: String(err) }, 500);
  }
});
```

- [ ] **Step 2: Set the Stripe secret**

Ask Ricardo for his Stripe **test-mode** secret key (`sk_test_...`) if not
already provided. Set it as an Edge Function secret — via the Supabase
Dashboard (Project Settings → Edge Functions → Secrets → add
`STRIPE_SECRET_KEY`), or if the Supabase CLI is available in your
environment: `npx supabase secrets set --project-ref iatyvxljzrcdfmmtesig STRIPE_SECRET_KEY=sk_test_...`.
No MCP tool exposes secret-setting for this project as of this plan being
written — check with ToolSearch in case one has since been added, but
default to the manual path.

- [ ] **Step 3: Deploy**

`deploy_edge_function`, `project_id: "iatyvxljzrcdfmmtesig"`, `name:
"create-checkout-session"`, `entrypoint_path: "index.ts"`, `verify_jwt:
true` (the public catalog's Supabase client automatically sends the anon
key as its bearer token even for anonymous visitors, which satisfies this
gate — no login required from the shopper), `files: [{ name: "index.ts",
content: <code above> }]`.

- [ ] **Step 4: Verify with curl**

```bash
curl -s -X POST 'https://iatyvxljzrcdfmmtesig.supabase.co/functions/v1/create-checkout-session' \
  -H "apikey: <ANON_KEY>" -H "Authorization: Bearer <ANON_KEY>" -H "Content-Type: application/json" \
  -d '{
    "items": [{"product_id": "<a-real-published-product-id-with-stock-online>", "quantity": 1}],
    "customer_name": "Prueba", "customer_phone": "5555555555", "customer_email": "prueba@example.com"
  }'
```

Expected: `{"url":"https://checkout.stripe.com/..."}`. Open that URL in a
browser — expect Stripe's real hosted checkout page showing the product
name and price in MXN.

Also verify the validation path: request a `quantity` larger than the
product's `stock_online` — expect a 409 with an `error` message, no Stripe
session created.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/create-checkout-session/index.ts
git commit -m "Add create-checkout-session Edge Function"
```

---

### Task 10: Edge Function — `stripe-webhook`

**Files:**
- Create: `supabase/functions/stripe-webhook/index.ts`

**Interfaces:**
- Consumes: `public.record_online_sale(...)` RPC (Task 4), Stripe
  `checkout.session.completed` events (from Task 9's sessions).
- Produces: `POST /functions/v1/stripe-webhook` (called by Stripe, not by
  our frontend).

- [ ] **Step 1: Write the function**

```typescript
// supabase/functions/stripe-webhook/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const STRIPE_WEBHOOK_SECRET = Deno.env.get('STRIPE_WEBHOOK_SECRET')!;

const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2024-06-20' });
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

Deno.serve(async (req) => {
  const signature = req.headers.get('stripe-signature');
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature!, STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    return new Response(`Firma inválida: ${err}`, { status: 400 });
  }

  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session;
    const meta = session.metadata!;
    const items = JSON.parse(meta.cart);

    const { error } = await supabase.rpc('record_online_sale', {
      p_stripe_checkout_session_id: session.id,
      p_stripe_payment_intent_id: (session.payment_intent as string) ?? null,
      p_customer_name: meta.customer_name,
      p_customer_phone: meta.customer_phone,
      p_customer_email: meta.customer_email,
      p_items: items,
    });
    if (error) {
      console.error('record_online_sale failed', error);
      return new Response('Error al registrar la venta', { status: 500 });
    }
  }

  return new Response('ok', { status: 200 });
});
```

- [ ] **Step 2: Deploy (before registering with Stripe — the URL must exist first)**

`deploy_edge_function`, `project_id: "iatyvxljzrcdfmmtesig"`, `name:
"stripe-webhook"`, `entrypoint_path: "index.ts"`, `verify_jwt: false`
(Stripe calls this with its own `stripe-signature` header, not a Supabase
JWT — the function body itself verifies authenticity via
`constructEventAsync`, which is exactly the documented exception for
disabling `verify_jwt`), `files: [{ name: "index.ts", content: <code
above> }]`. The function's URL will be
`https://iatyvxljzrcdfmmtesig.supabase.co/functions/v1/stripe-webhook`.

- [ ] **Step 3: Register the endpoint in Stripe and set both secrets**

This step is manual (no Stripe MCP tool is available in this session) —
walk Ricardo through it or do it together:
1. In the Stripe Dashboard (test mode) → Developers → Webhooks → "Add
   endpoint".
2. Endpoint URL: `https://iatyvxljzrcdfmmtesig.supabase.co/functions/v1/stripe-webhook`.
3. Event to send: `checkout.session.completed`.
4. After creating it, Stripe shows a signing secret (`whsec_...`) — copy
   it.
5. Set both `STRIPE_SECRET_KEY` (if not already set in Task 9) and
   `STRIPE_WEBHOOK_SECRET` as Edge Function secrets, same mechanism as
   Task 9 Step 2.

- [ ] **Step 4: Verify end-to-end with a real test payment**

Use the Stripe test card `4242 4242 4242 4242`, any future expiry, any CVC,
any ZIP:
1. Re-run the `create-checkout-session` curl from Task 9 to get a fresh
   checkout URL, open it, and pay with the test card.
2. In the Stripe Dashboard → Developers → Webhooks → your endpoint →
   confirm a `checkout.session.completed` event was delivered with a `200`
   response.
3. Verify via `execute_sql`: `select id, channel, status, total,
   customer_name, stripe_checkout_session_id from public.sales where
   channel = 'online' order by created_at desc limit 1;` — expect one row,
   `status = 'pagado'`.
4. Confirm the product's `stock_online` decreased by the purchased
   quantity: `select stock_online from public.products where id =
   '<the product id you bought>';`.
5. Re-deliver the same event from the Stripe Dashboard ("resend") to test
   idempotency — expect the webhook to return 200 again but **no second
   row** in `sales` for that `stripe_checkout_session_id`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/stripe-webhook/index.ts
git commit -m "Add stripe-webhook Edge Function"
```

---

### Task 11: Frontend — real checkout in the public catalog

**Files:**
- Modify: `app/index.html` (contact fields in the drawer, around line 90-94)
- Modify: `app/js/catalog.js` (checkout handler, lines 205-208; success/cancel handling)

**Interfaces:**
- Consumes: `create-checkout-session` Edge Function (Task 9).

- [ ] **Step 1: Add contact fields to the cart drawer**

In `app/index.html`, replace the `drawer-foot` div (lines 91-94) with:

```html
  <div class="drawer-foot">
    <div class="field"><label for="chk-name">Nombre</label><input class="cell-input" id="chk-name" type="text" required></div>
    <div class="field"><label for="chk-phone">Teléfono</label><input class="cell-input" id="chk-phone" type="tel" required></div>
    <div class="field"><label for="chk-email">Correo</label><input class="cell-input" id="chk-email" type="email" required></div>
    <p class="form-error" id="checkout-error"></p>
    <div class="subtotal-row"><span>Subtotal</span><strong id="subtotal">$0.00</strong></div>
    <button class="btn btn-primary" style="width:100%;justify-content:center;" id="checkout-btn" type="button">Ir a pagar</button>
    <p style="color:var(--ink-soft);font-size:0.8rem;margin:6px 0 0;">Recoges tu pedido en tienda — no hacemos envíos por ahora.</p>
  </div>
```

- [ ] **Step 2: Replace the demo checkout handler**

In `app/js/catalog.js`, replace lines 205-208:

```javascript
document.getElementById('checkout-btn').addEventListener('click', () => {
  if (Object.keys(cart).length === 0) { showToast('Agrega algo antes de pagar'); return; }
  showToast('Demo — el pago se conectaría aquí');
});
```

with:

```javascript
document.getElementById('checkout-btn').addEventListener('click', async () => {
  const errEl = document.getElementById('checkout-error');
  errEl.textContent = '';
  if (Object.keys(cart).length === 0) { showToast('Agrega algo antes de pagar'); return; }

  const customer_name = document.getElementById('chk-name').value.trim();
  const customer_phone = document.getElementById('chk-phone').value.trim();
  const customer_email = document.getElementById('chk-email').value.trim();
  if (!customer_name || !customer_phone || !customer_email) {
    errEl.textContent = 'Completa tus datos de contacto.';
    return;
  }

  const btn = document.getElementById('checkout-btn');
  btn.disabled = true;
  btn.textContent = 'Redirigiendo a pago…';

  const items = Object.entries(cart).map(([product_id, quantity]) => ({ product_id, quantity }));
  const { data, error } = await supabase.functions.invoke('create-checkout-session', {
    body: { items, customer_name, customer_phone, customer_email },
  });

  btn.disabled = false;
  btn.textContent = 'Ir a pagar';

  if (error || data?.error) {
    errEl.textContent = data?.error || error.message || 'No se pudo iniciar el pago';
    return;
  }
  window.location.href = data.url;
});
```

- [ ] **Step 3: Handle the return from Stripe**

In `app/js/catalog.js`, add near the bottom (right before the final
`buildHeroFloats(); updateCartUI(); loadAll(); subscribeRealtime();` calls
around line 273):

```javascript
function handleCheckoutReturn() {
  const params = new URLSearchParams(window.location.search);
  const status = params.get('checkout');
  if (status === 'success') {
    Object.keys(cart).forEach(id => delete cart[id]);
    updateCartUI();
    showToast('¡Listo! Tu pedido está pagado — pasa a recogerlo a la tienda.');
  } else if (status === 'cancel') {
    showToast('Pago cancelado. Tu carrito sigue aquí.');
  }
  if (status) {
    params.delete('checkout');
    const qs = params.toString();
    window.history.replaceState({}, '', window.location.pathname + (qs ? `?${qs}` : ''));
  }
}
```

Call it right after `updateCartUI();` in the bottom block:

```javascript
buildHeroFloats();
updateCartUI();
handleCheckoutReturn();
loadAll();
subscribeRealtime();
```

- [ ] **Step 4: Verify `supabase.functions` exists in the vendored bundle**

Before relying on `supabase.functions.invoke`, open the deployed catalog
page in a browser console and run `typeof window.supabase.functions?.invoke`.
Expected: `"function"`. If it's `"undefined"` instead, the vendored
`app/js/vendor/supabase.umd.js` build doesn't include the Functions client
— in that case, replace the `supabase.functions.invoke(...)` call in Step 2
with a raw fetch:

```javascript
const res = await fetch(`${SUPABASE_URL}/functions/v1/create-checkout-session`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'apikey': SUPABASE_ANON_KEY, 'Authorization': `Bearer ${SUPABASE_ANON_KEY}` },
  body: JSON.stringify({ items, customer_name, customer_phone, customer_email }),
});
const data = await res.json();
const error = res.ok ? null : new Error(data.error || 'Error');
```

(importing `SUPABASE_URL`/`SUPABASE_ANON_KEY` from `./config.js` if this
fallback is needed).

- [ ] **Step 5: Manual verification (full purchase flow)**

1. Open the deployed catalog, add a product to the cart, open the drawer.
2. Fill in name/phone/email, click "Ir a pagar". Expect a redirect to a
   real Stripe Checkout page.
3. Pay with `4242 4242 4242 4242`. Expect a redirect back to
   `index.html?checkout=success`, a confirmation toast, an empty cart, and
   the URL cleaned up (no `?checkout=success` lingering after the toast).
4. Confirm the product's stock badge on the catalog card reflects the new
   (lower) `stock_online`.
5. Add something to cart, click "Ir a pagar", then click Stripe's "back"
   link instead of paying. Expect `index.html?checkout=cancel`, a "Pago
   cancelado" toast, and the cart still populated.

- [ ] **Step 6: Commit**

```bash
git add app/index.html app/js/catalog.js
git commit -m "Wire the public catalog checkout to Stripe"
```

---

### Task 12: Frontend — Pedidos tab (online orders)

**Files:**
- Modify: `app/admin.html` (add `<section id="tab-orders">`, after `tab-sell`)
- Modify: `app/js/admin.js` (Pedidos tab controller)

**Interfaces:**
- Consumes: `public.sales` (channel='online'), `public.mark_sale_delivered(uuid)` RPC (Task 4).

- [ ] **Step 1: Add the tab markup**

In `app/admin.html`, insert right after the `</section>` that closes
`tab-sell` (before the Traspasos section):

```html
  <!-- ---------- Pedidos en línea ---------- -->
  <section class="tab-panel" id="tab-orders" hidden>
    <div class="grid-head"><h2>Pendientes</h2></div>
    <div class="table-wrap" style="margin-bottom:32px;">
      <table class="admin-table">
        <thead><tr><th>Fecha</th><th>Cliente</th><th>Teléfono</th><th>Total</th><th>Estado</th><th></th></tr></thead>
        <tbody id="orders-pending-tbody"></tbody>
      </table>
    </div>
    <div class="grid-head"><h2>Entregados</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <thead><tr><th>Fecha</th><th>Cliente</th><th>Teléfono</th><th>Total</th><th>Entregado</th></tr></thead>
        <tbody id="orders-delivered-tbody"></tbody>
      </table>
    </div>
  </section>
```

- [ ] **Step 2: Add the controller**

In `app/js/admin.js`, add after the Vender tab section:

```javascript
// ---------- Pedidos tab (online orders) ----------

let ORDERS = [];

async function loadOrders() {
  const { data, error } = await supabase
    .from('sales')
    .select('*')
    .eq('channel', 'online')
    .order('created_at', { ascending: false });
  if (error) { console.error(error); return; }
  ORDERS = data;
}

function orderStatusLabel(status) {
  if (status === 'pagado') return 'Pagado — pendiente de recoger';
  if (status === 'revisar_sin_stock') return 'Revisar — sin stock';
  return status;
}

function renderOrders() {
  const pending = ORDERS.filter(o => o.status === 'pagado' || o.status === 'revisar_sin_stock');
  const delivered = ORDERS.filter(o => o.status === 'entregado');

  const pendingTbody = document.getElementById('orders-pending-tbody');
  pendingTbody.innerHTML = pending.length === 0
    ? `<tr><td colspan="6" style="color:var(--ink-soft);">Sin pedidos pendientes.</td></tr>`
    : pending.map(o => `
      <tr data-id="${o.id}" class="${o.status === 'revisar_sin_stock' ? 'low-stock' : ''}">
        <td>${new Date(o.created_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' })}</td>
        <td>${escapeHtml(o.customer_name || '—')}</td>
        <td>${escapeHtml(o.customer_phone || '—')}</td>
        <td>${fmt.format(o.total)}</td>
        <td>${orderStatusLabel(o.status)}</td>
        <td>${o.status === 'pagado' ? `<button class="btn btn-primary btn-sm" type="button" data-role="deliver">Marcar entregado</button>` : ''}</td>
      </tr>`).join('');
  pendingTbody.querySelectorAll('[data-role="deliver"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      const { error } = await supabase.rpc('mark_sale_delivered', { p_sale_id: id });
      if (error) { showToast(error.message, true); return; }
      showToast('Pedido marcado como entregado');
      await loadOrders();
      renderOrders();
    });
  });

  const deliveredTbody = document.getElementById('orders-delivered-tbody');
  deliveredTbody.innerHTML = delivered.length === 0
    ? `<tr><td colspan="5" style="color:var(--ink-soft);">Sin entregas todavía.</td></tr>`
    : delivered.map(o => `
      <tr>
        <td>${new Date(o.created_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' })}</td>
        <td>${escapeHtml(o.customer_name || '—')}</td>
        <td>${escapeHtml(o.customer_phone || '—')}</td>
        <td>${fmt.format(o.total)}</td>
        <td>${o.delivered_at ? new Date(o.delivered_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' }) : '—'}</td>
      </tr>`).join('');
}
```

- [ ] **Step 3: Wire into `loadEverything` and realtime**

In `app/js/admin.js`, inside `loadEverything` (after `await
loadVendedores();` from Task 7), add:

```javascript
    await loadOrders();
```

and among the render calls, add:

```javascript
    renderOrders();
```

In `subscribeRealtime` (around line 630), add a `sales` subscription so a
new online payment shows up without a manual refresh:

```javascript
    .on('postgres_changes', { event: '*', schema: 'public', table: 'sales' }, scheduleReload)
```

(add this line among the existing `.on(...)` chain, before `.subscribe();`).

- [ ] **Step 4: Manual verification**

1. After completing Task 11's end-to-end Stripe test purchase, open the
   Pedidos tab as admin. Expect the test order listed under "Pendientes"
   with status "Pagado — pendiente de recoger".
2. Click "Marcar entregado". Expect it to move to the "Entregados" table
   with a delivered timestamp, and disappear from "Pendientes".
3. Log in as a vendedor and confirm they can see and act on the same tab.
4. Confirm a `sales` row with `status = 'entregado'` in the DB has
   `delivered_by` set to the user who clicked the button.

- [ ] **Step 5: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Add Pedidos tab for online order pickup tracking"
```

---

### Task 13: Reports — wire real sales data

**Files:**
- Modify: `app/admin.html:291` (remove the "not connected yet" note)
- Modify: `app/admin.html` (add a sales-by-month table to `tab-reports`)
- Modify: `app/js/admin.js` (`renderReports`, lines 559-585)

**Interfaces:**
- Consumes: `public.sales`, `public.sale_items_view` (Task 3).

- [ ] **Step 1: Add markup for the sales report**

In `app/admin.html`, inside `tab-reports` (right before the closing
`</section>` at line 292), replace the "not connected yet" paragraph:

```html
    <p style="color:var(--ink-soft);font-size:0.9rem;">Los reportes de ventas por mes (cuánto se vendió, ganancia real) van a aparecer aquí una vez que conectemos el punto de venta — por ahora estos números son del inventario actual, no de ventas históricas.</p>
```

with a new table (admin-only, since it includes real cost/profit):

```html
    <div class="grid-head"><h2>Ventas por mes</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <thead><tr><th>Mes</th><th>Ventas</th><th>Piezas vendidas</th><th>Total vendido</th><th>Costo real</th><th>Ganancia real</th></tr></thead>
        <tbody id="report-sales-tbody"></tbody>
      </table>
    </div>
```

- [ ] **Step 2: Extend `renderReports`**

In `app/js/admin.js`, add a new function after `renderReports` (which stays
as-is for the inventory-snapshot numbers) and call it alongside it:

```javascript
async function renderSalesReport() {
  if (CURRENT_ROLE !== 'admin') return;
  const { data: sales, error: salesErr } = await supabase
    .from('sales')
    .select('id, total, created_at, status')
    .in('status', ['completada', 'entregado'])
    .order('created_at', { ascending: false });
  if (salesErr) { console.error(salesErr); return; }

  const { data: items, error: itemsErr } = await supabase
    .from('sale_items_view')
    .select('sale_id, quantity, unit_price, unit_cost_price');
  if (itemsErr) { console.error(itemsErr); return; }

  const bySale = new Map(items.map(i => [i.sale_id, []]));
  items.forEach(i => bySale.get(i.sale_id)?.push(i) ?? bySale.set(i.sale_id, [i]));

  const byMonth = new Map(); // 'YYYY-MM' -> { count, pieces, total, cost }
  sales.forEach(s => {
    const month = s.created_at.slice(0, 7);
    const entry = byMonth.get(month) || { count: 0, pieces: 0, total: 0, cost: 0 };
    entry.count += 1;
    entry.total += Number(s.total);
    (bySale.get(s.id) || []).forEach(i => {
      entry.pieces += i.quantity;
      entry.cost += (Number(i.unit_cost_price) || 0) * i.quantity;
    });
    byMonth.set(month, entry);
  });

  const rows = [...byMonth.entries()].sort((a, b) => b[0].localeCompare(a[0]));
  document.getElementById('report-sales-tbody').innerHTML = rows.map(([month, r]) => `
    <tr>
      <td>${month}</td>
      <td>${r.count}</td>
      <td>${r.pieces}</td>
      <td>${fmt.format(r.total)}</td>
      <td>${fmt.format(r.cost)}</td>
      <td>${fmt.format(r.total - r.cost)}</td>
    </tr>`).join('') || `<tr><td colspan="6" style="color:var(--ink-soft);">Sin ventas todavía.</td></tr>`;
}
```

In `loadEverything`, replace the `renderReports();` call with:

```javascript
    renderReports();
    await renderSalesReport();
```

- [ ] **Step 3: Manual verification**

1. As admin, after having at least one físical sale (Task 8) and one
   online sale (Task 11) completed, open Reportes. Expect "Ventas por mes"
   to show a row for the current month with count 2, matching pieces/total,
   and a real cost/profit split (not the inventory-snapshot numbers from
   the existing table above it).
2. As vendedor, open Reportes — confirm the tab itself isn't visible at all
   (per Task 5's role gating; this section double-checks
   `renderSalesReport` also no-ops defensively if somehow reached).

- [ ] **Step 4: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Wire Reportes to real sales data (ventas por mes, ganancia real)"
```

---

### Task 14: Deploy to production and run the full manual E2E checklist

**Files:** none (deployment + verification only)

- [ ] **Step 1: Deploy the frontend to Netlify**

Call the Netlify MCP `netlify-deploy-services-updater` tool with
`operation: "deploy-site"`, `siteId: "195763a4-3546-4fc2-9a65-451f1ccdea09"`.
It returns an `npx @netlify/mcp@latest --site-id ... --proxy-path "..."`
command — run it via Bash and wait for `Deploy is ready!`.

- [ ] **Step 2: Smoke-test the live site**

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://lemus-store.netlify.app
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://lemus-store.netlify.app/admin.html
```

Expected: `HTTP 200` for both.

- [ ] **Step 3: Full manual checklist against production**

Run through each of these against `https://lemus-store.netlify.app` /
`https://lemus-store.netlify.app/admin.html` (not a local copy) — this is
the final acceptance check for the whole phase:

- [ ] Admin login works; signup option is gone.
- [ ] Admin sees all 8 tabs (Inventario, Vender, Pedidos, Traspasos,
      Promociones, Líneas y categorías, Reportes, Usuarios), including the
      Costo column and edit controls in Inventario.
- [ ] Admin invites a vendedor from Usuarios; the invite email arrives;
      the vendedor sets a password and logs in.
- [ ] Vendedor sees only Inventario (read-only, no Costo column), Vender,
      Pedidos — nothing else.
- [ ] A physical sale from the Vender tab (as vendedor or admin) correctly
      decrements `stock_fisica` and shows up in `sales`/Reportes.
- [ ] A real Stripe test-mode purchase (`4242 4242 4242 4242`) from the
      public catalog completes, redirects to the success page, decrements
      `stock_online`, and appears in Pedidos as "Pagado — pendiente de
      recoger".
- [ ] Marking that order as delivered from Pedidos works and moves it to
      "Entregados".
- [ ] `curl https://iatyvxljzrcdfmmtesig.supabase.co/rest/v1/products_view?select=*&limit=1 -H "apikey: <ANON_KEY>"`
      returns `cost_price: null` (anonymous, unauthenticated request).
- [ ] Reportes → "Ventas por mes" shows the physical + online sale from
      this checklist with correct totals and a non-zero "Ganancia real".

- [ ] **Step 4: Report results to Ricardo**

Summarize pass/fail for each checklist item in plain Spanish, with the
live URLs, and flag anything that needs his attention (e.g., moving Stripe
to live mode later, deleting the `vendedor-prueba@example.com` test
account created in Task 6 if it's still around).

---

## Self-Review Notes

- **Spec coverage:** roles + `profiles` (Task 1), admin-only writes +
  cost masking including the public-catalog leak found during brainstorming
  (Task 2, Task 5 Step 6), `sales`/`sale_items` model (Task 3), all three
  RPCs incl. idempotency and the `revisar_sin_stock` oversell path (Task 4),
  self-registration removal (Task 5), vendedor invite flow (Tasks 6-7),
  physical POS (Task 8), Stripe checkout incl. server-side price/stock
  validation (Tasks 9, 11), webhook idempotency (Task 10), pedido pickup
  workflow (Task 12), real "ventas por mes / ganancia real" reports (Task
  13), and full production deploy + E2E checklist (Task 14) are all
  covered. Out-of-scope items from the spec (delivery, card/transfer
  physical payment, printable receipts, customer accounts, deactivating
  vendedor accounts, stock reservation, physical card terminal, going Stripe
  live) are intentionally not tasked here.
- **Type/name consistency check:** `create_sale_fisica(p_items jsonb)` /
  `mark_sale_delivered(p_sale_id uuid)` / `record_online_sale(...)` names
  and parameter shapes match between the migration (Task 4) and every
  caller (Tasks 8, 9/10, 12). `products_view` / `sale_items_view` names
  match between migrations (Tasks 2, 3) and every frontend read (Tasks 5,
  9, 13). `CURRENT_ROLE` is defined once (Task 5) and only read afterward
  (Tasks 5, 7, 8, 13).
- **Placeholder scan:** no TBD/TODO; every code block is complete and
  runnable as written.
