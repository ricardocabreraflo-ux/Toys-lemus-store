import { supabase, fmt } from './supabase-client.js';
import { loadProductLines, loadCategories, loadActivePromotions, discountedPrice, accentFor, iconKeyFor } from './catalog-data.js';
import { iconSvg } from './icons.js';
import { initThemeToggle } from './theme.js';

let PRODUCTS = [];
let LINES = [];
let CATEGORIES = [];
let PROMOTIONS = [];
let activeLine = 'all';
let activeCat = 'all';
let query = '';
const cart = {}; // keyed by product id

initThemeToggle();

const lineById = (id) => LINES.find(l => l.id === id);
const catById = (id) => CATEGORIES.find(c => c.id === id);

function buildLineRail() {
  const rail = document.getElementById('line-scroll');
  rail.innerHTML = '';
  const all = document.createElement('button');
  all.className = 'chip'; all.type = 'button'; all.setAttribute('aria-pressed', activeLine === 'all' ? 'true' : 'false');
  all.innerHTML = '<span class="sw" style="--c:var(--ink)"></span> Todo';
  all.addEventListener('click', () => setLine('all'));
  rail.appendChild(all);
  LINES.forEach(line => {
    const btn = document.createElement('button');
    btn.className = 'chip'; btn.type = 'button'; btn.setAttribute('aria-pressed', activeLine === line.id ? 'true' : 'false');
    btn.style.setProperty('--c', accentFor(line.id));
    btn.innerHTML = '<span class="sw"></span> ' + line.name;
    btn.addEventListener('click', () => setLine(line.id));
    rail.appendChild(btn);
  });
}

function buildCatRail() {
  const rail = document.getElementById('cat-scroll');
  const wrap = document.getElementById('cat-rail-secondary');
  const cats = activeLine === 'all' ? [] : CATEGORIES.filter(c => c.product_line_id === activeLine);
  wrap.hidden = cats.length === 0;
  rail.innerHTML = '';
  const all = document.createElement('button');
  all.className = 'chip'; all.type = 'button'; all.setAttribute('aria-pressed', activeCat === 'all' ? 'true' : 'false');
  all.innerHTML = '<span class="sw" style="--c:var(--ink)"></span> Todas las categorías';
  all.addEventListener('click', () => setCat('all'));
  rail.appendChild(all);
  cats.forEach(cat => {
    const btn = document.createElement('button');
    btn.className = 'chip'; btn.type = 'button'; btn.setAttribute('aria-pressed', activeCat === cat.id ? 'true' : 'false');
    btn.style.setProperty('--c', accentFor(cat.id));
    btn.innerHTML = '<span class="sw"></span> ' + cat.name;
    btn.addEventListener('click', () => setCat(cat.id));
    rail.appendChild(btn);
  });
}

function setLine(id) {
  activeLine = id;
  activeCat = 'all';
  buildLineRail();
  buildCatRail();
  render(true);
}

function setCat(id) {
  activeCat = id;
  buildCatRail();
  render(true);
}

function matches(p) {
  const lineOk = activeLine === 'all' || p.product_line_id === activeLine;
  const catOk = activeCat === 'all' || p.category_id === activeCat;
  const q = query.trim().toLowerCase();
  const qOk = !q || p.name.toLowerCase().includes(q) || (p.code || '').toLowerCase().includes(q);
  return lineOk && catOk && qOk;
}

