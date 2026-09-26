# Conteo físico de inventario — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new "Conteo" tab in Admin — visible to admin and vendedor —
where scanning or typing a product's code/name adds it to an in-progress
count list, and a "Finalizar conteo" + "Aplicar todo" flow compares the
count against current stock and updates `stock_fisica` atomically.

**Architecture:** No new tables. The in-progress count lives only in
browser memory (a module-level array in `admin.js`, same pattern as the
existing `SELL_CART`/`LAYAWAY_CART`), reusing the already-loaded
`PRODUCTS` array for lookups. Applying the count calls one new Postgres
RPC, `apply_inventory_count`, that updates every counted product's
`stock_fisica` inside a single transaction — mirroring the existing
`create_sale_fisica`/`delete_sale`/`cancel_layaway` functions, so any
failure rolls back every row, not just the one that failed.

**Tech Stack:** Same as the rest of this project — vanilla JS ES modules, Supabase Postgres functions, no new dependencies.

## Global Constraints

- No new tables or columns — this feature adds exactly one Postgres
  function (`apply_inventory_count`) and touches no schema otherwise.
- The "Conteo" tab is visible to **both** admin and vendedor
  (`data-role-admin data-role-vendedor`, same as Vender/Pedidos/Apartados)
  — this is an operational task the vendedor also performs.
- The in-progress count list lives only in the browser (module-level JS
  array) — it is never written to Supabase until "Aplicar todo" is
  clicked. Reloading the page mid-count loses it; this is intentional
  per the spec, not a bug to fix.
- Applying the count is all-or-nothing: `apply_inventory_count` updates
  every product inside one Postgres transaction, so a failure on any row
  rolls back the entire call — no partial updates.
- Counted quantity is never allowed below 0, enforced both in the
  browser (clamped on edit) and in the RPC (rejected server-side).
- This feature only ever writes `stock_fisica` — never `stock_online`.
- No new dependencies.

---

### Task 1: `apply_inventory_count` RPC

**Files:**
- Create: `supabase/migrations/0023_apply_inventory_count.sql`

**Interfaces:**
- Consumes: `public.products(id, stock_fisica)`, already defined.
- Produces: `public.apply_inventory_count(p_items jsonb)` — callable via
  `supabase.rpc('apply_inventory_count', { p_items: [...] })` from Task 2,
  where each element of `p_items` is `{ product_id: uuid, counted: integer }`.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/0023_apply_inventory_count.sql`:

```sql
-- supabase/migrations/0023_apply_inventory_count.sql

-- Aplica un conteo físico de inventario: actualiza stock_fisica de cada
-- producto contado al valor realmente contado, todo dentro de una sola
-- transacción (si cualquier producto falla, ninguno se actualiza).
-- A diferencia de delete_sale/cancel_layaway (solo-admin), esta función
-- la puede llamar también el vendedor: el conteo es una tarea operativa
-- que él también hace.
create or replace function public.apply_inventory_count(p_items jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item record;
  v_exists boolean;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Agrega al menos un producto al conteo';
  end if;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, counted integer)
  loop
    if v_item.counted is null or v_item.counted < 0 then
      raise exception 'Cantidad contada inválida';
    end if;

    select exists(select 1 from public.products where id = v_item.product_id for update) into v_exists;
    if not v_exists then
      raise exception 'Producto no encontrado';
    end if;

    update public.products set stock_fisica = v_item.counted where id = v_item.product_id;
  end loop;
end;
$$;

revoke all on function public.apply_inventory_count(jsonb) from public;
grant execute on function public.apply_inventory_count(jsonb) to authenticated;

notify pgrst, 'reload schema';
```

`select ... for update` inside the loop locks each row before its
update, same locking style `create_sale_fisica` already uses — this is
what makes concurrent counts/sales on the same product serialize safely
instead of racing.

- [ ] **Step 2: Manual verification (no automated test suite in this project)**

Read the file back and confirm:
1. The function is `security definer` with `set search_path = public`,
   matching every other RPC in this project (`create_sale_fisica`,
   `delete_sale`, `cancel_layaway`).
2. It does **not** call `public.is_admin()` anywhere — unlike
   `delete_sale`/`cancel_layaway`, both admin and vendedor must be able
   to call it.
3. `grant execute ... to authenticated` (not `anon`) — matches every
   other RPC.
4. A `counted < 0` value raises before any `update` runs.
5. The `for` loop's single `raise exception` on any bad row means the
   whole call rolls back — Postgres functions run as one transaction by
   default, so this needs no explicit `begin`/`commit`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0023_apply_inventory_count.sql
git commit -m "Add apply_inventory_count RPC for physical inventory counts"
```

---

### Task 2: Admin — "Conteo" tab

