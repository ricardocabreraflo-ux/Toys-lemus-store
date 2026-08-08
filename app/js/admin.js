import { supabase, fmt } from './supabase-client.js';
import { loadProductLines, loadCategories } from './catalog-data.js';
import { initThemeToggle } from './theme.js';

let LINES = [];
let CATEGORIES = [];
let PRODUCTS = [];
let PROMOTIONS = [];
let TRANSFERS = [];
let query = '';
let lineFilter = 'all';
let catFilter = 'all';
let publishedOnly = false;
let CURRENT_ROLE = null; // 'admin' | 'vendedor'

initThemeToggle();

const loginView = document.getElementById('login-view');
const setPasswordView = document.getElementById('set-password-view');
const adminView = document.getElementById('admin-view');
const logoutBtn = document.getElementById('logout-btn');

// Invite/recovery links land here with the session token in the URL hash
// (e.g. #access_token=...&type=invite). supabase-js's client establishes
// the session from it automatically, but there's no built-in "set your
// password" screen — this app has to provide one before letting the
// person into the normal admin flow.
let isInviteFlow = (() => {
  const hashParams = new URLSearchParams(window.location.hash.slice(1));
  const type = hashParams.get('type');
  return type === 'invite' || type === 'recovery';
})();

const lineById = (id) => LINES.find(l => l.id === id);
const catById = (id) => CATEGORIES.find(c => c.id === id);
const catsForLine = (lineId) => CATEGORIES.filter(c => c.product_line_id === lineId);
const productById = (id) => PRODUCTS.find(p => p.id === id);

function showToast(msg, isError) {
  const t = document.getElementById('toast');
  t.classList.toggle('error', !!isError);
  t.innerHTML = (isError
    ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/></svg>'
    : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>'
  ) + msg;
  t.classList.add('show');
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => t.classList.remove('show'), 2600);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ---------- Tabs ----------

document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.setAttribute('aria-selected', String(b === btn)));
    document.querySelectorAll('.tab-panel').forEach(p => { p.hidden = p.id !== `tab-${btn.dataset.tab}`; });
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

// ---------- Auth ----------

async function refreshAuthUI() {
  const { data: { session } } = await supabase.auth.getSession();

  if (session && isInviteFlow) {
    loginView.hidden = true;
    adminView.hidden = true;
    setPasswordView.hidden = false;
    logoutBtn.hidden = true;
    return;
  }
  setPasswordView.hidden = true;

  if (session) {
    const { data: profile, error } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', session.user.id)
      .single();
    if (error || !profile) {
      showToast('Tu cuenta no tiene un rol asignado. Contacta al admin.', true);
      await supabase.auth.signOut();
      CURRENT_ROLE = null;
      loginView.hidden = false;
      adminView.hidden = true;
      logoutBtn.hidden = true;
      return;
    }
    CURRENT_ROLE = profile.role;
    loginView.hidden = true;
    adminView.hidden = false;
    logoutBtn.hidden = false;
    applyRoleVisibility();
    await loadEverything();
    subscribeRealtime();
  } else {
    CURRENT_ROLE = null;
    loginView.hidden = false;
    adminView.hidden = true;
    logoutBtn.hidden = true;
  }
}

document.getElementById('set-password-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const password = document.getElementById('new-password').value;
  const errEl = document.getElementById('set-password-error');
  errEl.textContent = '';

  const { error } = await supabase.auth.updateUser({ password });
  if (error) { errEl.textContent = error.message; return; }

  isInviteFlow = false;
  history.replaceState({}, '', window.location.pathname);
  showToast('Contraseña guardada');
  refreshAuthUI();
});

document.getElementById('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const email = document.getElementById('login-email').value.trim();
  const password = document.getElementById('login-password').value;
  const errEl = document.getElementById('login-error');
  errEl.textContent = '';

  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    errEl.textContent = 'No se pudo iniciar sesión. Revisa tu correo y contraseña.';
    return;
  }
  refreshAuthUI();
});

logoutBtn.addEventListener('click', async () => {
  await supabase.auth.signOut();
  refreshAuthUI();
});

// ---------- Shared select builders ----------

function optionsForLines(selectEl, { placeholder } = {}) {
  selectEl.innerHTML = (placeholder ? `<option value="all">${placeholder}</option>` : '') +
    LINES.map(l => `<option value="${l.id}">${escapeHtml(l.name)}</option>`).join('');
}

