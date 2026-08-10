# Apartados (layaway) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a customer reserve one or more products with a 50% deposit and
pay the rest in cash later, in both sales channels — per
`docs/superpowers/specs/2026-08-10-apartados-design.md`.

**Architecture:** 3 new SQL migrations (tables/views, physical-side RPCs,
online-deposit RPC) applied to the live Supabase project; 1 new Edge
Function (`create-layaway-checkout-session`) plus a small branch added to
the existing `stripe-webhook`; frontend changes to `app/js/admin.js`/
`app/admin.html` (new "Apartados" tab) and `app/js/catalog.js`/
`app/index.html` (new "Apartar" button in the cart drawer).

**Tech Stack:** Supabase (Postgres + Auth + Edge Functions/Deno), vanilla JS
ES modules (no bundler), Stripe Checkout (hosted page) via `npm:stripe` in
Deno, Netlify static hosting.

## Global Constraints

- This repo has **no test framework, no build step, no package.json** — a
  static site deployed as-is to Netlify. "Tests" in this plan mean, per
  layer:
  - **SQL/RPC:** a verification query with the expected result written out.
  - **Edge Functions:** a `curl` invocation with the expected JSON/HTTP
    response written out.
  - **Frontend:** an explicit manual browser verification (open the page,
    click X, expect Y).
- **The Supabase and Netlify MCP tools are unavailable in this environment**
  (`MCP error -32003`, confirmed non-transient across the whole of Fase 2).
  Every task that touches the live database or a deployed function follows
  this pattern instead: the implementer subagent writes and commits the
  file, then reports it as **pending manual application**. Applying it
  (pasting into the Supabase SQL Editor / Edge Functions code editor /
  Netlify Drop, run by Ricardo, the non-technical store owner) and verifying
  it live is done by the **controlling session directly with Ricardo**,
  outside the subagent's task — do not block a task's completion on Ricardo
  having applied it yet, but do not mark the whole plan done until every
  piece has been confirmed live (Task 8).
- Supabase project: `iatyvxljzrcdfmmtesig`. Latest applied migration is
  `supabase/migrations/0011_fix_final_review.sql` — this plan's migrations
  start at `0012`.
- Netlify site: `https://lemus-store.netlify.app` (not git-linked — deployed
  by zipping `app/` and having Ricardo drag it into Netlify Drop).
- All UI copy is in Spanish (Mexico), currency MXN, matching the existing
  app. Follow existing code conventions: vanilla template-literal HTML
  rendering, `escapeHtml()` for any user-entered text, `showToast()` for
  user feedback, `supabase-client.js`'s exported `supabase`/`fmt`.
- Never commit real secrets (Stripe keys, service role key) to the repo.
- **Security lesson from Fase 2's final review, apply from day one, not as
  a later patch:** every new `security definer` RPC must `revoke all ...
  from public, anon, authenticated` (not just `public` — Supabase's
  `alter default privileges` bootstrap grant to `anon`/`authenticated` is a
  separate ACL record a `public`-only revoke does not touch) before
  granting execute to only the role that should actually call it, AND
  check the caller inside the function body (`auth.uid() is null` for
  admin/vendedor-only RPCs, `auth.role() <> 'service_role'` for the
  webhook-only RPC) as defense in depth. Every new table holding
  `unit_cost_price` must get the same **table-level revoke + column-level
  re-grant excluding the cost column** pattern used for `products`
  (migration 0008) and `sale_items` (migration 0011) in its own creation
  migration, not bolted on afterward.

---

## File Structure

New files:
- `supabase/migrations/0012_layaways.sql`
- `supabase/migrations/0013_layaway_functions.sql`
- `supabase/migrations/0014_online_layaway_deposit.sql`
- `supabase/functions/create-layaway-checkout-session/index.ts`

Modified files:
- `supabase/functions/stripe-webhook/index.ts` — branch on
  `metadata.kind === 'layaway_deposit'`.
- `app/js/admin.js` — new "Apartados" tab controller (cart-building form,
  Activos/Historial lists, abono/extender/cancelar actions), wired into
  `loadEverything()` and `subscribeRealtime()`.
- `app/admin.html` — new tab button + `tab-layaways` section.
- `app/js/catalog.js` — new "Apartar" button handler, extend
  `handleCheckoutReturn()` for `?apartado=success`/`?apartado=cancel`.
- `app/index.html` — new "Apartar" button in the cart drawer.

---

### Task 1: Migration 0012 — `layaways`/`layaway_items`/`layaway_payments`

**Files:**
- Create: `supabase/migrations/0012_layaways.sql`

**Interfaces:**
- Consumes: `public.is_admin()` (migration 0007).
- Produces: tables `public.layaways`, `public.layaway_items`,
  `public.layaway_payments`; view `public.layaway_items_view` (masks
  `unit_cost_price` for non-admin, same pattern as `sale_items_view`) — used
  by `admin.js` and by every later RPC in this plan.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0012_layaways.sql
-- Apartados (layaway): a customer reserves products with a deposit and
-- pays the rest later. See
-- docs/superpowers/specs/2026-08-10-apartados-design.md.
--
-- Security note (lesson from Fase 2's final review): every grant below is
-- explicit for anon/authenticated, not just `from public` — a bare
-- `revoke ... from public` does NOT remove Supabase's automatic
-- `alter default privileges ... grant all to anon, authenticated`
-- bootstrap grant on new tables, since those are separate ACL records.

create table if not exists public.layaways (
  id                          uuid primary key default gen_random_uuid(),
  channel                     text not null check (channel in ('online', 'fisica')),
  status                      text not null check (status in ('activo', 'completado', 'cancelado', 'revisar_sin_stock')),
  customer_name               text not null,
  customer_phone              text not null,
  customer_email              text,
  total                       numeric(10, 2) not null check (total >= 0),
  deposit_percent             numeric(5, 2) not null default 50,
  due_date                    date not null,
  stripe_checkout_session_id  text unique,
  completed_sale_id           uuid references public.sales(id),
  created_by                  uuid references auth.users(id),
  cancelled_by                uuid references auth.users(id),
  cancelled_at                timestamptz,
  created_at                  timestamptz not null default now()
);

create index if not exists layaways_status_idx on public.layaways (status);
create index if not exists layaways_due_date_idx on public.layaways (due_date);

alter table public.layaways enable row level security;

drop policy if exists "authenticated read" on public.layaways;
create policy "authenticated read" on public.layaways for select to authenticated using (true);

-- No insert/update/delete policy: all writes go through the RPCs in
-- migrations 0013/0014, which are security definer.

create table if not exists public.layaway_items (
  id                uuid primary key default gen_random_uuid(),
  layaway_id        uuid not null references public.layaways(id) on delete cascade,
  product_id        uuid references public.products(id) on delete set null,
  product_name      text not null,
  quantity          integer not null check (quantity > 0),
  unit_price        numeric(10, 2) not null check (unit_price >= 0),
  unit_cost_price   numeric(10, 2) not null check (unit_cost_price >= 0)
);

create index if not exists layaway_items_layaway_idx on public.layaway_items (layaway_id);

alter table public.layaway_items enable row level security;

drop policy if exists "authenticated read" on public.layaway_items;
create policy "authenticated read" on public.layaway_items for select to authenticated using (true);

-- Cost masking, same table-level-revoke + column-level-re-grant pattern as
-- products (0008) and sale_items (0011) — applied from day one this time.
revoke select on public.layaway_items from anon, authenticated;
grant select (
  id, layaway_id, product_id, product_name, quantity, unit_price
) on public.layaway_items to authenticated;

create or replace view public.layaway_items_view as
select
  id, layaway_id, product_id, product_name, quantity, unit_price,
  case when public.is_admin() then unit_cost_price else null end as unit_cost_price
from public.layaway_items;

grant select on public.layaway_items_view to authenticated;

create table if not exists public.layaway_payments (
  id            uuid primary key default gen_random_uuid(),
  layaway_id    uuid not null references public.layaways(id) on delete cascade,
  amount        numeric(10, 2) not null check (amount > 0),
  method        text not null check (method in ('stripe', 'efectivo')),
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now()
);

create index if not exists layaway_payments_layaway_idx on public.layaway_payments (layaway_id);

alter table public.layaway_payments enable row level security;

drop policy if exists "authenticated read" on public.layaway_payments;
create policy "authenticated read" on public.layaway_payments for select to authenticated using (true);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'layaways'
  ) then
    alter publication supabase_realtime add table public.layaways;
  end if;
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'layaway_payments'
  ) then
    alter publication supabase_realtime add table public.layaway_payments;
  end if;
