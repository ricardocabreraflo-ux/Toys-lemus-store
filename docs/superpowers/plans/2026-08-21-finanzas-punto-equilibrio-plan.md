# Finanzas — punto de equilibrio — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new "Finanzas" tab in Admin where Ricardo records recurring
monthly fixed expenses (rent, salaries, utilities) and sees, at a
glance, whether the current calendar month's real profit (sales minus
their cost) has covered those expenses yet.

**Architecture:** One new table (`fixed_expenses`), admin-only end to
end (RLS + tab visibility, same pattern as Promociones/Reportes/
Ajustes). The break-even math reuses the exact same "revenue minus
cost" calculation the existing Reportes tab already does for
`sale_items_view`, just scoped to the current calendar month instead of
grouped by month.

**Tech Stack:** Same as the rest of this project — Supabase (Postgres + RLS), vanilla JS ES modules, no new dependencies.

## Global Constraints

- `fixed_expenses` is admin-only, full stop — no anon or vendedor
  read access (unlike `site_settings`/`promotions`, which are
  intentionally public-readable display settings). Follow the
  `public.is_admin()` guard pattern from `0008_admin_only_writes.sql`.
- The "Finanzas" tab button and panel must be gated `data-role-admin`
  only (no `data-role-vendedor`) — same as Reportes/Promociones/Ajustes.
- Break-even compares **current calendar month's real profit** (sales
  total minus cost, `status in ('completada', 'entregado')`) against
  **active fixed expenses only** — matches the spec exactly, no
  historical months, no revenue-only comparison.
- Zero active fixed expenses → show a neutral message, never a
  misleading "you've covered $0 of expenses" comparison.
- Do not touch sales, apartados, Mercado Pago checkout, Promociones, or
  any tab/file not named in this plan.
- No new dependencies.

---

### Task 1: Migration — `fixed_expenses` table

**Files:**
- Create: `supabase/migrations/0020_fixed_expenses.sql`

**Interfaces:**
- Produces: `public.fixed_expenses` (columns: `id`, `name`,
  `monthly_amount`, `active`, `created_at`), consumed by Task 2's
  frontend queries.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0020_fixed_expenses.sql
-- Ricardo wants a "Finanzas" tab with recurring monthly fixed expenses
-- (rent, salaries, utilities) compared against the current month's real
-- profit, to see his break-even point. Unlike site_settings/promotions,
-- this is internal financial data — admin-only read and write, no
-- public or vendedor access at all. See
-- docs/superpowers/specs/2026-08-21-finanzas-punto-equilibrio-design.md.

create table if not exists public.fixed_expenses (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  monthly_amount  numeric(10, 2) not null check (monthly_amount >= 0),
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);

alter table public.fixed_expenses enable row level security;

drop policy if exists "admin only" on public.fixed_expenses;
create policy "admin only" on public.fixed_expenses for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'fixed_expenses'
  ) then
    alter publication supabase_realtime add table public.fixed_expenses;
  end if;
end;
$$;

notify pgrst, 'reload schema';
```

Note this uses a single `for all` policy (read AND write both gated on
`is_admin()`) rather than separate read/write policies — correct here
specifically because, unlike `product_lines`/`site_settings`/
`promotions`, there is no legitimate anon or vendedor read case for
financial data. Do not add a public-read policy.

- [ ] **Step 2: Sanity-check the migration text**

No local Supabase instance or automated tests in this project — Ricardo
runs this by hand via the Supabase Dashboard SQL editor. Re-read the
file once against these checks and fix inline if any fails:
1. Every statement ends with a semicolon.
2. The `do $$ ... $$;` block matches the exact guarded-publication
   pattern already used in `0018_catalog_visibility_settings.sql` and
   `0019_promotions_by_product.sql` (open the more recent of the two
   and compare side by side).
3. The RLS policy references `public.is_admin()` (confirm that function
   exists — it's defined in an earlier migration and used throughout
   Admin; do not redefine it).

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0020_fixed_expenses.sql
git commit -m "Add fixed_expenses table for the Finanzas tab"
```

---

### Task 2: Admin — "Finanzas" tab (expense editor + break-even summary)

**Files:**
- Modify: `app/admin.html` (new tab button + new tab panel)
- Modify: `app/js/admin.js` (new state, load/render functions, wiring
  into `loadEverything()`/`subscribeRealtime()`)
- Modify: `app/css/styles.css` (one new `.stat-tile.ok` variant)

**Interfaces:**
- Consumes: `public.fixed_expenses` (Task 1), the existing `sales`/
  `sale_items_view` tables already used by `renderSalesReport()`, the
  existing `fmt`/`escapeHtml`/`showToast`/`CURRENT_ROLE` module-level
  helpers already defined in `admin.js`.
