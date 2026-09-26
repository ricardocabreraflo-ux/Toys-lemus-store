# Promociones por producto específico — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Ricardo create a promotion scoped to one specific product
(not just a whole line or category), searchable by name from Admin, and
show it on the public catalog as a large, eye-catching card instead of
the small text pill used today.

**Architecture:** Extend `promotions` with a `product_id` column and a
third `scope_type` value (`'product'`). Admin's promo form gains a
type-ahead search (filtering the already-loaded `PRODUCTS` array
client-side, no new endpoint) that replaces the plain `<select>` when
"Producto específico" is chosen. The public catalog's existing discount
math (`bestPromotionFor`) gains a product-match branch, and the promo
banner splits its rendering: product-scoped promos get a big card
(reusing the same icon/color system product cards already use), line/
category promos keep today's small pill.

**Tech Stack:** Supabase (Postgres + PostgREST), vanilla JS ES modules, no new dependencies.

## Global Constraints

- No real product photos exist in this system — the big banner card
  must use the existing `iconKeyFor`/`accentFor` icon-and-color system
  (same one `cardHtml` in `catalog.js` already uses), never an `<img>`
  placeholder or a broken image reference.
- Line/category-scoped promotions must render exactly as they do today
  (small text pill, unchanged) — only product-scoped promotions get the
  new big-card treatment.
- A product-scoped promotion whose target product's line is hidden from
  the public catalog (`product_lines.visible_public = false`) must not
  render anywhere on the public catalog — same fail-closed-to-hidden
  behavior the rest of `PROMOTIONS` filtering already has in `loadAll()`.
- Do not touch sales, apartados (layaway), Mercado Pago checkout, or any
  file outside what each task below names.
- No new libraries/dependencies for the autocomplete — a plain filtered
  `<button>` list is sufficient at this catalog's size.

---

### Task 1: Migration — `product_id` column and 3-way scope constraint

**Files:**
- Create: `supabase/migrations/0019_promotions_by_product.sql`

**Interfaces:**
- Produces: `public.promotions.product_id` (uuid, nullable, references
  `public.products(id) on delete cascade`) — consumed by Task 2 (insert
  payload) and Task 3 (`bestPromotionFor` product match, banner lookup).
- Produces: `public.promotions.scope_type` now allows `'product'` in
  addition to the existing `'line'`/`'category'`.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0019_promotions_by_product.sql
-- Ricardo wants promotions that target one specific product (searchable
-- by name in Admin), not just a whole line or category. Adds the column
-- and widens the scope_type/scope-matches-target constraints to a
-- three-way check. See docs/superpowers/specs/2026-08-20-promociones-por-producto-design.md.

alter table public.promotions
  add column if not exists product_id uuid references public.products(id) on delete cascade;

-- Drop whatever the scope_type check constraint actually ended up named
-- (Postgres auto-names an inline column check; find it dynamically
-- instead of guessing, so a wrongly-guessed name can't leave a stale
-- constraint behind that still blocks 'product' rows).
do $$
declare
  con record;
begin
  for con in
    select c.conname
    from pg_constraint c
    join pg_class rel on rel.oid = c.conrelid
    where rel.relname = 'promotions'
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%scope_type%'
  loop
    execute format('alter table public.promotions drop constraint %I', con.conname);
  end loop;
end;
$$;

alter table public.promotions add constraint promotions_scope_type_check
  check (scope_type in ('line', 'category', 'product'));

alter table public.promotions drop constraint if exists promotions_scope_matches_target;
alter table public.promotions add constraint promotions_scope_matches_target check (
  (scope_type = 'line' and product_line_id is not null and category_id is null and product_id is null) or
  (scope_type = 'category' and category_id is not null and product_line_id is null and product_id is null) or
  (scope_type = 'product' and product_id is not null and product_line_id is null and category_id is null)
);

notify pgrst, 'reload schema';
```

- [ ] **Step 2: Sanity-check the migration text**

This project has no local Supabase instance and no automated test
suite — Ricardo runs every migration by hand via the Supabase Dashboard
SQL editor. There is nothing to execute here. Instead, re-read the file
once against these three checks and fix inline if any fails:
1. Every `alter`/`create`/`do` statement ends with a semicolon.
2. The `do $$ ... $$;` block's `loop`/`end loop;`/`end;` structure is
   balanced (one `loop` per `for`, one `end;` closing the block).
3. The three-way `check` in `promotions_scope_matches_target` has no
   stray `and`/`or` — each of the three branches is a complete,
   independently-true-or-false expression joined by `or`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0019_promotions_by_product.sql
git commit -m "Add product_id column and 3-way scope constraint to promotions"
```

