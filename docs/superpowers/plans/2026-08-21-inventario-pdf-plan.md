# Exportar inventario a PDF — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A button in Inventario that opens a column picker, then opens
the browser's print dialog with a clean, print-only view of the
currently-filtered product list — so Ricardo can "Guardar como PDF"
himself. No new dependency, no server involvement.

**Architecture:** A hidden `#print-inventory` container, a direct child
of `<body>`, populated on demand from `PRODUCTS.filter(matchesFilters)`
(the exact same filter function the on-screen table already uses) and
the checked columns, then shown via `@media print` CSS while
`window.print()` hides everything else.

**Tech Stack:** Same as the rest of this project — vanilla JS ES modules, no new dependencies, no migration.

## Global Constraints

- **Costo is never an option** — it must not appear in the column
  picker, must not be a valid `data-col` value anywhere, and must never
  be reachable in the exported table under any combination of checkbox
  states.
- The export must use the products currently visible under Inventario's
  active filters (`matchesFilters`) — never the full unfiltered
  `PRODUCTS` array.
- No new Supabase query — this reads only already-loaded `PRODUCTS`/
  `LINES`/`CATEGORIES` module state.
- `#print-inventory` must be a direct child of `<body>` (not nested
  inside `<main>`) for the `body > *:not(#print-inventory)` print CSS
  selector to correctly hide everything else.
- Do not touch sales, Mercado Pago checkout, Promociones, Finanzas,
  borrado-protegido, permisos-vendedor, or the Reportes tables added in
  the prior plan.
- No new dependencies.

---

### Task 1: Inventario — column picker and print-to-PDF export

