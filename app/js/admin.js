import { supabase, CATEGORIES, fmt } from './supabase-client.js';
import { initThemeToggle } from './theme.js';

let PRODUCTS = [];
let query = '';
let catFilter = 'all';

initThemeToggle();

const loginView = document.getElementById('login-view');
const adminView = document.getElementById('admin-view');
const logoutBtn = document.getElementById('logout-btn');

function showToast(msg, isError) {
  const t = document.getElementById('toast');
  t.classList.toggle('error', !!isError);
  t.innerHTML = (isError
    ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/></svg>'
    : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>'
  ) + msg;
  t.classList.add('show');
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => t.classList.remove('show'), 2400);
}

// ---------- Auth ----------

async function refreshAuthUI() {
  const { data: { session } } = await supabase.auth.getSession();
  if (session) {
    loginView.hidden = true;
    adminView.hidden = false;
    logoutBtn.hidden = false;
    loadProducts();
    subscribeRealtime();
  } else {
    loginView.hidden = false;
    adminView.hidden = true;
    logoutBtn.hidden = true;
  }
}

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

// ---------- Category select options ----------

function fillCategorySelects() {
  const filterSel = document.getElementById('admin-cat-filter');
  const newSel = document.getElementById('new-category');
  Object.entries(CATEGORIES).forEach(([key, meta]) => {
    const o1 = document.createElement('option'); o1.value = key; o1.textContent = meta.label;
    filterSel.appendChild(o1);
    const o2 = document.createElement('option'); o2.value = key; o2.textContent = meta.label;
    newSel.appendChild(o2);
  });
}

// ---------- Stats ----------

function renderStats() {
  document.getElementById('stat-total').textContent = PRODUCTS.length;
  const value = PRODUCTS.reduce((s, p) => s + p.price * p.stock, 0);
  document.getElementById('stat-value').textContent = fmt.format(value);
  document.getElementById('stat-low').textContent = PRODUCTS.filter(p => p.stock === 1).length;
  document.getElementById('stat-oos').textContent = PRODUCTS.filter(p => p.stock === 0).length;
}

// ---------- Table ----------

function categoryOptionsHtml(selected) {
  return Object.entries(CATEGORIES).map(([key, meta]) =>
    `<option value="${key}" ${key === selected ? 'selected' : ''}>${meta.label}</option>`
  ).join('');
}

function rowHtml(p) {
  const meta = CATEGORIES[p.category] || CATEGORIES.creativos;
  return `
    <tr data-id="${p.id}" class="${p.stock <= 1 ? 'low-stock' : ''}">
      <td>
        <select class="cell-input cat-select" data-field="category" style="--c:${meta.color}">
          ${categoryOptionsHtml(p.category)}
        </select>
      </td>
      <td><input class="cell-input" data-field="code" value="${p.code ? escapeHtml(p.code) : ''}" placeholder="—"></td>
      <td><input class="cell-input name-input" data-field="name" value="${escapeHtml(p.name)}"></td>
      <td><input class="cell-input" data-field="price" type="number" min="0" step="0.01" value="${p.price}"></td>
      <td><input class="cell-input" data-field="stock" type="number" min="0" step="1" value="${p.stock}"></td>
      <td><span class="save-pill" data-role="save-pill">Guardado</span></td>
      <td>
        <div class="row-actions">
          <button class="icon-mini danger" data-role="delete" type="button" aria-label="Eliminar ${escapeHtml(p.name)}">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
          </button>
        </div>
      </td>
    </tr>`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function matches(p) {
  const catOk = catFilter === 'all' || p.category === catFilter;
  const q = query.trim().toLowerCase();
  const qOk = !q || p.name.toLowerCase().includes(q) || (p.code || '').toLowerCase().includes(q);
  return catOk && qOk;
}

function renderTable() {
  const tbody = document.getElementById('admin-tbody');
  const focused = document.activeElement;
  const focusedRow = focused && focused.closest ? focused.closest('tr[data-id]') : null;
  const focusedId = focusedRow ? focusedRow.dataset.id : null;
  const focusedField = focused && focused.dataset ? focused.dataset.field : null;

  const filtered = PRODUCTS.filter(matches);
  document.getElementById('admin-count').textContent = filtered.length + (filtered.length === 1 ? ' producto' : ' productos');
  tbody.innerHTML = filtered.map(rowHtml).join('');

  tbody.querySelectorAll('input[data-field], select[data-field]').forEach(input => {
    input.addEventListener('input', () => input.classList.add('dirty'));
    input.addEventListener('change', () => saveField(input));
    if (input.tagName === 'INPUT') {
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') input.blur(); });
    }
  });
  tbody.querySelectorAll('[data-role="delete"]').forEach(btn => {
    btn.addEventListener('click', () => deleteProduct(btn.closest('tr').dataset.id));
  });

  // Restore focus so a realtime refresh doesn't interrupt active typing.
  if (focusedId && focusedField) {
    const row = tbody.querySelector(`tr[data-id="${focusedId}"]`);
    const el = row && row.querySelector(`[data-field="${focusedField}"]`);
    if (el) el.focus();
  }
}

async function saveField(input) {
  const row = input.closest('tr');
  const id = row.dataset.id;
  const field = input.dataset.field;
  let value = input.value;
  if (field === 'price') value = Math.max(0, Number(value) || 0);
  if (field === 'stock') value = Math.max(0, Math.round(Number(value) || 0));

  const { error } = await supabase.from('products').update({ [field]: value }).eq('id', id);
  if (error) {
    showToast('No se pudo guardar el cambio', true);
    console.error(error);
    return;
  }
  const local = PRODUCTS.find(p => p.id === id);
  if (local) local[field] = value;
  input.classList.remove('dirty');
  const pill = row.querySelector('[data-role="save-pill"]');
  pill.classList.add('show');
  clearTimeout(pill._t);
  pill._t = setTimeout(() => pill.classList.remove('show'), 1200);
  if (field === 'stock' || field === 'price') renderStats();
  if (field === 'category') row.querySelector('.cat-select').style.setProperty('--c', CATEGORIES[value].color);
}

async function deleteProduct(id) {
  const p = PRODUCTS.find(x => x.id === id);
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
  const category = document.getElementById('new-category').value;
  const price = Math.max(0, Number(document.getElementById('new-price').value) || 0);
  const stock = Math.max(0, Math.round(Number(document.getElementById('new-stock').value) || 0));
  if (!name) return;

  const { data, error } = await supabase.from('products').insert({ code, name, category, price, stock }).select().single();
  if (error) { showToast('No se pudo agregar el producto', true); console.error(error); return; }
  PRODUCTS.push(data);
  renderStats();
  renderTable();
  showToast(`"${name}" agregado`);
  e.target.reset();
});

document.getElementById('admin-search').addEventListener('input', (e) => { query = e.target.value; renderTable(); });
document.getElementById('admin-cat-filter').addEventListener('change', (e) => { catFilter = e.target.value; renderTable(); });

// ---------- Data ----------

async function loadProducts() {
  const { data, error } = await supabase
    .from('products')
    .select('*')
    .order('category', { ascending: true })
    .order('name', { ascending: true });
  if (error) { showToast('No se pudo cargar el inventario', true); console.error(error); return; }
  PRODUCTS = data;
  renderStats();
  renderTable();
}

let realtimeSubscribed = false;
function subscribeRealtime() {
  if (realtimeSubscribed) return;
  realtimeSubscribed = true;
  supabase
    .channel('admin:products')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'products' }, () => loadProducts())
    .subscribe();
}

fillCategorySelects();
refreshAuthUI();
