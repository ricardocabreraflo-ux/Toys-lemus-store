# Mercado Pago Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Stripe with Mercado Pago as the payment processor for both
the public catalog's checkout and the apartados online deposit, per
`docs/superpowers/specs/2026-08-14-mercadopago-migration-design.md`.

**Architecture:** 2 new SQL migrations (`pending_checkouts` table + column
renames, then the RPC updates); full rewrite of the 2 existing
`create-*-checkout-session` Edge Functions to call Mercado Pago's Preferences
API instead of Stripe Checkout Sessions; 1 new Edge Function
(`mercadopago-webhook`) replacing `stripe-webhook`. The public catalog and
admin frontend need **no code changes** — they keep calling the same Edge
Function names and reading the same `?checkout=`/`?apartado=` return
query params.

**Tech Stack:** Supabase (Postgres + Edge Functions/Deno), Mercado Pago
Checkout Pro (Preferences API, card-only), Deno's built-in `crypto.subtle`
for webhook signature verification (no external crypto library needed).

## Global Constraints

- No test framework/build step in this repo — verification per layer:
  **SQL/RPC** a verification query with expected result written out;
  **Edge Functions** a `curl` invocation with expected response written out;
  **frontend** N/A, this plan makes no frontend changes.
- **The Supabase/Netlify MCP tools are unreliable in this environment**
  (`MCP error -32003`/`-32600` seen at different points, servers
  disconnect/reconnect). Every task that touches the live database or a
  deployed function ends with the implementer reporting it as **pending
  manual application** — applying it (Supabase SQL Editor / Edge Functions
  code editor) is done by the controlling session directly with Ricardo,
  the non-technical store owner, outside the subagent's task.
- Supabase project: `iatyvxljzrcdfmmtesig`. Latest applied migration is
  `supabase/migrations/0015_fix_final_review_apartados.sql` — this plan's
  migrations start at `0016`.
- Netlify site: `https://lemus-store.netlify.app`.
- Mercado Pago API base URL: `https://api.mercadopago.com`. Currency is
  always `MXN`. **`unit_price` in Mercado Pago's items is the real decimal
  amount (e.g. `130.00`), NOT cents** — this is the opposite convention
  from Stripe, which used integer cents. Do not multiply by 100 anywhere.
- Card-only checkout: every preference must set
  `payment_methods.excluded_payment_types` to exclude `ticket` (OXXO/cash
  vouchers) and `atm` (bank transfer/SPEI) — confirmed field names from
  Mercado Pago's own documentation.
- Test mode first: the Edge Functions must pick `sandbox_init_point` vs
  `init_point` automatically based on whether `MP_ACCESS_TOKEN` starts with
  `"TEST-"` — this is what makes "switch to real charges = swap 2 keys,
  no code change" true, per the spec.
- Historical Stripe test purchases are never rewritten — `'stripe'` stays a
  valid (but no-longer-written) value in the relevant check constraints.
- All UI copy/error messages are in Spanish (Mexico), matching the existing
  app's tone. Never commit real secrets (Mercado Pago tokens) to the repo.

---

## File Structure

New files:
- `supabase/migrations/0016_mercadopago_pending_checkouts.sql`
- `supabase/migrations/0017_mercadopago_rpcs.sql`
- `supabase/functions/mercadopago-webhook/index.ts`

Modified files (full rewrite of contents, same file path/function name):
- `supabase/functions/create-checkout-session/index.ts`
- `supabase/functions/create-layaway-checkout-session/index.ts`

Deleted (operational step, not a file in this repo — `stripe-webhook` was
never tracked outside `supabase/functions/stripe-webhook/index.ts`, which
this plan leaves in the repo as historical record but instructs Ricardo to
disable/delete the deployed function):
- Deployed Edge Function `stripe-webhook` (Supabase Dashboard).

No changes: `app/js/catalog.js`, `app/index.html`, `app/js/admin.js`,
`app/admin.html` — same Edge Function names invoked, same return query
params (`?checkout=success/cancel`, `?apartado=success/cancel`), same
error-recovery pattern (`error.context.json()`) already in place.

---

### Task 1: Migration 0016 — `pending_checkouts` + column renames

**Files:**
- Create: `supabase/migrations/0016_mercadopago_pending_checkouts.sql`