end;
$$;
```

- [ ] **Step 2: Commit**

```bash
git add supabase/migrations/0012_layaways.sql
git commit -m "Add layaways/layaway_items/layaway_payments tables"
```

Report this task as **pending manual application** — the controlling
session will hand the SQL to Ricardo to run via the Supabase SQL Editor.

- [ ] **Step 3 (controller, after Ricardo confirms he ran it): Verify**

```sql
select table_name from information_schema.tables
where table_schema = 'public' and table_name in ('layaways', 'layaway_items', 'layaway_payments');
```

Expected: all 3 rows present.

```sql
select grantee, privilege_type from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'layaway_items' and grantee in ('anon', 'authenticated');
```

Expected: no row grants `SELECT` on the whole table to `anon` or
`authenticated` (only the column-level grant from the migration applies).

---

### Task 2: Migration 0013 — apartar/abonar/cancelar/extender RPCs (canal físico)

**Files:**
- Create: `supabase/migrations/0013_layaway_functions.sql`

**Interfaces:**
- Consumes: `public.layaways`/`layaway_items`/`layaway_payments` (Task 1),
  `public.sales`/`sale_items` (migration 0009).
- Produces: RPCs `create_layaway_fisica(p_items jsonb, p_customer_name
  text, p_customer_phone text, p_customer_email text) returns uuid`,
  `record_layaway_abono(p_layaway_id uuid, p_amount numeric) returns text`
  (returns the layaway's new status), `cancel_layaway(p_layaway_id uuid)
  returns void`, `extend_layaway_due_date(p_layaway_id uuid, p_new_due_date
  date) returns void` — all called directly from `admin.js` in Task 6.
  Also widens `sales.payment_method`'s check constraint to allow
  `'apartado'`.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0013_layaway_functions.sql
-- RPCs for the physical/manual side of apartados: creating one in-store,
-- registering cash abonos (which graduate the layaway into a real `sales`
-- row once fully paid), cancelling, and extending the due date. All
-- callable by admin or vendedor, same as create_sale_fisica.

-- A completed layaway becomes a normal sale so it shows up in Reportes
-- like any other — payment_method='apartado' is added here (rather than
-- reusing 'efectivo' or 'stripe') so reports don't misreport a sale that
-- was actually part deposit + part cash as 100% one or the other.
alter table public.sales drop constraint if exists sales_payment_method_check;
alter table public.sales add constraint sales_payment_method_check
  check (payment_method in ('stripe', 'efectivo', 'apartado'));

create or replace function public.create_layaway_fisica(
  p_items jsonb,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_layaway_id uuid;
  v_item record;
  v_stock integer;
  v_price numeric(10,2);
  v_cost numeric(10,2);
  v_name text;
  v_total numeric(10,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Sin productos en el apartado';
  end if;
  if p_customer_name is null or p_customer_name = '' or p_customer_phone is null or p_customer_phone = '' then
    raise exception 'Nombre y teléfono del cliente son obligatorios';
  end if;

  -- First pass: lock every row and validate stock before writing anything,
  -- same all-or-nothing approach as create_sale_fisica/transfer_stock.
  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  loop
    select stock_fisica, price, cost_price, name
      into v_stock, v_price, v_cost, v_name
      from public.products where id = v_item.product_id for update;

    if v_stock is null then
      raise exception 'Producto no encontrado';
    end if;
    if v_stock < v_item.quantity then
      raise exception 'Solo hay % disponibles de "%"', v_stock, v_name;
    end if;

    v_total := v_total + v_price * v_item.quantity;
  end loop;

  insert into public.layaways (
    channel, status, customer_name, customer_phone, customer_email,
    total, deposit_percent, due_date, created_by
  ) values (
    'fisica', 'activo', p_customer_name, p_customer_phone, nullif(p_customer_email, ''),
    v_total, 50, current_date + 15, auth.uid()
  ) returning id into v_layaway_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  loop
    select stock_fisica, price, cost_price, name
      into v_stock, v_price, v_cost, v_name
      from public.products where id = v_item.product_id for update;

    update public.products set stock_fisica = stock_fisica - v_item.quantity where id = v_item.product_id;

    insert into public.layaway_items (layaway_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_layaway_id, v_item.product_id, v_name, v_item.quantity, v_price, v_cost);
  end loop;

  insert into public.layaway_payments (layaway_id, amount, method, created_by)
  values (v_layaway_id, round(v_total * 0.5, 2), 'efectivo', auth.uid());

  return v_layaway_id;
end;
$$;

revoke all on function public.create_layaway_fisica(jsonb, text, text, text) from public, anon, authenticated;
grant execute on function public.create_layaway_fisica(jsonb, text, text, text) to authenticated;

create or replace function public.record_layaway_abono(
  p_layaway_id uuid,
  p_amount numeric
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_channel text;
  v_total numeric(10,2);
  v_paid numeric(10,2);
  v_pending numeric(10,2);
  v_sale_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'El monto debe ser mayor a cero';
  end if;

  select status, channel, total into v_status, v_channel, v_total
    from public.layaways where id = p_layaway_id for update;
  if v_status is null then
    raise exception 'Apartado no encontrado';
  end if;
  if v_status not in ('activo', 'revisar_sin_stock') then
    raise exception 'Este apartado ya no admite abonos';
  end if;

  select coalesce(sum(amount), 0) into v_paid from public.layaway_payments where layaway_id = p_layaway_id;
  v_pending := v_total - v_paid;
  if p_amount > v_pending then
    raise exception 'El abono no puede ser mayor al saldo pendiente ($%)', v_pending;
  end if;

  insert into public.layaway_payments (layaway_id, amount, method, created_by)
  values (p_layaway_id, p_amount, 'efectivo', auth.uid());

  if v_paid + p_amount >= v_total then
    insert into public.sales (
      channel, status, customer_name, customer_phone, customer_email,
      payment_method, total, created_by
    )
    select channel, 'completada', customer_name, customer_phone, customer_email,
      'apartado', total, auth.uid()
    from public.layaways where id = p_layaway_id
    returning id into v_sale_id;

    insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    select v_sale_id, product_id, product_name, quantity, unit_price, unit_cost_price
    from public.layaway_items where layaway_id = p_layaway_id;

    update public.layaways set status = 'completado', completed_sale_id = v_sale_id where id = p_layaway_id;
    return 'completado';
  end if;

  return v_status;
end;
$$;

revoke all on function public.record_layaway_abono(uuid, numeric) from public, anon, authenticated;
grant execute on function public.record_layaway_abono(uuid, numeric) to authenticated;

create or replace function public.cancel_layaway(p_layaway_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_channel text;
  v_item record;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;

  select status, channel into v_status, v_channel from public.layaways where id = p_layaway_id for update;
  if v_status is null then
    raise exception 'Apartado no encontrado';
  end if;
  if v_status not in ('activo', 'revisar_sin_stock') then
    raise exception 'Este apartado ya no se puede cancelar';
  end if;

  for v_item in select product_id, quantity from public.layaway_items where layaway_id = p_layaway_id
  loop
    if v_item.product_id is not null then
      if v_channel = 'fisica' then
        update public.products set stock_fisica = stock_fisica + v_item.quantity where id = v_item.product_id;
      else
        update public.products set stock_online = stock_online + v_item.quantity where id = v_item.product_id;
      end if;
    end if;
  end loop;

  update public.layaways
    set status = 'cancelado', cancelled_by = auth.uid(), cancelled_at = now()
    where id = p_layaway_id;
end;
$$;

revoke all on function public.cancel_layaway(uuid) from public, anon, authenticated;
grant execute on function public.cancel_layaway(uuid) to authenticated;

create or replace function public.extend_layaway_due_date(
  p_layaway_id uuid,
  p_new_due_date date
) returns void
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
  if p_new_due_date <= current_date then
    raise exception 'La nueva fecha debe ser futura';
  end if;

  select status into v_status from public.layaways where id = p_layaway_id for update;
  if v_status is null then
    raise exception 'Apartado no encontrado';
  end if;
  if v_status not in ('activo', 'revisar_sin_stock') then
    raise exception 'Este apartado ya no se puede modificar';
  end if;

  update public.layaways set due_date = p_new_due_date where id = p_layaway_id;
end;
$$;

revoke all on function public.extend_layaway_due_date(uuid, date) from public, anon, authenticated;
grant execute on function public.extend_layaway_due_date(uuid, date) to authenticated;
```