function optionsForCategories(selectEl, lineId, { placeholder } = {}) {
  const cats = lineId ? catsForLine(lineId) : CATEGORIES;
  selectEl.innerHTML = (placeholder ? `<option value="all">${placeholder}</option>` : '') +
    cats.map(c => `<option value="${c.id}">${escapeHtml(c.name)}</option>`).join('');
}

// ---------- Stats ----------

function renderStats() {
  document.getElementById('stat-total').textContent = PRODUCTS.length;
  const value = PRODUCTS.reduce((s, p) => s + p.price * (p.stock_online + p.stock_fisica), 0);
  document.getElementById('stat-value').textContent = fmt.format(value);
  document.getElementById('stat-low').textContent = PRODUCTS.filter(p => p.stock_online === 1).length;
  document.getElementById('stat-oos').textContent = PRODUCTS.filter(p => p.stock_online === 0).length;
}

// ---------- Inventory tab ----------

function initInventoryForm() {
  const lineSel = document.getElementById('new-line');
  const catSel = document.getElementById('new-category');
  optionsForLines(lineSel);
  optionsForCategories(catSel, lineSel.value);
  lineSel.addEventListener('change', () => optionsForCategories(catSel, lineSel.value));
}

function initInventoryFilters() {
  const lineSel = document.getElementById('admin-line-filter');
  const catSel = document.getElementById('admin-cat-filter');
  optionsForLines(lineSel, { placeholder: 'Todas las líneas' });
  optionsForCategories(catSel, null, { placeholder: 'Todas las categorías' });
  lineSel.addEventListener('change', () => {
    lineFilter = lineSel.value;
    catFilter = 'all';
    optionsForCategories(catSel, lineFilter === 'all' ? null : lineFilter, { placeholder: 'Todas las categorías' });
    renderTable();
  });
  catSel.addEventListener('change', () => { catFilter = catSel.value; renderTable(); });
}

function matchesFilters(p) {
  const lineOk = lineFilter === 'all' || p.product_line_id === lineFilter;
  const catOk = catFilter === 'all' || p.category_id === catFilter;
  const pubOk = !publishedOnly || p.published_online;
  const q = query.trim().toLowerCase();
  const qOk = !q || p.name.toLowerCase().includes(q) || (p.code || '').toLowerCase().includes(q);
  return lineOk && catOk && pubOk && qOk;
}

function lineCategoryCellHtml(p, dis) {
  const cats = catsForLine(p.product_line_id);
  const lineOpts = LINES.map(l => `<option value="${l.id}" ${l.id === p.product_line_id ? 'selected' : ''}>${escapeHtml(l.name)}</option>`).join('');
  const catOpts = cats.map(c => `<option value="${c.id}" ${c.id === p.category_id ? 'selected' : ''}>${escapeHtml(c.name)}</option>`).join('');
  return `
    <select class="cell-input" data-field="product_line_id" style="margin-bottom:4px;" ${dis}>${lineOpts}</select>
    <select class="cell-input" data-field="category_id" ${dis}>${catOpts}</select>`;
}

function rowHtml(p) {
  const low = p.stock_online <= 1 || p.stock_fisica <= 1;
  const readOnly = CURRENT_ROLE !== 'admin';
  const dis = readOnly ? 'disabled' : '';
  return `
    <tr data-id="${p.id}" class="${low ? 'low-stock' : ''}">
      <td style="min-width:180px;">${lineCategoryCellHtml(p, dis)}</td>
      <td><input class="cell-input" data-field="code" value="${p.code ? escapeHtml(p.code) : ''}" placeholder="—" ${dis}></td>
      <td><input class="cell-input name-input" data-field="name" value="${escapeHtml(p.name)}" ${dis}></td>
      ${CURRENT_ROLE === 'admin' ? `<td><input class="cell-input" data-field="cost_price" type="number" min="0" step="0.01" value="${p.cost_price}"></td>` : ''}
      <td><input class="cell-input" data-field="price" type="number" min="0" step="0.01" value="${p.price}" ${dis}></td>
      <td><input class="cell-input" data-field="stock_online" type="number" min="0" step="1" value="${p.stock_online}" ${dis}></td>
      <td><input class="cell-input" data-field="stock_fisica" type="number" min="0" step="1" value="${p.stock_fisica}" ${dis}></td>
      <td style="text-align:center;"><input type="checkbox" data-field="published_online" ${p.published_online ? 'checked' : ''} ${dis}></td>
      <td><span class="save-pill" data-role="save-pill">Guardado</span></td>
      <td>
        ${CURRENT_ROLE === 'admin' ? `<button class="icon-mini danger" data-role="delete" type="button" aria-label="Eliminar ${escapeHtml(p.name)}">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
        </button>` : ''}
      </td>
    </tr>`;
}

