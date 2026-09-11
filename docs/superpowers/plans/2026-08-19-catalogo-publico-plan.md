# Mejoras al catálogo público Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Ricardo control over which product lines show publicly, paginate the public catalog, show an active-promotions banner, let him hide/show the "Productos activos" stat, and auto-switch the public catalog's theme by time of day in Mexico City — all from a new "Ajustes" tab in Admin.

**Architecture:** One migration adds `product_lines.visible_public` and a new singleton `site_settings` table (RLS: public read, admin-only write, same pattern as every other admin-gated table in this project). A new Admin "Ajustes" tab exposes both. The public catalog (`app/js/catalog.js`) filters, paginates, and themes itself using this data — all client-side, no new Edge Functions.

**Tech Stack:** Postgres/Supabase (RLS), vanilla JS/HTML/CSS, no build step.

## Global Constraints

- Zero changes to sales, apartados (layaway), or Mercado Pago checkout code — this plan only touches the public catalog display and a new Admin settings tab.
- Admin-only writes use the existing `public.is_admin()` guard, exactly like every other admin-gated table (`product_lines`, `categories`, `promotions`) — see `supabase/migrations/0008_admin_only_writes.sql` for the reference pattern.
- If `site_settings` fails to load client-side, the "Productos activos" stat stays hidden (fail toward the default Ricardo asked for).
- If line-visibility data is missing/undefined for any row, that line is treated as visible (fail-open — never let a data glitch make the whole catalog vanish).
- The Admin panel's theme (manual toggle) is untouched — auto theme-by-time applies ONLY to the public catalog (`app/index.html`).
- This is entirely additive to the existing catalog/admin — no existing HTML ids, CSS classes, or JS function signatures are renamed or removed except the one deliberate removal in Task 7 (the manual theme-toggle button on `index.html`, per the approved spec).

---

## File Structure

- Create: `supabase/migrations/0018_catalog_visibility_settings.sql` — `product_lines.visible_public` column + `site_settings` singleton table.
- Modify: `app/admin.html` — new "Ajustes" tab button + panel.
- Modify: `app/js/admin.js` — load/render/save logic for the Ajustes tab.
- Modify: `app/js/catalog-data.js` — add `loadSiteSettings()`.
- Modify: `app/js/catalog.js` — line-visibility filtering, pagination, promo banner, stat visibility, auto theme init.
- Modify: `app/js/theme.js` — add `applyAutoTheme()`.
- Modify: `app/index.html` — pagination controls, promo banner container, stat wrapper id, remove manual theme button.
- Modify: `app/css/styles.css` — pagination and promo-banner styles.

---

### Task 1: Migration — line visibility + site_settings

**Files:**
- Create: `supabase/migrations/0018_catalog_visibility_settings.sql`

**Interfaces:**
- Produces: `public.product_lines.visible_public` (boolean, not null, default true — Toys `true`, every other existing line `false` after this migration runs), `public.site_settings` (singleton table, one row, `show_products_stat` boolean not null default false). Consumed by every later task in this plan.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/0018_catalog_visibility_settings.sql`:

```sql
-- supabase/migrations/0018_catalog_visibility_settings.sql
-- Ricardo wants only "Toys" visible on the public catalog for now, with a
-- per-line on/off switch in Admin, plus a place to hide/show the
-- "Productos activos" stat. Both are pure display settings — RLS follows
-- the exact same public-read / admin-write pattern already used for
-- product_lines/categories/promotions (see 0008_admin_only_writes.sql).

alter table public.product_lines
  add column if not exists visible_public boolean not null default true;

-- Toys stays visible; every other existing line starts hidden, matching
-- exactly what Ricardo asked for. New lines created after this migration
-- default to visible (see the column default above) unless an admin turns
-- them off from the new Ajustes tab.
update public.product_lines set visible_public = (name = 'Toys');

create table if not exists public.site_settings (
  id                  boolean primary key default true,
  show_products_stat  boolean not null default false,
  constraint site_settings_single_row check (id)
);

insert into public.site_settings (id) values (true) on conflict (id) do nothing;

