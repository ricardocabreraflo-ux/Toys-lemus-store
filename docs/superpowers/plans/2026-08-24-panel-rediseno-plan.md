# Rediseño del panel — Dashboard y navegación — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the always-visible top stat strip + horizontal 12-button
tab row with a new "Dashboard" landing tab plus a grouped left sidebar
(desktop) / bottom nav + "Más" sheet (mobile, ≤640px — the same
breakpoint already used elsewhere in this project), with Dashboard
showing real numbers (role-aware) instead of a placeholder.

**Architecture:** Purely frontend (`app/admin.html`, `app/js/admin.js`,
`app/css/styles.css`) — no Supabase migration, no new query. Every
real section (Vender, Inventario, Reportes, etc.) keeps its existing
`<section class="tab-panel" id="tab-...">` markup and JS untouched;
only how you *navigate* to them changes. Because a section now has to
be reachable from two physical locations at once (the desktop sidebar,
and either the mobile bottom bar or the "Más" sheet), every nav
trigger keeps the existing `.tab-btn` class and `data-tab`/
`data-role-*` attributes, but the click/selection/role-visibility
logic is rewritten to key off `data-tab` value instead of DOM-element
identity — otherwise clicking a mobile copy would leave its desktop
sidebar twin looking unselected (and vice versa). Dashboard's content
is built entirely from arrays `admin.js` already loads today
(`PRODUCTS`, `ORDERS`, `LAYAWAYS`, and — admin only —
`SALES_REPORT_SALES`, already fetched by the existing
`renderSalesReport()` call in `loadEverything()`).

**Tech Stack:** Same as the rest of this project — vanilla JS ES modules, plain CSS with this project's existing design tokens (`--accent`, `--ink`, etc.) and fonts (`Baloo 2`, `Karla`) — no new dependencies, no new fonts.

## Global Constraints

- No Supabase changes of any kind — this plan is 100% frontend.
- Every nav trigger (sidebar item, bottom-nav item, "Más"-sheet item)
  keeps the `.tab-btn` class and the exact `data-role-admin`/
  `data-role-vendedor` attributes the corresponding section already
  uses today — role visibility must end up byte-for-byte equivalent to
  today's, just re-homed.
- **Any element whose visibility is toggled via the `hidden` attribute
  must never also carry an author CSS rule that sets its own
  `display` without an explicit `[hidden] { display: none; }`
  companion rule.** This exact bug (an author `display` value silently
  beating the browser's default `[hidden]{display:none}`) has already
  been hit and fixed twice in this project (the Finanzas summary row,
  and the Conteo camera button/video) — do not reintroduce it a third
  time. This plan adds `display: flex` to `.tab-btn` and gives
  `.more-sheet`/`.more-backdrop` their own `display` values, so both
  need their `[hidden]` companion rule (specified below).
- The breakpoint for switching from sidebar to bottom-nav is
  `max-width: 640px` — the same breakpoint `app/css/styles.css`
  already uses (`@media (max-width: 640px)`), not a new one.
- Dashboard becomes the default landing tab (replacing Inventario) —
  its button carries `data-role-admin data-role-vendedor` and starts
  `aria-selected="true"`; every other nav button (including both
  Inventario copies) starts `aria-selected="false"`.
- No changes to any existing tab's internal behavior — Vender,
  Inventario, Reportes, Conteo (including its camera scanning), etc.
  keep working exactly as they do today. In particular, the existing
  "stop the Conteo camera when leaving that tab" behavior must
  continue to fire correctly.
- Reuse this project's existing fonts (`Baloo 2` for headings/display,
  `Karla` for body/labels) and color tokens — do not introduce new
  fonts or a new color palette.

---

### Task 1: Navigation shell — sidebar, bottom nav, "Más" sheet

**Files:**
- Modify: `app/admin.html` (icon sprite, sidebar/bottom-nav/sheet
  markup, new empty Dashboard tab-panel, `hidden` added to Inventario's
  panel, admin-view wrapper class)
- Modify: `app/js/admin.js` (tab-switch/role-visibility rewritten to
  key off `data-tab`, "Más" sheet open/close wiring)
- Modify: `app/css/styles.css` (sidebar/bottom-nav/sheet layout,
  `.tab-btn` redefined for its new role, old `.tab-row` styling removed)

**Interfaces:**
- Consumes: `CURRENT_ROLE`, `stopCountCamera()`, all already defined
  in `admin.js` from the Conteo plans — do not redefine them.
- Produces: `setActiveTab(tabKey)`, `openMoreSheet()`,
  `closeMoreSheet()` — Task 2's Dashboard content calls
  `setActiveTab()` for its "Atención hoy" deep links.

- [ ] **Step 1: Add the icon sprite**

In `app/admin.html`, find:

```html
<body>

<header class="site">
```

Replace it with (adds a hidden, reusable icon sprite right after
`<body>`, before the header):