function renderTable() {
  document.getElementById('col-cost-header').hidden = CURRENT_ROLE !== 'admin';
  document.getElementById('add-form').hidden = CURRENT_ROLE !== 'admin';
  const tbody = document.getElementById('admin-tbody');
  const focused = document.activeElement;
  const focusedRow = focused && focused.closest ? focused.closest('tr[data-id]') : null;
  const focusedId = focusedRow ? focusedRow.dataset.id : null;
  const focusedField = focused && focused.dataset ? focused.dataset.field : null;

  const filtered = PRODUCTS.filter(matchesFilters);
  document.getElementById('admin-count').textContent = filtered.length + (filtered.length === 1 ? ' producto' : ' productos');
  tbody.innerHTML = filtered.map(rowHtml).join('');

  tbody.querySelectorAll('tr[data-id]').forEach(row => {
    const lineSel = row.querySelector('[data-field="product_line_id"]');
    const catSel = row.querySelector('[data-field="category_id"]');
    lineSel.addEventListener('change', async () => {
      const cats = catsForLine(lineSel.value);
      catSel.innerHTML = cats.map(c => `<option value="${c.id}">${escapeHtml(c.name)}</option>`).join('');
      await saveField(row, 'product_line_id', lineSel.value);
      await saveField(row, 'category_id', catSel.value);
    });
    catSel.addEventListener('change', () => saveField(row, 'category_id', catSel.value));

    row.querySelectorAll('input[data-field]').forEach(input => {
      if (input.type === 'checkbox') {
        input.addEventListener('change', () => saveField(row, 'published_online', input.checked));
        return;
      }
      input.addEventListener('input', () => input.classList.add('dirty'));
      input.addEventListener('change', () => saveField(row, input.dataset.field, input.value));
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') input.blur(); });
    });
  });
  tbody.querySelectorAll('[data-role="delete"]').forEach(btn => {
    btn.addEventListener('click', () => deleteProduct(btn.closest('tr').dataset.id));
  });

  if (focusedId && focusedField) {
    const row = tbody.querySelector(`tr[data-id="${focusedId}"]`);
    const el = row && row.querySelector(`[data-field="${focusedField}"]`);
    if (el) el.focus();
  }
}

async function saveField(row, field, rawValue) {
  const id = row.dataset.id;
  let value = rawValue;
  if (field === 'price' || field === 'cost_price') value = Math.max(0, Number(value) || 0);
  if (field === 'stock_online' || field === 'stock_fisica') value = Math.max(0, Math.round(Number(value) || 0));

  const { error } = await supabase.from('products').update({ [field]: value }).eq('id', id);
  if (error) {
    showToast('No se pudo guardar el cambio', true);
    console.error(error);
    return;
  }
  const local = productById(id);
  if (local) local[field] = value;
  const input = row.querySelector(`[data-field="${field}"]`);
  if (input) input.classList.remove('dirty');
  const pill = row.querySelector('[data-role="save-pill"]');
  pill.classList.add('show');
  clearTimeout(pill._t);
  pill._t = setTimeout(() => pill.classList.remove('show'), 1200);
  renderStats();
}

async function deleteProduct(id) {
  const p = productById(id);
  if (!p) return;
  if (!confirm(`¿Eliminar "${p.name}" del catálogo? Esto no se puede deshacer.`)) return;
  const { error } = await supabase.from('products').delete().eq('id', id);
  if (error) { showToast('No se pudo eliminar', true); console.error(error); return; }
  PRODUCTS = PRODUCTS.filter(x => x.id !== id);
  renderStats();
  renderTable();
  showToast(`"${p.name}" eliminado`);
}