**Interfaces:**
- Produces: table `public.pending_checkouts(id, kind, payload, status,
  created_at)` — no RLS policies (RLS enabled, zero policies = only
  `service_role` can touch it), used by Tasks 3-5. Renamed columns
  `public.sales.payment_id` and `public.layaways.payment_id` (formerly
  `stripe_checkout_session_id`) — used by Task 2's RPCs. Widened check
  constraints `sales_payment_method_check` and
  `layaway_payments_method_check` (both now allow `'mercadopago'` alongside
  the existing values).

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0016_mercadopago_pending_checkouts.sql
-- Migración de pagos: Stripe -> Mercado Pago. Ver
-- docs/superpowers/specs/2026-08-14-mercadopago-migration-design.md.
--
-- pending_checkouts guarda el carrito + datos de contacto ANTES de mandar
-- al cliente a pagar, porque el webhook de Mercado Pago solo manda un id
-- de pago (no el carrito completo como sí hacían los metadata de Stripe
-- Checkout Sessions). Solo la tocan las Edge Functions con la llave de
-- servicio — sin política de RLS, nadie más puede leerla ni escribirla.

create table if not exists public.pending_checkouts (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('venta', 'apartado')),
  payload     jsonb not null,
  status      text not null default 'pendiente' check (status in ('pendiente', 'confirmado')),
  created_at  timestamptz not null default now()
);

alter table public.pending_checkouts enable row level security;
-- Sin policies: RLS habilitado + cero policies = nadie vía anon/authenticated
-- puede leer ni escribir. Solo service_role (que ignora RLS) la toca.

-- Renombrar la columna de "sesión de Stripe" a algo neutral: mismo
-- propósito (identificar el pago, evitar registrarlo dos veces), ahora
-- guarda el id de pago de Mercado Pago. Las filas viejas de pruebas hechas
-- con Stripe conservan su valor tal cual, solo cambia el nombre de columna.
alter table public.sales rename column stripe_checkout_session_id to payment_id;
alter table public.layaways rename column stripe_checkout_session_id to payment_id;

-- Mercado Pago no separa "intento de pago" y "pago" como sí hacía Stripe.
alter table public.sales drop column if exists stripe_payment_intent_id;

-- 'mercadopago' se agrega; 'stripe' se conserva para no invalidar el
-- historial de las ventas de prueba que ya se hicieron por Stripe.
alter table public.sales drop constraint if exists sales_payment_method_check;
alter table public.sales add constraint sales_payment_method_check
  check (payment_method in ('stripe', 'mercadopago', 'efectivo', 'apartado'));

alter table public.layaway_payments drop constraint if exists layaway_payments_method_check;
alter table public.layaway_payments add constraint layaway_payments_method_check
  check (method in ('stripe', 'mercadopago', 'efectivo'));