alter table public.site_settings enable row level security;

drop policy if exists "public read" on public.site_settings;
create policy "public read" on public.site_settings
  for select to anon, authenticated using (true);

drop policy if exists "admin write" on public.site_settings;
create policy "admin write" on public.site_settings for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

notify pgrst, 'reload schema';
```

- [ ] **Step 2: Sanity-check the SQL**

There's no live Supabase connection in this environment to run the
migration against (it gets applied manually later, in Task 8, by Ricardo
via the Supabase Dashboard SQL editor — same process as every other
migration in this project). Just re-read the file once for typos: table
name matches everywhere (`site_settings`), the `check (id)` constraint
references the actual primary key column, and every `drop policy if
exists` name matches the `create policy` name right below it.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0018_catalog_visibility_settings.sql
git commit -m "Add product_lines.visible_public and site_settings for catalog display controls"
```

---

### Task 2: Admin — pestaña "Ajustes"

**Files:**
- Modify: `app/admin.html:82` (add tab button), `app/admin.html:447` (add tab panel)
- Modify: `app/js/admin.js`

**Interfaces:**
- Consumes: `product_lines.visible_public`, `site_settings.show_products_stat` (Task 1).
- Produces: writes to both, live for Task 3/6's frontend reads once Ricardo applies the migration and toggles something.

- [ ] **Step 1: Add the tab button**

In `app/admin.html`, find this line (currently the last button in the tab row, line 82):

```html
    <button class="tab-btn" data-tab="users" type="button" aria-selected="false" data-role-admin>Usuarios</button>
```

Add this line immediately after it (still inside the `<div class="tab-row" role="tablist">`):

```html
    <button class="tab-btn" data-tab="settings" type="button" aria-selected="false" data-role-admin>Ajustes</button>
```

- [ ] **Step 2: Add the tab panel**

In `app/admin.html`, find the closing tag of the Usuarios panel (currently right before `</main>`):

```html
  </section>
</main>
```

Replace it with (adds a new panel between the two):

```html
  </section>

  <!-- ---------- Ajustes ---------- -->
  <section class="tab-panel" id="tab-settings" hidden>
    <div class="grid-head"><h2>Visibilidad de líneas</h2></div>
    <div class="table-wrap" style="margin-bottom:32px;">
      <table class="admin-table">
        <thead><tr><th>Línea</th><th>Visible al público</th></tr></thead>
        <tbody id="settings-lines-tbody"></tbody>
      </table>
    </div>

    <div class="grid-head"><h2>Página principal</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <tbody>
          <tr>
            <td>Mostrar contador de "Productos activos"</td>
            <td><input type="checkbox" id="setting-show-stat"></td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
</main>
```

- [ ] **Step 3: Load site_settings and render the tab**

In `app/js/admin.js`, find this line near the top (module-level state):

```javascript
let CURRENT_ROLE = null; // 'admin' | 'vendedor'
```

Add this line immediately after it:

```javascript
let SITE_SETTINGS = { show_products_stat: false };
```

Then, find this exact point in the file — the closing `}` of `renderTaxonomy()`, immediately followed by the start of `refreshAllLineDependentUI()`:

```javascript
      CATEGORIES = CATEGORIES.filter(c => c.id !== id);
      refreshAllLineDependentUI();
    });
  });
}

function refreshAllLineDependentUI() {
```

Insert the new function between that closing `}` and `function refreshAllLineDependentUI() {`:

```javascript
// ---------- Settings tab ----------

async function loadSiteSettings() {
  const { data, error } = await supabase.from('site_settings').select('*').single();
  if (error) throw error;
  return data;
}

function renderSettings() {
  document.getElementById('settings-lines-tbody').innerHTML = LINES.map(l => `
    <tr data-id="${l.id}">
      <td>${escapeHtml(l.name)}</td>
      <td><input type="checkbox" data-role="line-visible" ${l.visible_public ? 'checked' : ''}></td>
    </tr>`).join('');
  document.getElementById('settings-lines-tbody').querySelectorAll('[data-role="line-visible"]').forEach(cb => {
    cb.addEventListener('change', async () => {
      const id = cb.closest('tr').dataset.id;
      const { error } = await supabase.from('product_lines').update({ visible_public: cb.checked }).eq('id', id);
      if (error) { showToast('No se pudo actualizar', true); cb.checked = !cb.checked; return; }
      const line = lineById(id);
      if (line) line.visible_public = cb.checked;
    });
  });

  const statCb = document.getElementById('setting-show-stat');
  statCb.checked = SITE_SETTINGS.show_products_stat;
  statCb.onchange = async () => {
    const { error } = await supabase.from('site_settings').update({ show_products_stat: statCb.checked }).eq('id', true);
    if (error) { showToast('No se pudo actualizar', true); statCb.checked = !statCb.checked; return; }
    SITE_SETTINGS.show_products_stat = statCb.checked;
  };
}
```

- [ ] **Step 4: Wire it into loadEverything() and subscribeRealtime()**

In `app/js/admin.js`, find this block inside `loadEverything()`:

```javascript
    const [lines, cats] = await Promise.all([loadProductLines(), loadCategories()]);
    LINES = lines;
    CATEGORIES = cats;
```

Replace it with:

```javascript
    const [lines, cats, settings] = await Promise.all([loadProductLines(), loadCategories(), loadSiteSettings()]);
    LINES = lines;
    CATEGORIES = cats;
    SITE_SETTINGS = settings;
```

Then find this line, still inside `loadEverything()` (part of the block of `render*()` calls near the end of the function):

```javascript
    renderTaxonomy();
```

Add this line immediately after it:

```javascript
    renderSettings();
```

Finally, find this line inside `subscribeRealtime()`:

```javascript
    .on('postgres_changes', { event: '*', schema: 'public', table: 'promotions' }, scheduleReload)
```

Add this line immediately after it:

```javascript
    .on('postgres_changes', { event: '*', schema: 'public', table: 'site_settings' }, scheduleReload)
```

- [ ] **Step 5: Verify the page loads without errors**

```bash
cd /home/user/Toys-lemus-store
NODE_PATH=/opt/node22/lib/node_modules node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('file://' + process.cwd() + '/app/admin.html');
  const settingsTabExists = await page.\$('#tab-settings') !== null;
  const settingsBtnExists = await page.\$('button[data-tab=\"settings\"]') !== null;
  console.log('settings tab panel exists:', settingsTabExists);
  console.log('settings tab button exists:', settingsBtnExists);
  console.log('page errors:', errors);
  await browser.close();
})();
"
```

Expected: `settings tab panel exists: true`, `settings tab button exists: true`, `page errors: []`. (Supabase calls will fail since this is a local `file://` load with no live session — that's expected, we're only checking for JS syntax/parse errors and that the new DOM elements exist.)

- [ ] **Step 6: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Add Ajustes tab: line visibility toggles and products-stat toggle"
```

---

### Task 3: Catálogo — filtrar líneas ocultas

**Files:**
- Modify: `app/js/catalog.js`

**Interfaces:**
- Consumes: `product_lines.visible_public` (Task 1).
- Produces: `LINES`/`CATEGORIES`/`PRODUCTS` module-level arrays now contain only publicly-visible-line data — every later task in this file builds on this filtered state.

- [ ] **Step 1: Filter by visibility in loadAll()**

In `app/js/catalog.js`, find this block inside `loadAll()`:

```javascript
    if (productsRes.error) throw productsRes.error;
    LINES = lines;
    CATEGORIES = cats;
    PROMOTIONS = promos;
    PRODUCTS = productsRes.data;
```

Replace it with:

```javascript
    if (productsRes.error) throw productsRes.error;
    // A missing/undefined visible_public (e.g. a stale client before the
    // migration lands) fails OPEN — better to show an extra line than to
    // make the whole catalog vanish.
    LINES = lines.filter(l => l.visible_public !== false);
    const visibleLineIds = new Set(LINES.map(l => l.id));
    CATEGORIES = cats.filter(c => visibleLineIds.has(c.product_line_id));
    PROMOTIONS = promos;
    PRODUCTS = productsRes.data.filter(p => visibleLineIds.has(p.product_line_id));