document.getElementById('add-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const code = document.getElementById('new-code').value.trim();
  const name = document.getElementById('new-name').value.trim();
  const product_line_id = document.getElementById('new-line').value;
  const category_id = document.getElementById('new-category').value;
  const cost_price = Math.max(0, Number(document.getElementById('new-cost').value) || 0);
  const price = Math.max(0, Number(document.getElementById('new-price').value) || 0);
  const stock_online = Math.max(0, Math.round(Number(document.getElementById('new-stock-online').value) || 0));
  const stock_fisica = Math.max(0, Math.round(Number(document.getElementById('new-stock-fisica').value) || 0));
  const published_online = document.getElementById('new-published').checked;
  if (!name || !product_line_id || !category_id) return;

  const { data, error } = await supabase.from('products')
    .insert({ code, name, product_line_id, category_id, cost_price, price, stock_online, stock_fisica, published_online })
    .select('id, code, name, product_line_id, category_id, price, stock_online, stock_fisica, published_online, created_at, updated_at')
    .single();
  if (error) { showToast('No se pudo agregar el producto', true); console.error(error); return; }
  PRODUCTS.push({ ...data, cost_price });
  renderStats();
  renderTable();
  refreshTransferProductOptions();
  showToast(`"${name}" agregado`);
  e.target.reset();
  document.getElementById('new-published').checked = true;
  document.getElementById('new-stock-online').value = 0;
  document.getElementById('new-stock-fisica').value = 0;
});

document.getElementById('admin-search').addEventListener('input', (e) => { query = e.target.value; renderTable(); });
document.getElementById('admin-published-filter').addEventListener('change', (e) => { publishedOnly = e.target.checked; renderTable(); });

// ---------- Vender tab (POS física) ----------

let SELL_CART = []; // [{ product_id, quantity }]

function refreshSellProductOptions() {
  const sel = document.getElementById('sell-product');
  const current = sel.value;
  sel.innerHTML = PRODUCTS
    .filter(p => p.stock_fisica > 0)
    .map(p => `<option value="${p.id}">${p.code ? escapeHtml(p.code) + ' — ' : ''}${escapeHtml(p.name)} (Física: ${p.stock_fisica})</option>`)
    .join('');
  if (current && PRODUCTS.some(p => p.id === current)) sel.value = current;
}

document.getElementById('sell-add-form').addEventListener('submit', (e) => {
  e.preventDefault();
  const productId = document.getElementById('sell-product').value;
  const qty = Math.round(Number(document.getElementById('sell-qty').value) || 0);
  if (!productId || qty <= 0) return;
  const existing = SELL_CART.find(i => i.product_id === productId);
  if (existing) existing.quantity += qty;
  else SELL_CART.push({ product_id: productId, quantity: qty });
  renderSellCart();
});

function renderSellCart() {
  const tbody = document.getElementById('sell-cart-tbody');
  if (SELL_CART.length === 0) {
    tbody.innerHTML = `<tr><td colspan="5" style="color:var(--ink-soft);">Carrito vacío.</td></tr>`;
  } else {
    tbody.innerHTML = SELL_CART.map((item, idx) => {
      const p = productById(item.product_id);
      const subtotal = (p?.price || 0) * item.quantity;
      return `<tr>
        <td>${escapeHtml(p?.name || '—')}</td>
        <td>${item.quantity}</td>
        <td>${fmt.format(p?.price || 0)}</td>
        <td>${fmt.format(subtotal)}</td>
        <td><button class="icon-mini danger" type="button" data-idx="${idx}" aria-label="Quitar">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6l12 12M18 6L6 18"/></svg>
        </button></td>
      </tr>`;
    }).join('');
    tbody.querySelectorAll('button[data-idx]').forEach(btn => {
      btn.addEventListener('click', () => {
        SELL_CART.splice(Number(btn.dataset.idx), 1);
        renderSellCart();
      });
    });
  }
  const total = SELL_CART.reduce((s, item) => s + (productById(item.product_id)?.price || 0) * item.quantity, 0);
  document.getElementById('sell-total').textContent = fmt.format(total);
  updateSellChange();
}

function updateSellChange() {
  const total = SELL_CART.reduce((s, item) => s + (productById(item.product_id)?.price || 0) * item.quantity, 0);
  const cash = Number(document.getElementById('sell-cash').value) || 0;
  const changeEl = document.getElementById('sell-change');
  changeEl.textContent = cash > 0 ? `Cambio: ${fmt.format(Math.max(0, cash - total))}` : '';
}
document.getElementById('sell-cash').addEventListener('input', updateSellChange);

document.getElementById('sell-confirm-btn').addEventListener('click', async () => {
  const errEl = document.getElementById('sell-error');
  errEl.textContent = '';
  if (SELL_CART.length === 0) { errEl.textContent = 'Agrega al menos un producto.'; return; }

  const { error } = await supabase.rpc('create_sale_fisica', {
    p_items: SELL_CART.map(i => ({ product_id: i.product_id, quantity: i.quantity })),
  });
  if (error) { errEl.textContent = error.message; return; }

  showToast('Venta registrada');
  SELL_CART = [];
  document.getElementById('sell-cash').value = '';
  renderSellCart();
  await reloadProducts();
  renderTable();
  refreshSellProductOptions();
  refreshTransferProductOptions();
  renderStats();
});