```

- [ ] **Step 2: Commit**

```bash
git add supabase/migrations/0016_mercadopago_pending_checkouts.sql
git commit -m "Add pending_checkouts table and rename Stripe-specific columns for Mercado Pago"
```

Report this task as **pending manual application**.

- [ ] **Step 3 (controller, after Ricardo confirms he ran it): Verify**

```sql
select table_name from information_schema.tables
where table_schema = 'public' and table_name = 'pending_checkouts';
```

Expected: 1 row.

```sql
select column_name from information_schema.columns
where table_schema = 'public' and table_name in ('sales', 'layaways') and column_name = 'payment_id';
```

Expected: 2 rows (`sales.payment_id`, `layaways.payment_id`).

```sql
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'sales' and column_name = 'stripe_payment_intent_id';
```

Expected: 0 rows (column dropped).

```sql
select pg_get_constraintdef(oid) from pg_constraint where conname = 'sales_payment_method_check';
```

Expected: definition includes `'mercadopago'` and `'stripe'`.

---

### Task 2: Migration 0017 — update `record_online_sale` / `record_online_layaway_deposit`

**Files:**
- Create: `supabase/migrations/0017_mercadopago_rpcs.sql`

**Interfaces:**
- Consumes: `public.pending_checkouts`, `public.sales.payment_id`,
  `public.layaways.payment_id` (Task 1).
- Produces: RPC `record_online_sale(p_payment_id text, p_customer_name
  text, p_customer_phone text, p_customer_email text, p_items jsonb)
  returns uuid` (note: **one fewer parameter** than before —
  `p_stripe_payment_intent_id` is gone). RPC
  `record_online_layaway_deposit(p_payment_id text, p_customer_name text,
  p_customer_phone text, p_customer_email text, p_total numeric,
  p_deposit_amount numeric, p_items jsonb) returns uuid` (same arity as
  before, only the first parameter's name changed). Both are called by
  `mercadopago-webhook` in Task 5 with these exact parameter names.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0017_mercadopago_rpcs.sql
-- Update record_online_sale and record_online_layaway_deposit for
-- Mercado Pago: they now receive a single payment id (Mercado Pago has no
-- separate "payment intent" concept like Stripe did) and record
-- payment_method/method as 'mercadopago'. Idempotency, the service_role-only
-- guard, and the oversell-handling logic are unchanged from migration 0015.
--
-- record_online_sale's parameter list SHRINKS (6 args -> 5 args: removed
-- p_stripe_payment_intent_id), which is a different function signature in
-- Postgres (identity = name + argument types) — the old 6-arg overload must
-- be dropped explicitly, `create or replace` alone would just add a second
-- overload instead of replacing it. record_online_layaway_deposit keeps the
-- same 7-argument shape (only a parameter NAME changed), so a plain
-- `create or replace` is enough for it.

drop function if exists public.record_online_sale(text, text, text, text, text, jsonb);

create or replace function public.record_online_sale(
  p_payment_id text,
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
  v_cost numeric(10,2);
  v_name text;
  v_total numeric(10,2) := 0;
  v_oversold boolean := false;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'No autorizado';
  end if;

  -- Idempotencia: Mercado Pago puede reenviar el mismo aviso más de una vez.
  select id into v_sale_id from public.sales where payment_id = p_payment_id;
  if v_sale_id is not null then
    return v_sale_id;
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Sin productos en el pedido';
  end if;

  insert into public.sales (
    channel, status, customer_name, customer_phone, customer_email,
    payment_method, payment_id, total
  ) values (
    'online', 'pagado', p_customer_name, p_customer_phone, p_customer_email,
    'mercadopago', p_payment_id, 0
  ) returning id into v_sale_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer, unit_price numeric)
  loop
    if v_item.unit_price is null or v_item.unit_price < 0 then
      raise exception 'Precio inválido en el pedido';
    end if;

    select stock_online, cost_price, name
      into v_stock, v_cost, v_name
      from public.products where id = v_item.product_id for update;

    if v_stock is null then
      v_oversold := true;
      insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
      values (v_sale_id, null, '(producto ya no existe)', v_item.quantity, 0, 0);
      continue;
    end if;

    if v_stock < v_item.quantity then
      v_oversold := true;
      update public.products set stock_online = 0 where id = v_item.product_id;
    else
      update public.products set stock_online = stock_online - v_item.quantity where id = v_item.product_id;
    end if;

    insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_sale_id, v_item.product_id, v_name, v_item.quantity, v_item.unit_price, v_cost);

    v_total := v_total + v_item.unit_price * v_item.quantity;
  end loop;

  update public.sales
    set total = v_total, status = case when v_oversold then 'revisar_sin_stock' else 'pagado' end
    where id = v_sale_id;

  return v_sale_id;
end;
$$;

revoke all on function public.record_online_sale(text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.record_online_sale(text, text, text, text, jsonb) to service_role;

create or replace function public.record_online_layaway_deposit(
  p_payment_id text,
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
  v_reserved integer;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'No autorizado';
  end if;

  select id into v_layaway_id from public.layaways where payment_id = p_payment_id;
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
    total, deposit_percent, due_date, payment_id
  ) values (
    'online', 'activo', p_customer_name, p_customer_phone, p_customer_email,
    p_total, 50, current_date + 15, p_payment_id
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
      values (v_layaway_id, null, '(producto ya no existe)', v_item.quantity, 0, 0);
      continue;
    end if;

    if v_stock < v_item.quantity then
      v_oversold := true;
      v_reserved := v_stock;
      update public.products set stock_online = 0 where id = v_item.product_id;
    else
      v_reserved := v_item.quantity;
      update public.products set stock_online = stock_online - v_item.quantity where id = v_item.product_id;
    end if;

    insert into public.layaway_items (layaway_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_layaway_id, v_item.product_id, v_name, v_reserved, v_item.unit_price, v_cost);
  end loop;

  insert into public.layaway_payments (layaway_id, amount, method, created_by)
  values (v_layaway_id, p_deposit_amount, 'mercadopago', null);

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
git add supabase/migrations/0017_mercadopago_rpcs.sql
git commit -m "Update record_online_sale and record_online_layaway_deposit for Mercado Pago"
```

