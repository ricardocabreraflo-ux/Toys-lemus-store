# Borrado protegido de ventas y productos — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Protect product and sale deletion with a short admin-defined
PIN (to prevent accidental deletion), and add the sale-deletion
capability itself — which doesn't exist yet — restoring stock when a
sale is deleted.

**Architecture:** One new admin-only table (`security_settings`) for
the PIN, one new SECURITY DEFINER RPC (`delete_sale`) that restores
stock and deletes a sale, and a shared client-side confirm+PIN helper
reused across the four deletion points (Inventario's existing product
delete, new delete buttons in Pedidos and a new "Ventas recientes" list
in Vender).

**Tech Stack:** Same as the rest of this project — Supabase (Postgres + RLS + RPC), vanilla JS ES modules, no new dependencies.

## Global Constraints

- The PIN is a client-side accidental-click guard, not a server-side
  security boundary — `delete_sale` is protected by `public.is_admin()`
  (a real access-control check), but the PIN itself is only compared in
  the browser. Do not add server-side PIN verification — it's out of
  scope and was explicitly not requested (see the spec's threat-model
  note).
- `delete_sale` must restore stock: `stock_online` for `channel =
  'online'` sales, `stock_fisica` for `channel = 'fisica'` sales, using
  each sale's own `sale_items.quantity` — then delete the sale (cascades
  to `sale_items`).
- Apartados/layaways are out of scope — do not touch anything under
  `tab-layaways`, `LAYAWAYS`, or the layaway RPCs.
- Deleting a product must keep its existing referential-integrity
  behavior unchanged (still fails if the product has references that
  block deletion) — only the PIN step is added in front of it.
- Do not touch sales-recording RPCs (`record_online_sale`,
  `create_sale_fisica`), Mercado Pago checkout, Promociones, or
  Finanzas.
- No new dependencies.

---

### Task 1: Migration — `security_settings` table and `delete_sale` RPC

**Files:**
- Create: `supabase/migrations/0021_borrado_protegido.sql`

**Interfaces:**
- Produces: `public.security_settings` (singleton row: `id`,
  `delete_pin`), consumed by Task 2's Ajustes UI.
- Produces: `public.delete_sale(p_sale_id uuid) returns void`, consumed
  by Task 2's Pedidos and Vender delete handlers.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0021_borrado_protegido.sql
-- Ricardo wants a short PIN (separate from his login password) that
-- guards accidental deletion of products and sales, plus the ability
-- to delete a sale at all (doesn't exist yet) — deleting a sale
-- restores the stock it sold. See
-- docs/superpowers/specs/2026-08-21-borrado-protegido-design.md.

create table if not exists public.security_settings (
  id          boolean primary key default true,
  delete_pin  text not null default '0000',
  constraint security_settings_single_row check (id)
);

insert into public.security_settings (id) values (true) on conflict (id) do nothing;

alter table public.security_settings enable row level security;

drop policy if exists "admin only" on public.security_settings;
create policy "admin only" on public.security_settings for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'security_settings'
  ) then
    alter publication supabase_realtime add table public.security_settings;
  end if;
end;
$$;