```html
<body>

<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <defs>
    <symbol id="i-home" viewBox="0 0 24 24"><path d="M4 11L12 4l8 7v8a1 1 0 0 1-1 1h-4v-6H9v6H5a1 1 0 0 1-1-1v-8Z"/></symbol>
    <symbol id="i-box" viewBox="0 0 24 24"><path d="M3 8l9-4 9 4-9 4-9-4Z"/><path d="M3 8v9l9 4 9-4V8"/><path d="M12 12v9"/></symbol>
    <symbol id="i-cart" viewBox="0 0 24 24"><path d="M3 4h2l2.4 12.2a2 2 0 0 0 2 1.6h7.4a2 2 0 0 0 2-1.6L21 8H6"/><circle cx="9" cy="20" r="1.3"/><circle cx="17" cy="20" r="1.3"/></symbol>
    <symbol id="i-pkg" viewBox="0 0 24 24"><rect x="3" y="7" width="14" height="11" rx="1.4"/><path d="M17 10h2.3L21 13v5h-4"/><circle cx="7" cy="19.5" r="1.2"/><circle cx="18" cy="19.5" r="1.2"/></symbol>
    <symbol id="i-clock" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3.5 2"/></symbol>
    <symbol id="i-barcode" viewBox="0 0 24 24"><path d="M4 5v14M8 5v14M11 5v14M15 5v14M17.5 5v14M21 5v14" stroke-width="1.6"/></symbol>
    <symbol id="i-swap" viewBox="0 0 24 24"><path d="M4 8h13l-3-3M20 16H7l3 3"/></symbol>
    <symbol id="i-tag" viewBox="0 0 24 24"><path d="M11 3h6a2 2 0 0 1 2 2v6l-9.5 9.5a1.5 1.5 0 0 1-2 0L3 16a1.5 1.5 0 0 1 0-2L11 3Z"/><circle cx="15.5" cy="7.5" r="1.1"/></symbol>
    <symbol id="i-grid" viewBox="0 0 24 24"><rect x="3.5" y="3.5" width="7" height="7" rx="1.2"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.2"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.2"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.2"/></symbol>
    <symbol id="i-chart" viewBox="0 0 24 24"><path d="M4 20V10M12 20V4M20 20v-7" stroke-width="2.1"/></symbol>
    <symbol id="i-wallet" viewBox="0 0 24 24"><rect x="3" y="6" width="18" height="13" rx="2"/><path d="M3 10h18"/><circle cx="17" cy="14" r="1"/></symbol>
    <symbol id="i-users" viewBox="0 0 24 24"><circle cx="9" cy="8.5" r="3"/><path d="M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6"/><circle cx="17.5" cy="9.5" r="2.3"/><path d="M15.7 14.1c2.4.3 4.3 2.4 4.3 5"/></symbol>
    <symbol id="i-gear" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.2"/><path d="M12 3v2.2M12 18.8V21M21 12h-2.2M5.2 12H3M18.4 5.6l-1.5 1.5M7.1 16.9l-1.5 1.5M18.4 18.4l-1.5-1.5M7.1 7.1 5.6 5.6"/></symbol>
    <symbol id="i-menu" viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h16"/></symbol>
  </defs>
</svg>

<header class="site">
```

- [ ] **Step 2: Replace the top stat row + tab row with the sidebar / bottom-nav / "Más" sheet shell**

In `app/admin.html`, find:

```html
<main class="wrap admin-main" id="admin-view" hidden>
  <div class="stat-row">
    <div class="stat-tile"><strong id="stat-total">—</strong><span>Productos</span></div>
    <div class="stat-tile"><strong id="stat-value">—</strong><span>Valor de inventario (venta)</span></div>
    <div class="stat-tile warn"><strong id="stat-low">—</strong><span>Con 1 pieza (online)</span></div>
    <div class="stat-tile"><strong id="stat-oos">—</strong><span>Agotados (online)</span></div>
  </div>

  <div class="tab-row" role="tablist">
    <button class="tab-btn" data-tab="inventory" type="button" aria-selected="true" data-role-admin data-role-vendedor>Inventario</button>
    <button class="tab-btn" data-tab="sell" type="button" aria-selected="false" data-role-admin data-role-vendedor>Vender</button>
    <button class="tab-btn" data-tab="orders" type="button" aria-selected="false" data-role-admin data-role-vendedor>Pedidos</button>
    <button class="tab-btn" data-tab="layaways" type="button" aria-selected="false" data-role-admin data-role-vendedor>Apartados</button>
    <button class="tab-btn" data-tab="count" type="button" aria-selected="false" data-role-admin data-role-vendedor>Conteo</button>
    <button class="tab-btn" data-tab="transfers" type="button" aria-selected="false" data-role-admin>Traspasos</button>
    <button class="tab-btn" data-tab="promotions" type="button" aria-selected="false" data-role-admin>Promociones</button>
    <button class="tab-btn" data-tab="taxonomy" type="button" aria-selected="false" data-role-admin>Líneas y categorías</button>
    <button class="tab-btn" data-tab="reports" type="button" aria-selected="false" data-role-admin>Reportes</button>
    <button class="tab-btn" data-tab="finance" type="button" aria-selected="false" data-role-admin>Finanzas</button>
    <button class="tab-btn" data-tab="users" type="button" aria-selected="false" data-role-admin>Usuarios</button>
    <button class="tab-btn" data-tab="settings" type="button" aria-selected="false" data-role-admin>Ajustes</button>
  </div>

  <!-- ---------- Inventario ---------- -->
  <section class="tab-panel" id="tab-inventory">
```