Report this task as **pending manual application**.

- [ ] **Step 3 (controller, after Ricardo confirms he ran it): Verify**

```sql
select proname, pronargs from pg_proc where proname = 'record_online_sale';
```

Expected: exactly 1 row (the old 6-arg overload is gone), `pronargs = 5`.

```sql
select routine_name, grantee from information_schema.role_routine_grants
where routine_name in ('record_online_sale', 'record_online_layaway_deposit') and grantee = 'anon';
```

Expected: **zero rows**.

---

### Task 3: Rewrite `create-checkout-session` for Mercado Pago

**Files:**
- Modify: `supabase/functions/create-checkout-session/index.ts` (full
  rewrite of contents — same file path, same function name, same frontend
  caller)

**Interfaces:**
- Consumes: `public.pending_checkouts` (Task 1, insert only).
- Produces: HTTP endpoint, same request/response contract as before
  (`{items, customer_name, customer_phone, customer_email}` in →
  `{url}`/`{error}` out) — `catalog.js`'s existing caller needs zero
  changes. Sets `external_reference` on the Mercado Pago preference to the
  new `pending_checkouts` row's `id` — read by `mercadopago-webhook`
  (Task 5).

- [ ] **Step 1: Write the function**

```typescript
// supabase/functions/create-checkout-session/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MP_ACCESS_TOKEN = Deno.env.get('MP_ACCESS_TOKEN')!;
const SITE_URL = Deno.env.get('SITE_URL') ?? 'https://lemus-store.netlify.app';

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

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

    // Same "best active promotion" logic as app/js/catalog-data.js.
    function discountedPrice(p: { price: number; product_line_id: string | null; category_id: string | null }) {
      const matches = (promotions ?? []).filter((promo: { scope_type: string; product_line_id: string | null; category_id: string | null; discount_percent: number }) =>
        (promo.scope_type === 'line' && promo.product_line_id === p.product_line_id) ||
        (promo.scope_type === 'category' && promo.category_id === p.category_id)
      );
      if (matches.length === 0) return p.price;
      const best = matches.reduce((a, b) => (b.discount_percent > a.discount_percent ? b : a), matches[0]);
      return Math.round(p.price * (1 - best.discount_percent / 100) * 100) / 100;
    }

    // Aggregate quantities per product_id to prevent overselling.
    const qtyMap = new Map<string, number>();
    for (const item of items) {
      const qty = Number(item.quantity) || 0;
      const current = qtyMap.get(item.product_id) ?? 0;
      qtyMap.set(item.product_id, current + qty);
    }

    const mpItems = [];
    const cartItems = [];
    for (const [productId, totalQty] of qtyMap.entries()) {
      const p = products.find((x: { id: string }) => x.id === productId);
      if (!p || !p.published_online) {
        return json({ error: 'Un producto de tu carrito ya no está disponible.' }, 409);
      }
      if (totalQty <= 0 || totalQty > p.stock_online) {
        return json({ error: `Solo quedan ${p.stock_online} de "${p.name}" — actualiza tu carrito.` }, 409);
      }
      const unitPrice = discountedPrice(p);
      mpItems.push({
        title: p.name,
        quantity: totalQty,
        unit_price: unitPrice,
        currency_id: 'MXN',
      });
      cartItems.push({ product_id: productId, quantity: totalQty, unit_price: unitPrice });
    }

    const { data: pending, error: pendingErr } = await supabase
      .from('pending_checkouts')
      .insert({
        kind: 'venta',
        payload: { items: cartItems, customer_name, customer_phone, customer_email },
      })
      .select('id')
      .single();
    if (pendingErr) throw pendingErr;

    const mpRes = await fetch('https://api.mercadopago.com/checkout/preferences', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${MP_ACCESS_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        items: mpItems,
        payer: { email: customer_email },
        back_urls: {
          success: `${SITE_URL}/index.html?checkout=success`,
          failure: `${SITE_URL}/index.html?checkout=cancel`,
          pending: `${SITE_URL}/index.html?checkout=cancel`,
        },
        auto_return: 'approved',
        notification_url: `${SUPABASE_URL}/functions/v1/mercadopago-webhook`,
        external_reference: pending.id,
        payment_methods: {
          excluded_payment_types: [{ id: 'ticket' }, { id: 'atm' }],
        },
      }),
    });
    const mpData = await mpRes.json();
    if (!mpRes.ok) {
      console.error('Mercado Pago preference error', mpData);
      return json({ error: 'No se pudo iniciar el pago' }, 500);
    }

    const isTestMode = MP_ACCESS_TOKEN.startsWith('TEST-');
    const checkoutUrl = isTestMode ? mpData.sandbox_init_point : mpData.init_point;

    return json({ url: checkoutUrl });
  } catch (err) {
    return json({ error: String(err) }, 500);
  }
});
```