**Files:**
- Modify: `app/admin.html` (new tab button + panel)
- Modify: `app/js/admin.js` (count state, search/scan handling, list
  rendering, finalize/apply)

**Interfaces:**
- Consumes: `PRODUCTS`/`productById`/`escapeHtml`/`showToast`/
  `reloadProducts`/`renderTable`/`refreshSellProductOptions`/
  `refreshTransferProductOptions`/`refreshLayawayProductOptions`/
  `renderStats`, all already defined in `admin.js`. Calls
  `apply_inventory_count` from Task 1 via `supabase.rpc(...)`.
- Produces: nothing consumed elsewhere — this is the only other task in
  this plan.

- [ ] **Step 1: Add the "Conteo" tab button**

In `app/admin.html`, find the Apartados tab button:

```html
    <button class="tab-btn" data-tab="layaways" type="button" aria-selected="false" data-role-admin data-role-vendedor>Apartados</button>
    <button class="tab-btn" data-tab="transfers" type="button" aria-selected="false" data-role-admin>Traspasos</button>
```

Insert the new button between them:

```html
    <button class="tab-btn" data-tab="layaways" type="button" aria-selected="false" data-role-admin data-role-vendedor>Apartados</button>
    <button class="tab-btn" data-tab="count" type="button" aria-selected="false" data-role-admin data-role-vendedor>Conteo</button>
    <button class="tab-btn" data-tab="transfers" type="button" aria-selected="false" data-role-admin>Traspasos</button>
```

- [ ] **Step 2: Add the "Conteo" tab panel**

In `app/admin.html`, find the end of the Apartados panel and the start
of the Traspasos comment:

```html
    <div class="grid-head"><h2>Historial</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <thead><tr><th>Fecha límite</th><th>Cliente</th><th>Total</th><th>Estado</th></tr></thead>
        <tbody id="layaways-history-tbody"></tbody>
      </table>
    </div>
  </section>

  <!-- ---------- Traspasos ---------- -->
```

Insert the new panel between them:

```html
    <div class="grid-head"><h2>Historial</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <thead><tr><th>Fecha límite</th><th>Cliente</th><th>Total</th><th>Estado</th></tr></thead>
        <tbody id="layaways-history-tbody"></tbody>
      </table>
    </div>
  </section>

  <!-- ---------- Conteo físico ---------- -->
  <section class="tab-panel" id="tab-count" hidden>
    <div class="grid-head"><h2>Conteo físico de inventario</h2></div>
    <div class="autocomplete-wrap" id="count-search-wrap">
      <input class="cell-input" id="count-search" type="text" autocomplete="off" placeholder="Escanea el código o escribe el nombre del producto…">
      <div class="autocomplete-list" id="count-suggestions" hidden></div>
    </div>

    <div class="table-wrap" style="margin-top:16px;">
      <table class="admin-table">
        <thead><tr><th>Producto</th><th>Contado</th><th></th></tr></thead>
        <tbody id="count-items-tbody"></tbody>
      </table>
    </div>

    <button class="btn btn-primary" type="button" id="count-finish-btn" style="margin-top:12px;">Finalizar conteo</button>

    <div id="count-diff-wrap" hidden>
      <div class="grid-head" style="margin-top:32px;"><h2>Resultado del conteo</h2></div>
      <div class="table-wrap">
        <table class="admin-table">
          <thead><tr><th>Producto</th><th>Stock actual</th><th>Contado</th><th>Diferencia</th></tr></thead>
          <tbody id="count-diff-tbody"></tbody>
        </table>
      </div>
      <button class="btn btn-primary" type="button" id="count-apply-btn" style="margin-top:12px;">Aplicar todo</button>
    </div>
  </section>

  <!-- ---------- Traspasos ---------- -->
```