-- Deleting a sale restores the stock it sold (stock_online for
-- 'online' sales, stock_fisica for 'fisica' sales), then deletes the
-- sale (sale_items cascades). Known, accepted limitation: an 'online'
-- sale marked 'revisar_sin_stock' was oversold, so its real stock
-- deduction at the time was less than sale_items.quantity (clamped to
-- 0) — deleting it restores the full sale_items quantity, which can
-- over-restore by a few units in that one edge case. Those sales
-- already require manual review, so this isn't solved here.
create or replace function public.delete_sale(p_sale_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_channel text;
  v_item record;
begin
  if not public.is_admin() then
    raise exception 'No autorizado';
  end if;

  select channel into v_channel from public.sales where id = p_sale_id;
  if v_channel is null then
    raise exception 'Venta no encontrada';
  end if;

  for v_item in
    select product_id, quantity from public.sale_items
    where sale_id = p_sale_id and product_id is not null
  loop
    if v_channel = 'online' then
      update public.products set stock_online = stock_online + v_item.quantity where id = v_item.product_id;
    else
      update public.products set stock_fisica = stock_fisica + v_item.quantity where id = v_item.product_id;
    end if;
  end loop;

  delete from public.sales where id = p_sale_id;
end;
$$;

revoke all on function public.delete_sale(uuid) from public;
grant execute on function public.delete_sale(uuid) to authenticated;

notify pgrst, 'reload schema';
```

- [ ] **Step 2: Sanity-check the migration text**

No local Supabase instance or automated tests in this project — Ricardo
runs this by hand via the Supabase Dashboard SQL editor. Re-read the
file once against these checks:
1. Every statement ends with a semicolon.
2. The `do $$ ... $$;` publication guard matches the exact pattern
   already used in `0018_catalog_visibility_settings.sql`/
   `0019_promotions_by_product.sql`/`0020_fixed_expenses.sql`.
3. `delete_sale`'s `for v_item in select ... loop ... end loop;`
   structure is balanced, and the `if v_channel = 'online' ... else
   ... end if;` inside it correctly updates exactly one of
   `stock_online`/`stock_fisica` per iteration.
4. `revoke`/`grant` on `delete_sale` matches the exact pattern used for
   `mark_sale_delivered` in `0010_sale_functions.sql` (revoke from
   `public`, grant execute to `authenticated` — the `is_admin()` check
   inside the function body is the actual gate).

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0021_borrado_protegido.sql
git commit -m "Add security_settings table and delete_sale RPC"
```

---

### Task 2: Admin frontend — PIN gate, sale deletion UI, "Ventas recientes"

**Files:**
- Modify: `app/admin.html` (Ajustes → Seguridad section; Pedidos delete
  buttons; new "Ventas recientes" section in Vender)
- Modify: `app/js/admin.js` (shared PIN helper, `SECURITY_SETTINGS`
  state, `deleteProduct()` update, Pedidos/Vender delete wiring, new
  recent-physical-sales load/render, `loadEverything()`/
  `subscribeRealtime()` wiring)

**Interfaces:**
- Consumes: `public.security_settings`, `public.delete_sale(uuid)`
  (Task 1); the existing `fmt`/`escapeHtml`/`showToast`/`CURRENT_ROLE`/
  `supabase` helpers already in `admin.js`; the existing `reloadProducts`/
  `renderTable`/`renderStats`/`refreshSellProductOptions` functions
  already used elsewhere in this file for refreshing product data after
  a stock-affecting change.
- Produces: `askForDeletePin(message)` — a shared helper other future
  deletion features in this file can reuse (returns `true`/`false`,
  never touches the network itself).

- [ ] **Step 1: Add the Seguridad section to Ajustes**

In `app/admin.html`, inside `#tab-settings`, right before the section's
closing `</section>` (after the existing "Página principal" block that
ends with the `show_products_stat` checkbox row), add:

```html
    <div class="grid-head"><h2>Seguridad</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <tbody>
          <tr>
            <td>Código para borrar ventas y productos</td>
            <td><input class="cell-input" id="setting-delete-pin" type="text" style="max-width:120px;"></td>
          </tr>
        </tbody>
      </table>
    </div>
```

- [ ] **Step 2: Add delete buttons to the Pedidos tables**

In `app/admin.html`, inside `#tab-orders`, the "Entregados" table's
header currently has no trailing action column. Change:

```html
        <thead><tr><th>Fecha</th><th>Cliente</th><th>Teléfono</th><th>Total</th><th>Entregado</th></tr></thead>
```

to:

```html
        <thead><tr><th>Fecha</th><th>Cliente</th><th>Teléfono</th><th>Total</th><th>Entregado</th><th></th></tr></thead>
```

The "Pendientes" table's header already has a trailing empty `<th></th>`
for the existing "Marcar entregado" button — no HTML change needed
there, only the row template changes in Step 4.

- [ ] **Step 3: Add "Ventas recientes" to Vender**

In `app/admin.html`, inside `#tab-sell`, right before the section's
closing `</section>` (after the existing `#sell-confirm-btn` button),
add:

```html
    <div class="grid-head" style="margin-top:32px;"><h2>Ventas recientes</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <thead><tr><th>Fecha</th><th>Total</th><th></th></tr></thead>
        <tbody id="recent-sales-tbody"></tbody>
      </table>
    </div>
```

- [ ] **Step 4: Add `SECURITY_SETTINGS` state, `loadSecuritySettings()`, and `askForDeletePin()`**

In `app/js/admin.js`, find the module-level state block (it currently
ends with lines like `let FIXED_EXPENSES = [];` and
`let CURRENT_MONTH_MARGIN = 0;` — read the file to find its exact
current end, since other tasks may have appended to it) and add:

```javascript
let SECURITY_SETTINGS = { delete_pin: '0000' };
let RECENT_PHYSICAL_SALES = [];
```

Add these two functions near the other small helpers (e.g. next to
`escapeHtml`/`showToast` is a reasonable spot — read the file to place
them naturally):

```javascript
async function loadSecuritySettings() {
  const { data, error } = await supabase.from('security_settings').select('*').single();
  if (error) throw error;
  return data;
}

// Shared by every deletion point in this file: browser confirm, then
// a PIN prompt compared against SECURITY_SETTINGS.delete_pin. This is
// an accidental-click guard, not a real access-control boundary (see
// the design spec's threat-model note) — delete_sale's real gate is
// public.is_admin() on the server.
function askForDeletePin(confirmMessage) {
  if (!window.confirm(confirmMessage)) return false;
  const entered = window.prompt('Escribe el código de seguridad para borrar:');
  if (entered === null) return false;
  if (entered !== SECURITY_SETTINGS.delete_pin) {
    showToast('Código incorrecto, no se borró nada', true);
    return false;
  }
  return true;
}
```

- [ ] **Step 5: Wire the PIN field in `renderSettings()`**

In `app/js/admin.js`'s `renderSettings()` function, add this at the end
of the function (after the existing `statCb.onchange = ...` block):

```javascript
  const pinInput = document.getElementById('setting-delete-pin');
  pinInput.value = SECURITY_SETTINGS.delete_pin;
  pinInput.onchange = async () => {
    const value = pinInput.value.trim();
    if (!value) { pinInput.value = SECURITY_SETTINGS.delete_pin; return; }
    const { error } = await supabase.from('security_settings').update({ delete_pin: value }).eq('id', true);
    if (error) { showToast('No se pudo actualizar', true); pinInput.value = SECURITY_SETTINGS.delete_pin; return; }
    SECURITY_SETTINGS.delete_pin = value;
    showToast('Código actualizado');
  };
```

- [ ] **Step 6: Gate `deleteProduct()` with the PIN**

In `app/js/admin.js`, find:

```javascript
async function deleteProduct(id) {
  const p = productById(id);
  if (!p) return;
  if (!confirm(`¿Eliminar "${p.name}" del catálogo? Esto no se puede deshacer.`)) return;
  const { error } = await supabase.from('products').delete().eq('id', id);
```

Replace the `confirm(...)` line with:

```javascript
async function deleteProduct(id) {
  const p = productById(id);
  if (!p) return;
  if (!askForDeletePin(`¿Eliminar "${p.name}" del catálogo? Esto no se puede deshacer.`)) return;
  const { error } = await supabase.from('products').delete().eq('id', id);
```

The rest of the function (error handling, local state update, toast)
stays exactly as-is.

- [ ] **Step 7: Add delete handlers to `renderOrders()`**

In `app/js/admin.js`'s `renderOrders()`, replace the pending row
template's last cell:

```javascript
        <td>${(o.status === 'pagado' || o.status === 'revisar_sin_stock') ? `<button class="btn btn-primary btn-sm" type="button" data-role="deliver">Marcar entregado</button>` : ''}</td>
```

with:

```javascript
        <td>
          ${(o.status === 'pagado' || o.status === 'revisar_sin_stock') ? `<button class="btn btn-primary btn-sm" type="button" data-role="deliver">Marcar entregado</button>` : ''}
          <button class="icon-mini danger" data-role="order-delete" type="button" aria-label="Eliminar pedido" style="margin-left:6px;">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
          </button>
        </td>
```

Then, right after the existing `pendingTbody.querySelectorAll('[data-role="deliver"]')...` block, add:

```javascript
  pendingTbody.querySelectorAll('[data-role="order-delete"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      if (!askForDeletePin('¿Eliminar este pedido? El stock vendido regresa al inventario.')) return;
      const { error } = await supabase.rpc('delete_sale', { p_sale_id: id });
      if (error) { showToast(error.message, true); return; }
      showToast('Pedido eliminado');
      await loadOrders();
      renderOrders();
      await reloadProducts();
      renderTable();
      renderStats();
    });
  });
```

Now update the delivered table. Replace:

```javascript
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

with:

```javascript
  const deliveredTbody = document.getElementById('orders-delivered-tbody');
  deliveredTbody.innerHTML = delivered.length === 0
    ? `<tr><td colspan="6" style="color:var(--ink-soft);">Sin entregas todavía.</td></tr>`
    : delivered.map(o => `
      <tr data-id="${o.id}">
        <td>${new Date(o.created_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' })}</td>
        <td>${escapeHtml(o.customer_name || '—')}</td>
        <td>${escapeHtml(o.customer_phone || '—')}</td>
        <td>${fmt.format(o.total)}</td>
        <td>${o.delivered_at ? new Date(o.delivered_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' }) : '—'}</td>
        <td>
          <button class="icon-mini danger" data-role="order-delete" type="button" aria-label="Eliminar pedido">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
          </button>
        </td>
      </tr>`).join('');
  deliveredTbody.querySelectorAll('[data-role="order-delete"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      if (!askForDeletePin('¿Eliminar este pedido? El stock vendido regresa al inventario.')) return;
      const { error } = await supabase.rpc('delete_sale', { p_sale_id: id });
      if (error) { showToast(error.message, true); return; }
      showToast('Pedido eliminado');
      await loadOrders();
      renderOrders();
      await reloadProducts();
      renderTable();
      renderStats();
    });
  });
}
```

(`colspan` on the empty-state row goes from `5` to `6` to match the
new column count.)

- [ ] **Step 8: Add `loadRecentSales()` and `renderRecentSales()`**

Add these two functions near the end of the "Vender tab (POS física)"
section in `app/js/admin.js` (after `refreshSellProductOptions()` and
the `sell-confirm-btn` handler, before the `// ---------- Pedidos tab
----------` comment — read the file to place them exactly there):

```javascript
async function loadRecentSales() {
  const { data, error } = await supabase
    .from('sales')
    .select('id, total, created_at')
    .eq('channel', 'fisica')
    .order('created_at', { ascending: false })
    .limit(20);
  if (error) { console.error(error); return; }
  RECENT_PHYSICAL_SALES = data;
}

