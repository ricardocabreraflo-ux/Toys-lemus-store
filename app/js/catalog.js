import { supabase, CATEGORIES, fmt } from './supabase-client.js';
import { iconSvg } from './icons.js';
import { initThemeToggle } from './theme.js';

let PRODUCTS = [];
let activeCat = 'all';
let query = '';
const cart = {}; // keyed by product id

initThemeToggle();

function buildCatRail() {
  const rail = document.getElementById('cat-scroll');
  rail.innerHTML = '';
  const all = document.createElement('button');
  all.className = 'chip'; all.type = 'button'; all.setAttribute('aria-pressed', 'true');
  all.innerHTML = '<span class="sw" style="--c:var(--ink)"></span> Todo';
  all.addEventListener('click', () => setCat('all'));
  rail.appendChild(all);
  Object.entries(CATEGORIES).forEach(([key, meta]) => {
    const btn = document.createElement('button');
    btn.className = 'chip'; btn.type = 'button'; btn.setAttribute('aria-pressed', 'false');
    btn.style.setProperty('--c', meta.color);
    btn.innerHTML = '<span class="sw"></span> ' + meta.label;
    btn.addEventListener('click', () => setCat(key));
    rail.appendChild(btn);
  });
}

function setCat(key) {
  activeCat = key;
  document.querySelectorAll('.chip').forEach((c, i) => {
    const isAll = i === 0;
    c.setAttribute('aria-pressed', String(isAll ? key === 'all' : c.textContent.trim() === CATEGORIES[key]?.label));
  });
  render(true);
}

function matches(p) {
  const catOk = activeCat === 'all' || p.category === activeCat;
  const q = query.trim().toLowerCase();
  const qOk = !q || p.name.toLowerCase().includes(q) || (p.code || '').toLowerCase().includes(q);
  return catOk && qOk;
}