```

`buildLineRail()` already just does `LINES.forEach(...)` to build the filter
chips, and `initStats()` already reads `LINES.length` for the "Líneas"
stat — both automatically reflect only the visible lines now, with no
further changes needed in this task.

- [ ] **Step 2: Verify the page loads without errors**

```bash
cd /home/user/Toys-lemus-store
NODE_PATH=/opt/node22/lib/node_modules node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('file://' + process.cwd() + '/app/index.html');
  console.log('page errors:', errors);
  await browser.close();
})();
"
```

Expected: `page errors: []`.

- [ ] **Step 3: Commit**

```bash
git add app/js/catalog.js
git commit -m "Filter public catalog to only publicly-visible product lines"
```

---

### Task 4: Catálogo — paginación (15 productos)

**Files:**
- Modify: `app/index.html`
- Modify: `app/js/catalog.js`
- Modify: `app/css/styles.css`

**Interfaces:**
- Consumes: `PRODUCTS`, `matches()`, `render()` (existing, and as filtered by Task 3).
- Produces: `currentPage`, `PAGE_SIZE` module state in `catalog.js`; `#pagination`, `#page-prev`, `#page-label`, `#page-next` DOM ids, consumed by no later task in this plan (this is a leaf feature).

- [ ] **Step 1: Add pagination markup**

In `app/index.html`, find this line:

```html
  <div class="grid" id="grid"></div>
```

Replace it with:

```html
  <div class="grid" id="grid"></div>
  <nav class="pagination" id="pagination" aria-label="Paginación del catálogo" hidden>
    <button class="btn btn-ghost btn-sm" id="page-prev" type="button">← Anterior</button>
    <span class="pagination-label" id="page-label"></span>
    <button class="btn btn-ghost btn-sm" id="page-next" type="button">Siguiente →</button>
  </nav>
```

- [ ] **Step 2: Add pagination styles**

In `app/css/styles.css`, find this line:

```css
.grid-head .count { color: var(--ink-soft); font-size: 0.92rem; }
```

Add these lines immediately after it:

```css
.pagination { display: flex; align-items: center; justify-content: center; gap: 16px; margin: 28px 0 8px; }
.pagination[hidden] { display: none; }
.pagination-label { font-weight: 700; color: var(--ink-soft); font-size: 0.92rem; }
```

- [ ] **Step 3: Add pagination state and reset it on filter/search changes**

In `app/js/catalog.js`, find this line:

```javascript
const cart = {}; // keyed by product id
```

Add these lines immediately after it:

```javascript
let currentPage = 1;
const PAGE_SIZE = 15;
```

Find this function:

```javascript
function setLine(id) {
  activeLine = id;
  activeCat = 'all';
  buildLineRail();
  buildCatRail();
  render(true);
}
```

Replace it with:

```javascript
function setLine(id) {
  activeLine = id;
  activeCat = 'all';
  currentPage = 1;
  buildLineRail();
  buildCatRail();
  render(true);
}
```

Find this function:

```javascript
function setCat(id) {
  activeCat = id;
  buildCatRail();
  render(true);
}
```

Replace it with:

```javascript
function setCat(id) {
  activeCat = id;
  currentPage = 1;
  buildCatRail();
  render(true);
}
```

Find this line:

```javascript
document.getElementById('search').addEventListener('input', (e) => { query = e.target.value; render(false); });
```

Replace it with:

```javascript
document.getElementById('search').addEventListener('input', (e) => { query = e.target.value; currentPage = 1; render(false); });
```

- [ ] **Step 4: Paginate render() and add the Anterior/Siguiente handlers**

In `app/js/catalog.js`, find this function:

```javascript
function render(animate) {
  const grid = document.getElementById('grid');
  const filtered = PRODUCTS.filter(matches);
  grid.classList.toggle('animate-in', !!animate);
  grid.innerHTML = filtered.map((p, pos) => cardHtml(p, pos)).join('');
  document.getElementById('empty-state').hidden = filtered.length !== 0 || PRODUCTS.length === 0;
  document.getElementById('result-count').textContent = filtered.length + (filtered.length === 1 ? ' producto' : ' productos');
  document.getElementById('section-title').textContent =
    activeCat !== 'all' ? (catById(activeCat)?.name || '') :
    activeLine !== 'all' ? (lineById(activeLine)?.name || '') :
    'Todo el catálogo';
  grid.querySelectorAll('.add-btn').forEach(btn => {
    btn.addEventListener('click', () => addToCart(btn.dataset.id));
  });
}
```

Replace it with:

```javascript
function render(animate) {
  const grid = document.getElementById('grid');
  const filtered = PRODUCTS.filter(matches);
  const totalPages = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  if (currentPage > totalPages) currentPage = totalPages;
  const start = (currentPage - 1) * PAGE_SIZE;
  const pageItems = filtered.slice(start, start + PAGE_SIZE);

  grid.classList.toggle('animate-in', !!animate);
  grid.innerHTML = pageItems.map((p, pos) => cardHtml(p, pos)).join('');
  document.getElementById('empty-state').hidden = filtered.length !== 0 || PRODUCTS.length === 0;
  document.getElementById('result-count').textContent = filtered.length + (filtered.length === 1 ? ' producto' : ' productos');
  document.getElementById('section-title').textContent =
    activeCat !== 'all' ? (catById(activeCat)?.name || '') :
    activeLine !== 'all' ? (lineById(activeLine)?.name || '') :
    'Todo el catálogo';

  const pagination = document.getElementById('pagination');
  pagination.hidden = filtered.length <= PAGE_SIZE;
  document.getElementById('page-label').textContent = `Página ${currentPage} de ${totalPages}`;
  document.getElementById('page-prev').disabled = currentPage <= 1;
  document.getElementById('page-next').disabled = currentPage >= totalPages;

  grid.querySelectorAll('.add-btn').forEach(btn => {
    btn.addEventListener('click', () => addToCart(btn.dataset.id));
  });
}
```

Then, find this line:

```javascript
document.getElementById('search').addEventListener('input', (e) => { query = e.target.value; currentPage = 1; render(false); });
```

Add these lines immediately after it:

```javascript
document.getElementById('page-prev').addEventListener('click', () => {
  currentPage--;
  render(true);
  document.getElementById('catalogo').scrollIntoView({ behavior: 'smooth', block: 'start' });
});
document.getElementById('page-next').addEventListener('click', () => {
  currentPage++;
  render(true);
  document.getElementById('catalogo').scrollIntoView({ behavior: 'smooth', block: 'start' });
});
```

- [ ] **Step 5: Verify the page loads without errors**

```bash
cd /home/user/Toys-lemus-store
NODE_PATH=/opt/node22/lib/node_modules node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('file://' + process.cwd() + '/app/index.html');
  const paginationExists = await page.\$('#pagination') !== null;
  console.log('pagination nav exists:', paginationExists);
  console.log('page errors:', errors);
  await browser.close();
})();
"
```

Expected: `pagination nav exists: true`, `page errors: []`.

- [ ] **Step 6: Commit**

```bash
git add app/index.html app/js/catalog.js app/css/styles.css
git commit -m "Paginate the public catalog at 15 products per page"
```

---

### Task 5: Catálogo — banner de promociones

**Files:**
- Modify: `app/index.html`
- Modify: `app/js/catalog.js`
- Modify: `app/css/styles.css`

**Interfaces:**
- Consumes: `PROMOTIONS`, `lineById()`, `catById()` (existing).
- Produces: `#promo-banner` DOM id; `renderPromoBanner()` function, called once from `loadAll()`.

- [ ] **Step 1: Add the banner container**

In `app/index.html`, find this block (the pagination nav added in Task 4):

```html
  <nav class="pagination" id="pagination" aria-label="Paginación del catálogo" hidden>
    <button class="btn btn-ghost btn-sm" id="page-prev" type="button">← Anterior</button>
    <span class="pagination-label" id="page-label"></span>
    <button class="btn btn-ghost btn-sm" id="page-next" type="button">Siguiente →</button>
  </nav>
```