function renderRecentSales() {
  const tbody = document.getElementById('recent-sales-tbody');
  tbody.innerHTML = RECENT_PHYSICAL_SALES.length === 0
    ? `<tr><td colspan="3" style="color:var(--ink-soft);">Sin ventas físicas todavía.</td></tr>`
    : RECENT_PHYSICAL_SALES.map(s => `
      <tr data-id="${s.id}">
        <td>${new Date(s.created_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' })}</td>
        <td>${fmt.format(s.total)}</td>
        <td>
          <button class="icon-mini danger" data-role="sale-delete" type="button" aria-label="Eliminar venta">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
          </button>
        </td>
      </tr>`).join('');
  tbody.querySelectorAll('[data-role="sale-delete"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      if (!askForDeletePin('¿Eliminar esta venta? El stock vendido regresa al inventario.')) return;
      const { error } = await supabase.rpc('delete_sale', { p_sale_id: id });
      if (error) { showToast(error.message, true); return; }
      showToast('Venta eliminada');
      await loadRecentSales();
      renderRecentSales();
      await reloadProducts();
      renderTable();
      refreshSellProductOptions();
      renderStats();
    });
  });
}
```

- [ ] **Step 9: Wire everything into `loadEverything()`**

In `app/js/admin.js`'s `loadEverything()`, find:

```javascript
    try {
      SITE_SETTINGS = await loadSiteSettings();
    } catch (err) {
      console.error('No se pudo cargar site_settings, usando valores por defecto', err);
    }