- [ ] **Step 2: Commit**

```bash
git add supabase/functions/create-checkout-session/index.ts
git commit -m "Rewrite create-checkout-session to use Mercado Pago instead of Stripe"
```

Report this task as **pending manual deploy** — Ricardo deploys the same
function name via the Supabase Dashboard's Edge Functions code editor
(overwrites the existing Stripe version), "Verify JWT" **off** (unchanged
from before — anonymous shoppers call this with no Supabase session), and
sets 2 new secrets first: `MP_ACCESS_TOKEN` (Mercado Pago's test access
token) and confirms `SITE_URL` is still set from before.

- [ ] **Step 3 (controller, after Ricardo confirms he deployed it): Verify with curl**

```bash
curl -s -X OPTIONS "https://iatyvxljzrcdfmmtesig.supabase.co/functions/v1/create-checkout-session" \
  -H "Origin: https://lemus-store.netlify.app" -w "\nHTTP %{http_code}\n"
```

Expected: `HTTP 200` — confirms the redeploy went out and CORS still answers.

---

### Task 4: Rewrite `create-layaway-checkout-session` for Mercado Pago

**Files:**
- Modify: `supabase/functions/create-layaway-checkout-session/index.ts`
  (full rewrite of contents — same file path, same function name)

**Interfaces:**
- Consumes: `public.pending_checkouts` (Task 1, insert only).
- Produces: same contract as before (`{items, customer_name,
  customer_phone, customer_email}` in → `{url}`/`{error}` out) —
  `catalog.js`'s existing caller needs zero changes.

- [ ] **Step 1: Write the function**

```typescript
// supabase/functions/create-layaway-checkout-session/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MP_ACCESS_TOKEN = Deno.env.get('MP_ACCESS_TOKEN')!;
const SITE_URL = Deno.env.get('SITE_URL') ?? 'https://lemus-store.netlify.app';

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

    const { data: pending, error: pendingErr } = await supabase
      .from('pending_checkouts')
      .insert({
        kind: 'apartado',
        payload: { items: cartItems, customer_name, customer_phone, customer_email, total, deposit_amount: depositAmount },
      })
      .select('id')
      .single();
    if (pendingErr) throw pendingErr;

    const mpRes = await fetch('https://api.mercadopago.com/checkout/preferences', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${MP_ACCESS_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        items: [{
          title: `Anticipo de apartado (${DEPOSIT_PERCENT}% de $${total.toFixed(2)})`,
          quantity: 1,
          unit_price: depositAmount,
          currency_id: 'MXN',
        }],
        payer: { email: customer_email },
        back_urls: {
          success: `${SITE_URL}/index.html?apartado=success`,
          failure: `${SITE_URL}/index.html?apartado=cancel`,
          pending: `${SITE_URL}/index.html?apartado=cancel`,
        },
        auto_return: 'approved',
        notification_url: `${SUPABASE_URL}/functions/v1/mercadopago-webhook`,
        external_reference: pending.id,
        payment_methods: {
          excluded_payment_types: [{ id: 'ticket' }, { id: 'atm' }],
        },
      }),
    });
    const mpData = await mpRes.json();
    if (!mpRes.ok) {
      console.error('Mercado Pago preference error', mpData);
      return json({ error: 'No se pudo iniciar el apartado' }, 500);
    }

    const isTestMode = MP_ACCESS_TOKEN.startsWith('TEST-');
    const checkoutUrl = isTestMode ? mpData.sandbox_init_point : mpData.init_point;

    return json({ url: checkoutUrl });
  } catch (err) {
    return json({ error: String(err) }, 500);
  }
});
```