- [ ] **Step 2: Commit**

```bash
git add supabase/migrations/0013_layaway_functions.sql
git commit -m "Add create/abono/cancel/extend layaway RPCs"
```

Report this task as **pending manual application**.

- [ ] **Step 3 (controller, after Ricardo confirms he ran it): Verify**

```sql
select proname, prosecdef from pg_proc
where proname in ('create_layaway_fisica', 'record_layaway_abono', 'cancel_layaway', 'extend_layaway_due_date');
```

Expected: all 4 rows, `prosecdef = true` on each.

```sql
select conname, pg_get_constraintdef(oid) from pg_constraint
where conname = 'sales_payment_method_check';
```

Expected: definition includes `'apartado'`.

```sql
select routine_name, grantee, privilege_type from information_schema.role_routine_grants
where routine_name in ('create_layaway_fisica', 'record_layaway_abono', 'cancel_layaway', 'extend_layaway_due_date')
and grantee = 'anon';
```

Expected: **zero rows** — `anon` must not have execute on any of these.

---

### Task 3: Migration 0014 — `record_online_layaway_deposit` (canal en línea)

**Files:**
- Create: `supabase/migrations/0014_online_layaway_deposit.sql`

**Interfaces:**
- Consumes: `public.layaways`/`layaway_items`/`layaway_payments` (Task 1).
- Produces: RPC `record_online_layaway_deposit(p_stripe_checkout_session_id
  text, p_customer_name text, p_customer_phone text, p_customer_email
  text, p_total numeric, p_deposit_amount numeric, p_items jsonb) returns
  uuid` — callable **only** by `service_role`, invoked by `stripe-webhook`
  in Task 5. `p_items` shape: `[{product_id, quantity, unit_price}, ...]`
  (same shape `create-layaway-checkout-session` in Task 4 puts in Stripe's
  metadata, mirroring how `record_online_sale` trusts a checkout-time
  `unit_price` after Fase 2's final-review fix).

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0014_online_layaway_deposit.sql
-- Online apartado deposits: called only by stripe-webhook (service_role),
-- never directly from the browser. Locked down the same way
-- record_online_sale was fixed in migration 0011 — explicit revoke from
-- anon/authenticated (not just public) PLUS an internal role check, from
-- day one this time.

create or replace function public.record_online_layaway_deposit(
  p_stripe_checkout_session_id text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_total numeric,
  p_deposit_amount numeric,
  p_items jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_layaway_id uuid;
  v_item record;
  v_stock integer;
  v_cost numeric(10,2);
  v_name text;
  v_oversold boolean := false;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'No autorizado';
  end if;

  -- Idempotencia: Stripe puede reenviar el mismo evento más de una vez.
  select id into v_layaway_id from public.layaways where stripe_checkout_session_id = p_stripe_checkout_session_id;
  if v_layaway_id is not null then
    return v_layaway_id;
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Sin productos en el apartado';
  end if;
  if p_deposit_amount is null or p_deposit_amount <= 0 then
    raise exception 'Anticipo inválido';
  end if;
  if p_total is null or p_total < p_deposit_amount then
    raise exception 'Total inválido';
  end if;

  insert into public.layaways (
    channel, status, customer_name, customer_phone, customer_email,
    total, deposit_percent, due_date, stripe_checkout_session_id
  ) values (
    'online', 'activo', p_customer_name, p_customer_phone, p_customer_email,
    p_total, 50, current_date + 15, p_stripe_checkout_session_id
  ) returning id into v_layaway_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer, unit_price numeric)
  loop
    if v_item.unit_price is null or v_item.unit_price < 0 then
      raise exception 'Precio inválido en el apartado';
    end if;

    select stock_online, cost_price, name
      into v_stock, v_cost, v_name
      from public.products where id = v_item.product_id for update;

    if v_stock is null then
      v_oversold := true;
      insert into public.layaway_items (layaway_id, product_id, product_name, quantity, unit_price, unit_cost_price)
      values (v_layaway_id, v_item.product_id, '(producto ya no existe)', v_item.quantity, 0, 0);
      continue;
    end if;

    if v_stock < v_item.quantity then
      v_oversold := true;
      update public.products set stock_online = 0 where id = v_item.product_id;
    else
      update public.products set stock_online = stock_online - v_item.quantity where id = v_item.product_id;
    end if;

    insert into public.layaway_items (layaway_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_layaway_id, v_item.product_id, v_name, v_item.quantity, v_item.unit_price, v_cost);
  end loop;

  insert into public.layaway_payments (layaway_id, amount, method, created_by)
  values (v_layaway_id, p_deposit_amount, 'stripe', null);

  if v_oversold then
    update public.layaways set status = 'revisar_sin_stock' where id = v_layaway_id;
  end if;

  return v_layaway_id;
end;
$$;

revoke all on function public.record_online_layaway_deposit(text, text, text, text, numeric, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.record_online_layaway_deposit(text, text, text, text, numeric, numeric, jsonb) to service_role;
```

- [ ] **Step 2: Commit**

```bash
git add supabase/migrations/0014_online_layaway_deposit.sql
git commit -m "Add record_online_layaway_deposit RPC for the online apartado flow"
```

Report this task as **pending manual application**.

- [ ] **Step 3 (controller, after Ricardo confirms he ran it): Verify with curl**

```bash
ANON="<anon key from app/js/config.js>"
curl -s -X POST "https://iatyvxljzrcdfmmtesig.supabase.co/rest/v1/rpc/record_online_layaway_deposit" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{"p_stripe_checkout_session_id":"plan-security-test","p_customer_name":"t","p_customer_phone":"t","p_customer_email":"t@t.com","p_total":100,"p_deposit_amount":50,"p_items":[]}' \
  -w "\nHTTP %{http_code}\n"
```

Expected: `HTTP 401` with `"permission denied for function record_online_layaway_deposit"` — confirms `anon` is rejected at the permission layer, same check that caught the Fase 2 bug on `record_online_sale`.

---

### Task 4: Edge Function `create-layaway-checkout-session`

**Files:**
- Create: `supabase/functions/create-layaway-checkout-session/index.ts`

**Interfaces:**
- Consumes: `products`, `promotions` tables (service-role read, bypasses
  RLS); Stripe Checkout Sessions API.
- Produces: HTTP endpoint invoked by `catalog.js` (Task 7) with body
  `{items: [{product_id, quantity}], customer_name, customer_phone,
  customer_email}`, responds `{url}` (Stripe Checkout URL) or `{error}`.
  Creates a Stripe Checkout Session whose `metadata.kind` is
  `'layaway_deposit'` — read by `stripe-webhook` in Task 5.

- [ ] **Step 1: Write the function**

```typescript
// supabase/functions/create-layaway-checkout-session/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const SITE_URL = Deno.env.get('SITE_URL') ?? 'https://lemus-store.netlify.app';

const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2024-06-20' });
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const DEPOSIT_PERCENT = 50;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
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
      .select('id, name, price, stock_online, published_online, product_line_id, category_id')
      .in('id', ids);
    if (prodErr) throw prodErr;

    const nowIso = new Date().toISOString();
    const { data: promotions, error: promoErr } = await supabase
      .from('promotions')
      .select('*')
      .eq('active', true)
      .or(`starts_at.is.null,starts_at.lte.${nowIso}`)
      .or(`ends_at.is.null,ends_at.gte.${nowIso}`);
    if (promoErr) throw promoErr;

    // Same "best active promotion" logic as app/js/catalog-data.js and
    // create-checkout-session, kept in sync manually since Edge Functions
    // can't import frontend modules.
    function discountedPrice(p: { price: number; product_line_id: string | null; category_id: string | null }) {
      const matches = (promotions ?? []).filter((promo: { scope_type: string; product_line_id: string | null; category_id: string | null; discount_percent: number }) =>
        (promo.scope_type === 'line' && promo.product_line_id === p.product_line_id) ||
        (promo.scope_type === 'category' && promo.category_id === p.category_id)
      );
      if (matches.length === 0) return p.price;
      const best = matches.reduce((a, b) => (b.discount_percent > a.discount_percent ? b : a), matches[0]);
      return Math.round(p.price * (1 - best.discount_percent / 100) * 100) / 100;
    }

    const qtyMap = new Map<string, number>();
    for (const item of items) {
      const qty = Number(item.quantity) || 0;
      const current = qtyMap.get(item.product_id) ?? 0;
      qtyMap.set(item.product_id, current + qty);
    }

    const cartItems = [];
    let total = 0;
    for (const [productId, totalQty] of qtyMap.entries()) {
      const p = products.find((x: { id: string }) => x.id === productId);
      if (!p || !p.published_online) {
        return json({ error: 'Un producto de tu carrito ya no está disponible.' }, 409);
      }
      if (totalQty <= 0 || totalQty > p.stock_online) {
        return json({ error: `Solo quedan ${p.stock_online} de "${p.name}" — actualiza tu carrito.` }, 409);
      }
      const unitPrice = discountedPrice(p);
      total += unitPrice * totalQty;
      cartItems.push({ product_id: productId, quantity: totalQty, unit_price: unitPrice });
    }

    total = Math.round(total * 100) / 100;
    const depositAmount = Math.round(total * (DEPOSIT_PERCENT / 100) * 100) / 100;

    const cartMetadata = JSON.stringify(cartItems);
    if (cartMetadata.length > 500) {
      return json({ error: 'Carrito con demasiados productos distintos para procesar de una vez.' }, 400);
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      line_items: [{
        quantity: 1,
        price_data: {
          currency: 'mxn',
          unit_amount: Math.round(depositAmount * 100),
          product_data: { name: `Anticipo de apartado (${DEPOSIT_PERCENT}% de $${total.toFixed(2)})` },
        },
      }],
      success_url: `${SITE_URL}/index.html?apartado=success`,
      cancel_url: `${SITE_URL}/index.html?apartado=cancel`,
      customer_email,
      metadata: {
        kind: 'layaway_deposit',
        cart: cartMetadata,
        customer_name,
        customer_phone,
        customer_email,
        total: total.toFixed(2),
        deposit_amount: depositAmount.toFixed(2),
      },
    });

    return json({ url: session.url });
  } catch (err) {
    return json({ error: String(err) }, 500);
  }
});
```

- [ ] **Step 2: Commit**

```bash
git add supabase/functions/create-layaway-checkout-session/index.ts
git commit -m "Add create-layaway-checkout-session Edge Function"
```

Report this task as **pending manual deploy** — Ricardo deploys it via the
Supabase Dashboard's Edge Functions code editor (new function, "Verify JWT"
**off**, same as `create-checkout-session`, since anonymous shoppers call
this with no Supabase session).

- [ ] **Step 3 (controller, after Ricardo confirms he deployed it): Verify with curl**

```bash
curl -s -X OPTIONS "https://iatyvxljzrcdfmmtesig.supabase.co/functions/v1/create-layaway-checkout-session" \
  -H "Origin: https://lemus-store.netlify.app" -w "\nHTTP %{http_code}\n"