---

### Task 2: Admin — product search when creating a product-scoped promotion

**Files:**
- Modify: `app/admin.html:328-357` (the `#promo-form` block)
- Modify: `app/js/admin.js:798-852` (`refreshPromoScopeTarget`, the
  `#promo-form` submit handler, `promoScopeLabel`)
- Modify: `app/css/styles.css` (add autocomplete styles near the
  existing `.add-form`/`.cell-input` rules, ~line 296-299)

**Interfaces:**
- Consumes: `PRODUCTS` (module-level array in `admin.js`, already
  populated by `loadEverything()` before the Promociones tab can be
  used — each item has `.id` and `.name`).
- Consumes: `escapeHtml()` (already defined in `admin.js`, used
  elsewhere for user-supplied text in table cells).
- Produces: `promotions` insert payload now includes `product_id`,
  consumed by nothing else in this task (Task 1's migration already
  accepts it).

- [ ] **Step 1: Add the third "Aplica a" option and the autocomplete markup**

In `app/admin.html`, inside `#promo-form`, change:

```html
      <div class="field">
        <label for="promo-scope-type">Aplica a</label>
        <select class="cell-input" id="promo-scope-type">
          <option value="line">Una línea completa</option>
          <option value="category">Una categoría</option>
        </select>
      </div>
      <div class="field">
        <label for="promo-scope-target">¿Cuál?</label>
        <select class="cell-input" id="promo-scope-target" required></select>
      </div>
```

to:

```html
      <div class="field">
        <label for="promo-scope-type">Aplica a</label>
        <select class="cell-input" id="promo-scope-type">
          <option value="line">Una línea completa</option>
          <option value="category">Una categoría</option>
          <option value="product">Un producto específico</option>
        </select>
      </div>
      <div class="field" id="promo-target-field">
        <label for="promo-scope-target">¿Cuál?</label>
        <select class="cell-input" id="promo-scope-target" required></select>
        <div class="autocomplete-wrap" id="promo-product-wrap" hidden>
          <input class="cell-input" id="promo-product-search" type="text" autocomplete="off" placeholder="Escribe el nombre del producto…">
          <div class="autocomplete-list" id="promo-product-suggestions" hidden></div>
        </div>
      </div>
```

- [ ] **Step 2: Add autocomplete CSS**

In `app/css/styles.css`, near the existing `.add-form`/`.cell-input`
rules (around line 296-299), add:

```css
.autocomplete-wrap { position: relative; margin-top: 6px; }
.autocomplete-list { position: absolute; top: 100%; left: 0; right: 0; z-index: 20; background: var(--panel); border: 2px solid var(--line); border-radius: 10px; margin-top: 4px; max-height: 220px; overflow-y: auto; box-shadow: var(--shadow); }
.autocomplete-list[hidden] { display: none; }
.autocomplete-item { display: block; width: 100%; text-align: left; padding: 8px 12px; border: none; background: transparent; color: var(--ink); font: inherit; cursor: pointer; }
.autocomplete-item:hover, .autocomplete-item:focus-visible { background: var(--bg-alt); outline: none; }
```

- [ ] **Step 3: Wire the autocomplete and extend the scope-type switch in `admin.js`**

Replace the existing `refreshPromoScopeTarget` function (currently at
`admin.js:798-806`):

```javascript
function refreshPromoScopeTarget() {
  const typeSel = document.getElementById('promo-scope-type');
  const targetSel = document.getElementById('promo-scope-target');
  if (typeSel.value === 'line') {
    optionsForLines(targetSel);
  } else {
    targetSel.innerHTML = CATEGORIES.map(c =>
      `<option value="${c.id}">${escapeHtml(lineById(c.product_line_id)?.name || '')} — ${escapeHtml(c.name)}</option>`
    ).join('');
  }
}
```

with:

```javascript
let selectedPromoProductId = null;

function renderPromoProductSuggestions(query) {
  const list = document.getElementById('promo-product-suggestions');
  const q = query.trim().toLowerCase();
  if (!q) { list.hidden = true; list.innerHTML = ''; return; }
  const matches = PRODUCTS.filter(p => p.name.toLowerCase().includes(q)).slice(0, 8);
  if (matches.length === 0) { list.hidden = true; list.innerHTML = ''; return; }
  list.innerHTML = matches.map(p =>
    `<button type="button" class="autocomplete-item" data-id="${p.id}">${escapeHtml(p.name)}</button>`
  ).join('');
  list.hidden = false;
}

function refreshPromoScopeTarget() {
  const typeSel = document.getElementById('promo-scope-type');
  const targetSel = document.getElementById('promo-scope-target');
  const productWrap = document.getElementById('promo-product-wrap');
  if (typeSel.value === 'product') {
    targetSel.hidden = true;
    targetSel.required = false;
    // refreshPromoScopeTarget() is also called after unrelated
    // line/category realtime updates (see refreshAllLineDependentUI),
    // not just on an actual "Aplica a" change — only reset the search
    // when actually switching into product mode, so one of those
    // unrelated calls can't wipe an in-progress product search.
    if (productWrap.hidden) {
      productWrap.hidden = false;
      selectedPromoProductId = null;
      document.getElementById('promo-product-search').value = '';
      document.getElementById('promo-product-suggestions').hidden = true;
    }
    return;
  }
  targetSel.hidden = false;
  targetSel.required = true;
  productWrap.hidden = true;
  if (typeSel.value === 'line') {
    optionsForLines(targetSel);
  } else {
    targetSel.innerHTML = CATEGORIES.map(c =>
      `<option value="${c.id}">${escapeHtml(lineById(c.product_line_id)?.name || '')} — ${escapeHtml(c.name)}</option>`
    ).join('');
  }
}

document.getElementById('promo-product-search').addEventListener('input', (e) => {
  selectedPromoProductId = null;
  renderPromoProductSuggestions(e.target.value);
});

document.getElementById('promo-product-suggestions').addEventListener('click', (e) => {
  const btn = e.target.closest('[data-id]');
  if (!btn) return;
  const product = PRODUCTS.find(p => p.id === btn.dataset.id);
  if (!product) return;
  selectedPromoProductId = product.id;
  document.getElementById('promo-product-search').value = product.name;
  document.getElementById('promo-product-suggestions').hidden = true;
  const nameField = document.getElementById('promo-name');
  if (!nameField.value.trim()) nameField.value = product.name;
});

document.addEventListener('click', (e) => {
  const wrap = document.getElementById('promo-product-wrap');
  if (!wrap.hidden && !wrap.contains(e.target)) {
    document.getElementById('promo-product-suggestions').hidden = true;
  }
});
```

This sits at the same place in the file (right before the existing
`document.getElementById('promo-scope-type').addEventListener('change', refreshPromoScopeTarget);`
line, which stays unchanged).

- [ ] **Step 4: Include `product_id` in the submit payload**

Replace the existing submit handler (currently at `admin.js:811-838`):

```javascript
document.getElementById('promo-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const name = document.getElementById('promo-name').value.trim();
  const scope_type = document.getElementById('promo-scope-type').value;
  const target = document.getElementById('promo-scope-target').value;
  const discount_percent = Math.min(100, Math.max(1, Number(document.getElementById('promo-discount').value) || 0));
  const startsRaw = document.getElementById('promo-starts').value;
  const endsRaw = document.getElementById('promo-ends').value;
  if (!name || !target) return;

  const payload = {
    name,
    scope_type,
    product_line_id: scope_type === 'line' ? target : null,
    category_id: scope_type === 'category' ? target : null,
    discount_percent,
    starts_at: startsRaw ? new Date(startsRaw + 'T00:00:00').toISOString() : null,
    ends_at: endsRaw ? new Date(endsRaw + 'T23:59:59').toISOString() : null,
    active: true,
  };
  const { data, error } = await supabase.from('promotions').insert(payload).select().single();
  if (error) { showToast('No se pudo crear la promoción', true); console.error(error); return; }
  PROMOTIONS.unshift(data);
  renderPromotions();
  showToast(`Promoción "${name}" creada`);
  e.target.reset();
  refreshPromoScopeTarget();
});
```

with:

```javascript
document.getElementById('promo-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const name = document.getElementById('promo-name').value.trim();
  const scope_type = document.getElementById('promo-scope-type').value;
  const target = scope_type === 'product' ? selectedPromoProductId : document.getElementById('promo-scope-target').value;
  const discount_percent = Math.min(100, Math.max(1, Number(document.getElementById('promo-discount').value) || 0));
  const startsRaw = document.getElementById('promo-starts').value;
  const endsRaw = document.getElementById('promo-ends').value;
  if (!name || !target) {
    if (scope_type === 'product' && !target) showToast('Elige un producto de la lista', true);
    return;
  }

  const payload = {
    name,
    scope_type,
    product_line_id: scope_type === 'line' ? target : null,
    category_id: scope_type === 'category' ? target : null,
    product_id: scope_type === 'product' ? target : null,
    discount_percent,
    starts_at: startsRaw ? new Date(startsRaw + 'T00:00:00').toISOString() : null,
    ends_at: endsRaw ? new Date(endsRaw + 'T23:59:59').toISOString() : null,
    active: true,
  };
  const { data, error } = await supabase.from('promotions').insert(payload).select().single();
  if (error) { showToast('No se pudo crear la promoción', true); console.error(error); return; }
  PROMOTIONS.unshift(data);
  renderPromotions();
  showToast(`Promoción "${name}" creada`);
  e.target.reset();
  selectedPromoProductId = null;
  document.getElementById('promo-product-suggestions').hidden = true;
  refreshPromoScopeTarget();
});
```

- [ ] **Step 5: Show the target product's name in the promotions list**

Replace the existing `promoScopeLabel` function (currently at
`admin.js:840-843`):

```javascript
function promoScopeLabel(p) {
  if (p.scope_type === 'line') return (lineById(p.product_line_id)?.name || '—') + ' (línea completa)';
  const c = catById(p.category_id);
  return c ? `${lineById(c.product_line_id)?.name || ''} — ${c.name}` : '—';
}
```

with:

```javascript
function promoScopeLabel(p) {
  if (p.scope_type === 'line') return (lineById(p.product_line_id)?.name || '—') + ' (línea completa)';
  if (p.scope_type === 'product') {
    const prod = PRODUCTS.find(pr => pr.id === p.product_id);
    return prod ? `${prod.name} (producto)` : '—';
  }
  const c = catById(p.category_id);
  return c ? `${lineById(c.product_line_id)?.name || ''} — ${c.name}` : '—';
}
```

- [ ] **Step 6: Manual verification (no automated tests in this project)**

Run `node --check app/js/admin.js` to catch syntax errors. Then, since
there's no local Supabase/dev server in this environment, trace through
the code by hand for these two paths and confirm by reading (not
guessing):
1. `scope_type` select set to `product` → `refreshPromoScopeTarget()`
   hides `#promo-scope-target`, shows `#promo-product-wrap`, and typing
   in `#promo-product-search` calls `renderPromoProductSuggestions`
   which filters `PRODUCTS` case-insensitively.
2. Clicking a suggestion sets `selectedPromoProductId`, fills the search
   box with the product's name, and — only if `#promo-name` was empty —
   fills `#promo-name` too.
3. Submitting with `scope_type === 'product'` and no product chosen
   shows the "Elige un producto de la lista" toast and does not call
   `supabase.from('promotions').insert`.

- [ ] **Step 7: Commit**

```bash
git add app/admin.html app/js/admin.js app/css/styles.css
git commit -m "Add product search to the promotions form in Admin"
```

---

### Task 3: Catálogo público — big banner card for product-scoped promotions

**Files:**
- Modify: `app/js/catalog-data.js:49-55` (`bestPromotionFor`)
- Modify: `app/js/catalog.js` (`loadAll()`'s `PROMOTIONS` filter,
  `promoBannerText`/`renderPromoBanner`, add `productPromoCardHtml`)
- Modify: `app/css/styles.css` (the `.promo-banner*` rules)

**Interfaces:**
- Consumes: `product_id` on a `promotions` row (Task 1), the module-level
  `PRODUCTS`/`PROMOTIONS`/`CATEGORIES` arrays already populated by
  `loadAll()` in `catalog.js`, `discountedPrice`/`accentFor`/`iconKeyFor`
  (already imported in `catalog.js` from `catalog-data.js`), `iconSvg`
  (already imported from `./icons.js`), `fmt` (already imported from
  `./supabase-client.js`).
- Produces: nothing consumed by a later task — this is the last task in
  this plan.