**Files:**
- Modify: `app/admin.html` (export button + column-picker panel in
  Inventario's toolbar; new `#print-inventory` body-level container)
- Modify: `app/js/admin.js` (column definitions, panel toggle, generate
  handler)
- Modify: `app/css/styles.css` (print CSS)

**Interfaces:**
- Consumes: the existing `PRODUCTS`/`matchesFilters`/`lineById`/
  `catById`/`fmt`/`escapeHtml` already in `admin.js` — no new data
  layer.
- Produces: nothing consumed elsewhere — this is the only task in this
  plan.

- [ ] **Step 1: Add the export button and column-picker panel to Inventario's toolbar**

In `app/admin.html`, find the Inventario toolbar's closing structure:

```html
      <label style="display:flex;align-items:center;gap:6px;font-size:0.88rem;color:var(--ink-soft);">
        <input type="checkbox" id="admin-published-filter" style="width:auto;"> Solo publicados
      </label>
      <span class="count" id="admin-count" style="margin-left:auto;"></span>
    </div>
```

Replace it with (adds the export button right before the count, and a
new hidden panel row right after the toolbar's closing `</div>`):

```html
      <label style="display:flex;align-items:center;gap:6px;font-size:0.88rem;color:var(--ink-soft);">
        <input type="checkbox" id="admin-published-filter" style="width:auto;"> Solo publicados
      </label>
      <button class="btn btn-sm" type="button" id="export-pdf-btn">Exportar a PDF</button>
      <span class="count" id="admin-count" style="margin-left:auto;"></span>
    </div>

    <div class="toolbar" id="export-pdf-panel" hidden>
      <label style="display:flex;align-items:center;gap:6px;font-size:0.88rem;">
        <input type="checkbox" class="export-col" data-col="line_cat" checked style="width:auto;"> Línea / Categoría
      </label>
      <label style="display:flex;align-items:center;gap:6px;font-size:0.88rem;">
        <input type="checkbox" class="export-col" data-col="code" checked style="width:auto;"> Código
      </label>
      <label style="display:flex;align-items:center;gap:6px;font-size:0.88rem;">
        <input type="checkbox" class="export-col" data-col="price" checked style="width:auto;"> Precio
      </label>
      <label style="display:flex;align-items:center;gap:6px;font-size:0.88rem;">
        <input type="checkbox" class="export-col" data-col="stock_online" checked style="width:auto;"> Stock online
      </label>
      <label style="display:flex;align-items:center;gap:6px;font-size:0.88rem;">
        <input type="checkbox" class="export-col" data-col="stock_fisica" checked style="width:auto;"> Stock física
      </label>
      <label style="display:flex;align-items:center;gap:6px;font-size:0.88rem;">
        <input type="checkbox" class="export-col" data-col="published" checked style="width:auto;"> Publicado
      </label>
      <button class="btn btn-primary btn-sm" type="button" id="export-pdf-generate">Generar PDF</button>
    </div>
```

`Costo` is deliberately absent from this list of checkboxes — do not
add it, under any label.

- [ ] **Step 2: Add the body-level `#print-inventory` container**

In `app/admin.html`, find:

```html
<div class="toast" id="toast"></div>
```

Add the new container as its sibling, right after it (still a direct
child of `<body>`, before the `<script>` tags):

```html
<div class="toast" id="toast"></div>

<div id="print-inventory"></div>
```

- [ ] **Step 3: Add print CSS**

In `app/css/styles.css`, add this block near the end of the file (or
wherever a new top-level ruleset naturally fits — read the file's
existing structure to place it in a sensible spot, e.g. after the last
existing rule):

```css
#print-inventory { display: none; }
@media print {
  body > *:not(#print-inventory) { display: none !important; }
  #print-inventory { display: block !important; padding: 24px; }
  #print-inventory h1 { font-size: 1.3rem; margin-bottom: 4px; }
  #print-inventory table { width: 100%; border-collapse: collapse; margin-top: 12px; }
  #print-inventory th, #print-inventory td { border: 1px solid #000; padding: 4px 8px; font-size: 11px; text-align: left; }
}
```

- [ ] **Step 4: Add the column definitions and export logic to `admin.js`**

In `app/js/admin.js`, add this near `matchesFilters()` (the existing
function this task reuses — read the file to place it naturally in the
same "Inventory tab" section):

```javascript
// Costo is deliberately never in this list — it's sensitive data and
// must never be exportable via this feature, by design (see the spec).
const EXPORT_COLUMNS = [
  { key: 'line_cat', label: 'Línea / Categoría', render: p => `${escapeHtml(lineById(p.product_line_id)?.name || '')} — ${escapeHtml(catById(p.category_id)?.name || '')}` },
  { key: 'code', label: 'Código', render: p => escapeHtml(p.code || '') },
  { key: 'price', label: 'Precio', render: p => fmt.format(p.price) },
  { key: 'stock_online', label: 'Stock online', render: p => String(p.stock_online) },
  { key: 'stock_fisica', label: 'Stock física', render: p => String(p.stock_fisica) },
  { key: 'published', label: 'Publicado', render: p => (p.published_online ? 'Sí' : 'No') },
];

document.getElementById('export-pdf-btn').addEventListener('click', () => {
  const panel = document.getElementById('export-pdf-panel');
  panel.hidden = !panel.hidden;
});

document.getElementById('export-pdf-generate').addEventListener('click', () => {
  const selectedKeys = Array.from(document.querySelectorAll('.export-col:checked')).map(cb => cb.dataset.col);
  const columns = EXPORT_COLUMNS.filter(c => selectedKeys.includes(c.key));
  const filtered = PRODUCTS.filter(matchesFilters);

  const headerCells = ['Nombre', ...columns.map(c => c.label)]
    .map(h => `<th>${escapeHtml(h)}</th>`).join('');
  const bodyRows = filtered.length === 0
    ? `<tr><td colspan="${columns.length + 1}">Sin productos con este filtro.</td></tr>`
    : filtered.map(p => `<tr><td>${escapeHtml(p.name)}</td>${columns.map(c => `<td>${c.render(p)}</td>`).join('')}</tr>`).join('');

  document.getElementById('print-inventory').innerHTML = `
    <h1>Inventario — Lemus Store</h1>
    <p>${new Date().toLocaleDateString('es-MX', { dateStyle: 'long' })}</p>
    <table>
      <thead><tr>${headerCells}</tr></thead>
      <tbody>${bodyRows}</tbody>
    </table>`;
  window.print();
});
```

`matchesFilters`, `PRODUCTS`, `lineById`, `catById`, `fmt`,
`escapeHtml` are all already defined earlier in this file — do not
redefine or reimplement any of them.

- [ ] **Step 5: Manual verification (no automated test suite in this project)**

Run `node --check app/js/admin.js`. Then trace through by hand:
1. Clicking "Exportar a PDF" toggles `#export-pdf-panel`'s `hidden`
   attribute (shows on first click, hides on second).
2. `EXPORT_COLUMNS` has exactly 6 entries and none of them has
   `key: 'cost'` or references `p.cost_price` anywhere — grep the final
   file for `cost_price` to confirm zero matches inside this task's new
   code.
3. With every checkbox checked, `columns` includes all 6 in the same
   order as `EXPORT_COLUMNS`; unchecking one removes exactly that
   column from both `headerCells` and every row.
4. `filtered` is built from `matchesFilters` (the same function
   `renderTable()` already uses), so changing the line/category/search
   filters before exporting changes what appears in `#print-inventory`.
5. Zero filtered products → the table body renders the "Sin productos
   con este filtro." row instead of an empty `<tbody>`.
6. `#print-inventory` is a direct child of `<body>` in the final HTML
   (not nested inside `<main id="admin-view">`) — confirm this by
   re-reading the actual file structure after editing, not just trusting
   the diff.

- [ ] **Step 6: Commit**

```bash
git add app/admin.html app/js/admin.js app/css/styles.css
git commit -m "Add PDF export (print-to-PDF) for the inventory list"
```