```

Expected: `HTTP 200`, confirms the function is deployed and answers CORS
preflight (the exact failure mode Fase 2 hit with a missing
`x-client-info` header — this function's `CORS_HEADERS` already includes
it, this just confirms the deploy went out with that fix in place).

---

### Task 5: `stripe-webhook` — branch on `metadata.kind`

**Files:**
- Modify: `supabase/functions/stripe-webhook/index.ts:23-40`

**Interfaces:**
- Consumes: RPC `record_online_layaway_deposit` (Task 3).

- [ ] **Step 1: Add the layaway branch**

Current code (the whole `checkout.session.completed` handling block):

```typescript
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

Replace it with:

```typescript
  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session;
    const meta = session.metadata!;
    const items = JSON.parse(meta.cart);

    if (meta.kind === 'layaway_deposit') {
      const { error } = await supabase.rpc('record_online_layaway_deposit', {
        p_stripe_checkout_session_id: session.id,
        p_customer_name: meta.customer_name,
        p_customer_phone: meta.customer_phone,
        p_customer_email: meta.customer_email,
        p_total: Number(meta.total),
        p_deposit_amount: Number(meta.deposit_amount),
        p_items: items,
      });
      if (error) {
        console.error('record_online_layaway_deposit failed', error);
        return new Response('Error al registrar el apartado', { status: 500 });
      }
      return new Response('ok', { status: 200 });
    }

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

(Existing `checkout.session.completed` sales flow is otherwise untouched —
regular checkout sessions never set `metadata.kind`, so `meta.kind ===
'layaway_deposit'` is `false` for them and they fall through to the
existing `record_online_sale` call exactly as before.)

- [ ] **Step 2: Commit**

```bash
git add supabase/functions/stripe-webhook/index.ts
git commit -m "Branch stripe-webhook to handle layaway deposit sessions"
```

Report this task as **pending manual re-deploy** of the existing
`stripe-webhook` function (same function, updated code — no new webhook
registration needed in Stripe's dashboard, the endpoint URL doesn't
change).

- [ ] **Step 3 (controller, after Ricardo confirms he re-deployed it): Verify**

No live-callable verification for this one in isolation (it only reacts to
real Stripe webhook events) — verified end-to-end together with Task 4 in
Task 8's manual checklist (a real test-mode apartado purchase).

---

### Task 6: Frontend — pestaña "Apartados" (`admin.js` + `admin.html`)

**Files:**
- Modify: `app/admin.html:73-74` (new tab button), `app/admin.html:206-221`
  (insert new section after the existing `tab-orders` section)
- Modify: `app/js/admin.js:360-438` region (new controller functions,
  placed after the existing Vender/Pedidos tab code), `app/js/admin.js`'s
  `loadEverything()` and `subscribeRealtime()` functions

**Interfaces:**
- Consumes: RPCs `create_layaway_fisica`, `record_layaway_abono`,
  `cancel_layaway`, `extend_layaway_due_date` (Task 2); existing
  `productById`, `escapeHtml`, `fmt`, `showToast`, `supabase`, `PRODUCTS`,
  `reloadProducts`, `renderTable`, `refreshSellProductOptions`,
  `refreshTransferProductOptions`, `renderStats` (all already defined
  elsewhere in `admin.js`).
- Produces: `refreshLayawayProductOptions()`, `loadLayaways()`,
  `renderLayaways()` — called from `loadEverything()`, same pattern as the
  existing `loadOrders()`/`renderOrders()` pair.

- [ ] **Step 1: Add the tab button in `admin.html`**

In the tab bar (after the existing `data-tab="orders"` button, before
`data-tab="transfers"`):

```html
<button class="tab-btn" data-tab="layaways" type="button" aria-selected="false" data-role-admin data-role-vendedor>Apartados</button>
```

- [ ] **Step 2: Add the tab section in `admin.html`**

Insert this whole section right after the existing `</section>` that closes
`tab-orders` (before the `<!-- ---------- Traspasos ---------- -->` comment):

```html
<!-- ---------- Apartados ---------- -->
<section class="tab-panel" id="tab-layaways" hidden>
  <div class="grid-head"><h2>Nuevo apartado</h2></div>
  <form class="add-form" id="layaway-add-form" style="grid-template-columns: 2fr 1fr auto;">
    <div class="field">
      <label for="layaway-product">Producto</label>
      <select class="cell-input" id="layaway-product" required></select>
    </div>
    <div class="field">
      <label for="layaway-qty">Cantidad</label>
      <input class="cell-input" id="layaway-qty" type="number" min="1" step="1" value="1" required>
    </div>
    <div class="submit-cell"><button class="btn btn-primary btn-sm" type="submit" id="layaway-add-btn">Agregar</button></div>
  </form>

  <div class="table-wrap" style="margin-top:16px;">
    <table class="admin-table">
      <thead><tr><th>Producto</th><th>Cantidad</th><th>Precio</th><th>Subtotal</th><th></th></tr></thead>
      <tbody id="layaway-cart-tbody"></tbody>
    </table>
  </div>

  <div class="add-form" style="grid-template-columns: 1fr 1fr 1fr; margin-top:12px;">
    <div class="field"><label for="layaway-name">Nombre del cliente</label><input class="cell-input" id="layaway-name" type="text" required></div>
    <div class="field"><label for="layaway-phone">Teléfono</label><input class="cell-input" id="layaway-phone" type="tel" required></div>
    <div class="field"><label for="layaway-email">Correo (opcional)</label><input class="cell-input" id="layaway-email" type="email"></div>
  </div>

  <div class="stat-row" style="margin-top:16px;">
    <div class="stat-tile"><strong id="layaway-total">$0.00</strong><span>Total</span></div>
    <div class="stat-tile"><strong id="layaway-deposit">$0.00</strong><span>Anticipo (50%)</span></div>
  </div>
  <p class="form-error" id="layaway-error"></p>
  <button class="btn btn-primary" type="button" id="layaway-confirm-btn" style="margin-top:12px;">Registrar apartado</button>

  <div class="grid-head" style="margin-top:32px;"><h2>Activos</h2></div>
  <div class="table-wrap" style="margin-bottom:32px;">
    <table class="admin-table">
      <thead><tr><th>Fecha límite</th><th>Cliente</th><th>Teléfono</th><th>Total</th><th>Pagado</th><th>Saldo</th><th>Estado</th><th></th></tr></thead>
      <tbody id="layaways-active-tbody"></tbody>
    </table>
  </div>

  <div class="grid-head"><h2>Historial</h2></div>
  <div class="table-wrap">
    <table class="admin-table">
      <thead><tr><th>Fecha límite</th><th>Cliente</th><th>Total</th><th>Estado</th></tr></thead>
      <tbody id="layaways-history-tbody"></tbody>
    </table>
  </div>
