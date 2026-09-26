# Reporte de ventas por categoría y producto — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two new tables to Reportes — sales grouped by category and
by individual product — for a period Ricardo picks (a specific month or
all time), reusing the exact same data `renderSalesReport()` already
fetches for the existing "Ventas por mes" table.

**Architecture:** No new database query, view, or migration — the sale
rows and `sale_items_view` rows `renderSalesReport()` already fetches
are cached in module state and re-grouped in the browser whenever the
period filter changes, joining each line item's `product_id` against
the already-loaded `PRODUCTS` array (which carries `category_id`/
`product_line_id`) to know its category.

**Tech Stack:** Same as the rest of this project — vanilla JS ES modules, no new dependencies, no migration.

## Global Constraints

- No new Supabase query beyond what `renderSalesReport()` already
  makes — the period filter re-groups already-fetched data in memory,
  it never re-fetches.
- The existing "Ventas por mes" table's behavior and markup are
  unchanged — this plan only adds two new tables below it.
- A `sale_items_view` row with `product_id = null` (the "producto ya no
  existe" case), or whose `product_id` isn't found in the currently
  loaded `PRODUCTS` array, is excluded from BOTH new tables — it still
  counts in the existing month table's totals, which don't change.
- The by-product table shows only products with at least one sale in
  the selected period, sorted by profit (total minus cost) descending.
- Do not touch sales, Mercado Pago checkout, Promociones, Finanzas, or
  borrado-protegido/permisos-vendedor code.
- No new dependencies.

---

### Task 1: Reportes — period filter and the two new tables

**Files:**
- Modify: `app/admin.html` (new period-filter select + two new tables
  in `#tab-reports`)
- Modify: `app/js/admin.js` (cache the fetched sales/items, populate
  the period filter, group-and-render the two new tables)

**Interfaces:**
- Consumes: the existing `PRODUCTS`/`CATEGORIES`/`LINES` module state,
  `catById`/`lineById`/`productById` helpers, `fmt`/`escapeHtml`
  already in `admin.js`.
- Produces: nothing consumed elsewhere — this is the only task in this
  plan.

- [ ] **Step 1: Add the period filter and two new tables to `admin.html`**

In `app/admin.html`, inside `#tab-reports`, find the existing "Ventas
por mes" block:

```html
    <div class="grid-head"><h2>Ventas por mes</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <thead><tr><th>Mes</th><th>Ventas</th><th>Piezas vendidas</th><th>Total vendido</th><th>Costo real</th><th>Ganancia real</th></tr></thead>
        <tbody id="report-sales-tbody"></tbody>
      </table>
    </div>
  </section>
```

Replace it with (the existing block, unchanged, plus two new tables and
the closing `</section>` moved to after them):

```html
    <div class="grid-head"><h2>Ventas por mes</h2></div>
    <div class="table-wrap" style="margin-bottom:32px;">
      <table class="admin-table">
        <thead><tr><th>Mes</th><th>Ventas</th><th>Piezas vendidas</th><th>Total vendido</th><th>Costo real</th><th>Ganancia real</th></tr></thead>
        <tbody id="report-sales-tbody"></tbody>
      </table>
    </div>

    <div class="grid-head">
      <h2>Ventas por categoría y producto</h2>
      <select class="cell-input" id="report-period-filter" style="max-width:200px;">
        <option value="all">Todos los periodos</option>
      </select>
    </div>
    <div class="table-wrap" style="margin-bottom:32px;">
      <table class="admin-table">
        <thead><tr><th>Categoría</th><th>Ventas</th><th>Piezas vendidas</th><th>Total vendido</th><th>Costo real</th><th>Ganancia real</th></tr></thead>
        <tbody id="report-category-tbody"></tbody>
      </table>
    </div>
    <div class="table-wrap">
      <table class="admin-table">
        <thead><tr><th>Producto</th><th>Ventas</th><th>Piezas vendidas</th><th>Total vendido</th><th>Costo real</th><th>Ganancia real</th></tr></thead>
        <tbody id="report-product-tbody"></tbody>
      </table>
    </div>
  </section>
```

(`.grid-head` is already `display: flex; justify-content: space-between`
in `app/css/styles.css` — the `<select>` lands to the right of the
`<h2>` with no new CSS needed, same as `.count` elements elsewhere in
this file.)

- [ ] **Step 2: Widen the `sale_items_view` select and cache the fetched data**

In `app/js/admin.js`, find the module-level state block (it currently
ends with lines like `let VENDEDOR_PERMISSIONS = { can_cancel_layaways:
false };` — read the file to find its exact current end) and add:

```javascript
let SALES_REPORT_SALES = [];
let SALES_REPORT_ITEMS = [];
```

Then find `renderSalesReport()`'s items query:

```javascript
  const { data: items, error: itemsErr } = await supabase
    .from('sale_items_view')
    .select('sale_id, quantity, unit_price, unit_cost_price');
  if (itemsErr) { console.error(itemsErr); return; }
```

Widen the `select` to also fetch `product_id` (needed to join against
`PRODUCTS` for category grouping — `product_name` is NOT needed since
every kept row will have a matching `PRODUCTS` entry, see Step 3):

```javascript
  const { data: items, error: itemsErr } = await supabase
    .from('sale_items_view')
    .select('sale_id, product_id, quantity, unit_price, unit_cost_price');
  if (itemsErr) { console.error(itemsErr); return; }
```

Right after that block (before the existing `const bySale = new Map(...)`
line), add:

```javascript
  SALES_REPORT_SALES = sales;
  SALES_REPORT_ITEMS = items;
```

- [ ] **Step 3: Add `populateSalesPeriodFilter()` and `renderSalesDetailReport()`**

Add these two functions right after `renderSalesReport()` in
`app/js/admin.js`:

```javascript
function populateSalesPeriodFilter(months) {
  const sel = document.getElementById('report-period-filter');
  const current = sel.value;
  sel.innerHTML = '<option value="all">Todos los periodos</option>' +
    months.map(m => `<option value="${m}">${m}</option>`).join('');
  sel.value = (current === 'all' || months.includes(current)) ? current : 'all';
}

function renderSalesDetailReport() {
  const period = document.getElementById('report-period-filter').value;
  const saleIds = new Set(
    SALES_REPORT_SALES
      .filter(s => period === 'all' || s.created_at.slice(0, 7) === period)
      .map(s => s.id)
  );

  const byCategory = new Map(); // category_id -> { name, pieces, total, cost, saleIds: Set }
  const byProduct = new Map();  // product_id -> { name, pieces, total, cost, saleIds: Set }

  SALES_REPORT_ITEMS.forEach(item => {
    if (!saleIds.has(item.sale_id) || !item.product_id) return;
    const product = productById(item.product_id);
    if (!product) return; // deleted/unavailable product — excluded per spec, still counted in the month table above

    const revenue = Number(item.unit_price) * item.quantity;
    const cost = (Number(item.unit_cost_price) || 0) * item.quantity;

    const pEntry = byProduct.get(product.id) || { name: product.name, pieces: 0, total: 0, cost: 0, saleIds: new Set() };
    pEntry.pieces += item.quantity;
    pEntry.total += revenue;
    pEntry.cost += cost;
    pEntry.saleIds.add(item.sale_id);
    byProduct.set(product.id, pEntry);

    const cat = catById(product.category_id);
    const catLabel = cat ? `${lineById(cat.product_line_id)?.name || ''} — ${cat.name}` : 'Sin categoría';
    const catKey = product.category_id || 'none';
    const cEntry = byCategory.get(catKey) || { name: catLabel, pieces: 0, total: 0, cost: 0, saleIds: new Set() };
    cEntry.pieces += item.quantity;
    cEntry.total += revenue;
    cEntry.cost += cost;
    cEntry.saleIds.add(item.sale_id);
    byCategory.set(catKey, cEntry);
  });

  const renderGroupTable = (map, tbodyId, emptyMessage) => {
    const rows = [...map.values()]
      .map(r => ({ ...r, count: r.saleIds.size }))
      .sort((a, b) => (b.total - b.cost) - (a.total - a.cost));
    document.getElementById(tbodyId).innerHTML = rows.map(r => `
      <tr>
        <td>${escapeHtml(r.name)}</td>
        <td>${r.count}</td>
        <td>${r.pieces}</td>
        <td>${fmt.format(r.total)}</td>
        <td>${fmt.format(r.cost)}</td>
        <td>${fmt.format(r.total - r.cost)}</td>
      </tr>`).join('') || `<tr><td colspan="6" style="color:var(--ink-soft);">${emptyMessage}</td></tr>`;
  };

  renderGroupTable(byCategory, 'report-category-tbody', 'Sin ventas en este periodo.');
  renderGroupTable(byProduct, 'report-product-tbody', 'Sin ventas en este periodo.');
}
```

`productById`/`catById`/`lineById` are already defined earlier in this
file (module-level const arrow functions) — do not redefine them.

- [ ] **Step 4: Call the new functions from `renderSalesReport()` and wire the filter**

In `renderSalesReport()`, find the end of the existing month-table
render (the `document.getElementById('report-sales-tbody').innerHTML =
...` statement) and add right after it:

```javascript
  populateSalesPeriodFilter([...byMonth.keys()].sort((a, b) => b.localeCompare(a)));
  renderSalesDetailReport();
```

Then, at the top level of `app/js/admin.js` (not inside any function —
find a reasonable spot near other one-time `addEventListener`
registrations on static elements, e.g. near where `invite-form` or
`expense-form` are wired), add:

```javascript
document.getElementById('report-period-filter').addEventListener('change', renderSalesDetailReport);
```

This registers the listener exactly once when the module loads (the
`<select>` is a static element in `admin.html`, never re-created by any
render function) — changing the filter only re-groups the already-cached
`SALES_REPORT_SALES`/`SALES_REPORT_ITEMS`, no network call.

- [ ] **Step 5: Manual verification (no automated test suite in this project)**

Run `node --check app/js/admin.js`. Then trace through by hand:
1. `renderSalesReport()`'s existing "Ventas por mes" table output is
   byte-for-byte unchanged from before this task (same query shape
   except the added `product_id` column, same grouping, same render).
2. With "Todos los periodos" selected, the category/product tables sum
   across every fetched sale.
3. Selecting a specific month re-groups using only that month's sale
   ids — confirm this happens without calling `renderSalesReport()`
   again (no new `supabase.from(...)` call in `renderSalesDetailReport()`
   or the filter's `change` handler).
4. The product table is sorted by profit (`total - cost`) descending.
5. A `sale_items_view` row with `product_id: null`, or a `product_id`
   not found via `productById()`, is skipped in both new tables (the
   `if (!saleIds.has(...) || !item.product_id) return;` and `if
   (!product) return;` guards).
6. Zero sales in the selected period → both new tables show "Sin
   ventas en este periodo." instead of an empty `<tbody>`.

- [ ] **Step 6: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Add sales-by-category and sales-by-product tables to Reportes"
```