Add this line immediately after it (still inside `<main class="wrap" id="catalogo">`):

```html
  <div class="promo-banner" id="promo-banner" hidden></div>
```

- [ ] **Step 2: Add banner styles**

In `app/css/styles.css`, find this line:

```css
.pagination-label { font-weight: 700; color: var(--ink-soft); font-size: 0.92rem; }
```

Add these lines immediately after it:

```css
.promo-banner { display: flex; flex-wrap: wrap; gap: 10px; margin: 24px 0 8px; }
.promo-banner[hidden] { display: none; }
.promo-banner-item { background: var(--accent-2); color: var(--ink); font-weight: 700; padding: 10px 18px; border-radius: 999px; border: 2px solid var(--ink); font-size: 0.88rem; }
```

- [ ] **Step 3: Render the banner from active promotions**

In `app/js/catalog.js`, find this function:

```javascript
function findProduct(id) { return PRODUCTS.find(p => p.id === id); }
```

Add these lines immediately before it:

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

- [ ] **Step 4: Call it once per data reload**

In `app/js/catalog.js`, find this line inside `loadAll()`:

```javascript
    render(true);
  } catch (err) {
    showToast('No se pudo cargar el catálogo');
```

Replace it with:

```javascript
    render(true);
    renderPromoBanner();
  } catch (err) {
    showToast('No se pudo cargar el catálogo');
```

- [ ] **Step 5: Verify the page loads without errors**

```bash
cd /home/user/Toys-lemus-store
NODE_PATH=/opt/node22/lib/node_modules node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('file://' + process.cwd() + '/app/index.html');
  const bannerExists = await page.\$('#promo-banner') !== null;
  console.log('promo banner exists:', bannerExists);
  console.log('page errors:', errors);
  await browser.close();
})();
"
```

Expected: `promo banner exists: true`, `page errors: []`.

- [ ] **Step 6: Commit**

```bash
git add app/index.html app/js/catalog.js app/css/styles.css
git commit -m "Show a banner of active promotions below the public catalog"
```

---

### Task 6: Catálogo — ocultar contador de "productos activos"

**Files:**
- Modify: `app/index.html`
- Modify: `app/js/catalog-data.js`
- Modify: `app/js/catalog.js`