</section>
```

- [ ] **Step 3: Add the Apartados controller to `admin.js`**

Add this whole block after the existing "Pedidos tab" section (after the
closing of `renderOrders()`'s function body):

```javascript
// ---------- Apartados tab ----------

let LAYAWAY_CART = []; // [{ product_id, quantity }]
let LAYAWAYS = [];

function refreshLayawayProductOptions() {
  const sel = document.getElementById('layaway-product');
  const current = sel.value;
  sel.innerHTML = PRODUCTS
    .filter(p => p.stock_fisica > 0)
    .map(p => `<option value="${p.id}">${p.code ? escapeHtml(p.code) + ' — ' : ''}${escapeHtml(p.name)} (Física: ${p.stock_fisica})</option>`)
    .join('');
  if (current && PRODUCTS.some(p => p.id === current)) sel.value = current;
}

document.getElementById('layaway-add-form').addEventListener('submit', (e) => {
  e.preventDefault();
  const productId = document.getElementById('layaway-product').value;
  const qty = Math.round(Number(document.getElementById('layaway-qty').value) || 0);
  if (!productId || qty <= 0) return;
  const existing = LAYAWAY_CART.find(i => i.product_id === productId);
  if (existing) existing.quantity += qty;
  else LAYAWAY_CART.push({ product_id: productId, quantity: qty });
  renderLayawayCart();
});