// ---------- Pedidos tab (online orders) ----------

let ORDERS = [];

async function loadOrders() {
  const { data, error } = await supabase
    .from('sales')
    .select('*')
    .eq('channel', 'online')
    .order('created_at', { ascending: false });
  if (error) { console.error(error); return; }
  ORDERS = data;
}

function orderStatusLabel(status) {
  if (status === 'pagado') return 'Pagado — pendiente de recoger';
  if (status === 'revisar_sin_stock') return 'Revisar — sin stock';
  return status;
}

function renderOrders() {
  const pending = ORDERS.filter(o => o.status === 'pagado' || o.status === 'revisar_sin_stock');
  const delivered = ORDERS.filter(o => o.status === 'entregado');

  const pendingTbody = document.getElementById('orders-pending-tbody');
  pendingTbody.innerHTML = pending.length === 0
    ? `<tr><td colspan="6" style="color:var(--ink-soft);">Sin pedidos pendientes.</td></tr>`
    : pending.map(o => `
      <tr data-id="${o.id}" class="${o.status === 'revisar_sin_stock' ? 'low-stock' : ''}">
        <td>${new Date(o.created_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' })}</td>
        <td>${escapeHtml(o.customer_name || '—')}</td>
        <td>${escapeHtml(o.customer_phone || '—')}</td>
        <td>${fmt.format(o.total)}</td>
        <td>${orderStatusLabel(o.status)}</td>
        <td>${o.status === 'pagado' ? `<button class="btn btn-primary btn-sm" type="button" data-role="deliver">Marcar entregado</button>` : ''}</td>
      </tr>`).join('');
  pendingTbody.querySelectorAll('[data-role="deliver"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      const { error } = await supabase.rpc('mark_sale_delivered', { p_sale_id: id });
      if (error) { showToast(error.message, true); return; }
      showToast('Pedido marcado como entregado');
      await loadOrders();
      renderOrders();
    });
  });

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

// ---------- Transfers tab ----------

function refreshTransferProductOptions() {
  const sel = document.getElementById('tr-product');
  const current = sel.value;
  sel.innerHTML = PRODUCTS.map(p =>
    `<option value="${p.id}">${p.code ? escapeHtml(p.code) + ' — ' : ''}${escapeHtml(p.name)} (Online: ${p.stock_online} / Física: ${p.stock_fisica})</option>`
  ).join('');
  if (current && PRODUCTS.some(p => p.id === current)) sel.value = current;
}

document.getElementById('transfer-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const errEl = document.getElementById('transfer-error');
  errEl.textContent = '';
  const product_id = document.getElementById('tr-product').value;
  const from = document.getElementById('tr-from').value;
  const to = document.getElementById('tr-to').value;
  const quantity = Math.round(Number(document.getElementById('tr-qty').value) || 0);
  const note = document.getElementById('tr-note').value.trim() || null;

  if (from === to) { errEl.textContent = 'El origen y destino deben ser distintos.'; return; }
  if (!product_id || quantity <= 0) { errEl.textContent = 'Elige un producto y una cantidad válida.'; return; }

  const { error } = await supabase.rpc('transfer_stock', {
    p_product_id: product_id, p_from: from, p_to: to, p_quantity: quantity, p_note: note,
  });
  if (error) { errEl.textContent = error.message; return; }

  showToast('Traspaso registrado');
  e.target.reset();
  await Promise.all([reloadProducts(), loadTransfers()]);
  renderTable();
  refreshTransferProductOptions();
  renderTransfers();
});

async function loadTransfers() {
  const { data, error } = await supabase
    .from('stock_transfers')
    .select('*, products(name, code)')
    .order('created_at', { ascending: false })
    .limit(30);
  if (error) { console.error(error); return; }
  TRANSFERS = data;
}

const locationLabel = (loc) => loc === 'online' ? 'Online' : 'Física';