- [ ] **Step 1: Match products in `bestPromotionFor`**

In `app/js/catalog-data.js`, replace:

```javascript
export function bestPromotionFor(product, promotions) {
  const matches = promotions.filter(p =>
    (p.scope_type === 'line' && p.product_line_id === product.product_line_id) ||
    (p.scope_type === 'category' && p.category_id === product.category_id)
  );
  if (matches.length === 0) return null;
  return matches.reduce((best, p) => (p.discount_percent > best.discount_percent ? p : best), matches[0]);
}
```

with:

```javascript
export function bestPromotionFor(product, promotions) {
  const matches = promotions.filter(p =>
    (p.scope_type === 'line' && p.product_line_id === product.product_line_id) ||
    (p.scope_type === 'category' && p.category_id === product.category_id) ||
    (p.scope_type === 'product' && p.product_id === product.id)
  );
  if (matches.length === 0) return null;
  return matches.reduce((best, p) => (p.discount_percent > best.discount_percent ? p : best), matches[0]);
}
```

- [ ] **Step 2: Include product-scoped promotions in the visibility filter**

In `app/js/catalog.js`'s `loadAll()`, find the existing `PROMOTIONS`
assignment:

```javascript
    PROMOTIONS = promos.filter(p =>
      p.scope_type === 'line' ? visibleLineIds.has(p.product_line_id)
                              : CATEGORIES.some(c => c.id === p.category_id));
```

Replace with:

```javascript
    PROMOTIONS = promos.filter(p => {
      if (p.scope_type === 'line') return visibleLineIds.has(p.product_line_id);
      if (p.scope_type === 'category') return CATEGORIES.some(c => c.id === p.category_id);
      const targetProduct = productsRes.data.find(pr => pr.id === p.product_id);
      return targetProduct ? visibleLineIds.has(targetProduct.product_line_id) : false;
    });
```

This reads `productsRes.data` (the raw, not-yet-filtered fetch result
already in scope at this point in `loadAll()`) rather than the
module-level `PRODUCTS`, because `PRODUCTS` is assigned on the line
right after this one — using `productsRes.data` avoids depending on
assignment order.

- [ ] **Step 3: Split the banner into product cards and text pills**

In `app/js/catalog.js`, replace the existing `promoBannerText`/
`renderPromoBanner` pair:

```javascript
function promoBannerText(promo) {
  const scopeName = promo.scope_type === 'line'
    ? (lineById(promo.product_line_id)?.name || '')
    : (catById(promo.category_id)?.name || '');
  return `${promo.discount_percent}% de descuento en ${scopeName}`;
}

function renderPromoBanner() {
  const el = document.getElementById('promo-banner');
  if (PROMOTIONS.length === 0) { el.hidden = true; el.innerHTML = ''; return; }
  el.hidden = false;
  el.innerHTML = PROMOTIONS.map(promo => `<div class="promo-banner-item">${promoBannerText(promo)}</div>`).join('');
}
```

with:

```javascript
function promoBannerText(promo) {
  const scopeName = promo.scope_type === 'line'
    ? (lineById(promo.product_line_id)?.name || '')
    : (catById(promo.category_id)?.name || '');
  return `${promo.discount_percent}% de descuento en ${scopeName}`;
}

// No real product photos exist in this store — reuse the same
// icon+color system the catalog cards already use (see cardHtml),
// just larger, so the banner stays visually consistent.
function productPromoCardHtml(promo) {
  const product = findProduct(promo.product_id);
  if (!product) return '';
  const c = accentFor(product.category_id);
  const icon = iconKeyFor(product.category_id);
  const { price } = discountedPrice(product, PROMOTIONS);
  return `
    <article class="promo-product-card" style="--c:${c}">
      <div class="promo-product-art">${iconSvg(icon, 'stroke-width="1.6"')}</div>
      <div class="promo-product-body">
        <span class="promo-product-badge">-${promo.discount_percent}%</span>
        <h3 class="promo-product-name">${product.name}</h3>
        <div class="promo-product-price">
          <span class="price">${fmt.format(price)}<sup> MXN</sup></span>
          <span class="price-was">${fmt.format(product.price)}</span>
        </div>
      </div>
    </article>`;
}

function renderPromoBanner() {
  const el = document.getElementById('promo-banner');
  const productPromos = PROMOTIONS.filter(p => p.scope_type === 'product');
  const textPromos = PROMOTIONS.filter(p => p.scope_type !== 'product');
  const productCardsHtml = productPromos.map(productPromoCardHtml).filter(Boolean).join('');
  const textPillsHtml = textPromos.map(promo => `<div class="promo-banner-item">${promoBannerText(promo)}</div>`).join('');
  if (!productCardsHtml && !textPillsHtml) { el.hidden = true; el.innerHTML = ''; return; }
  el.hidden = false;
  el.innerHTML =
    (productCardsHtml ? `<div class="promo-product-row">${productCardsHtml}</div>` : '') +
    (textPillsHtml ? `<div class="promo-banner-pills">${textPillsHtml}</div>` : '');
}
```