function renderLayawayCart() {
  const tbody = document.getElementById('layaway-cart-tbody');
  if (LAYAWAY_CART.length === 0) {
    tbody.innerHTML = `<tr><td colspan="5" style="color:var(--ink-soft);">Carrito vacío.</td></tr>`;
  } else {
    tbody.innerHTML = LAYAWAY_CART.map((item, idx) => {
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
        LAYAWAY_CART.splice(Number(btn.dataset.idx), 1);
        renderLayawayCart();
      });
    });
  }
  const total = LAYAWAY_CART.reduce((s, item) => s + (productById(item.product_id)?.price || 0) * item.quantity, 0);
  document.getElementById('layaway-total').textContent = fmt.format(total);
  document.getElementById('layaway-deposit').textContent = fmt.format(total * 0.5);
}

document.getElementById('layaway-confirm-btn').addEventListener('click', async (e) => {
  const btn = e.currentTarget;
  const errEl = document.getElementById('layaway-error');
  errEl.textContent = '';
  if (LAYAWAY_CART.length === 0) { errEl.textContent = 'Agrega al menos un producto.'; return; }
  const customer_name = document.getElementById('layaway-name').value.trim();
  const customer_phone = document.getElementById('layaway-phone').value.trim();
  const customer_email = document.getElementById('layaway-email').value.trim();
  if (!customer_name || !customer_phone) { errEl.textContent = 'Captura nombre y teléfono del cliente.'; return; }

  btn.disabled = true;
  try {
    const { error } = await supabase.rpc('create_layaway_fisica', {
      p_items: LAYAWAY_CART.map(i => ({ product_id: i.product_id, quantity: i.quantity })),
      p_customer_name: customer_name,
      p_customer_phone: customer_phone,
      p_customer_email: customer_email || null,
    });
    if (error) { errEl.textContent = error.message; return; }

    showToast('Apartado registrado');
    LAYAWAY_CART = [];
    document.getElementById('layaway-name').value = '';
    document.getElementById('layaway-phone').value = '';
    document.getElementById('layaway-email').value = '';
    renderLayawayCart();
    await reloadProducts();
    renderTable();
    refreshSellProductOptions();
    refreshTransferProductOptions();
    refreshLayawayProductOptions();
    renderStats();
    await loadLayaways();
    renderLayaways();
  } finally {
    btn.disabled = false;
  }
});

async function loadLayaways() {
  const { data, error } = await supabase
    .from('layaways')
    .select('*, layaway_payments(amount)')
    .order('due_date', { ascending: true });
  if (error) { console.error(error); return; }
  LAYAWAYS = data;
}

function layawayPaidSoFar(l) {
  return (l.layaway_payments || []).reduce((s, p) => s + Number(p.amount), 0);
}

function layawayIsOverdue(l) {
  return new Date(l.due_date) < new Date(new Date().toDateString());
}

function layawayStatusLabel(l) {
  if (l.status === 'revisar_sin_stock') return 'Revisar — sin stock';
  if (l.status === 'completado') return 'Completado';
  if (l.status === 'cancelado') return 'Cancelado';
  return layawayIsOverdue(l) ? 'Activo — vencido' : 'Activo';
}