function cardHtml(p, pos) {
  const c = accentFor(p.category_id);
  const icon = iconKeyFor(p.category_id);
  const low = p.stock_online <= 1;
  const staggerPos = Math.min(pos, 11);
  const { price, promo } = discountedPrice(p, PROMOTIONS);
  const priceHtml = promo
    ? `<span class="price">${fmt.format(price)}<sup> MXN</sup></span> <span class="price-was">${fmt.format(p.price)}</span> <span class="promo-badge">-${promo.discount_percent}%</span>`
    : `<span class="price">${fmt.format(price)}<sup> MXN</sup></span>`;
  return `
    <article class="card" style="--c:${c}; --i:${staggerPos}">
      <div class="card-art">
        <span class="ring"></span>
        ${iconSvg(icon, 'stroke-width="1.6"')}
        ${low ? '<span class="badge-stock">Última pieza</span>' : (p.stock_online <= 2 ? `<span class="badge-stock">Quedan ${p.stock_online}</span>` : '')}
        ${p.code ? `<span class="badge-code">#${p.code}</span>` : ''}
      </div>
      <div class="card-body">
        <span class="card-cat">${catById(p.category_id)?.name || ''}</span>
        <h3 class="card-name">${p.name}</h3>
        <div class="card-foot">
          <span class="price-wrap">${priceHtml}</span>
          <button class="add-btn" type="button" data-id="${p.id}" ${p.stock_online <= 0 ? 'disabled' : ''} aria-label="Agregar ${p.name} al carrito">
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
  document.getElementById('section-title').textContent =
    activeCat !== 'all' ? (catById(activeCat)?.name || '') :
    activeLine !== 'all' ? (lineById(activeLine)?.name || '') :
    'Todo el catálogo';
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
        <p>Tu carrito está vacío.<br>Agrega algún producto del catálogo.</p>
      </div>`;
  } else {
    itemsEl.innerHTML = entries.map(([id, qty]) => {
      const p = findProduct(id);
      const c = accentFor(p.category_id);
      const icon = iconKeyFor(p.category_id);
      const { price } = discountedPrice(p, PROMOTIONS);
      return `<div class="cart-row" style="--c:${c}">
          <div class="art">${iconSvg(icon, 'stroke-width="1.6"')}</div>
          <div class="info">
            <div class="n">${p.name}</div>
            <div class="p">${fmt.format(price)}</div>
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

  const subtotal = entries.reduce((s, [id, qty]) => s + discountedPrice(findProduct(id), PROMOTIONS).price * qty, 0);
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
document.getElementById('checkout-btn').addEventListener('click', async () => {
  const errEl = document.getElementById('checkout-error');
  errEl.textContent = '';
  if (Object.keys(cart).length === 0) { showToast('Agrega algo antes de pagar'); return; }

  const customer_name = document.getElementById('chk-name').value.trim();
  const customer_phone = document.getElementById('chk-phone').value.trim();
  const customer_email = document.getElementById('chk-email').value.trim();
  if (!customer_name || !customer_phone || !customer_email) {
    errEl.textContent = 'Completa tus datos de contacto.';
    return;
  }

  const btn = document.getElementById('checkout-btn');
  btn.disabled = true;
  btn.textContent = 'Redirigiendo a pago…';

  const items = Object.entries(cart).map(([product_id, quantity]) => ({ product_id, quantity }));
  const { data, error } = await supabase.functions.invoke('create-checkout-session', {
    body: { items, customer_name, customer_phone, customer_email },
  });

  btn.disabled = false;
  btn.textContent = 'Ir a pagar';

  if (error || data?.error) {
    // functions.invoke() doesn't parse the body on non-2xx responses — the
    // real `{error: "..."}` JSON the Edge Function sent is unread on
    // error.context (the raw Response). Recover it, falling back to the
    // generic FunctionsHttpError message if that's not possible.
    let message = data?.error || error?.message;
    try {
      if (error?.context && typeof error.context.json === 'function') {
        const body = await error.context.json();
        if (body?.error) message = body.error;
      }
    } catch {}
    errEl.textContent = message || 'No se pudo iniciar el pago';
    return;
  }
  window.location.href = data.url;
});

document.getElementById('layaway-btn').addEventListener('click', async () => {
  const errEl = document.getElementById('checkout-error');
  errEl.textContent = '';
  if (Object.keys(cart).length === 0) { showToast('Agrega algo antes de apartar'); return; }

  const customer_name = document.getElementById('chk-name').value.trim();
  const customer_phone = document.getElementById('chk-phone').value.trim();
  const customer_email = document.getElementById('chk-email').value.trim();
  if (!customer_name || !customer_phone || !customer_email) {
    errEl.textContent = 'Completa tus datos de contacto.';
    return;
  }

  const btn = document.getElementById('layaway-btn');
  btn.disabled = true;
  btn.textContent = 'Redirigiendo a pago…';

  const items = Object.entries(cart).map(([product_id, quantity]) => ({ product_id, quantity }));
  const { data, error } = await supabase.functions.invoke('create-layaway-checkout-session', {
    body: { items, customer_name, customer_phone, customer_email },
  });

  btn.disabled = false;
  btn.textContent = 'Apartar (paga 50% ahora)';

  if (error || data?.error) {
    let message = data?.error || error?.message;
    try {
      if (error?.context && typeof error.context.json === 'function') {
        const body = await error.context.json();
        if (body?.error) message = body.error;
      }
    } catch {}
    errEl.textContent = message || 'No se pudo iniciar el apartado';
    return;
  }
  window.location.href = data.url;
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
  document.getElementById('stat-cats').textContent = LINES.length;
  document.getElementById('stat-low').textContent = PRODUCTS.filter(p => p.stock_online <= 1).length;
}

async function loadAll() {
  try {
    const [lines, cats, promos, productsRes] = await Promise.all([
      loadProductLines(),
      loadCategories(),
      loadActivePromotions(),
      supabase.from('products_view').select('*').eq('published_online', true).order('name'),
    ]);
    if (productsRes.error) throw productsRes.error;
    // A missing/undefined visible_public (e.g. a stale client before the
    // migration lands) fails OPEN — better to show an extra line than to
    // make the whole catalog vanish.
    LINES = lines.filter(l => l.visible_public !== false);
    const visibleLineIds = new Set(LINES.map(l => l.id));
    CATEGORIES = cats.filter(c => visibleLineIds.has(c.product_line_id));
    PROMOTIONS = promos;
    PRODUCTS = productsRes.data.filter(p => visibleLineIds.has(p.product_line_id));
    buildLineRail();
    buildCatRail();
    initStats();
    render(true);
  } catch (err) {
    showToast('No se pudo cargar el catálogo');
    console.error(err);
  }
}

function subscribeRealtime() {
  supabase
    .channel('public:catalog')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'products' }, () => loadAll())
    .on('postgres_changes', { event: '*', schema: 'public', table: 'promotions' }, () => loadAll())
    .on('postgres_changes', { event: '*', schema: 'public', table: 'categories' }, () => loadAll())
    .on('postgres_changes', { event: '*', schema: 'public', table: 'product_lines' }, () => loadAll())
    .subscribe();
}

function handleCheckoutReturn() {
  const params = new URLSearchParams(window.location.search);
  const status = params.get('checkout');
  const apartadoStatus = params.get('apartado');
  if (status === 'success') {
    Object.keys(cart).forEach(id => delete cart[id]);
    updateCartUI();
    showToast('¡Listo! Tu pedido está pagado — pasa a recogerlo a la tienda.');
  } else if (status === 'cancel') {
    showToast('Pago cancelado. Tu carrito sigue aquí.');
  } else if (apartadoStatus === 'success') {
    Object.keys(cart).forEach(id => delete cart[id]);
    updateCartUI();
    showToast('¡Listo! Tu apartado quedó registrado — paga el resto en tienda en efectivo antes de la fecha límite.');
  } else if (apartadoStatus === 'cancel') {
    showToast('Apartado cancelado. Tu carrito sigue aquí.');
  }
  if (status || apartadoStatus) {
    params.delete('checkout');
    params.delete('apartado');
    const qs = params.toString();
    window.history.replaceState({}, '', window.location.pathname + (qs ? `?${qs}` : ''));
  }
}

buildHeroFloats();
updateCartUI();
handleCheckoutReturn();
loadAll();
subscribeRealtime();