- [ ] **Step 2: Commit**

```bash
git add supabase/functions/create-layaway-checkout-session/index.ts
git commit -m "Rewrite create-layaway-checkout-session to use Mercado Pago instead of Stripe"
```

Report this task as **pending manual deploy** — same deployment
instructions as Task 3 (same function name, overwrite existing).

- [ ] **Step 3 (controller, after Ricardo confirms he deployed it): Verify with curl**

```bash
curl -s -X OPTIONS "https://iatyvxljzrcdfmmtesig.supabase.co/functions/v1/create-layaway-checkout-session" \
  -H "Origin: https://lemus-store.netlify.app" -w "\nHTTP %{http_code}\n"
```

Expected: `HTTP 200`.

---

### Task 5: New Edge Function `mercadopago-webhook`

**Files:**
- Create: `supabase/functions/mercadopago-webhook/index.ts`

**Interfaces:**
- Consumes: `public.pending_checkouts` (Tasks 3/4, read + update), RPCs
  `record_online_sale`/`record_online_layaway_deposit` (Task 2).
- Produces: HTTP endpoint that Mercado Pago calls directly (never invoked
  by the browser) — no CORS headers needed, matching the old
  `stripe-webhook`'s pattern.

- [ ] **Step 1: Write the function**

```typescript
// supabase/functions/mercadopago-webhook/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MP_ACCESS_TOKEN = Deno.env.get('MP_ACCESS_TOKEN')!;
const MP_WEBHOOK_SECRET = Deno.env.get('MP_WEBHOOK_SECRET')!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Verifica x-signature: "ts=<timestamp_ms>,v1=<hmac_hex>". El manifest a
// firmar es "id:{dataId en minúsculas};request-id:{x-request-id};ts:{ts};",
// HMAC-SHA256 con el secreto de webhook de la cuenta de Mercado Pago.
async function verifySignature(xSignature: string, xRequestId: string, dataId: string, secret: string): Promise<boolean> {
  const parts: Record<string, string> = {};
  for (const piece of xSignature.split(',')) {
    const [k, v] = piece.split('=');
    if (k && v) parts[k.trim()] = v.trim();
  }
  const ts = parts['ts'];
  const v1 = parts['v1'];
  if (!ts || !v1) return false;

  const manifest = `id:${dataId.toLowerCase()};request-id:${xRequestId};ts:${ts};`;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const sigBuffer = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(manifest));
  const expectedHex = Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  if (expectedHex.length !== v1.length) return false;
  let diff = 0;
  for (let i = 0; i < expectedHex.length; i++) {
    diff |= expectedHex.charCodeAt(i) ^ v1.charCodeAt(i);
  }
  return diff === 0;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const dataIdFromQuery = url.searchParams.get('data.id') ?? url.searchParams.get('id');

  const xSignature = req.headers.get('x-signature');
  const xRequestId = req.headers.get('x-request-id');
  const body = await req.json().catch(() => null);

  const dataId = dataIdFromQuery ?? body?.data?.id;
  if (!dataId) {
    return new Response('ok', { status: 200 });
  }

  if (!xSignature || !xRequestId) {
    return new Response('Falta firma', { status: 401 });
  }

  const valid = await verifySignature(xSignature, xRequestId, String(dataId), MP_WEBHOOK_SECRET);
  if (!valid) {
    return new Response('Firma inválida', { status: 401 });
  }

  if (body?.type && body.type !== 'payment') {
    return new Response('ok', { status: 200 });
  }

  const paymentRes = await fetch(`https://api.mercadopago.com/v1/payments/${dataId}`, {
    headers: { Authorization: `Bearer ${MP_ACCESS_TOKEN}` },
  });
  if (!paymentRes.ok) {
    console.error('No se pudo consultar el pago', dataId, await paymentRes.text());
    return new Response('ok', { status: 200 });
  }
  const payment = await paymentRes.json();

  if (payment.status !== 'approved') {
    return new Response('ok', { status: 200 });
  }

  const pendingId = payment.external_reference;
  const { data: pending, error: pendingErr } = await supabase
    .from('pending_checkouts')
    .select('*')
    .eq('id', pendingId)
    .single();

  if (pendingErr || !pending) {
    console.error('pending_checkouts no encontrado para external_reference', pendingId);
    return new Response('ok', { status: 200 });
  }

  const payload = pending.payload as Record<string, unknown>;

  if (pending.kind === 'apartado') {
    const { error } = await supabase.rpc('record_online_layaway_deposit', {
      p_payment_id: String(dataId),
      p_customer_name: payload.customer_name,
      p_customer_phone: payload.customer_phone,
      p_customer_email: payload.customer_email,
      p_total: payload.total,
      p_deposit_amount: payload.deposit_amount,
      p_items: payload.items,
    });
    if (error) {
      console.error('record_online_layaway_deposit failed', error);
      return new Response('Error al registrar el apartado', { status: 500 });
    }
  } else {
    const { error } = await supabase.rpc('record_online_sale', {
      p_payment_id: String(dataId),
      p_customer_name: payload.customer_name,
      p_customer_phone: payload.customer_phone,
      p_customer_email: payload.customer_email,
      p_items: payload.items,
    });
    if (error) {
      console.error('record_online_sale failed', error);
      return new Response('Error al registrar la venta', { status: 500 });
    }
  }

  await supabase.from('pending_checkouts').update({ status: 'confirmado' }).eq('id', pendingId);

  return new Response('ok', { status: 200 });
});
```

- [ ] **Step 2: Commit**

```bash
git add supabase/functions/mercadopago-webhook/index.ts
git commit -m "Add mercadopago-webhook Edge Function"
```

Report this task as **pending manual deploy** — Ricardo deploys this as a
**new** function named `mercadopago-webhook`, "Verify JWT" **off**
(Mercado Pago's calls carry no Supabase JWT, same reasoning as
`stripe-webhook` before it), with the secret `MP_WEBHOOK_SECRET` set — that
secret only exists after Ricardo configures a webhook in Mercado Pago's
Developer panel (Integraciones → Webhooks), which is where Mercado Pago
generates and shows it. Order matters here: deploy this function first (so
its URL exists), then Ricardo configures the webhook in Mercado Pago's
panel pointing at
`https://iatyvxljzrcdfmmtesig.supabase.co/functions/v1/mercadopago-webhook`,
then copies the generated secret back into this function's `MP_WEBHOOK_SECRET`.