Replace it with (Dashboard's own panel is a placeholder here — Task 2
fills it in; every existing tab-panel below is untouched except
Inventario, which now gets `hidden` since it's no longer the default):

```html
<main class="admin-shell" id="admin-view" hidden>
  <nav class="admin-sidebar" id="admin-sidebar" aria-label="Secciones">
    <div class="sidebar-brand"><span class="sidebar-mark">🧸</span> Lemus Store</div>
    <button class="tab-btn nav-item" data-tab="dashboard" type="button" aria-selected="true" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-home"/></svg>Dashboard</button>
    <p class="nav-group-label">Operación diaria</p>
    <button class="tab-btn nav-item" data-tab="sell" type="button" aria-selected="false" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-cart"/></svg>Vender</button>
    <button class="tab-btn nav-item" data-tab="orders" type="button" aria-selected="false" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-pkg"/></svg>Pedidos</button>
    <button class="tab-btn nav-item" data-tab="layaways" type="button" aria-selected="false" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-clock"/></svg>Apartados</button>
    <button class="tab-btn nav-item" data-tab="count" type="button" aria-selected="false" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-barcode"/></svg>Conteo</button>
    <p class="nav-group-label">Catálogo y precios</p>
    <button class="tab-btn nav-item" data-tab="inventory" type="button" aria-selected="false" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-box"/></svg>Inventario</button>
    <button class="tab-btn nav-item" data-tab="transfers" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-swap"/></svg>Traspasos</button>
    <button class="tab-btn nav-item" data-tab="promotions" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-tag"/></svg>Promociones</button>
    <button class="tab-btn nav-item" data-tab="taxonomy" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-grid"/></svg>Líneas y categorías</button>
    <p class="nav-group-label">Negocio</p>
    <button class="tab-btn nav-item" data-tab="reports" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-chart"/></svg>Reportes</button>
    <button class="tab-btn nav-item" data-tab="finance" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-wallet"/></svg>Finanzas</button>
    <button class="tab-btn nav-item" data-tab="users" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-users"/></svg>Usuarios</button>
    <button class="tab-btn nav-item" data-tab="settings" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-gear"/></svg>Ajustes</button>
  </nav>

  <nav class="admin-bottomnav" id="admin-bottomnav" aria-label="Secciones">
    <button class="tab-btn nav-bn-item" data-tab="dashboard" type="button" aria-selected="true" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-home"/></svg><span>Hoy</span></button>
    <button class="tab-btn nav-bn-item" data-tab="sell" type="button" aria-selected="false" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-cart"/></svg><span>Vender</span></button>
    <button class="tab-btn nav-bn-item" data-tab="count" type="button" aria-selected="false" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-barcode"/></svg><span>Conteo</span></button>
    <button class="tab-btn nav-bn-item" data-tab="inventory" type="button" aria-selected="false" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-box"/></svg><span>Inventario</span></button>
    <button class="nav-bn-item" id="more-nav-btn" type="button" aria-expanded="false"><svg class="icon"><use href="#i-menu"/></svg><span>Más</span></button>
  </nav>

  <div class="more-backdrop" id="more-backdrop" hidden></div>
  <div class="more-sheet" id="more-sheet" hidden role="dialog" aria-label="Más secciones">
    <div class="more-sheet-head">
      <span>Más secciones</span>
      <button class="icon-btn" id="more-sheet-close" type="button" aria-label="Cerrar">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6l12 12M18 6L6 18"/></svg>
      </button>
    </div>
    <p class="nav-group-label">Operación diaria</p>
    <button class="tab-btn nav-item" data-tab="orders" type="button" aria-selected="false" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-pkg"/></svg>Pedidos</button>
    <button class="tab-btn nav-item" data-tab="layaways" type="button" aria-selected="false" data-role-admin data-role-vendedor><svg class="icon"><use href="#i-clock"/></svg>Apartados</button>
    <p class="nav-group-label">Catálogo y precios</p>
    <button class="tab-btn nav-item" data-tab="transfers" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-swap"/></svg>Traspasos</button>
    <button class="tab-btn nav-item" data-tab="promotions" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-tag"/></svg>Promociones</button>
    <button class="tab-btn nav-item" data-tab="taxonomy" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-grid"/></svg>Líneas y categorías</button>
    <p class="nav-group-label">Negocio</p>
    <button class="tab-btn nav-item" data-tab="reports" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-chart"/></svg>Reportes</button>
    <button class="tab-btn nav-item" data-tab="finance" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-wallet"/></svg>Finanzas</button>
    <button class="tab-btn nav-item" data-tab="users" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-users"/></svg>Usuarios</button>
    <button class="tab-btn nav-item" data-tab="settings" type="button" aria-selected="false" data-role-admin><svg class="icon"><use href="#i-gear"/></svg>Ajustes</button>
  </div>

  <div class="admin-content">

  <!-- ---------- Dashboard ---------- -->
  <section class="tab-panel" id="tab-dashboard">
    <div class="stat-row">
      <div class="stat-tile"><strong id="stat-total">—</strong><span>Productos</span></div>
      <div class="stat-tile"><strong id="stat-value">—</strong><span>Valor de inventario (venta)</span></div>
      <div class="stat-tile warn"><strong id="stat-low">—</strong><span>Con 1 pieza (online)</span></div>
      <div class="stat-tile"><strong id="stat-oos">—</strong><span>Agotados (online)</span></div>
    </div>
  </section>

  <!-- ---------- Inventario ---------- -->
  <section class="tab-panel" id="tab-inventory" hidden>
```

`#stat-total`/`#stat-value`/`#stat-low`/`#stat-oos` are the exact same
ids the existing `renderStats()` function (`app/js/admin.js`) already
targets — moving them into `#tab-dashboard` with their ids unchanged
means `renderStats()` needs no changes in this task. Task 2 replaces
this placeholder block with the real, role-aware Dashboard content.

- [ ] **Step 3: Close the new `.admin-content` wrapper**

In `app/admin.html`, find the end of the Ajustes panel and the close
of `<main>`:

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
  </section>
</main>
```

Replace it with (adds the closing `</div>` for `.admin-content` opened
in Step 2, right before `</main>`):

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
  </section>

  </div>
</main>
```

- [ ] **Step 4: Rewrite the tab-switch / role-visibility JS to key off `data-tab`**

In `app/js/admin.js`, find:

```javascript
// ---------- Tabs ----------

document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.setAttribute('aria-selected', String(b === btn)));
    document.querySelectorAll('.tab-panel').forEach(p => { p.hidden = p.id !== `tab-${btn.dataset.tab}`; });
    if (btn.dataset.tab !== 'count') stopCountCamera();
  });
});

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

Replace it with (every real tab now has two `.tab-btn` copies — one in
the sidebar, one in the bottom nav or the "Más" sheet — so selection
and role-visibility are keyed off `data-tab` instead of element
identity, and a shared `setActiveTab()` also closes the "Más" sheet):

```javascript
// ---------- Tabs ----------

function setActiveTab(tabKey) {
  document.querySelectorAll('.tab-btn').forEach(b => b.setAttribute('aria-selected', String(b.dataset.tab === tabKey)));
  document.querySelectorAll('.tab-panel').forEach(p => { p.hidden = p.id !== `tab-${tabKey}`; });
  if (tabKey !== 'count') stopCountCamera();
  closeMoreSheet();
}

document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => setActiveTab(btn.dataset.tab));
});