```

Add a matching isolated block right after it (same non-critical
posture as `SITE_SETTINGS` — a failure here shouldn't take down the
whole panel, it should just leave the in-memory default PIN in place):

```javascript
    try {
      SECURITY_SETTINGS = await loadSecuritySettings();
    } catch (err) {
      console.error('No se pudo cargar security_settings, usando el PIN por defecto', err);
    }
```

Then find:

```javascript
    await loadOrders();
    await loadLayaways();
```

and add the recent-sales load right after it:

```javascript
    await loadOrders();
    await loadLayaways();
    await loadRecentSales();
```

Finally, find:

```javascript
    renderOrders();
    renderLayaways();
```

and add the render call:

```javascript
    renderOrders();
    renderLayaways();
    renderRecentSales();
```

- [ ] **Step 10: Add `security_settings` to the realtime subscription**

In `app/js/admin.js`'s `subscribeRealtime()`, find the chain ending in:

```javascript
    .on('postgres_changes', { event: '*', schema: 'public', table: 'fixed_expenses' }, scheduleReload)
    .subscribe();
```

Add one line before `.subscribe()`:

```javascript
    .on('postgres_changes', { event: '*', schema: 'public', table: 'fixed_expenses' }, scheduleReload)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'security_settings' }, scheduleReload)
    .subscribe();
```

No new entry is needed for sale deletion itself — `'sales'` is already
in this same subscription chain from before this task, so a
`delete_sale` call already triggers `scheduleReload` and refreshes
Pedidos/Vender/Reportes/Finanzas.

- [ ] **Step 11: Manual verification (no automated test suite in this project)**

Run `node --check app/js/admin.js`. Then trace through by hand:
1. `askForDeletePin` returns `false` (no network call happens) if the
   user cancels the `confirm()`, cancels the `prompt()`, or types the
   wrong PIN — and `true` only on an exact match.
2. `deleteProduct()` calls `askForDeletePin` before its existing
   `supabase.from('products').delete()` call — unchanged otherwise.
3. Both Pedidos delete handlers (pending and delivered) call
   `delete_sale` via RPC, then refresh orders AND products/stats (since
   stock changed) — not just the orders list.
4. `renderRecentSales()`'s delete handler does the same three-way
   refresh (recent sales, products/table, sell product options —
   since a restored unit might make a previously stock_fisica=0
   product sellable again).
5. `renderSettings()`'s new PIN field reverts to the last-known value
   (not blanked) on an empty input or a failed save — never lets the
   local `SECURITY_SETTINGS.delete_pin` fall out of sync with what's
   actually saved.

- [ ] **Step 12: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Add PIN-protected deletion for products and sales, plus a Ventas recientes list"
```