function renderTransfers() {
  const tbody = document.getElementById('transfers-tbody');
  if (TRANSFERS.length === 0) {
    tbody.innerHTML = `<tr><td colspan="5" style="color:var(--ink-soft);">Todavía no hay traspasos.</td></tr>`;
    return;
  }
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
document.getElementById('promo-scope-type').addEventListener('change', refreshPromoScopeTarget);

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
    starts_at: startsRaw ? new Date(startsRaw).toISOString() : null,
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

function promoScopeLabel(p) {
  if (p.scope_type === 'line') return (lineById(p.product_line_id)?.name || '—') + ' (línea completa)';
  const c = catById(p.category_id);
  return c ? `${lineById(c.product_line_id)?.name || ''} — ${c.name}` : '—';
}

function promoVigenciaLabel(p) {
  const start = p.starts_at ? new Date(p.starts_at).toLocaleDateString('es-MX') : null;
  const end = p.ends_at ? new Date(p.ends_at).toLocaleDateString('es-MX') : null;
  if (!start && !end) return 'Sin límite';
  if (start && end) return `${start} – ${end}`;
  return start ? `Desde ${start}` : `Hasta ${end}`;
}

function renderPromotions() {
  const tbody = document.getElementById('promo-tbody');
  if (PROMOTIONS.length === 0) {
    tbody.innerHTML = `<tr><td colspan="6" style="color:var(--ink-soft);">Sin promociones todavía.</td></tr>`;
    return;
  }
  tbody.innerHTML = PROMOTIONS.map(p => `
    <tr data-id="${p.id}">
      <td>${escapeHtml(p.name)}</td>
      <td>${escapeHtml(promoScopeLabel(p))}</td>
      <td>-${p.discount_percent}%</td>
      <td>${promoVigenciaLabel(p)}</td>
      <td><input type="checkbox" data-role="promo-active" ${p.active ? 'checked' : ''}></td>
      <td>
        <button class="icon-mini danger" data-role="promo-delete" type="button" aria-label="Eliminar ${escapeHtml(p.name)}">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
        </button>
      </td>
    </tr>`).join('');

  tbody.querySelectorAll('[data-role="promo-active"]').forEach(cb => {
    cb.addEventListener('change', async () => {
      const id = cb.closest('tr').dataset.id;
      const { error } = await supabase.from('promotions').update({ active: cb.checked }).eq('id', id);
      if (error) { showToast('No se pudo actualizar', true); return; }
      const promo = PROMOTIONS.find(p => p.id === id);
      if (promo) promo.active = cb.checked;
    });
  });
  tbody.querySelectorAll('[data-role="promo-delete"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      if (!confirm('¿Eliminar esta promoción?')) return;
      const { error } = await supabase.from('promotions').delete().eq('id', id);
      if (error) { showToast('No se pudo eliminar', true); return; }
      PROMOTIONS = PROMOTIONS.filter(p => p.id !== id);
      renderPromotions();
    });
  });
}

// ---------- Taxonomy tab (lines & categories) ----------

document.getElementById('line-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const input = document.getElementById('line-name');
  const name = input.value.trim();
  if (!name) return;
  const { data, error } = await supabase.from('product_lines').insert({ name, sort_order: LINES.length }).select().single();
  if (error) { showToast('No se pudo agregar la línea', true); console.error(error); return; }
  LINES.push(data);
  refreshAllLineDependentUI();
  input.value = '';
  showToast(`Línea "${name}" agregada`);
});

document.getElementById('category-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const lineSel = document.getElementById('cat-line');
  const input = document.getElementById('cat-name');
  const name = input.value.trim();
  const product_line_id = lineSel.value;
  if (!name || !product_line_id) return;
  const { data, error } = await supabase.from('categories')
    .insert({ product_line_id, name, sort_order: catsForLine(product_line_id).length })
    .select().single();
  if (error) { showToast('No se pudo agregar la categoría', true); console.error(error); return; }
  CATEGORIES.push(data);
  refreshAllLineDependentUI();
  input.value = '';
  showToast(`Categoría "${name}" agregada`);
});