function renderLayaways() {
  const active = LAYAWAYS.filter(l => l.status === 'activo' || l.status === 'revisar_sin_stock');
  const history = LAYAWAYS.filter(l => l.status === 'completado' || l.status === 'cancelado');

  const activeTbody = document.getElementById('layaways-active-tbody');
  activeTbody.innerHTML = active.length === 0
    ? `<tr><td colspan="8" style="color:var(--ink-soft);">Sin apartados activos.</td></tr>`
    : active.map(l => {
      const paid = layawayPaidSoFar(l);
      const pending = Number(l.total) - paid;
      const flagged = layawayIsOverdue(l) || l.status === 'revisar_sin_stock';
      return `<tr data-id="${l.id}" class="${flagged ? 'low-stock' : ''}">
        <td>${new Date(l.due_date).toLocaleDateString('es-MX', { dateStyle: 'medium' })}</td>
        <td>${escapeHtml(l.customer_name)}</td>
        <td>${escapeHtml(l.customer_phone)}</td>
        <td>${fmt.format(l.total)}</td>
        <td>${fmt.format(paid)}</td>
        <td>${fmt.format(pending)}</td>
        <td>${layawayStatusLabel(l)}</td>
        <td>
          <button class="btn btn-primary btn-sm" type="button" data-role="abono">Abonar</button>
          <button class="btn btn-sm" type="button" data-role="extend">Extender</button>
          <button class="btn btn-danger btn-sm" type="button" data-role="cancel">Cancelar</button>
        </td>
      </tr>`;
    }).join('');

  activeTbody.querySelectorAll('[data-role="abono"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      const raw = window.prompt('Monto del abono en efectivo:');
      if (raw === null) return;
      const amount = Number(raw);
      if (!amount || amount <= 0) { showToast('Monto inválido', true); return; }
      btn.disabled = true;
      try {
        const { error } = await supabase.rpc('record_layaway_abono', { p_layaway_id: id, p_amount: amount });
        if (error) { showToast(error.message, true); return; }
        showToast('Abono registrado');
        await loadLayaways();
        renderLayaways();
      } finally {
        btn.disabled = false;
      }
    });
  });

  activeTbody.querySelectorAll('[data-role="extend"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      const raw = window.prompt('Nueva fecha límite (AAAA-MM-DD):');
      if (raw === null || !raw.trim()) return;
      btn.disabled = true;
      try {
        const { error } = await supabase.rpc('extend_layaway_due_date', { p_layaway_id: id, p_new_due_date: raw.trim() });
        if (error) { showToast(error.message, true); return; }
        showToast('Fecha actualizada');
        await loadLayaways();
        renderLayaways();
      } finally {
        btn.disabled = false;
      }
    });
  });

  activeTbody.querySelectorAll('[data-role="cancel"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      if (!window.confirm('¿Cancelar este apartado? Se libera el stock reservado.')) return;
      btn.disabled = true;
      try {
        const { error } = await supabase.rpc('cancel_layaway', { p_layaway_id: id });
        if (error) { showToast(error.message, true); return; }
        showToast('Apartado cancelado');
        await reloadProducts();
        renderTable();
        refreshSellProductOptions();
        refreshTransferProductOptions();
        refreshLayawayProductOptions();
        renderStats();
        await loadLayaways();
        renderLayaways();
      } finally {
        btn.disabled = false;
      }
    });
  });

  const historyTbody = document.getElementById('layaways-history-tbody');
  historyTbody.innerHTML = history.length === 0
    ? `<tr><td colspan="4" style="color:var(--ink-soft);">Sin historial todavía.</td></tr>`
    : history.map(l => `
      <tr>
        <td>${new Date(l.due_date).toLocaleDateString('es-MX', { dateStyle: 'medium' })}</td>
        <td>${escapeHtml(l.customer_name)}</td>
        <td>${fmt.format(l.total)}</td>
        <td>${l.status === 'completado' ? 'Completado' : 'Cancelado'}</td>
      </tr>`).join('');
}
```

- [ ] **Step 4: Wire it into `loadEverything()` and `subscribeRealtime()`**

In `loadEverything()`, add calls alongside the existing `loadOrders()`/
`renderOrders()` pair:

```javascript
    await loadOrders();
    await loadLayaways();
```

(right after the existing `await loadOrders();` line), and:

```javascript
    refreshSellProductOptions();
    refreshLayawayProductOptions();
```

(right after the existing `refreshSellProductOptions();` line), and:

```javascript
    renderOrders();
    renderLayaways();
```

(right after the existing `renderOrders();` line, at the end of the
function).

In `subscribeRealtime()`, add two more `.on('postgres_changes', ...)`
calls alongside the existing ones, before `.subscribe()`:

```javascript
    .on('postgres_changes', { event: '*', schema: 'public', table: 'layaways' }, scheduleReload)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'layaway_payments' }, scheduleReload)
```

- [ ] **Step 5: Manual verification**

With the migrations from Tasks 1-3 already applied (this task can be
implemented and reviewed before that, but not manually verified until
they are), log in as admin on a local copy of `app/` (or after Netlify
deploy) and confirm:
- The "Apartados" tab appears for both admin and vendedor logins.
- Adding a product with `stock_fisica > 0` to the cart, filling in
  nombre/teléfono, and clicking "Registrar apartado" creates a row in
  "Activos" with the correct total/anticipo, and decrements that
  product's `stock_fisica` in the Inventario tab.
- "Abonar" with an amount larger than the saldo pendiente shows the
  rejection message from the RPC.
- "Abonar" with the exact saldo pendiente moves the row from "Activos" to
  "Historial" as "Completado", and a matching row appears in Reportes →
  "Ventas por mes" once the month total updates.
- "Cancelar" moves the row to "Historial" as "Cancelado" and restores the
  `stock_fisica` count.

- [ ] **Step 6: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Add Apartados tab: create, abono, extend, cancel"
```

---

### Task 7: Frontend — botón "Apartar" en el catálogo (`catalog.js` + `index.html`)

**Files:**
- Modify: `app/index.html:97` (insert new button after `checkout-btn`)
- Modify: `app/js/catalog.js:205-246` (new click handler for the layaway
  button, placed after the existing `checkout-btn` handler),
  `app/js/catalog.js:311-326` (`handleCheckoutReturn()`)

**Interfaces:**
- Consumes: Edge Function `create-layaway-checkout-session` (Task 4);
  existing `cart`, `updateCartUI`, `showToast`, `supabase` (already defined
  in `catalog.js`).

- [ ] **Step 1: Add the button in `index.html`**

Right after the existing `checkout-btn` button (before the "Recoges tu
pedido..." paragraph):

```html
<button class="btn btn-ghost" style="width:100%;justify-content:center;margin-top:8px;" id="layaway-btn" type="button">Apartar (paga 50% ahora)</button>
```

- [ ] **Step 2: Add the click handler in `catalog.js`**

Add this block right after the existing `checkout-btn` click handler:

```javascript
document.getElementById('layaway-btn').addEventListener('click', async () => {
  const errEl = document.getElementById('checkout-error');
  errEl.textContent = '';
  if (Object.keys(cart).length === 0) { showToast('Agrega algo antes de apartar'); return; }

  const customer_name = document.getElementById('chk-name').value.trim();
  const customer_phone = document.getElementById('chk-phone').value.trim();
  const customer_email = document.getElementById('chk-email').value.trim();
  if (!customer_name || !customer_phone || !customer_email) {
    errEl.textContent = 'Completa tus datos de contacto.';
    return;
  }

  const btn = document.getElementById('layaway-btn');
  btn.disabled = true;
  btn.textContent = 'Redirigiendo a pago…';

  const items = Object.entries(cart).map(([product_id, quantity]) => ({ product_id, quantity }));
  const { data, error } = await supabase.functions.invoke('create-layaway-checkout-session', {
    body: { items, customer_name, customer_phone, customer_email },
  });

  btn.disabled = false;
  btn.textContent = 'Apartar (paga 50% ahora)';

  if (error || data?.error) {
    let message = data?.error || error?.message;
    try {
      if (error?.context && typeof error.context.json === 'function') {
        const body = await error.context.json();
        if (body?.error) message = body.error;
      }
    } catch {}
    errEl.textContent = message || 'No se pudo iniciar el apartado';
    return;
  }
  window.location.href = data.url;
});
```

- [ ] **Step 3: Extend `handleCheckoutReturn()` for the apartado return**

Replace the existing function:

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

with:

```javascript
function handleCheckoutReturn() {
  const params = new URLSearchParams(window.location.search);
  const status = params.get('checkout');
  const apartadoStatus = params.get('apartado');
  if (status === 'success') {
    Object.keys(cart).forEach(id => delete cart[id]);
    updateCartUI();
    showToast('¡Listo! Tu pedido está pagado — pasa a recogerlo a la tienda.');
  } else if (status === 'cancel') {
    showToast('Pago cancelado. Tu carrito sigue aquí.');
  } else if (apartadoStatus === 'success') {
    Object.keys(cart).forEach(id => delete cart[id]);
    updateCartUI();
    showToast('¡Listo! Tu apartado quedó registrado — paga el resto en tienda en efectivo antes de la fecha límite.');
  } else if (apartadoStatus === 'cancel') {
    showToast('Apartado cancelado. Tu carrito sigue aquí.');
  }
  if (status || apartadoStatus) {
    params.delete('checkout');
    params.delete('apartado');
    const qs = params.toString();
    window.history.replaceState({}, '', window.location.pathname + (qs ? `?${qs}` : ''));
  }
}
```

- [ ] **Step 4: Manual verification**

Requires Tasks 1-5 already deployed. Add a product to the public cart,
click "Apartar (paga 50% ahora)", confirm it redirects to Stripe Checkout
showing **half** the cart's total as the amount to pay (not the full
total), pay with the test card `4242 4242 4242 4242`, confirm it redirects
back to `index.html?apartado=success` with the confirmation toast, and
confirm a new row shows up in the admin's Apartados → Activos with
`channel` implied as online (same customer data) and the correct
50%-paid amount.