function cardHtml(p, pos) {
  const meta = CATEGORIES[p.category] || CATEGORIES.creativos;
  const low = p.stock <= 1;
  const staggerPos = Math.min(pos, 11);
  return `
    <article class="card" style="--c:${meta.color}; --i:${staggerPos}">
      <div class="card-art">
        <span class="ring"></span>
        ${iconSvg(meta.icon, 'stroke-width="1.6"')}
        ${low ? '<span class="badge-stock">Última pieza</span>' : (p.stock <= 2 ? `<span class="badge-stock">Quedan ${p.stock}</span>` : '')}
        ${p.code ? `<span class="badge-code">#${p.code}</span>` : ''}
      </div>
      <div class="card-body">
        <span class="card-cat">${meta.label}</span>
        <h3 class="card-name">${p.name}</h3>
        <div class="card-foot">
          <span class="price">${fmt.format(p.price)}<sup> MXN</sup></span>
          <button class="add-btn" type="button" data-id="${p.id}" ${p.stock <= 0 ? 'disabled' : ''} aria-label="Agregar ${p.name} al carrito">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"/></svg>
          </button>
        </div>
      </div>
    </article>`;
}

function render(animate) {
  const grid = document.getElementById('grid');
  const filtered = PRODUCTS.filter(matches);
  grid.classList.toggle('animate-in', !!animate);
  grid.innerHTML = filtered.map((p, pos) => cardHtml(p, pos)).join('');
  document.getElementById('empty-state').hidden = filtered.length !== 0 || PRODUCTS.length === 0;
  document.getElementById('result-count').textContent = filtered.length + (filtered.length === 1 ? ' producto' : ' productos');
  document.getElementById('section-title').textContent = activeCat === 'all' ? 'Todo el catálogo' : CATEGORIES[activeCat].label;
  grid.querySelectorAll('.add-btn').forEach(btn => {
    btn.addEventListener('click', () => addToCart(btn.dataset.id));
  });
}

function findProduct(id) { return PRODUCTS.find(p => p.id === id); }

function addToCart(id) {
  const p = findProduct(id);
  if (!p) return;
  cart[id] = (cart[id] || 0) + 1;
  updateCartUI();
  showToast(`${p.name} — agregado`);
}

function changeQty(id, delta) {
  cart[id] = (cart[id] || 0) + delta;
  if (cart[id] <= 0) delete cart[id];
  updateCartUI();
}

function updateCartUI() {
  const entries = Object.entries(cart).filter(([id]) => findProduct(id));
  const count = entries.reduce((s, [, q]) => s + q, 0);
  const countEl = document.getElementById('cart-count');
  countEl.textContent = count;
  countEl.hidden = count === 0;
  countEl.classList.remove('bump');
  void countEl.offsetWidth;
  countEl.classList.add('bump');
  clearTimeout(updateCartUI._t);
  updateCartUI._t = setTimeout(() => countEl.classList.remove('bump'), 180);

  const itemsEl = document.getElementById('drawer-items');
  if (entries.length === 0) {
    itemsEl.innerHTML = `<div class="drawer-empty">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="9" cy="21" r="1.4"/><circle cx="18" cy="21" r="1.4"/><path d="M3 3h2.4l2.6 12.2a2 2 0 0 0 2 1.6h7.6a2 2 0 0 0 2-1.6L21 7H6"/></svg>
        <p>Tu carrito está vacío.<br>Agrega algún juguete del catálogo.</p>
      </div>`;
  } else {
    itemsEl.innerHTML = entries.map(([id, qty]) => {
      const p = findProduct(id);
      const meta = CATEGORIES[p.category] || CATEGORIES.creativos;
      return `<div class="cart-row" style="--c:${meta.color}">
          <div class="art">${iconSvg(meta.icon, 'stroke-width="1.6"')}</div>
          <div class="info">
            <div class="n">${p.name}</div>
            <div class="p">${fmt.format(p.price)}</div>
          </div>
          <div class="qty-ctrl">
            <button type="button" data-id="${id}" data-d="-1" aria-label="Quitar uno">−</button>
            <span>${qty}</span>
            <button type="button" data-id="${id}" data-d="1" aria-label="Agregar uno">+</button>
          </div>
        </div>`;
    }).join('');
    itemsEl.querySelectorAll('.qty-ctrl button').forEach(btn => {
      btn.addEventListener('click', () => changeQty(btn.dataset.id, Number(btn.dataset.d)));
    });
  }

  const subtotal = entries.reduce((s, [id, qty]) => s + findProduct(id).price * qty, 0);
  document.getElementById('subtotal').textContent = fmt.format(subtotal);
}

let toastTimer;
function showToast(msg) {
  const t = document.getElementById('toast');
  t.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>' + msg;
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 2200);
}

const overlay = document.getElementById('overlay');
const drawer = document.getElementById('drawer');
function openDrawer() { overlay.classList.add('open'); drawer.classList.add('open'); }
function closeDrawer() { overlay.classList.remove('open'); drawer.classList.remove('open'); }
document.getElementById('cart-btn').addEventListener('click', openDrawer);
document.getElementById('close-drawer').addEventListener('click', closeDrawer);
overlay.addEventListener('click', closeDrawer);
document.getElementById('checkout-btn').addEventListener('click', () => {
  if (Object.keys(cart).length === 0) { showToast('Agrega algo antes de pagar'); return; }
  showToast('Demo — el pago se conectaría aquí');
});

document.getElementById('search').addEventListener('input', (e) => { query = e.target.value; render(false); });

function buildHeroFloats() {
  const hero = document.querySelector('.hero');
  const specs = [
    { icon: 'dice', top: '12%', left: '78%', size: 46, delay: '0s', dur: '5.5s', rot: -10 },
    { icon: 'car', top: '68%', left: '86%', size: 54, delay: '.6s', dur: '6.5s', rot: 8 },
    { icon: 'shield', top: '20%', left: '90%', size: 38, delay: '1.1s', dur: '5s', rot: 14 },
    { icon: 'blob', top: '78%', left: '68%', size: 40, delay: '1.6s', dur: '7s', rot: -14 },
    { icon: 'doll', top: '48%', left: '94%', size: 34, delay: '.3s', dur: '6s', rot: 6 },
  ];
  specs.forEach(s => {
    const el = document.createElement('div');
    el.className = 'float-toy';
    el.style.top = s.top; el.style.left = s.left;
    el.style.width = s.size + 'px'; el.style.height = s.size + 'px';
    el.style.color = 'var(--accent)';
    el.style.animationDelay = s.delay; el.style.animationDuration = s.dur;
    el.style.setProperty('--r', s.rot + 'deg'); el.style.setProperty('--r2', (s.rot + 10) + 'deg');
    el.innerHTML = iconSvg(s.icon, 'stroke-width="1.4" style="width:100%;height:100%"');
    hero.appendChild(el);
  });
}

function initStats() {
  document.getElementById('stat-products').textContent = PRODUCTS.length;
  document.getElementById('stat-cats').textContent = Object.keys(CATEGORIES).length;
  document.getElementById('stat-low').textContent = PRODUCTS.filter(p => p.stock <= 1).length;
}

async function loadProducts() {
  const { data, error } = await supabase
    .from('products')
    .select('*')
    .order('category', { ascending: true })
    .order('name', { ascending: true });
  if (error) {
    showToast('No se pudo cargar el inventario');
    console.error(error);
    return;
  }
  PRODUCTS = data;
  initStats();
  render(true);
}

function subscribeRealtime() {
  supabase
    .channel('public:products')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'products' }, () => {
      // Any admin edit re-pulls the list so the catalog always reflects
      // live stock/price without the visitor refreshing the page.
      loadProducts();
    })
    .subscribe();
}

buildCatRail();
buildHeroFloats();
updateCartUI();
loadProducts();
subscribeRealtime();