function renderTaxonomy() {
  document.getElementById('lines-tbody').innerHTML = LINES.map(l => `
    <tr data-id="${l.id}">
      <td>${escapeHtml(l.name)}</td>
      <td><button class="icon-mini danger" data-role="line-delete" type="button" aria-label="Eliminar ${escapeHtml(l.name)}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
      </button></td>
    </tr>`).join('');
  document.getElementById('lines-tbody').querySelectorAll('[data-role="line-delete"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      const line = lineById(id);
      if (!confirm(`¿Eliminar la línea "${line.name}"? Solo se puede si no tiene categorías ni productos.`)) return;
      const { error } = await supabase.from('product_lines').delete().eq('id', id);
      if (error) { showToast('No se pudo eliminar: revisa que no tenga categorías o productos', true); return; }
      LINES = LINES.filter(l => l.id !== id);
      refreshAllLineDependentUI();
    });
  });

  document.getElementById('categories-tbody').innerHTML = CATEGORIES.map(c => `
    <tr data-id="${c.id}">
      <td>${escapeHtml(lineById(c.product_line_id)?.name || '')}</td>
      <td>${escapeHtml(c.name)}</td>
      <td><button class="icon-mini danger" data-role="cat-delete" type="button" aria-label="Eliminar ${escapeHtml(c.name)}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
      </button></td>
    </tr>`).join('');
  document.getElementById('categories-tbody').querySelectorAll('[data-role="cat-delete"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      const cat = catById(id);
      if (!confirm(`¿Eliminar la categoría "${cat.name}"? Solo se puede si no tiene productos.`)) return;
      const { error } = await supabase.from('categories').delete().eq('id', id);
      if (error) { showToast('No se pudo eliminar: revisa que no tenga productos', true); return; }
      CATEGORIES = CATEGORIES.filter(c => c.id !== id);
      refreshAllLineDependentUI();
    });
  });
}

function refreshAllLineDependentUI() {
  optionsForLines(document.getElementById('new-line'));
  optionsForCategories(document.getElementById('new-category'), document.getElementById('new-line').value);
  optionsForLines(document.getElementById('admin-line-filter'), { placeholder: 'Todas las líneas' });
  optionsForCategories(document.getElementById('admin-cat-filter'), lineFilter === 'all' ? null : lineFilter, { placeholder: 'Todas las categorías' });
  optionsForLines(document.getElementById('cat-line'));
  refreshPromoScopeTarget();
  renderTaxonomy();
  renderTable();
}

// ---------- Reports tab ----------

function renderReports() {
  const rows = LINES.map(line => {
    const items = PRODUCTS.filter(p => p.product_line_id === line.id);
    const pieces = items.reduce((s, p) => s + p.stock_online + p.stock_fisica, 0);
    const costTotal = items.reduce((s, p) => s + p.cost_price * (p.stock_online + p.stock_fisica), 0);
    const saleValue = items.reduce((s, p) => s + p.price * (p.stock_online + p.stock_fisica), 0);
    return { line, count: items.length, pieces, costTotal, saleValue, profit: saleValue - costTotal };
  });
  document.getElementById('report-lines-tbody').innerHTML = rows.map(r => `
    <tr>
      <td>${escapeHtml(r.line.name)}</td>
      <td>${r.count}</td>
      <td>${r.pieces}</td>
      <td>${fmt.format(r.costTotal)}</td>
      <td>${fmt.format(r.saleValue)}</td>
      <td>${fmt.format(r.profit)}</td>
    </tr>`).join('') || `<tr><td colspan="6" style="color:var(--ink-soft);">Sin datos todavía.</td></tr>`;

  const low = PRODUCTS.filter(p => p.stock_online <= 1 || p.stock_fisica <= 1);
  document.getElementById('report-low-tbody').innerHTML = low.map(p => `
    <tr class="low-stock">
      <td>${escapeHtml(p.name)}</td>
      <td>${escapeHtml(lineById(p.product_line_id)?.name || '')}</td>
      <td>${p.stock_online}</td>
      <td>${p.stock_fisica}</td>
    </tr>`).join('') || `<tr><td colspan="4" style="color:var(--ink-soft);">Todo con existencias saludables.</td></tr>`;
}

async function renderSalesReport() {
  if (CURRENT_ROLE !== 'admin') return;
  const { data: sales, error: salesErr } = await supabase
    .from('sales')
    .select('id, total, created_at, status')
    .in('status', ['completada', 'entregado'])
    .order('created_at', { ascending: false });
  if (salesErr) { console.error(salesErr); return; }

  const { data: items, error: itemsErr } = await supabase
    .from('sale_items_view')
    .select('sale_id, quantity, unit_price, unit_cost_price');
  if (itemsErr) { console.error(itemsErr); return; }

  const bySale = new Map(items.map(i => [i.sale_id, []]));
  items.forEach(i => bySale.get(i.sale_id)?.push(i) ?? bySale.set(i.sale_id, [i]));

  const byMonth = new Map(); // 'YYYY-MM' -> { count, pieces, total, cost }
  sales.forEach(s => {
    const month = s.created_at.slice(0, 7);
    const entry = byMonth.get(month) || { count: 0, pieces: 0, total: 0, cost: 0 };
    entry.count += 1;
    entry.total += Number(s.total);
    (bySale.get(s.id) || []).forEach(i => {
      entry.pieces += i.quantity;
      entry.cost += (Number(i.unit_cost_price) || 0) * i.quantity;
    });
    byMonth.set(month, entry);
  });

  const rows = [...byMonth.entries()].sort((a, b) => b[0].localeCompare(a[0]));
  document.getElementById('report-sales-tbody').innerHTML = rows.map(([month, r]) => `
    <tr>
      <td>${month}</td>
      <td>${r.count}</td>
      <td>${r.pieces}</td>
      <td>${fmt.format(r.total)}</td>
      <td>${fmt.format(r.cost)}</td>
      <td>${fmt.format(r.total - r.cost)}</td>
    </tr>`).join('') || `<tr><td colspan="6" style="color:var(--ink-soft);">Sin ventas todavía.</td></tr>`;
}