- Produces: nothing consumed by a later task — this is the only other
  task in this plan.

- [ ] **Step 1: Add the tab button**

In `app/admin.html`, find the tab button row (it currently ends with
Reportes, Usuarios, Ajustes):

```html
    <button class="tab-btn" data-tab="reports" type="button" aria-selected="false" data-role-admin>Reportes</button>
    <button class="tab-btn" data-tab="users" type="button" aria-selected="false" data-role-admin>Usuarios</button>
    <button class="tab-btn" data-tab="settings" type="button" aria-selected="false" data-role-admin>Ajustes</button>
```

Insert a new button right after Reportes:

```html
    <button class="tab-btn" data-tab="reports" type="button" aria-selected="false" data-role-admin>Reportes</button>
    <button class="tab-btn" data-tab="finance" type="button" aria-selected="false" data-role-admin>Finanzas</button>
    <button class="tab-btn" data-tab="users" type="button" aria-selected="false" data-role-admin>Usuarios</button>
    <button class="tab-btn" data-tab="settings" type="button" aria-selected="false" data-role-admin>Ajustes</button>
```

No `data-role-vendedor` attribute — this matches Reportes/Promociones/
Ajustes exactly, so `applyRoleVisibility()` (already in `admin.js`,
unchanged by this task) hides it entirely for the vendedor role.

- [ ] **Step 2: Add the tab panel**

Find the existing `<section class="tab-panel" id="tab-reports" ...>`
block and its closing `</section>` (it's followed by
`<section class="tab-panel" id="tab-settings" ...>` or similar — locate
it by searching for `id="tab-reports"` in the file). Add this new
section immediately after that closing `</section>`:

```html
  <section class="tab-panel" id="tab-finance" hidden>
    <div class="grid-head"><h2>Gastos fijos</h2></div>
    <form class="add-form" id="expense-form">
      <div class="field" style="grid-column: span 2;">
        <label for="expense-name">Nombre</label>
        <input class="cell-input" id="expense-name" type="text" required placeholder="Ej. Renta">
      </div>
      <div class="field">
        <label for="expense-amount">Monto mensual</label>
        <input class="cell-input" id="expense-amount" type="number" min="0" step="0.01" required>
      </div>
      <div class="submit-cell">
        <button class="btn btn-primary btn-sm" type="submit">Agregar gasto</button>
      </div>
    </form>
    <div class="table-wrap" style="margin-bottom:32px;">
      <table class="admin-table">
        <thead><tr><th>Nombre</th><th>Monto mensual</th><th>Activo</th><th></th></tr></thead>
        <tbody id="finance-expenses-tbody"></tbody>
      </table>
    </div>

    <div class="grid-head"><h2>Punto de equilibrio de este mes</h2></div>
    <div class="stat-row" id="finance-summary">
      <div class="stat-tile"><strong id="finance-margin">—</strong><span>Ganancia de este mes</span></div>
      <div class="stat-tile"><strong id="finance-expenses-total">—</strong><span>Gastos fijos activos</span></div>
      <div class="stat-tile" id="finance-result-tile"><strong id="finance-result">—</strong><span id="finance-result-label">Punto de equilibrio</span></div>
    </div>
    <p id="finance-no-expenses-msg" hidden style="color:var(--ink-soft);">Agrega tus gastos fijos para ver tu punto de equilibrio este mes.</p>
  </section>
```

- [ ] **Step 3: Add the `.stat-tile.ok` CSS variant**

`app/css/styles.css` already has:

```css
.stat-tile.warn strong { color: var(--stock-low); }
```

Add a matching positive variant right after it (both `--ok` and
`--ok-bg` are already defined in every theme block in this file — used
today by `.save-pill` — so no new custom property is needed):

```css
.stat-tile.warn strong { color: var(--stock-low); }
.stat-tile.ok strong { color: var(--ok); }
```

- [ ] **Step 4: Add module state and the expense-form submit handler**

In `app/js/admin.js`, find the existing module-level state block:

```javascript
let PRODUCTS = [];
let PROMOTIONS = [];
let TRANSFERS = [];
```

(read the file to find its exact current contents — other tasks may
have added lines since; add these two new lines wherever that block
currently ends, keeping the existing lines untouched):

```javascript
let FIXED_EXPENSES = [];
let CURRENT_MONTH_MARGIN = 0;
```

Then add a submit handler for the new form, placed near the other
`*-form` submit handlers (e.g. right after the `promo-form` handler is
a reasonable spot — read the file to place it naturally among similar
handlers):

```javascript
document.getElementById('expense-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const name = document.getElementById('expense-name').value.trim();
  const monthly_amount = Math.max(0, Number(document.getElementById('expense-amount').value) || 0);
  if (!name) return;

  const { data, error } = await supabase.from('fixed_expenses').insert({ name, monthly_amount, active: true }).select().single();
  if (error) { showToast('No se pudo agregar el gasto', true); console.error(error); return; }
  FIXED_EXPENSES.push(data);
  renderFinance();
  showToast(`Gasto "${name}" agregado`);
  e.target.reset();
});
```