`findProduct` is already defined later in this same file
(`function findProduct(id) { return PRODUCTS.find(p => p.id === id); }`)
— function declarations are hoisted, so calling it from
`productPromoCardHtml` above its own definition is safe. Do not move or
duplicate `findProduct`.

- [ ] **Step 4: Update the promo banner CSS**

In `app/css/styles.css`, replace the existing block:

```css
.promo-banner { display: flex; flex-wrap: wrap; gap: 10px; margin: 24px 0 8px; }
.promo-banner[hidden] { display: none; }
.promo-banner-item { background: var(--accent-2); color: var(--ink); font-weight: 700; padding: 10px 18px; border-radius: 999px; border: 2px solid var(--ink); font-size: 0.88rem; }
```

with:

```css
.promo-banner { margin: 24px 0 8px; }
.promo-banner[hidden] { display: none; }
.promo-product-row { display: flex; flex-wrap: wrap; gap: 16px; margin-bottom: 10px; }
.promo-product-card { --c: var(--accent); display: flex; align-items: center; gap: 16px; background: var(--panel); border: 3px solid var(--ink); border-radius: 18px; padding: 16px 22px; box-shadow: var(--shadow); flex: 1 1 320px; max-width: 480px; }
.promo-product-art { width: 76px; height: 76px; flex-shrink: 0; border-radius: 16px; background: color-mix(in srgb, var(--c) 22%, var(--panel)); display: grid; place-items: center; color: var(--c); }
.promo-product-art svg { width: 44px; height: 44px; }
.promo-product-body { display: flex; flex-direction: column; gap: 4px; }
.promo-product-badge { align-self: flex-start; font-size: 0.72rem; font-weight: 700; background: var(--accent-4); color: #fff; padding: 3px 10px; border-radius: 999px; }
.promo-product-name { font-size: 1.05rem; margin: 0; }
.promo-product-price { display: flex; align-items: baseline; gap: 8px; }
.promo-banner-pills { display: flex; flex-wrap: wrap; gap: 10px; }
```

`.promo-banner-item`'s own rule (background/padding/border for the
pill) is untouched elsewhere in the file — only this one block moves.
Verify with `grep -n "promo-banner-item" app/css/styles.css` that
exactly one declaration remains after this edit (the selector block
itself was only ever declared once, in the block replaced above).

- [ ] **Step 5: Manual verification**

Run `node --check app/js/catalog.js` and `node --check app/js/catalog-data.js`
to catch syntax errors. Then trace through by hand:
1. A `scope_type: 'product'` promo whose `product_id` matches a product
   in `PRODUCTS` renders a `.promo-product-card` with the product's
   name, discounted price, original price struck through, and the `-X%`
   badge — reusing `discountedPrice`/`accentFor`/`iconKeyFor` exactly as
   `cardHtml` does for the same product elsewhere on the page.
2. A `scope_type: 'product'` promo whose product is not in `PRODUCTS`
   (unpublished, or its line is hidden) renders nothing — confirm
   `productPromoCardHtml` returns `''` and `.filter(Boolean)` drops it,
   and confirm separately that Step 2's `PROMOTIONS` filter already
   excludes it before it reaches this code at all when the line is
   hidden.
3. Line/category promos still render as `.promo-banner-item` pills,
   unchanged from before this task.
4. Zero product promos and zero text promos → `#promo-banner` stays
   `hidden`.

- [ ] **Step 6: Commit**

```bash
git add app/js/catalog-data.js app/js/catalog.js app/css/styles.css
git commit -m "Show product-specific promotions as a big banner card on the public catalog"
```