function openMoreSheet() {
  document.getElementById('more-backdrop').hidden = false;
  document.getElementById('more-sheet').hidden = false;
  document.getElementById('more-nav-btn').setAttribute('aria-expanded', 'true');
}
function closeMoreSheet() {
  document.getElementById('more-backdrop').hidden = true;
  document.getElementById('more-sheet').hidden = true;
  document.getElementById('more-nav-btn').setAttribute('aria-expanded', 'false');
}
document.getElementById('more-nav-btn').addEventListener('click', () => {
  const isOpen = document.getElementById('more-nav-btn').getAttribute('aria-expanded') === 'true';
  if (isOpen) closeMoreSheet(); else openMoreSheet();
});
document.getElementById('more-backdrop').addEventListener('click', closeMoreSheet);
document.getElementById('more-sheet-close').addEventListener('click', closeMoreSheet);

function applyRoleVisibility() {
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.hidden = !btn.hasAttribute(`data-role-${CURRENT_ROLE}`);
  });
  const activeBtn = document.querySelector('.tab-btn[aria-selected="true"]');
  const activeKey = activeBtn ? activeBtn.dataset.tab : null;
  const activeStillVisible = activeKey && document.querySelector(`.tab-btn[data-tab="${activeKey}"]:not([hidden])`);
  if (!activeStillVisible) {
    const firstVisible = document.querySelector('.tab-btn:not([hidden])');
    if (firstVisible) setActiveTab(firstVisible.dataset.tab);
  }
}
```

`CURRENT_ROLE` and `stopCountCamera` are already defined elsewhere in
this file — do not redefine them. Every other call site of
`applyRoleVisibility()` (in `refreshAuthUI()`) is unchanged.

- [ ] **Step 5: Replace the old tab-row/tab-btn CSS with sidebar/bottom-nav/sheet CSS**

In `app/css/styles.css`, find:

```css
.admin-main { padding: 32px 0 100px; }
.tab-row { display: flex; gap: 6px; overflow-x: auto; border-bottom: 2px solid var(--line); margin-bottom: 22px; }
.tab-btn { flex-shrink: 0; border: none; background: none; padding: 10px 16px; font-weight: 700; font-size: 0.92rem; color: var(--ink-soft); cursor: pointer; border-bottom: 3px solid transparent; margin-bottom: -2px; transition: color 0.12s ease, border-color 0.12s ease; }
.tab-btn:hover { color: var(--ink); }
.tab-btn[aria-selected="true"] { color: var(--ink); border-color: var(--accent); }
.tab-panel[hidden] { display: none; }
```

Replace it with:

```css
.admin-shell { max-width: 1180px; margin: 0 auto; padding: 24px 24px 100px; display: flex; gap: 28px; align-items: flex-start; }
.admin-content { flex: 1; min-width: 0; }
.tab-panel[hidden] { display: none; }