- [ ] **Step 5: Add `loadFinance()` and `computeCurrentMonthMargin()`**

Add these two functions near `renderSalesReport()` (they belong to the
same "Finanzas/Reportes data loading" area of the file):

```javascript
async function computeCurrentMonthMargin() {
  const now = new Date();
  const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();
  const { data: sales, error: salesErr } = await supabase
    .from('sales')
    .select('id, total, status')
    .in('status', ['completada', 'entregado'])
    .gte('created_at', startOfMonth);
  if (salesErr) { console.error(salesErr); return 0; }
  if (sales.length === 0) return 0;

  const saleIds = sales.map(s => s.id);
  const { data: items, error: itemsErr } = await supabase
    .from('sale_items_view')
    .select('sale_id, quantity, unit_cost_price')
    .in('sale_id', saleIds);
  if (itemsErr) { console.error(itemsErr); return 0; }

  const totalRevenue = sales.reduce((s, x) => s + Number(x.total), 0);
  const totalCost = items.reduce((s, i) => s + (Number(i.unit_cost_price) || 0) * i.quantity, 0);
  return totalRevenue - totalCost;
}

async function loadFinance() {
  if (CURRENT_ROLE !== 'admin') return;
  const { data, error } = await supabase.from('fixed_expenses').select('*').order('created_at', { ascending: true });
  if (error) { console.error(error); return; }
  FIXED_EXPENSES = data;
  CURRENT_MONTH_MARGIN = await computeCurrentMonthMargin();
}
```

`sale_items_view` (not the raw `sale_items` table) is required here —
it's the same admin-cost-masking view `renderSalesReport()` already
reads, and this function runs only for `CURRENT_ROLE === 'admin'`
callers, matching that existing precedent exactly.

- [ ] **Step 6: Add `renderFinance()`, `renderExpensesTable()`, `renderBreakEvenSummary()`**

Add these three functions right after the two from Step 5:

```javascript
function renderFinance() {
  if (CURRENT_ROLE !== 'admin') return;
  renderExpensesTable();
  renderBreakEvenSummary();
}

function renderExpensesTable() {
  const tbody = document.getElementById('finance-expenses-tbody');
  tbody.innerHTML = FIXED_EXPENSES.map(exp => `
    <tr data-id="${exp.id}">
      <td><input class="cell-input" data-field="name" value="${escapeHtml(exp.name)}"></td>
      <td><input class="cell-input" data-field="monthly_amount" type="number" min="0" step="0.01" value="${exp.monthly_amount}"></td>
      <td><input type="checkbox" data-role="expense-active" ${exp.active ? 'checked' : ''}></td>
      <td>
        <button class="icon-mini danger" data-role="expense-delete" type="button" aria-label="Eliminar ${escapeHtml(exp.name)}">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
        </button>
      </td>
    </tr>`).join('') || `<tr><td colspan="4" style="color:var(--ink-soft);">Sin gastos fijos todavía.</td></tr>`;

  tbody.querySelectorAll('[data-field]').forEach(input => {
    input.addEventListener('change', async () => {
      const row = input.closest('tr');
      const id = row.dataset.id;
      const field = input.dataset.field;
      let value = input.value;
      if (field === 'monthly_amount') value = Math.max(0, Number(value) || 0);
      else value = value.trim();
      const { error } = await supabase.from('fixed_expenses').update({ [field]: value }).eq('id', id);
      if (error) { showToast('No se pudo guardar el cambio', true); return; }
      const local = FIXED_EXPENSES.find(e => e.id === id);
      if (local) local[field] = value;
      renderFinance();
    });
  });

  tbody.querySelectorAll('[data-role="expense-active"]').forEach(cb => {
    cb.addEventListener('change', async () => {
      const id = cb.closest('tr').dataset.id;
      const { error } = await supabase.from('fixed_expenses').update({ active: cb.checked }).eq('id', id);
      if (error) { showToast('No se pudo actualizar', true); cb.checked = !cb.checked; return; }
      const local = FIXED_EXPENSES.find(e => e.id === id);
      if (local) local.active = cb.checked;
      renderFinance();
    });
  });

  tbody.querySelectorAll('[data-role="expense-delete"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      const expense = FIXED_EXPENSES.find(e => e.id === id);
      if (!expense || !confirm(`¿Eliminar el gasto "${expense.name}"?`)) return;
      const { error } = await supabase.from('fixed_expenses').delete().eq('id', id);
      if (error) { showToast('No se pudo eliminar', true); return; }
      FIXED_EXPENSES = FIXED_EXPENSES.filter(e => e.id !== id);
      renderFinance();
    });
  });
}

function renderBreakEvenSummary() {
  const activeExpenses = FIXED_EXPENSES.filter(e => e.active);
  const summaryEl = document.getElementById('finance-summary');
  const noExpensesMsg = document.getElementById('finance-no-expenses-msg');

  if (activeExpenses.length === 0) {
    summaryEl.hidden = true;
    noExpensesMsg.hidden = false;
    return;
  }
  summaryEl.hidden = false;
  noExpensesMsg.hidden = true;

  const expensesTotal = activeExpenses.reduce((s, e) => s + Number(e.monthly_amount), 0);
  document.getElementById('finance-margin').textContent = fmt.format(CURRENT_MONTH_MARGIN);
  document.getElementById('finance-expenses-total').textContent = fmt.format(expensesTotal);

  const resultTile = document.getElementById('finance-result-tile');
  const resultEl = document.getElementById('finance-result');
  const resultLabel = document.getElementById('finance-result-label');
  const delta = CURRENT_MONTH_MARGIN - expensesTotal;

  if (delta >= 0) {
    resultTile.classList.remove('warn');
    resultTile.classList.add('ok');
    resultLabel.textContent = 'Ganancia neta (ya cubriste gastos)';
    resultEl.textContent = fmt.format(delta);
  } else {
    resultTile.classList.remove('ok');
    resultTile.classList.add('warn');
    resultLabel.textContent = 'Te faltan para cubrir gastos';
    resultEl.textContent = fmt.format(Math.abs(delta));
  }
}
```