No new CSS is needed — `.autocomplete-wrap`/`.autocomplete-list`/
`.autocomplete-item` (used today by Promociones' product search) and
`.admin-table tr.low-stock` (used today by Pedidos/Apartados to flag
rows needing attention) are reused as-is.

- [ ] **Step 3: Add the Conteo state, search/scan handling, and list rendering to `admin.js`**

In `app/js/admin.js`, find the end of `renderTransfers()` and the start
of the Promotions tab section:

```javascript
  tbody.innerHTML = TRANSFERS.map(t => `
    <tr>
      <td>${new Date(t.created_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' })}</td>
      <td>${t.products ? escapeHtml(t.products.name) : '—'}</td>
      <td>${locationLabel(t.from_location)} → ${locationLabel(t.to_location)}</td>
      <td>${t.quantity}</td>
      <td>${t.note ? escapeHtml(t.note) : '—'}</td>
    </tr>`).join('');
}

// ---------- Promotions tab ----------
```

Insert the new section between them:

```javascript
  tbody.innerHTML = TRANSFERS.map(t => `
    <tr>
      <td>${new Date(t.created_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' })}</td>
      <td>${t.products ? escapeHtml(t.products.name) : '—'}</td>
      <td>${locationLabel(t.from_location)} → ${locationLabel(t.to_location)}</td>
      <td>${t.quantity}</td>
      <td>${t.note ? escapeHtml(t.note) : '—'}</td>
    </tr>`).join('');
}

// ---------- Conteo tab ----------

let COUNT_ITEMS = []; // [{ product_id, counted }]

function addToCount(productId) {
  const existing = COUNT_ITEMS.find(i => i.product_id === productId);
  if (existing) existing.counted += 1;
  else COUNT_ITEMS.push({ product_id: productId, counted: 1 });
  renderCountItems();
  document.getElementById('count-diff-wrap').hidden = true;
}

function renderCountSuggestions(query) {
  const list = document.getElementById('count-suggestions');
  const q = query.trim().toLowerCase();
  if (!q) { list.hidden = true; list.innerHTML = ''; return; }
  const matches = PRODUCTS.filter(p => p.name.toLowerCase().includes(q)).slice(0, 8);
  if (matches.length === 0) { list.hidden = true; list.innerHTML = ''; return; }
  list.innerHTML = matches.map(p =>
    `<button type="button" class="autocomplete-item" data-id="${p.id}">${escapeHtml(p.name)}</button>`
  ).join('');
  list.hidden = false;
}

document.getElementById('count-search').addEventListener('input', (e) => {
  const raw = e.target.value;
  const q = raw.trim().toLowerCase();
  const list = document.getElementById('count-suggestions');
  if (!q) { list.hidden = true; list.innerHTML = ''; return; }

  const exact = PRODUCTS.find(p => (p.code || '').toLowerCase() === q);
  if (exact) {
    addToCount(exact.id);
    e.target.value = '';
    list.hidden = true;
    list.innerHTML = '';
    return;
  }
  renderCountSuggestions(raw);
});

document.getElementById('count-search').addEventListener('keydown', (e) => {
  if (e.key !== 'Enter') return;
  const raw = e.target.value.trim();
  if (!raw) return;
  const list = document.getElementById('count-suggestions');
  if (!list.hidden && list.children.length > 0) return; // hay coincidencias por nombre, se elige con clic
  showToast('Producto no encontrado', true);
  e.target.value = '';
  list.hidden = true;
  list.innerHTML = '';
});

document.getElementById('count-suggestions').addEventListener('click', (e) => {
  const btn = e.target.closest('[data-id]');
  if (!btn) return;
  addToCount(btn.dataset.id);
  document.getElementById('count-search').value = '';
  document.getElementById('count-suggestions').hidden = true;
  document.getElementById('count-suggestions').innerHTML = '';
  document.getElementById('count-search').focus();
});

document.addEventListener('click', (e) => {
  const wrap = document.getElementById('count-search-wrap');
  const list = document.getElementById('count-suggestions');
  if (!list.hidden && !wrap.contains(e.target)) list.hidden = true;
});

function renderCountItems() {
  const tbody = document.getElementById('count-items-tbody');
  if (COUNT_ITEMS.length === 0) {
    tbody.innerHTML = `<tr><td colspan="3" style="color:var(--ink-soft);">Todavía no has contado ningún producto.</td></tr>`;
    return;
  }
  tbody.innerHTML = COUNT_ITEMS.map((item, idx) => {
    const p = productById(item.product_id);
    return `<tr>
      <td>${escapeHtml(p?.name || '—')}</td>
      <td><input class="cell-input" type="number" min="0" step="1" value="${item.counted}" data-idx="${idx}" style="max-width:100px;"></td>
      <td><button class="icon-mini danger" type="button" data-idx="${idx}" aria-label="Quitar">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6l12 12M18 6L6 18"/></svg>
      </button></td>
    </tr>`;
  }).join('');
  tbody.querySelectorAll('input[data-idx]').forEach(input => {
    input.addEventListener('change', () => {
      const idx = Number(input.dataset.idx);
      const val = Math.max(0, Math.round(Number(input.value) || 0));
      COUNT_ITEMS[idx].counted = val;
      input.value = val;
    });
  });
  tbody.querySelectorAll('button[data-idx]').forEach(btn => {
    btn.addEventListener('click', () => {
      COUNT_ITEMS.splice(Number(btn.dataset.idx), 1);
      renderCountItems();
    });
  });
}

document.getElementById('count-finish-btn').addEventListener('click', () => {
  if (COUNT_ITEMS.length === 0) {
    showToast('Agrega al menos un producto al conteo', true);
    return;
  }
  const tbody = document.getElementById('count-diff-tbody');
  tbody.innerHTML = COUNT_ITEMS.map(item => {
    const p = productById(item.product_id);
    const actual = p?.stock_fisica ?? 0;
    const diff = item.counted - actual;
    return `<tr class="${diff !== 0 ? 'low-stock' : ''}">
      <td>${escapeHtml(p?.name || '—')}</td>
      <td>${actual}</td>
      <td>${item.counted}</td>
      <td>${diff > 0 ? '+' : ''}${diff}</td>
    </tr>`;
  }).join('');
  document.getElementById('count-diff-wrap').hidden = false;
});

document.getElementById('count-apply-btn').addEventListener('click', async (e) => {
  const btn = e.currentTarget;
  if (COUNT_ITEMS.length === 0) return;
  btn.disabled = true;
  try {
    const { error } = await supabase.rpc('apply_inventory_count', {
      p_items: COUNT_ITEMS.map(i => ({ product_id: i.product_id, counted: i.counted })),
    });
    if (error) { showToast('No se pudo aplicar el conteo, ningún producto se actualizó', true); console.error(error); return; }

    showToast('Conteo aplicado, stock física actualizado');
    COUNT_ITEMS = [];
    renderCountItems();
    document.getElementById('count-diff-wrap').hidden = true;
    await reloadProducts();
    renderTable();
    refreshSellProductOptions();
    refreshTransferProductOptions();
    refreshLayawayProductOptions();
    renderStats();
  } finally {
    btn.disabled = false;
  }
});

// ---------- Promotions tab ----------
```

`PRODUCTS`, `productById`, `escapeHtml`, `showToast`, `reloadProducts`,
`renderTable`, `refreshSellProductOptions`, `refreshTransferProductOptions`,
`refreshLayawayProductOptions`, `renderStats`, and `supabase` are all
already defined/imported earlier in this file — do not redefine or
reimplement any of them. `COUNT_ITEMS` is never touched by
`loadEverything()`/realtime reloads, exactly like the existing
`SELL_CART`/`LAYAWAY_CART` — those also survive reloads untouched and
are only ever mutated by their own tab's handlers.

- [ ] **Step 4: Manual verification (no automated test suite in this project)**

Run `node --check app/js/admin.js`. Then trace through by hand:
1. `applyRoleVisibility()` (already defined, unchanged by this task)
   toggles `.tab-btn[data-role-...]` — the new "Conteo" button carries
   both `data-role-admin` and `data-role-vendedor`, so it's visible to
   both roles, matching Vender/Pedidos/Apartados.
2. Typing a query whose lowercased value exactly equals some product's
   lowercased `code` fires on the very next keystroke that completes the
   match — `addToCount` runs immediately, the input clears itself, and
   no suggestions list ever appears for that keystroke. This is what
   makes a barcode scan (which types the full code near-instantly) add
   automatically with no click.
3. Typing a partial name with 2+ case-insensitive substring matches in
   `PRODUCTS` shows up to 8 as clickable buttons in `#count-suggestions`;
   clicking one calls `addToCount`, clears the input, and hides the list.
4. Pressing Enter with the suggestions list empty and non-hidden-with-
   children shows "Producto no encontrado" via `showToast` and adds
   nothing to `COUNT_ITEMS`.
5. `addToCount` on a product already in `COUNT_ITEMS` increments its
   `counted` instead of adding a duplicate row.
6. Editing the quantity `<input>` for a row clamps to `Math.max(0, ...)`
   on `change` — typing `-3` or `0` never leaves `COUNT_ITEMS[idx].counted`
   negative.
7. Clicking a row's remove button splices exactly that index out of
   `COUNT_ITEMS` and re-renders.
8. "Finalizar conteo" with an empty `COUNT_ITEMS` shows an error toast
   and never un-hides `#count-diff-wrap`.
9. With items counted, "Finalizar conteo" renders one row per counted
   item comparing `productById(item.product_id).stock_fisica` (actual)
   against `item.counted`, with `diff = counted - actual` and the
   `low-stock` class applied only when `diff !== 0`.
10. "Aplicar todo" calls `supabase.rpc('apply_inventory_count', ...)`
    with `p_items` shaped `{ product_id, counted }[]` — matching Task 1's
    `jsonb_to_recordset(p_items) as x(product_id uuid, counted integer)`
    exactly.
11. On RPC error, the `if (error) { ...; return; }` branch returns
    *before* `COUNT_ITEMS = []` — the in-progress count is preserved and
    nothing is cleared when the apply fails, satisfying the spec's
    "ningún producto se actualiza a medias" requirement together with
    Task 1's single-transaction RPC.
12. On success, `COUNT_ITEMS` is cleared, the diff panel re-hides, and
    `reloadProducts()` + the same refresher calls the existing
    transfer-form handler uses are run so Inventario, Vender, Traspasos,
    and Apartados all reflect the new `stock_fisica` immediately.

- [ ] **Step 5: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Add Conteo tab for scan-driven physical inventory counts"
```