.admin-sidebar { flex: none; width: 220px; position: sticky; top: 90px; display: flex; flex-direction: column; gap: 2px; }
.sidebar-brand { font-family: 'Baloo 2'; font-size: 1.1rem; display: flex; align-items: center; gap: 8px; padding: 4px 10px 14px; }
.sidebar-mark { font-size: 1.3rem; }
.nav-group-label { font-size: 0.72rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ink-soft); margin: 14px 0 4px; padding: 0 10px; }
.nav-group-label:first-of-type { margin-top: 6px; }

.tab-btn { display: flex; align-items: center; gap: 10px; border: none; background: none; cursor: pointer; font-family: 'Karla'; font-weight: 700; font-size: 0.92rem; color: var(--ink-soft); text-align: left; transition: color 0.12s ease, background 0.12s ease; }
.tab-btn[hidden] { display: none; }
.tab-btn .icon { width: 17px; height: 17px; stroke: currentColor; fill: none; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; flex: none; }

.tab-btn.nav-item { padding: 9px 10px; border-radius: 10px; }
.tab-btn.nav-item:hover { color: var(--ink); background: var(--bg-alt); }
.tab-btn.nav-item[aria-selected="true"] { color: var(--accent-ink); background: var(--accent); }

.tab-btn.nav-bn-item { flex-direction: column; gap: 3px; padding: 6px 4px; font-size: 0.62rem; border-radius: 10px; }
.tab-btn.nav-bn-item[aria-selected="true"] { color: var(--accent); }
#more-nav-btn { display: flex; flex-direction: column; align-items: center; gap: 3px; padding: 6px 4px; border: none; background: none; cursor: pointer; font-family: 'Karla'; font-weight: 700; font-size: 0.62rem; color: var(--ink-soft); border-radius: 10px; }
#more-nav-btn .icon { width: 17px; height: 17px; stroke: currentColor; fill: none; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
#more-nav-btn[aria-expanded="true"] { color: var(--accent); }

.admin-bottomnav { display: none; }

.more-backdrop { position: fixed; inset: 0; background: rgba(31,42,68,0.35); z-index: 46; }
.more-backdrop[hidden] { display: none; }
.more-sheet {
  display: flex; flex-direction: column; gap: 2px; position: fixed; left: 0; right: 0; bottom: 0; z-index: 47;
  background: var(--panel); border-radius: 20px 20px 0 0; padding: 10px 14px calc(14px + env(safe-area-inset-bottom));
  max-height: 70vh; overflow-y: auto; box-shadow: var(--shadow-lg);
}
.more-sheet[hidden] { display: none; }
.more-sheet-head { display: flex; align-items: center; justify-content: space-between; font-family: 'Baloo 2'; font-size: 1.05rem; padding: 4px 6px 10px; }

@media (max-width: 640px) {
  .admin-shell { flex-direction: column; padding: 16px 16px 84px; gap: 0; }
  .admin-sidebar { display: none; }
  .admin-bottomnav {
    display: flex; justify-content: space-around; align-items: center;
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 45;
    background: var(--panel); border-top: 2px solid var(--line); padding: 4px 4px calc(4px + env(safe-area-inset-bottom));
  }
}
```

`.tab-panel[hidden] { display: none; }` is carried over unchanged from
the block being replaced — it still applies (tab panels now live
inside `.admin-content` instead of directly inside `.wrap`, which
doesn't affect this rule). `.tab-btn[hidden] { display: none; }` is
new and required per this plan's Global Constraints — `.tab-btn` now
sets `display: flex`, so without this companion rule a role-hidden
button would render anyway (the exact bug already fixed twice
elsewhere in this file).

- [ ] **Step 6: Manual verification (no automated test suite in this project)**

Run `node --check app/js/admin.js`. Then trace through by hand, and
verify live in a browser:
1. On load, `#tab-dashboard` is visible and every other `.tab-panel`
   (including `#tab-inventory`) is `hidden` — confirm the only
   `.tab-panel` without a `hidden` attribute in the final HTML is
   `#tab-dashboard`.