**Interfaces:**
- Consumes: `site_settings.show_products_stat` (Task 1).
- Produces: `loadSiteSettings()` (exported from `catalog-data.js`, same name/shape as the one added independently to `admin.js` in Task 2 — they're separate files with no shared import, this duplication matches how `loadProductLines`/`loadCategories` are already separately imported by both `catalog.js` and `admin.js` from the shared `catalog-data.js` module, except `admin.js`'s copy was written inline in Task 2 since `admin.js` doesn't import from `catalog-data.js` for one-off loaders — both call the same `site_settings` table with the same shape, so this is intentional, not a bug).

- [ ] **Step 1: Give the stat block a stable id**

In `app/index.html`, find this line:

```html
      <div><strong id="stat-products">—</strong><span>Productos activos</span></div>
```

Replace it with:

```html
      <div id="stat-products-wrap"><strong id="stat-products">—</strong><span>Productos activos</span></div>
```

- [ ] **Step 2: Add the loader**

In `app/js/catalog-data.js`, find this function:

```javascript
export async function loadActivePromotions() {
```

Add these lines immediately before it:

```javascript
export async function loadSiteSettings() {
  const { data, error } = await supabase.from('site_settings').select('*').single();
  if (error) throw error;
  return data;
}

```

- [ ] **Step 3: Import it and add module state**

In `app/js/catalog.js`, find this line:

```javascript
import { loadProductLines, loadCategories, loadActivePromotions, discountedPrice, accentFor, iconKeyFor } from './catalog-data.js';
```

Replace it with:

```javascript
import { loadProductLines, loadCategories, loadActivePromotions, loadSiteSettings, discountedPrice, accentFor, iconKeyFor } from './catalog-data.js';
```

Find this line:

```javascript
let PROMOTIONS = [];
```

Add this line immediately after it:

```javascript
let SITE_SETTINGS = { show_products_stat: false };
```

- [ ] **Step 4: Load it (isolated from the critical catalog fetch) and toggle the stat**

In `app/js/catalog.js`, find this function:

```javascript
function initStats() {
  document.getElementById('stat-products').textContent = PRODUCTS.length;
  document.getElementById('stat-cats').textContent = LINES.length;
  document.getElementById('stat-low').textContent = PRODUCTS.filter(p => p.stock_online <= 1).length;
}
```

Replace it with:

```javascript
function initStats() {
  document.getElementById('stat-products-wrap').hidden = !SITE_SETTINGS.show_products_stat;
  document.getElementById('stat-products').textContent = PRODUCTS.length;
  document.getElementById('stat-cats').textContent = LINES.length;
  document.getElementById('stat-low').textContent = PRODUCTS.filter(p => p.stock_online <= 1).length;
}
```

Then find this block, the start of `loadAll()`:

```javascript
async function loadAll() {
  try {
    const [lines, cats, promos, productsRes] = await Promise.all([
```

Replace it with:

```javascript
async function loadAll() {
  try {
    // Isolated from the critical Promise.all below on purpose: a failure
    // here shouldn't take down the whole catalog, it should just leave the
    // stat hidden (the default Ricardo wants anyway).
    let settings = SITE_SETTINGS;
    try {
      settings = await loadSiteSettings();
    } catch (err) {
      console.error('No se pudo cargar site_settings, usando valores por defecto', err);
    }
    const [lines, cats, promos, productsRes] = await Promise.all([
```

Finally, find this line (the last assignment before `buildLineRail()` in `loadAll()`, added by Task 3):

```javascript
    PRODUCTS = productsRes.data.filter(p => visibleLineIds.has(p.product_line_id));
```

Add this line immediately after it:

```javascript
    SITE_SETTINGS = settings;
```

- [ ] **Step 5: Verify the page loads without errors**

```bash
cd /home/user/Toys-lemus-store
NODE_PATH=/opt/node22/lib/node_modules node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('file://' + process.cwd() + '/app/index.html');
  const wrapExists = await page.\$('#stat-products-wrap') !== null;
  console.log('stat wrapper exists:', wrapExists);
  console.log('page errors:', errors);
  await browser.close();
})();
"
```

Expected: `stat wrapper exists: true`, `page errors: []`.

- [ ] **Step 6: Commit**

```bash
git add app/index.html app/js/catalog-data.js app/js/catalog.js
git commit -m "Hide the products-active stat by default, toggleable from Ajustes"
```

---

### Task 7: Catálogo — tema automático día/noche

**Files:**
- Modify: `app/js/theme.js`
- Modify: `app/js/catalog.js`
- Modify: `app/index.html`

**Interfaces:**
- Produces: `applyAutoTheme()` exported from `theme.js`. `admin.js`/`admin.html` are untouched — they keep using `initThemeToggle()` and the manual button exactly as today.

- [ ] **Step 1: Add the auto-theme function**

In `app/js/theme.js`, find this line:

```javascript
export function applyTheme(t) {
```

Add these lines immediately before it:

```javascript
// Only used by the public catalog (index.html) — Admin keeps its manual
// toggle untouched. Sets the theme straight from the clock, without
// touching localStorage: the two pages share an origin (and so share
// localStorage), and this must never leak into or fight with Admin's own
// manual preference stored under the same 'lemus-theme' key.
export function applyAutoTheme() {
  const hour = Number(new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Mexico_City',
    hour: 'numeric',
    hour12: false,
  }).format(new Date()));
  const isDay = hour >= 7 && hour < 19;
  root.setAttribute('data-theme', isDay ? 'light' : 'dark');
}

```

- [ ] **Step 2: Use it on the public catalog**

In `app/js/catalog.js`, find this line:

```javascript
import { initThemeToggle } from './theme.js';
```

Replace it with:

```javascript
import { applyAutoTheme } from './theme.js';
```

Find this line:

```javascript
initThemeToggle();
```

Replace it with:

```javascript
applyAutoTheme();
```

- [ ] **Step 3: Remove the manual toggle button from the public catalog**

In `app/index.html`, find this block:

```html
      <button class="icon-btn" id="theme-toggle" aria-label="Cambiar tema" type="button">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/></svg>
      </button>
```

Delete it entirely (the `#cart-btn` button right after it stays).

- [ ] **Step 4: Verify both pages still load without errors**

```bash
cd /home/user/Toys-lemus-store
NODE_PATH=/opt/node22/lib/node_modules node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  for (const p of ['app/index.html', 'app/admin.html']) {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto('file://' + process.cwd() + '/' + p);
    const theme = await page.evaluate(() => document.documentElement.getAttribute('data-theme'));
    console.log(p, '-> data-theme:', theme, '| page errors:', errors);
    await page.close();
  }
  await browser.close();
})();
"
```

Expected: `app/index.html -> data-theme: light` or `dark` (whichever matches the current hour in `America/Mexico_City` when this runs), `page errors: []`; `app/admin.html -> data-theme:` whatever it was before (likely `null`/unset, since Admin's manual toggle only sets it once a human clicks it or restores a saved preference), `page errors: []`. The key check is that neither page threw an error and `index.html` actually got a `light`/`dark` value assigned.

- [ ] **Step 5: Commit**

```bash
git add app/js/theme.js app/js/catalog.js app/index.html
git commit -m "Auto-switch the public catalog's theme by time of day in Mexico City"
```

---

### Task 8: Deploy + checklist en vivo con Ricardo

**Files:** none (manual migration + verification only)

**Interfaces:**
- Consumes: everything from Tasks 1-7.

- [ ] **Step 1: Hand Ricardo the migration to run manually**

Supabase isn't reachable from this environment — same as every other
migration in this project. Give Ricardo the full contents of
`supabase/migrations/0018_catalog_visibility_settings.sql` to paste into
the Supabase Dashboard's SQL editor and run, **before** the frontend
changes go live (the frontend code in Tasks 2-6 expects
`product_lines.visible_public` and `site_settings` to already exist).

- [ ] **Step 2: Push the branch**

```bash
git push origin claude/artifact-webpage-hyhkrh
```

- [ ] **Step 3: Confirm the Netlify deploy succeeded**

Check the Netlify dashboard (Deploys tab) shows a new "Published" deploy
for this branch (Netlify is connected to GitHub as of this session — no
manual drag-and-drop needed). If it's still "Building", wait for it to
finish before the next step.

- [ ] **Step 4: Live checklist with Ricardo**

1. Confirm Ricardo ran the migration (Step 1) successfully — no errors in
   the Supabase SQL editor.
2. Open `https://lemus-store.netlify.app` — confirm only the "Toys" line
   tab shows (no "Electrónica", "Cosméticos", etc.), and only Toys
   products appear under "Todo".
3. In Admin → Ajustes, turn on another line (e.g. "Electrónica") and
   confirm it appears on the public catalog within a few seconds
   (realtime).
4. Confirm the catalog shows 15 products per page with the "← Anterior /
   Página X de Y / Siguiente →" controls once more than 15 products are
   visible; confirm changing line/category/search resets to page 1.
5. In Admin → Promociones, activate a promotion and confirm the banner
   appears below the catalog on the public page; deactivate it and
   confirm the banner disappears.
6. Confirm "Productos activos" is hidden on the public catalog by
   default; in Admin → Ajustes, turn on "Mostrar contador de Productos
   activos" and confirm it appears live on the public page.
7. Confirm the public catalog's theme matches the current hour in Mexico
   City (light 7am–7pm, dark otherwise) and that the manual theme button
   is gone from that page. Confirm the Admin panel's manual theme button
   still works exactly as before.
8. Confirm nothing else regressed: add a product to the cart and run
   through a normal checkout to `?checkout=success` once, to confirm the
   Mercado Pago flow still works unchanged.

No code changes in this task — it's confirmation that everything built in
Tasks 1-7 works end-to-end on the live site.