- [ ] **Step 3 (controller, after Ricardo confirms he deployed it and configured the webhook): Verify**

No `curl`-based verification in isolation for this one (it only reacts to
real Mercado Pago webhook calls, and a hand-crafted request can't produce a
valid signature without the real secret) — verified end-to-end together
with Tasks 3-4 in Task 6's manual checklist (a real test-mode purchase).

---

### Task 6: Deploy manual + decommission Stripe + checklist E2E

**Files:** none (coordination task, run by the controlling session with
Ricardo — not delegated to a subagent, since it requires live access to
Ricardo's Supabase/Mercado Pago dashboards).

- [ ] **Step 1: Confirm every piece from Tasks 1-5 is live**

- Migrations 0016, 0017 applied (Task 1/2 Step 3 verifications pass).
- `create-checkout-session` and `create-layaway-checkout-session`
  redeployed with the new Mercado Pago code (Task 3/4 Step 3 verifications
  pass), with `MP_ACCESS_TOKEN` (test token) set as a secret on both.
- `mercadopago-webhook` deployed as a new function, `MP_WEBHOOK_SECRET` set
  (Task 5).

- [ ] **Step 2: Decommission Stripe**

- In Supabase Dashboard → Edge Functions: delete or disable the old
  `stripe-webhook` function.
- In Stripe's Dashboard → Developers → Webhooks: delete the webhook
  endpoint that used to point at `stripe-webhook` (stops Stripe from
  retrying calls to a function that no longer exists).
- Confirm no Edge Function secret still holds a live Stripe key that's no
  longer used (`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`) — safe to
  leave them set (unused) or remove them, Ricardo's choice.

- [ ] **Step 3: Full manual checklist against production (test mode)**

Run through each of these against `https://lemus-store.netlify.app` — final
acceptance check for this migration:

- [ ] Un pedido normal desde el catálogo público: agregar al carrito, "Ir a
      pagar", confirmar que redirige a la página de Mercado Pago (modo
      sandbox) mostrando **el total correcto en pesos** (no en centavos),
      y que **solo aparece la opción de pagar con tarjeta** (sin OXXO ni
      transferencia).