2. Both the sidebar's Dashboard button and the bottom-nav's Dashboard
   button start with `aria-selected="true"`; every other nav button
   (all 24 remaining copies) starts `aria-selected="false"`.
3. Clicking any nav item — in the sidebar, in the bottom nav, or
   inside the "Más" sheet — calls `setActiveTab(tabKey)`, which sets
   `aria-selected="true"` on **both** physical copies of that tab
   (sidebar copy and bottom-nav-or-sheet copy) and `false` on every
   other copy, and shows exactly the matching `.tab-panel`.
4. `applyRoleVisibility()` hides the exact same set of sections for a
   vendedor session as it did before this change (Traspasos,
   Promociones, Líneas y categorías, Reportes, Finanzas, Usuarios,
   Ajustes stay admin-only; everything else stays visible to both) —
   compare against the `data-role-*` attributes on each button.
5. Switching away from Conteo (via any nav trigger) still calls
   `stopCountCamera()` — confirm `tabKey !== 'count'` guards this
   exactly as the original code did.
6. Tapping "Más" opens the sheet (`#more-backdrop`/`#more-sheet`
   `hidden` become `false`, `#more-nav-btn`'s `aria-expanded` becomes
   `"true"`); tapping the backdrop, the close button, or any section
   inside the sheet closes it again (the last case via
   `setActiveTab()`'s `closeMoreSheet()` call).
7. At a viewport ≤640px wide, `.admin-sidebar` is not rendered
   (`display: none` from the media query) and `.admin-bottomnav` is
   visible, fixed to the bottom of the screen; above 640px, the
   reverse.
8. `renderStats()` (unchanged) still finds `#stat-total`/`#stat-value`/
   `#stat-low`/`#stat-oos` inside `#tab-dashboard` and populates them
   with real numbers on load — Dashboard shows real data, not a
   permanent "—".

- [ ] **Step 7: Commit**

```bash
git add app/admin.html app/js/admin.js app/css/styles.css
git commit -m "Replace the top tab row with a sidebar/bottom-nav shell and a Dashboard landing tab"
```

---

### Task 2: Dashboard content — stats, weekly chart, "Atención hoy"

**Files:**
- Modify: `app/admin.html` (replace Task 1's placeholder Dashboard
  panel content with the real, role-aware layout)
- Modify: `app/js/admin.js` (`renderDashboard()` and its call site)
- Modify: `app/css/styles.css` (dashboard card/chart/attention-list styles)

**Interfaces:**
- Consumes: `PRODUCTS`, `ORDERS`, `LAYAWAYS`, `SALES_REPORT_SALES`,
  `CURRENT_ROLE`, `fmt`, `layawayDueDate()`, `setActiveTab()` (from
  Task 1) — all already defined in `admin.js`. Do not redefine them.
- Produces: nothing consumed elsewhere — this is the only other task
  in this plan.

- [ ] **Step 1: Replace the placeholder Dashboard panel markup**

In `app/admin.html`, find (the placeholder Task 1 added):

```html
  <!-- ---------- Dashboard ---------- -->
  <section class="tab-panel" id="tab-dashboard">
    <div class="stat-row">
      <div class="stat-tile"><strong id="stat-total">—</strong><span>Productos</span></div>
      <div class="stat-tile"><strong id="stat-value">—</strong><span>Valor de inventario (venta)</span></div>
      <div class="stat-tile warn"><strong id="stat-low">—</strong><span>Con 1 pieza (online)</span></div>
      <div class="stat-tile"><strong id="stat-oos">—</strong><span>Agotados (online)</span></div>
    </div>
  </section>
```

Replace it with:

```html
  <!-- ---------- Dashboard ---------- -->
  <section class="tab-panel" id="tab-dashboard">
    <div class="stat-row" id="dash-stats"></div>
    <div class="dash-grid">
      <div class="dash-card" id="dash-chart-card" hidden>
        <h3>Ventas de la semana</h3>
        <div class="dash-bars" id="dash-bars"></div>
      </div>
      <div class="dash-card">
        <h3>Atención hoy</h3>
        <ul class="dash-attention" id="dash-attention"></ul>
      </div>
    </div>
  </section>
```

This removes the static `#stat-total`/`#stat-value`/`#stat-low`/
`#stat-oos` tiles — Step 3 below replaces `renderStats()`'s job with
`renderDashboard()`, which renders `#dash-stats` dynamically per role.

- [ ] **Step 2: Add the dashboard CSS**

In `app/css/styles.css`, add this block right after the block Task 1
added in its Step 5 (after the `@media (max-width: 640px) { ... }`
block that closes the sidebar/bottom-nav rules):

```css
.dash-grid { display: grid; grid-template-columns: 1.4fr 1fr; gap: 18px; }
@media (max-width: 780px) { .dash-grid { grid-template-columns: 1fr; } }
.dash-card { background: var(--panel); border: 2px solid var(--line); border-radius: 16px; padding: 18px 20px; box-shadow: var(--shadow); }
.dash-card h3 { font-size: 1rem; margin-bottom: 12px; }
.dash-bars { display: flex; align-items: flex-end; gap: 8px; height: 130px; }
.dash-bar { flex: 1; background: var(--accent-3); border-radius: 6px 6px 0 0; min-height: 3px; transition: height 0.25s var(--ease-out); }
.dash-attention { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.dash-attention-link { display: block; width: 100%; text-align: left; padding: 9px 4px; border: none; background: none; border-top: 1px solid var(--line); font-family: 'Karla'; font-size: 0.9rem; color: var(--ink); cursor: pointer; }
.dash-attention li:first-child .dash-attention-link { border-top: none; }
.dash-attention-empty { padding: 9px 4px; color: var(--ink-soft); font-size: 0.9rem; }
```

`#dash-chart-card` toggling via its `hidden` attribute needs no
`[hidden]` companion rule: `.dash-card` sets no `display` value of its
own, so the browser's default `[hidden] { display: none; }` already
applies cleanly (unlike `.tab-btn` in Task 1, which does set
`display: flex` and therefore does need one).

- [ ] **Step 3: Add `renderDashboard()` and wire it up**

In `app/js/admin.js`, find `renderStats()`:

```javascript
// ---------- Stats ----------

function renderStats() {
  document.getElementById('stat-total').textContent = PRODUCTS.length;
  const value = PRODUCTS.reduce((s, p) => s + p.price * (p.stock_online + p.stock_fisica), 0);
  document.getElementById('stat-value').textContent = fmt.format(value);
  document.getElementById('stat-low').textContent = PRODUCTS.filter(p => p.stock_online === 1).length;
  document.getElementById('stat-oos').textContent = PRODUCTS.filter(p => p.stock_online === 0).length;
}
```

Add `renderDashboard()` right after it:

```javascript
function startOfWeek(d) {
  const day = d.getDay(); // 0=domingo..6=sábado
  const diff = day === 0 ? -6 : 1 - day; // semana empieza en lunes
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + diff);
}

function renderDashboard() {
  const isAdmin = CURRENT_ROLE === 'admin';
  const outOfStock = PRODUCTS.filter(p => p.stock_online === 0).length;
  const lowStock = PRODUCTS.filter(p => p.stock_online === 1).length;
  const pendingOrders = ORDERS.filter(o => o.status === 'pagado' || o.status === 'revisar_sin_stock').length;
  const today = new Date(new Date().toDateString());
  const dueTodayLayaways = LAYAWAYS.filter(l =>
    (l.status === 'activo' || l.status === 'revisar_sin_stock') && layawayDueDate(l).getTime() === today.getTime()
  ).length;
  const attentionTotal = outOfStock + lowStock + dueTodayLayaways + pendingOrders;
  const invValue = PRODUCTS.reduce((s, p) => s + p.price * (p.stock_online + p.stock_fisica), 0);

  const statsEl = document.getElementById('dash-stats');
  if (isAdmin) {
    const todayStr = new Date().toDateString();
    const weekStart = startOfWeek(new Date());
    const soldToday = SALES_REPORT_SALES
      .filter(s => new Date(s.created_at).toDateString() === todayStr)
      .reduce((s, r) => s + Number(r.total), 0);
    const soldWeek = SALES_REPORT_SALES
      .filter(s => new Date(s.created_at) >= weekStart)
      .reduce((s, r) => s + Number(r.total), 0);
    statsEl.innerHTML = `
      <div class="stat-tile"><strong>${fmt.format(soldToday)}</strong><span>Vendido hoy</span></div>
      <div class="stat-tile"><strong>${fmt.format(soldWeek)}</strong><span>Vendido esta semana</span></div>
      <div class="stat-tile"><strong>${fmt.format(invValue)}</strong><span>Valor de inventario</span></div>
      <div class="stat-tile ${attentionTotal > 0 ? 'warn' : ''}"><strong>${attentionTotal}</strong><span>Necesitan atención</span></div>`;
  } else {
    statsEl.innerHTML = `
      <div class="stat-tile"><strong>${PRODUCTS.length}</strong><span>Productos</span></div>
      <div class="stat-tile"><strong>${fmt.format(invValue)}</strong><span>Valor de inventario</span></div>
      <div class="stat-tile ${attentionTotal > 0 ? 'warn' : ''}"><strong>${attentionTotal}</strong><span>Necesitan atención</span></div>`;
  }

  document.getElementById('dash-chart-card').hidden = !isAdmin;
  if (isAdmin) {
    const weekStart = startOfWeek(new Date());
    const dayTotals = [0, 0, 0, 0, 0, 0, 0];
    SALES_REPORT_SALES.forEach(s => {
      const d = new Date(new Date(s.created_at).toDateString());
      const diffDays = Math.round((d - weekStart) / 86400000);
      if (diffDays >= 0 && diffDays < 7) dayTotals[diffDays] += Number(s.total);
    });
    const max = Math.max(1, ...dayTotals);
    document.getElementById('dash-bars').innerHTML = dayTotals
      .map(v => `<div class="dash-bar" style="height:${Math.round((v / max) * 100)}%" title="${fmt.format(v)}"></div>`)
      .join('');
  }

  const rows = [];
  if (outOfStock > 0) rows.push({ label: `${outOfStock} producto${outOfStock === 1 ? '' : 's'} agotado${outOfStock === 1 ? '' : 's'} (online)`, tab: 'inventory' });
  if (lowStock > 0) rows.push({ label: `${lowStock} con 1 pieza (online)`, tab: 'inventory' });
  if (dueTodayLayaways > 0) rows.push({ label: `${dueTodayLayaways} apartado${dueTodayLayaways === 1 ? '' : 's'} vence${dueTodayLayaways === 1 ? '' : 'n'} hoy`, tab: 'layaways' });
  if (pendingOrders > 0) rows.push({ label: `${pendingOrders} pedido${pendingOrders === 1 ? '' : 's'} por revisar`, tab: 'orders' });

  const attEl = document.getElementById('dash-attention');
  attEl.innerHTML = rows.length === 0
    ? `<li class="dash-attention-empty">Todo al día 🎉</li>`
    : rows.map(r => `<li><button type="button" class="dash-attention-link" data-tab="${r.tab}">${r.label} ›</button></li>`).join('');
  attEl.querySelectorAll('.dash-attention-link').forEach(btn => {
    btn.addEventListener('click', () => setActiveTab(btn.dataset.tab));
  });
}
```

`layawayDueDate()` is already defined earlier in this file (used by
`layawayIsOverdue()`) — do not redefine it. `.dash-attention-link`
buttons are plain deep links, not `.tab-btn`s: they call the shared
`setActiveTab()` from Task 1 directly rather than going through the
generic `.tab-btn` click delegation, since they don't need
`data-role-*` gating (a vendedor already only sees attention rows
built from data they can already see — Inventario, Apartados, and
Pedidos are all sections a vendedor has access to).

- [ ] **Step 4: Call `renderDashboard()` from `loadEverything()`**

In `app/js/admin.js`, find the end of `loadEverything()`'s render
calls:

```javascript
    renderOrders();
    renderLayaways();
    renderRecentSales();
  } catch (err) {
```

Replace it with:

```javascript
    renderOrders();
    renderLayaways();
    renderRecentSales();
    renderDashboard();
  } catch (err) {
```

By this point in `loadEverything()`, `PRODUCTS`, `ORDERS`, `LAYAWAYS`,
and (for admin) `SALES_REPORT_SALES` have already all been
fetched/reloaded earlier in the same function — `renderDashboard()`
only reads from those in-memory arrays, it makes no network call of
its own.

- [ ] **Step 5: Manual verification (no automated test suite in this project)**

Run `node --check app/js/admin.js`. Then trace through by hand, and
verify live in a browser with real data:
1. As admin, Dashboard shows 4 tiles (Vendido hoy, Vendido esta
   semana, Valor de inventario, Necesitan atención) with real numbers,
   the weekly bar chart, and "Atención hoy".
2. As vendedor, Dashboard shows only 3 tiles (Productos, Valor de
   inventario, Necesitan atención), no chart card (`#dash-chart-card`
   stays `hidden`), and the same "Atención hoy" card.
3. "Necesitan atención" equals the sum of agotados + con 1 pieza +
   apartados que vencen hoy + pedidos pendientes — cross-check against
   the individual numbers already visible in Inventario/Apartados/
   Pedidos.
4. A signal at zero (e.g. no apartados vencen hoy) does not produce an
   empty/blank row in "Atención hoy" — it's omitted entirely per the
   `if (x > 0) rows.push(...)` guards.
5. If every signal is zero, "Atención hoy" shows "Todo al día 🎉"
   instead of an empty list.
6. Clicking a row in "Atención hoy" calls `setActiveTab()` and lands
   on the correct section (Inventario, Apartados, or Pedidos).
7. With zero sales ever recorded, the weekly chart renders all bars at
   their `min-height: 3px` floor (via the `Math.max(1, ...)` divisor
   guard) instead of collapsing to 0-height or dividing by zero.
8. Reloading the page while already logged in re-renders Dashboard
   with fresh numbers (via `loadEverything()`'s existing realtime
   `scheduleReload` path) — no manual refresh needed.

- [ ] **Step 6: Commit**

```bash
git add app/admin.html app/js/admin.js app/css/styles.css
git commit -m "Add real Dashboard content: stats, weekly sales chart, Atención hoy"
```
