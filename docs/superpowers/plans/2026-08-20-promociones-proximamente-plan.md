# Aviso de "Próximamente" para promociones futuras — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a small, price-free text line on the public catalog for
each promotion whose `starts_at` is still in the future ("Próximamente:
20% de descuento en X a partir del 21 de agosto"), so Ricardo can create
a promo ahead of time and customers see it's coming without seeing the
discounted price early.

**Architecture:** One new data-fetch function mirroring the existing
active-promotions fetch but inverted (`starts_at` in the future). The
existing per-scope-type "is this promo visible" check inside `loadAll()`
is extracted into a shared helper so it isn't duplicated a third time.

**Tech Stack:** Same as the rest of this project — vanilla JS ES modules, Supabase, no new dependencies.

## Global Constraints

- No price shown for an upcoming promotion — text only, per Ricardo's
  explicit choice (confirmed via clarifying question): "Texto simple,
  sin precio."
- Same visibility rule as active promotions: a promo targeting a hidden
  line/category/product must not appear in the upcoming strip either.
- Zero upcoming promotions → the strip renders nothing, no reserved
  space (`hidden` attribute, same pattern as `#promo-banner`).
- Do not touch sales, apartados, Mercado Pago checkout, or any file
  outside what this task names.
- No new dependencies.

---

### Task 1: Upcoming-promotions strip on the public catalog

**Files:**
- Modify: `app/js/catalog-data.js` (add `loadUpcomingPromotions`)
- Modify: `app/js/catalog.js` (add `isPromoVisible` shared helper, use it
  from `loadAll()` for both `PROMOTIONS` and the new
  `UPCOMING_PROMOTIONS`, add `upcomingPromoText`/`renderUpcomingPromos`)
- Modify: `app/index.html` (add `#promo-upcoming` container)
- Modify: `app/css/styles.css` (add `.promo-upcoming*` rules)

**Interfaces:**
- Produces: `loadUpcomingPromotions()` exported from `catalog-data.js`,
  same return shape as the existing `loadActivePromotions()` (array of
  `promotions` rows).
- Consumes/produces internally in `catalog.js`: a new module-level
  `UPCOMING_PROMOTIONS` array, alongside the existing `PROMOTIONS`.

- [ ] **Step 1: Add `loadUpcomingPromotions` to `catalog-data.js`**

Add this new exported function near the existing `loadActivePromotions`
(read the file first to place it naturally next to that function):

```javascript
export async function loadUpcomingPromotions() {
  const nowIso = new Date().toISOString();
  const { data, error } = await supabase
    .from('promotions')
    .select('*')
    .eq('active', true)
    .gt('starts_at', nowIso)
    .order('starts_at', { ascending: true });
  if (error) throw error;
  return data;
}
```

- [ ] **Step 2: Import the new function in `catalog.js`**

`catalog.js`'s current import line is:

```javascript
import { loadProductLines, loadCategories, loadActivePromotions, loadSiteSettings, discountedPrice, accentFor, iconKeyFor } from './catalog-data.js';
```

Add `loadUpcomingPromotions` to it:

```javascript
import { loadProductLines, loadCategories, loadActivePromotions, loadUpcomingPromotions, loadSiteSettings, discountedPrice, accentFor, iconKeyFor } from './catalog-data.js';
```

- [ ] **Step 3: Add `UPCOMING_PROMOTIONS` module state**

`catalog.js` currently declares:

```javascript
let PRODUCTS = [];
let LINES = [];
let CATEGORIES = [];
let PROMOTIONS = [];
let SITE_SETTINGS = { show_products_stat: false };
```

Add one line:

```javascript
let PRODUCTS = [];
let LINES = [];
let CATEGORIES = [];
let PROMOTIONS = [];
let UPCOMING_PROMOTIONS = [];
let SITE_SETTINGS = { show_products_stat: false };
```

- [ ] **Step 4: Extract the shared visibility check and use it for both promotion lists**

In `catalog.js`'s `loadAll()`, find the current `PROMOTIONS` assignment:

```javascript
    PROMOTIONS = promos.filter(p => {
      if (p.scope_type === 'line') return visibleLineIds.has(p.product_line_id);
      if (p.scope_type === 'category') return CATEGORIES.some(c => c.id === p.category_id);
      const targetProduct = productsRes.data.find(pr => pr.id === p.product_id);
      return targetProduct ? visibleLineIds.has(targetProduct.product_line_id) : false;
    });
```

Replace it with a call to a new shared helper, and fetch+filter the
upcoming list right after it using the same helper:

```javascript
    PROMOTIONS = promos.filter(p => isPromoVisible(p, { visibleLineIds, categories: CATEGORIES, productsData: productsRes.data }));
    UPCOMING_PROMOTIONS = upcoming.filter(p => isPromoVisible(p, { visibleLineIds, categories: CATEGORIES, productsData: productsRes.data }));
```

Add the `isPromoVisible` function itself somewhere above `loadAll()` in
the file (e.g. right before it, next to the other small helpers like
`lineById`/`catById`):

```javascript
function isPromoVisible(promo, { visibleLineIds, categories, productsData }) {
  if (promo.scope_type === 'line') return visibleLineIds.has(promo.product_line_id);
  if (promo.scope_type === 'category') return categories.some(c => c.id === promo.category_id);
  const targetProduct = productsData.find(pr => pr.id === promo.product_id);
  return targetProduct ? visibleLineIds.has(targetProduct.product_line_id) : false;
}
```

- [ ] **Step 5: Fetch the upcoming list alongside `promos` in the critical `Promise.all`**

`loadAll()`'s current critical fetch is:

```javascript
    const [lines, cats, promos, productsRes] = await Promise.all([
      loadProductLines(),
      loadCategories(),
      loadActivePromotions(),
      supabase.from('products_view').select('*').eq('published_online', true).order('name'),
    ]);
```

Widen it to fetch `upcoming` too — this fetch has the same
correctness-not-optional status as `promos` itself (both come from the
same `promotions` table and the same public-read policy), so it belongs
in the critical `Promise.all`, not the isolated `site_settings`-style
try/catch:

```javascript
    const [lines, cats, promos, upcoming, productsRes] = await Promise.all([
      loadProductLines(),
      loadCategories(),
      loadActivePromotions(),
      loadUpcomingPromotions(),
      supabase.from('products_view').select('*').eq('published_online', true).order('name'),
    ]);
```

- [ ] **Step 6: Render the upcoming strip**

Add these two functions near the existing `promoBannerText`/
`renderPromoBanner` (read the file to place them naturally next to that
pair — `findProduct`, `lineById`, `catById` are already defined
elsewhere in this same file and don't need to move):

```javascript
function upcomingPromoText(promo) {
  const dateLabel = new Date(promo.starts_at).toLocaleDateString('es-MX', { day: 'numeric', month: 'long' });
  if (promo.scope_type === 'product') {
    const product = findProduct(promo.product_id);
    if (!product) return '';
    return `Próximamente: ${promo.discount_percent}% de descuento en ${product.name} a partir del ${dateLabel}`;
  }
  const scopeName = promo.scope_type === 'line'
    ? (lineById(promo.product_line_id)?.name || '')
    : (catById(promo.category_id)?.name || '');
  return `Próximamente: ${promo.discount_percent}% de descuento en ${scopeName} a partir del ${dateLabel}`;
}

function renderUpcomingPromos() {
  const el = document.getElementById('promo-upcoming');
  const items = UPCOMING_PROMOTIONS.map(upcomingPromoText).filter(Boolean);
  if (items.length === 0) { el.hidden = true; el.innerHTML = ''; return; }
  el.hidden = false;
  el.innerHTML = items.map(text => `<div class="promo-upcoming-item">${text}</div>`).join('');
}
```

Then, in `loadAll()`, find:

```javascript
    render(true);
    renderPromoBanner();
```

and change it to:

```javascript
    render(true);
    renderPromoBanner();
    renderUpcomingPromos();
```

- [ ] **Step 7: Add the container in `index.html`**

Find the existing promo banner container:

```html
  <div class="promo-banner" id="promo-banner" hidden></div>
```

Add the new one right after it:

```html
  <div class="promo-banner" id="promo-banner" hidden></div>
  <div class="promo-upcoming" id="promo-upcoming" hidden></div>
```

- [ ] **Step 8: Add CSS**

In `app/css/styles.css`, near the existing `.promo-banner*`/
`.promo-product*` rules, add:

```css
.promo-upcoming { display: flex; flex-direction: column; gap: 4px; margin: 4px 0 8px; }
.promo-upcoming[hidden] { display: none; }
.promo-upcoming-item { font-size: 0.85rem; font-weight: 600; color: var(--ink-soft); }
```

This is deliberately understated (no badge, no background, no price) —
a heads-up, not a call to buy yet, per the plan's Global Constraints.

- [ ] **Step 9: Manual verification (no automated test suite in this project)**

Run `node --check app/js/catalog.js` and `node --check app/js/catalog-data.js`.
Then trace through by hand:
1. A `starts_at`-in-the-future, `active: true` promo of each scope type
   (line, category, product) produces the expected "Próximamente: …"
   text with no price anywhere in it.
2. A promo whose target's line is hidden does not appear in
   `UPCOMING_PROMOTIONS` at all (same fail-closed behavior as the active
   list).
3. `PROMOTIONS` (the active list) is completely unaffected by this
   change — same filter behavior as before Step 4's extraction, just
   read through a shared function instead of inlined twice.
4. Zero upcoming promos → `#promo-upcoming` stays `hidden`, no visible
   gap.

- [ ] **Step 10: Commit**

```bash
git add app/js/catalog-data.js app/js/catalog.js app/index.html app/css/styles.css
git commit -m "Show an upcoming-promotions strip on the public catalog"
```