- [ ] **Step 5: Commit**

```bash
git add app/index.html app/js/catalog.js
git commit -m "Add apartar (layaway deposit) flow to the public catalog"
```

---

### Task 8: Deploy manual + checklist E2E

**Files:** none (coordination task, run by the controlling session with
Ricardo — not delegated to a subagent, since it requires live access to
Ricardo's Supabase/Netlify/Stripe dashboards).

- [ ] **Step 1: Confirm every piece from Tasks 1-7 is live**

- Migrations 0012, 0013, 0014 applied (Task 1/2/3 Step 3 verifications
  pass).
- `create-layaway-checkout-session` deployed with "Verify JWT" off (Task 4
  Step 3 verification passes).
- `stripe-webhook` re-deployed with the new branch (Task 5).
- Latest `app/` zipped and uploaded via Netlify Drop (Tasks 6 and 7's
  frontend changes live).

- [ ] **Step 2: Full manual checklist against production**

Run through each of these against `https://lemus-store.netlify.app` /
`https://lemus-store.netlify.app/admin.html` — final acceptance check for
this phase:

- [ ] Admin and vendedor both see the "Apartados" tab.
- [ ] Apartar en tienda (as either role): reserving a product decrements
      `stock_fisica` immediately and shows up in Activos with the correct
      50% anticipo already registered as paid.
- [ ] Abonar un monto mayor al saldo pendiente se rechaza con el mensaje
      claro del saldo real.
- [ ] Abonar el saldo restante completo mueve el apartado a Historial
      ("Completado") y genera una venta real visible en Reportes → "Ventas
      por mes" ese mes, con `payment_method` `apartado`.
- [ ] Cancelar un apartado activo libera el stock reservado (verificar en
      Inventario) y lo mueve a Historial ("Cancelado").
- [ ] Extender la fecha límite de un apartado activo actualiza la fecha
      mostrada sin cambiar nada más.
- [ ] Apartar en línea con una compra de prueba de Stripe
      (`4242 4242 4242 4242`) cobra solo el 50% del total, redirige a
      `?apartado=success`, y crea el apartado (`channel='online'`) visible
      en Activos con ese anticipo ya registrado.
- [ ] `curl` directo con la llave anon a `record_online_layaway_deposit`
      sigue devolviendo `401 permission denied` (repetir la verificación
      del Task 3 una vez más, ya con el flujo completo probado).
- [ ] Un apartado en línea con stock insuficiente al momento del pago
      (forzarlo bajando el `stock_online` de un producto a 0 justo antes
      de pagar, en una prueba controlada) queda marcado
      "Revisar — sin stock" en vez de perderse.

- [ ] **Step 3: Report results to Ricardo**

Summarize pass/fail for each checklist item in plain Spanish, with live
URLs, and flag anything needing his attention.

---

## Self-Review Notes

- **Spec coverage:** data model (Task 1), physical creation + abono +
  cancel + extend RPCs incl. the `sales.payment_method` widening for
  graduation (Task 2), online deposit RPC incl. idempotency and the
  `revisar_sin_stock` oversell path (Task 3), online checkout session with
  promotion-aware pricing (Task 4), webhook branching (Task 5), Apartados
  tab UI incl. role visibility reusing the existing `data-role-*`
  convention (Task 6), public catalog "Apartar" button and return handling
  (Task 7), and full production deploy + E2E checklist (Task 8) are all
  covered. Out-of-scope items from the spec (automatic Stripe refunds,
  automatic reminders, configurable deposit %/plazo per apartado, online
  balance payment, editing items on an existing apartado, a dedicated
  "valor apartado pendiente" report, limits per client/product) are
  intentionally not tasked here.
- **Type/name consistency check:** `create_layaway_fisica(p_items jsonb,
  p_customer_name text, p_customer_phone text, p_customer_email text)` /
  `record_layaway_abono(p_layaway_id uuid, p_amount numeric)` /
  `cancel_layaway(p_layaway_id uuid)` /
  `extend_layaway_due_date(p_layaway_id uuid, p_new_due_date date)` names
  and parameter shapes match between the migration (Task 2) and every
  caller (Task 6). `record_online_layaway_deposit(...)` matches between
  the migration (Task 3), the Edge Function's metadata shape (Task 4), and
  the webhook call (Task 5) — specifically `p_items` always carries
  `{product_id, quantity, unit_price}` end to end. `layaway_items_view`
  name matches between its migration (Task 1) and its only reader
  (`admin.js`, not directly queried by any task here since Task 6's list
  reads `layaways`/`layaway_payments` only — cost is never shown in the
  Apartados tab at all, so `layaway_items_view` exists for future/API use
  but has no frontend reader yet; this matches the spec, which never
  specified per-item cost display in the Apartados UI). `LAYAWAY_CART`/
  `LAYAWAYS` globals are defined once (Task 6) and only read afterward.
- **Placeholder scan:** no TBD/TODO; every code block is complete and
  runnable as written, matching Fase 2's plan's standard.
- **Manual-deploy workflow made explicit:** every migration/Edge Function
  task ends with "pending manual application/deploy" instead of an MCP
  tool call, and Task 8 is the single point where the controller confirms
  everything is live together — this reflects the actual operating
  constraint of this session (MCP error -32003) rather than assuming tool
  access that isn't there, unlike the Fase 2 plan when it was first
  written.