// ---------- Users tab ----------

let VENDEDORES = [];

async function loadVendedores() {
  if (CURRENT_ROLE !== 'admin') return;
  const { data, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('role', 'vendedor')
    .order('created_at', { ascending: false });
  if (error) { console.error(error); return; }
  VENDEDORES = data;
}

function renderUsers() {
  const tbody = document.getElementById('users-tbody');
  if (VENDEDORES.length === 0) {
    tbody.innerHTML = `<tr><td colspan="2" style="color:var(--ink-soft);">Sin vendedores todavía.</td></tr>`;
    return;
  }
  tbody.innerHTML = VENDEDORES.map(v => `
    <tr>
      <td>${escapeHtml(v.email)}</td>
      <td>${new Date(v.created_at).toLocaleDateString('es-MX')}</td>
    </tr>`).join('');
}

document.getElementById('invite-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const errEl = document.getElementById('invite-error');
  errEl.textContent = '';
  const email = document.getElementById('invite-email').value.trim();
  if (!email) return;

  const { data, error } = await supabase.functions.invoke('invite-vendedor', { body: { email } });
  if (error) {
    // functions.invoke() doesn't parse the body on non-2xx responses — the
    // real `{error: "..."}` JSON the Edge Function sent is unread on
    // error.context (the raw Response). Recover it, falling back to the
    // generic FunctionsHttpError message if that's not possible.
    let message = error.message;
    try {
      if (error.context && typeof error.context.json === 'function') {
        const body = await error.context.json();
        if (body?.error) message = body.error;
      }
    } catch {}
    errEl.textContent = message || 'No se pudo invitar';
    return;
  }
  if (data?.error) {
    errEl.textContent = data.error;
    return;
  }
  showToast(`Invitación enviada a ${email}`);
  e.target.reset();
  await loadVendedores();
  renderUsers();
});

// ---------- Load & realtime ----------

async function reloadProducts() {
  const { data, error } = await supabase.from('products_view').select('*').order('name');
  if (error) { console.error(error); return; }
  PRODUCTS = data;
}

async function loadEverything() {
  try {
    const [lines, cats] = await Promise.all([loadProductLines(), loadCategories()]);
    LINES = lines;
    CATEGORIES = cats;
    await reloadProducts();
    const { data: promos, error: promoErr } = await supabase.from('promotions').select('*').order('created_at', { ascending: false });
    if (promoErr) throw promoErr;
    PROMOTIONS = promos;
    await loadTransfers();
    await loadVendedores();
    await loadOrders();

    initInventoryForm();
    initInventoryFilters();
    refreshPromoScopeTarget();
    optionsForLines(document.getElementById('cat-line'));
    refreshTransferProductOptions();
    refreshSellProductOptions();

    renderStats();
    renderTable();
    renderTransfers();
    renderPromotions();
    renderTaxonomy();
    renderReports();
    await renderSalesReport();
    renderUsers();
    renderOrders();
  } catch (err) {
    showToast('No se pudo cargar el panel', true);
    console.error(err);
  }
}

let realtimeSubscribed = false;
let reloadTimer = null;
function scheduleReload() {
  clearTimeout(reloadTimer);
  reloadTimer = setTimeout(loadEverything, 350);
}
function subscribeRealtime() {
  if (realtimeSubscribed) return;
  realtimeSubscribed = true;
  supabase
    .channel('admin:all')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'products' }, scheduleReload)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'categories' }, scheduleReload)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'product_lines' }, scheduleReload)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'promotions' }, scheduleReload)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'stock_transfers' }, scheduleReload)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'sales' }, scheduleReload)
    .subscribe();
}

refreshAuthUI();