- [ ] Pagar con una tarjeta de prueba de Mercado Pago (Ricardo tiene que
      sacar el número de tarjeta de prueba del panel de desarrolladores de
      Mercado Pago — es distinto al `4242...` de Stripe). Confirmar que
      redirige de vuelta a `?checkout=success` con el mensaje de
      confirmación.
- [ ] El pedido aparece en el admin → Pedidos, con `payment_method` /
      registro correcto, y el stock se descontó.
- [ ] Un apartado desde el catálogo: "Apartar (paga 50% ahora)" cobra
      **solo la mitad** del total (verificar el monto mostrado en la
      página de Mercado Pago antes de pagar) y, tras pagar, aparece en
      Apartados → Activos con ese anticipo ya registrado.
- [ ] Reportes → "Ventas por mes" incluye estas compras nuevas con el total
      correcto.
- [ ] Cancelar un pago a medias en Mercado Pago (no completar el pago)
      regresa al catálogo a `?checkout=cancel` sin registrar nada.

- [ ] **Step 4: Report results to Ricardo**

Summarize pass/fail for each checklist item in plain Spanish, with the live
URLs, and remind him that switching to real charges later is just swapping
`MP_ACCESS_TOKEN`/`MP_WEBHOOK_SECRET` for the production versions once his
RFC paperwork is ready — no code changes needed.

---

## Self-Review Notes

- **Spec coverage:** `pending_checkouts` table with no RLS policies
  (Task 1), column renames + constraint widening preserving Stripe history
  (Task 1), RPC updates including the signature-change drop/recreate
  distinction for `record_online_sale` (Task 2), both checkout Edge
  Functions rewritten with unchanged request/response contracts so the
  frontend needs no changes (Tasks 3-4), card-only restriction via
  `excluded_payment_types` (Tasks 3-4), automatic sandbox-vs-production URL
  selection (Tasks 3-4), the new webhook with signature verification,
  payment confirmation via the Payments API, and idempotent recording
  (Task 5), and full deploy + Stripe decommissioning + E2E checklist
  (Task 6) are all covered. Out-of-scope items from the spec (OXXO/SPEI,
  automatic refunds, keeping Stripe as a fallback, activating real charges,
  changes to cash-based Vender/apartar-en-tienda, rewriting historical
  Stripe-labeled rows) are intentionally not tasked here.
- **Type/name consistency check:** `record_online_sale(p_payment_id,
  p_customer_name, p_customer_phone, p_customer_email, p_items)` and
  `record_online_layaway_deposit(p_payment_id, p_customer_name,
  p_customer_phone, p_customer_email, p_total, p_deposit_amount, p_items)`
  match exactly between the migration (Task 2) and the only caller
  (`mercadopago-webhook`, Task 5). `pending_checkouts`'s `payload` shape
  (`{items, customer_name, customer_phone, customer_email}` for `kind:
  'venta'`; same plus `{total, deposit_amount}` for `kind: 'apartado'`) is
  produced identically by Tasks 3/4 and consumed identically by Task 5's
  two RPC-call branches. `sales.payment_id`/`layaways.payment_id` naming is
  consistent across Task 1 (rename), Task 2 (RPC bodies), and Task 5
  (nothing in Task 5 references the old `stripe_checkout_session_id` name).
- **Placeholder scan:** no TBD/TODO; every code block is complete and
  runnable as written. The `excluded_payment_types` field names
  (`ticket`, `atm`) were confirmed against Mercado Pago's own documentation
  during brainstorming, not left as a guess.
- **Manual-deploy workflow made explicit:** every migration/Edge Function
  task ends with "pending manual application/deploy" instead of assuming
  MCP tool access, matching the actual operating constraint of this
  session (confirmed still blocked, `-32600`, right before this plan was
  written).