`renderExpensesTable()`'s edit/toggle/delete handlers each call the
full `renderFinance()` afterward (not just `renderExpensesTable()`)
because `renderBreakEvenSummary()` depends on `FIXED_EXPENSES` too
(the total changes) — but note `renderBreakEvenSummary()` itself never
re-fetches `CURRENT_MONTH_MARGIN` from the network on these calls, only
`loadFinance()` does that. This keeps every inline edit fast (no extra
round trip) while still keeping the totals correct.

- [ ] **Step 7: Wire into `loadEverything()`**

In `app/js/admin.js`'s `loadEverything()`, find:

```javascript
    renderReports();
    await renderSalesReport();
    renderUsers();
```

(read the surrounding function first — other tasks may have changed
nearby lines; locate this exact three-line sequence and insert between
the second and third lines):

```javascript
    renderReports();
    await renderSalesReport();
    await loadFinance();
    renderFinance();
    renderUsers();
```

- [ ] **Step 8: Wire into `subscribeRealtime()`**

Find the existing channel subscription chain in `subscribeRealtime()`:

```javascript
    .on('postgres_changes', { event: '*', schema: 'public', table: 'layaway_payments' }, scheduleReload)
    .subscribe();
```

Add one more `.on(...)` line for the new table, right before
`.subscribe()`:

```javascript
    .on('postgres_changes', { event: '*', schema: 'public', table: 'layaway_payments' }, scheduleReload)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'fixed_expenses' }, scheduleReload)
    .subscribe();
```

This also means a new `sales`/`sale_items` change anywhere (e.g. a POS
sale in the Vender tab) already triggers `scheduleReload` →
`loadEverything()` → `loadFinance()` → fresh
`computeCurrentMonthMargin()`, so the break-even card stays live
without any additional wiring — `sales` is already in this same
subscription chain from before this task.

- [ ] **Step 9: Manual verification (no automated test suite in this project)**

Run `node --check app/js/admin.js`. Then trace through by hand:
1. Submitting the "Agregar gasto" form inserts a row, appends it to
   `FIXED_EXPENSES`, and `renderFinance()` shows it in the table and
   folds its amount into the totals — without a full page reload.
2. Editing a name or amount inline saves on `change` (blur/Enter), and
   the totals update.
3. Unchecking "Activo" removes that expense's amount from
   `finance-expenses-total` and recomputes the break-even delta,
   without an extra network fetch (only `FIXED_EXPENSES`-derived math
   changes; `CURRENT_MONTH_MARGIN` stays whatever `loadFinance()` last
   fetched).
4. Zero active expenses → `#finance-summary` is `hidden`,
   `#finance-no-expenses-msg` shows instead.
5. `CURRENT_ROLE !== 'admin'` (a vendedor session) never calls
   `loadFinance()`'s Supabase queries at all (guarded at the top of
   the function) — confirm the tab button itself is also invisible to
   vendedor via the existing `data-role-admin`-only gating from Step 1.

- [ ] **Step 10: Commit**

```bash
git add app/admin.html app/js/admin.js app/css/styles.css
git commit -m "Add Finanzas tab: fixed expenses and current-month break-even"
```
