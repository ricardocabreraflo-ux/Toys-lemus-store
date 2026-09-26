# Rediseño de "Vender" — punto de venta — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reemplazar la pestaña "Vender" (formulario simple + lista fija de
ventas recientes) por una pantalla de inicio con resumen del día, una
pantalla de venta con buscador/cámara que acepta productos del catálogo y
líneas libres en el mismo carrito, una pantalla de confirmación tras cobrar,
y una pantalla de Historial con filtro de fechas — según
`docs/superpowers/specs/2026-09-11-vender-rediseno-design.md`.

**Architecture:** Todo el trabajo vive en tres archivos: una migración
nueva de Supabase que amplía `create_sale_fisica` para aceptar líneas
libres (sin cambios de esquema), y `app/admin.html`/`app/js/admin.js` donde
la pestaña `#tab-sell` pasa de un formulario único a cuatro vistas internas
(`home`/`sale`/`sale-confirm`/`history`) controladas por una función
`setSellView()`, siguiendo el mismo patrón de vistas alternables ya usado
por Conteo (modo manual / modo cámara) y por el resto del panel
(`setActiveTab()`). El buscador y el escaneo de cámara de la pantalla de
venta copian línea por línea el patrón ya construido y ya endurecido en
Conteo (`#count-search`, `startCountCamera()`, etc.) con ids y variables
propias — el spec permite explícitamente copiar en vez de generalizar,
porque el código de Conteo está fuertemente ligado a sus propios ids y a
`COUNT_ITEMS`, y tocarlo arriesgaría una función que ya pasó por varias
rondas de corrección de bugs.

**Tech Stack:** Igual que el resto del proyecto — HTML/CSS/JS vanilla (sin
framework ni bundler), Supabase (Postgres + RPCs `security definer` +
RLS), `BarcodeDetector`/`getUserMedia` nativos del navegador. Sin suite de
pruebas automatizada — cada tarea se verifica a mano en el navegador.

## Global Constraints

- No se crean tablas nuevas ni se cambia el esquema de `sale_items` —
  `product_id` ya acepta `null` y `product_name` ya es texto libre.
- No se agrega ninguna dependencia nueva (ni librería, ni paquete npm).
- No se toca `create_layaway_fisica`, la pestaña Apartados, ni
  `renderSalesDetailReport()` (ya excluye renglones con `product_id` nulo
  de los desgloses por producto/categoría — comportamiento correcto tal
  cual, no se modifica).
- No se agregan botones +/− para editar cantidad en el carrito — repetir
  la búsqueda/escaneo del mismo producto suma cantidad; "Quitar" elimina
  el renglón completo.
- El vendedor no ve ningún monto en pesos en "Tu tienda hoy" — mismo
  criterio que ya usa `renderDashboard()` (ver `app/js/admin.js:283-316`).
- "Cotizaciones" queda fuera de este trabajo — no se agrega ese acceso ni
  ningún soporte para armar una cotización.
- La navegación general del panel (sidebar/bottom-nav, `setActiveTab()`)
  no cambia de estructura — solo se le agregan los dos hooks puntuales que
  cada tarea describe (detener la cámara de Vender al salir de la pestaña,
  y reiniciar la vista de Vender a "inicio" al entrar).
- La migración de la Tarea 1 debe estar aplicada al proyecto de Supabase
  real antes de poder probar de extremo a extremo la Tarea 4 (el carrito
  con línea libre — las Tareas 2 y 3 solo mandan líneas de catálogo, que
  ya funcionan con la función tal como existe hoy) — quien ejecute este
  plan debe confirmar con el humano a cargo que la migración ya corrió
  (por ejemplo con
  `mcp__Supabase__apply_migration` o desde el SQL Editor de Supabase)
  antes de dar por buena la prueba manual de esa tarea.

---

### Task 1: Supabase — `create_sale_fisica` acepta líneas libres

**Files:**
- Create: `supabase/migrations/0024_venta_libre.sql`

**Interfaces:**
- Consumes: nada de tareas anteriores (tarea independiente).
- Produces: `public.create_sale_fisica(p_items jsonb)` — mismo nombre y
  firma que ya existe, comportamiento ampliado. Cada elemento de
  `p_items` puede ser `{ "product_id": "<uuid>", "quantity": N }` (como
  hoy) o `{ "description": "texto", "amount": N }` (nuevo, sin
  `product_id`). Las Tareas 2 y 4 llaman a esta función tal cual, sin
  cambios en cómo se invoca desde el cliente (`supabase.rpc('create_sale_fisica', { p_items })`).

- [ ] **Step 1: Escribir la migración**

Crea `supabase/migrations/0024_venta_libre.sql` con este contenido exacto:

```sql
-- supabase/migrations/0024_venta_libre.sql
-- Amplía create_sale_fisica para aceptar, además de líneas de catálogo,
-- líneas "libres" (una descripción y un monto, sin producto ni efecto en
-- inventario) — ver docs/superpowers/specs/2026-09-11-vender-rediseno-design.md
-- punto 6. No requiere cambios de esquema: sale_items.product_id ya acepta
-- null (se usa cuando un producto de una venta antigua se borra del
-- catálogo) y product_name ya es texto libre.

create or replace function public.create_sale_fisica(p_items jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale_id uuid;
  v_item record;
  v_stock integer;
  v_price numeric(10,2);
  v_cost numeric(10,2);
  v_name text;
  v_total numeric(10,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión para vender';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Agrega al menos un producto';
  end if;

  insert into public.sales (channel, status, payment_method, total, created_by)
  values ('fisica', 'completada', 'efectivo', 0, auth.uid())
  returning id into v_sale_id;

  for v_item in
    select * from jsonb_to_recordset(p_items)
      as x(product_id uuid, quantity integer, description text, amount numeric)
  loop
    if v_item.product_id is not null then
      if v_item.quantity is null or v_item.quantity <= 0 then
        raise exception 'Cantidad inválida';
      end if;

      select stock_fisica, price, cost_price, name
        into v_stock, v_price, v_cost, v_name
        from public.products where id = v_item.product_id for update;

      if v_stock is null then
        raise exception 'Producto no encontrado';
      end if;
      if v_stock < v_item.quantity then
        raise exception 'No hay suficiente stock física de "%" (% disponibles)', v_name, v_stock;
      end if;

      update public.products set stock_fisica = stock_fisica - v_item.quantity where id = v_item.product_id;

      insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
      values (v_sale_id, v_item.product_id, v_name, v_item.quantity, v_price, v_cost);

      v_total := v_total + v_price * v_item.quantity;
    else
      if v_item.description is null or btrim(v_item.description) = '' then
        raise exception 'La línea libre necesita una descripción';
      end if;
      if v_item.amount is null or v_item.amount <= 0 then
        raise exception 'La línea libre necesita un monto mayor a cero';
      end if;

      insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
      values (v_sale_id, null, v_item.description, 1, v_item.amount, 0);

      v_total := v_total + v_item.amount;
    end if;
  end loop;

  update public.sales set total = v_total where id = v_sale_id;

  return v_sale_id;
end;
$$;

revoke all on function public.create_sale_fisica(jsonb) from public;
grant execute on function public.create_sale_fisica(jsonb) to authenticated;
```

- [ ] **Step 2: Revisión manual de la migración (sin base de datos local)**

Este proyecto no corre Supabase local — no hay forma de ejecutar esta
migración automáticamente en esta tarea. En vez de eso:

1. Relee el SQL completo y confirma que:
   - La rama `if v_item.product_id is not null then` es exactamente el
     cuerpo que ya tenía `create_sale_fisica` antes de este cambio (no se
     alteró ningún cálculo de stock, precio o costo de la ruta de
     catálogo).
   - La rama `else` no referencia `v_stock`, `v_price`, `v_cost`, ni
     `v_name` (esas variables son solo de la ruta de catálogo).
   - `jsonb_to_recordset` declara las 4 columnas
     (`product_id uuid, quantity integer, description text, amount numeric`)
     — una fila que solo trae `product_id`/`quantity` deja
     `description`/`amount` en `null` automáticamente, y viceversa; no
     hace falta ningún casteo adicional.
2. Verifica con `grep -n "create_layaway_fisica\|delete_sale\|sale_items_view" supabase/migrations/*.sql app/js/admin.js`
   que ninguna otra función o vista asume que `sale_items.product_id`
   siempre tiene valor (ya se confirmó en el spec que
   `renderSalesDetailReport()` ya filtra `if (!item.product_id) return;`
   — no debe aparecer ningún otro lugar que dependa de lo contrario).
3. Dile al humano a cargo de este plan (quien tiene acceso al MCP de
   Supabase) que esta migración queda lista para aplicarse al proyecto
   real antes de que la Tarea 4 (línea libre) pueda probarse de extremo a
   extremo — no marques esta tarea como bloqueada por eso, solo señala la
   dependencia.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0024_venta_libre.sql
git commit -m "Permitir líneas libres en create_sale_fisica"
```

---

### Task 2: Vender — pantalla de inicio, vistas y carrito/cobrar (base)

**Files:**
- Modify: `app/admin.html` (reemplaza por completo el bloque
  `<section class="tab-panel" id="tab-sell" hidden>...</section>`)
- Modify: `app/js/admin.js` (elimina el bloque
  `// ---------- Vender tab (POS física) ----------` completo —
  actualmente `SELL_CART`, `refreshSellProductOptions()`,
  `renderSellCart()`, `updateSellChange()`, el listener de
  `sell-confirm-btn`, `loadRecentSales()`, `renderRecentSales()` — y lo
  reemplaza por las funciones nuevas de esta tarea; también modifica
  `setActiveTab()` y `loadEverything()`, y elimina las 5 llamadas
  restantes a `refreshSellProductOptions()` fuera del bloque de Vender)

**Interfaces:**
- Consumes: `supabase`, `fmt`, `escapeHtml`, `productById`, `PRODUCTS`,
  `CURRENT_ROLE`, `showToast(msg, isError)`, `setActiveTab(tabKey)`,
  `reloadProducts()`, `renderTable()`, `renderDashboard()` — todas ya
  definidas en `admin.js`. `create_sale_fisica` con el contrato ampliado
  de la Tarea 1.
- Produces: `SELL_CART` (nuevo formato:
  `{ kind: 'product', product_id, quantity } | { kind: 'free', description, amount }`),
  `sellCartTotal()`, `renderSellCart()`, `addToSellCart(productId)`,
  `setSellView(view)` (`'home' | 'sale' | 'sale-confirm' | 'history'`),
  `resetSellView()`, `loadVenderToday()`, `renderSellHome()`,
  `stopSellCamera()` (cuerpo real llega en la Tarea 3; esta tarea define
  la función como no-operación para que `setSellView`/`setActiveTab`
  puedan llamarla desde ya sin error) — la Tarea 3 reemplaza este cuerpo.
  La Tarea 3 consume `addToSellCart`; la Tarea 4 consume `SELL_CART`,
  `renderSellCart()` y `sellCartTotal()`; la Tarea 5 consume
  `setSellView('history')`.

- [ ] **Step 1: Reemplazar el HTML de la pestaña Vender**

En `app/admin.html`, busca este bloque completo (empieza en el comentario
`<!-- ---------- Vender (POS física) ---------- -->` y termina en el
`</section>` que le sigue, justo antes de `<!-- ---------- Pedidos en línea ---------- -->`):

```html
  <!-- ---------- Vender (POS física) ---------- -->
  <section class="tab-panel" id="tab-sell" hidden>
    <div class="grid-head"><h2>Nueva venta en tienda</h2></div>
    <form class="add-form" id="sell-add-form" style="grid-template-columns: 2fr 1fr auto;">
      <div class="field">
        <label for="sell-product">Producto</label>
        <select class="cell-input" id="sell-product" required></select>
      </div>
      <div class="field">
        <label for="sell-qty">Cantidad</label>
        <input class="cell-input" id="sell-qty" type="number" min="1" step="1" value="1" required>
      </div>
      <div class="submit-cell"><button class="btn btn-primary btn-sm" type="submit" id="sell-add-btn">Agregar</button></div>
    </form>

    <div class="table-wrap" style="margin-top:16px;">
      <table class="admin-table">
        <thead><tr><th>Producto</th><th>Cantidad</th><th>Precio</th><th>Subtotal</th><th></th></tr></thead>
        <tbody id="sell-cart-tbody"></tbody>
      </table>
    </div>

    <div class="stat-row" style="margin-top:16px;">
      <div class="stat-tile"><strong id="sell-total">$0.00</strong><span>Total</span></div>
    </div>
    <div class="add-form" style="grid-template-columns: 1fr auto; margin-top:12px;">
      <div class="field">
        <label for="sell-cash">Efectivo recibido (opcional, solo para calcular cambio)</label>
        <input class="cell-input" id="sell-cash" type="number" min="0" step="0.01">
      </div>
      <div class="submit-cell" style="align-items:flex-end;">
        <span id="sell-change" style="color:var(--ink-soft);font-size:0.9rem;"></span>
      </div>
    </div>
    <p class="form-error" id="sell-error"></p>
    <button class="btn btn-primary" type="button" id="sell-confirm-btn" style="margin-top:12px;">Confirmar venta</button>

    <div class="grid-head" style="margin-top:32px;"><h2>Ventas recientes</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <thead><tr><th>Fecha</th><th>Total</th><th id="recent-sales-action-header"></th></tr></thead>
        <tbody id="recent-sales-tbody"></tbody>
      </table>
    </div>
  </section>
```

Reemplázalo con:

```html
  <!-- ---------- Vender (POS física) ---------- -->
  <section class="tab-panel" id="tab-sell" hidden>

    <div id="sell-home">
      <div class="grid-head"><h2>Tu tienda hoy</h2></div>
      <div class="stat-row" id="sell-today-stats">
        <div class="stat-tile"><strong>—</strong><span>Vendido hoy</span></div>
        <div class="stat-tile"><strong>—</strong><span>Ticket promedio</span></div>
        <div class="stat-tile"><strong>—</strong><span>Piezas vendidas hoy</span></div>
        <div class="stat-tile"><strong>—</strong><span>Ventas del día</span></div>
      </div>
      <button class="btn btn-primary" type="button" id="sell-start-btn" style="margin:8px 0 20px;">Registrar venta</button>
      <div style="display:flex; gap:10px; flex-wrap:wrap;">
        <button class="btn btn-ghost btn-sm" type="button" id="sell-goto-history-btn">Historial</button>
        <button class="btn btn-ghost btn-sm" type="button" id="sell-goto-layaways-btn">Apartados</button>
      </div>
    </div>

    <div id="sell-sale" hidden>
      <div class="grid-head">
        <h2>Nueva venta</h2>
        <button class="btn btn-ghost btn-sm" type="button" id="sell-sale-back-btn">‹ Cancelar</button>
      </div>

      <div class="autocomplete-wrap" id="sell-search-wrap">
        <input class="cell-input" id="sell-search" type="text" autocomplete="off" placeholder="Escanea el código o escribe el nombre del producto…">
        <div class="autocomplete-list" id="sell-suggestions" hidden></div>
      </div>
      <button class="btn btn-sm" type="button" id="sell-camera-btn" hidden style="margin-top:8px;">Escanear con cámara</button>
      <video id="sell-camera-video" autoplay playsinline muted hidden style="width:100%;max-width:360px;margin-top:8px;border-radius:10px;background:#000;"></video>

      <button class="btn btn-ghost btn-sm" type="button" id="sell-free-toggle-btn" style="margin-top:12px;">+ Agregar línea libre</button>
      <div class="add-form" id="sell-free-form" hidden style="grid-template-columns: 2fr 1fr auto; margin-top:8px;">
        <div class="field">
          <label for="sell-free-desc">Descripción</label>
          <input class="cell-input" id="sell-free-desc" type="text">
        </div>
        <div class="field">
          <label for="sell-free-amount">Monto</label>
          <input class="cell-input" id="sell-free-amount" type="number" min="0.01" step="0.01">
        </div>
        <div class="submit-cell"><button class="btn btn-primary btn-sm" type="button" id="sell-free-add-btn">Agregar</button></div>
      </div>
      <p class="form-error" id="sell-free-error"></p>

      <div class="table-wrap" style="margin-top:16px;">
        <table class="admin-table">
          <thead><tr><th>Producto</th><th>Cantidad</th><th>Precio</th><th>Subtotal</th><th></th></tr></thead>
          <tbody id="sell-cart-tbody"></tbody>
        </table>
      </div>

      <div class="stat-row" style="margin-top:16px;">
        <div class="stat-tile"><strong id="sell-total">$0.00</strong><span>Total</span></div>
      </div>
      <div class="add-form" style="grid-template-columns: 1fr auto; margin-top:12px;">
        <div class="field">
          <label for="sell-cash">Efectivo recibido (opcional, solo para calcular cambio)</label>
          <input class="cell-input" id="sell-cash" type="number" min="0" step="0.01">
        </div>
        <div class="submit-cell" style="align-items:flex-end;">
          <span id="sell-change" style="color:var(--ink-soft);font-size:0.9rem;"></span>
        </div>
      </div>
      <p class="form-error" id="sell-error"></p>
      <button class="btn btn-primary" type="button" id="sell-confirm-btn" style="margin-top:12px;">Cobrar</button>
    </div>

    <div id="sell-sale-confirm" hidden>
      <div class="grid-head"><h2>Venta registrada</h2></div>
      <div class="table-wrap">
        <table class="admin-table">
          <thead><tr><th>Producto</th><th>Cantidad</th><th>Subtotal</th></tr></thead>
          <tbody id="sell-confirm-tbody"></tbody>
        </table>
      </div>
      <div class="stat-row" style="margin-top:16px;">
        <div class="stat-tile"><strong id="sell-confirm-total">$0.00</strong><span>Total</span></div>
      </div>
      <p id="sell-confirm-change" style="color:var(--ink-soft);"></p>
      <div style="display:flex; gap:10px; margin-top:12px;">
        <button class="btn btn-primary" type="button" id="sell-confirm-new-btn">Nueva venta</button>
        <button class="btn btn-ghost" type="button" id="sell-confirm-history-btn">Ver historial</button>
      </div>
    </div>

    <div id="sell-history" hidden>
      <div class="grid-head">
        <h2>Historial de ventas</h2>
        <button class="btn btn-ghost btn-sm" type="button" id="sell-history-back-btn">‹ Volver</button>
      </div>
      <div class="add-form" style="grid-template-columns: 1fr 1fr;">
        <div class="field">
          <label for="sell-history-from">Desde</label>
          <input class="cell-input" id="sell-history-from" type="date">
        </div>
        <div class="field">
          <label for="sell-history-to">Hasta</label>
          <input class="cell-input" id="sell-history-to" type="date">
        </div>
      </div>
      <p class="form-error" id="sell-history-error"></p>
      <div class="table-wrap" style="margin-top:16px;">
        <table class="admin-table">
          <thead><tr><th>Fecha</th><th>Total</th><th id="sell-history-action-header"></th></tr></thead>
          <tbody id="sell-history-tbody"></tbody>
        </table>
      </div>
    </div>

  </section>
```

Ningún otro archivo CSS necesita cambios: `.add-form[hidden]`,
`.stat-row[hidden]`, `.autocomplete-list[hidden]` ya tienen su regla
`[hidden] { display: none; }` en `app/css/styles.css`, y los cuatro
`<div>` de vista (`#sell-home`, `#sell-sale`, `#sell-sale-confirm`,
`#sell-history`) no reciben ninguna regla de `display` propia, así que el
`[hidden]` por defecto del navegador ya los oculta correctamente — no
repitas el error ya corregido antes en este proyecto de ponerle a un
elemento oculto con `hidden` un `display` propio sin su regla
`[hidden]` a juego (por eso `#sell-camera-video` tampoco lleva
`display` en su `style` inline, igual que `#count-camera-video`).

- [ ] **Step 2: Eliminar el bloque de JS viejo de Vender**

En `app/js/admin.js`, borra por completo este bloque (desde el comentario
`// ---------- Vender tab (POS física) ----------` hasta la línea en
blanco antes de `// ---------- Pedidos tab (online orders) ----------`):

```javascript
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

document.getElementById('sell-confirm-btn').addEventListener('click', async (e) => {
  const btn = e.currentTarget;
  const errEl = document.getElementById('sell-error');
  errEl.textContent = '';
  if (SELL_CART.length === 0) { errEl.textContent = 'Agrega al menos un producto.'; return; }

  btn.disabled = true;
  try {
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
    renderDashboard();
  } finally {
    btn.disabled = false;
  }
});

async function loadRecentSales() {
  const { data, error } = await supabase
    .from('sales')
    .select('id, total, created_at')
    .eq('channel', 'fisica')
    .neq('payment_method', 'apartado')
    .order('created_at', { ascending: false })
    .limit(20);
  if (error) { console.error(error); return; }
  RECENT_PHYSICAL_SALES = data;
}

function renderRecentSales() {
  document.getElementById('recent-sales-action-header').hidden = CURRENT_ROLE !== 'admin';
  const tbody = document.getElementById('recent-sales-tbody');
  tbody.innerHTML = RECENT_PHYSICAL_SALES.length === 0
    ? `<tr><td colspan="3" style="color:var(--ink-soft);">Sin ventas físicas todavía.</td></tr>`
    : RECENT_PHYSICAL_SALES.map(s => `
      <tr data-id="${s.id}">
        <td>${new Date(s.created_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' })}</td>
        <td>${fmt.format(s.total)}</td>
        <td>
          ${CURRENT_ROLE === 'admin' ? `<button class="icon-mini danger" data-role="sale-delete" type="button" aria-label="Eliminar venta">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
          </button>` : ''}
        </td>
      </tr>`).join('');
  tbody.querySelectorAll('[data-role="sale-delete"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      if (!askForDeletePin('¿Eliminar esta venta? El stock vendido regresa al inventario.')) return;
      const { error } = await supabase.rpc('delete_sale', { p_sale_id: id });
      if (error) { showToast(error.message, true); return; }
      showToast('Venta eliminada');
      await loadRecentSales();
      renderRecentSales();
      await reloadProducts();
      renderTable();
      refreshSellProductOptions();
      renderDashboard();
    });
  });
}
```

Deja el comentario `// ---------- Pedidos tab (online orders) ----------`
y todo lo que sigue intacto — el bloque de arriba es lo único que se
borra en este paso.

- [ ] **Step 3: Agregar las funciones nuevas de Vender**

En el mismo lugar donde estaba el bloque borrado (justo antes de
`// ---------- Pedidos tab (online orders) ----------`), agrega:

```javascript
// ---------- Vender tab (POS física) ----------

let SELL_CART = []; // [{ kind: 'product', product_id, quantity } | { kind: 'free', description, amount }]
let VENDER_TODAY = { total: 0, count: 0, pieces: 0 };
let LAST_SELL_RECEIPT = null; // { lines: [{label, quantity, subtotal}], total, cash }

function sellCartTotal() {
  return SELL_CART.reduce((s, item) => {
    if (item.kind === 'product') return s + (productById(item.product_id)?.price || 0) * item.quantity;
    return s + item.amount;
  }, 0);
}

function addToSellCart(productId) {
  const existing = SELL_CART.find(i => i.kind === 'product' && i.product_id === productId);
  if (existing) existing.quantity += 1;
  else SELL_CART.push({ kind: 'product', product_id: productId, quantity: 1 });
  renderSellCart();
}

function renderSellCart() {
  const tbody = document.getElementById('sell-cart-tbody');
  if (SELL_CART.length === 0) {
    tbody.innerHTML = `<tr><td colspan="5" style="color:var(--ink-soft);">Carrito vacío.</td></tr>`;
  } else {
    tbody.innerHTML = SELL_CART.map((item, idx) => {
      if (item.kind === 'product') {
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
      }
      return `<tr>
        <td>${escapeHtml(item.description)}</td>
        <td>1</td>
        <td>${fmt.format(item.amount)}</td>
        <td>${fmt.format(item.amount)}</td>
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
  document.getElementById('sell-total').textContent = fmt.format(sellCartTotal());
  updateSellChange();
}

function updateSellChange() {
  const total = sellCartTotal();
  const cash = Number(document.getElementById('sell-cash').value) || 0;
  const changeEl = document.getElementById('sell-change');
  changeEl.textContent = cash > 0 ? `Cambio: ${fmt.format(Math.max(0, cash - total))}` : '';
}
document.getElementById('sell-cash').addEventListener('input', updateSellChange);

document.getElementById('sell-confirm-btn').addEventListener('click', async (e) => {
  const btn = e.currentTarget;
  const errEl = document.getElementById('sell-error');
  errEl.textContent = '';
  if (SELL_CART.length === 0) { errEl.textContent = 'Agrega al menos un producto.'; return; }

  btn.disabled = true;
  try {
    const p_items = SELL_CART.map(item => item.kind === 'product'
      ? { product_id: item.product_id, quantity: item.quantity }
      : { description: item.description, amount: item.amount });
    const { error } = await supabase.rpc('create_sale_fisica', { p_items });
    if (error) { errEl.textContent = error.message; return; }

    LAST_SELL_RECEIPT = {
      lines: SELL_CART.map(item => item.kind === 'product'
        ? { label: productById(item.product_id)?.name || '—', quantity: item.quantity, subtotal: (productById(item.product_id)?.price || 0) * item.quantity }
        : { label: item.description, quantity: 1, subtotal: item.amount }),
      total: sellCartTotal(),
      cash: Number(document.getElementById('sell-cash').value) || 0,
    };

    showToast('Venta registrada');
    SELL_CART = [];
    document.getElementById('sell-cash').value = '';
    renderSellCart();
    await reloadProducts();
    renderTable();
    await loadVenderToday();
    renderSellHome();
    renderDashboard();
    renderSellConfirm();
    setSellView('sale-confirm');
  } finally {
    btn.disabled = false;
  }
});

function renderSellConfirm() {
  const receipt = LAST_SELL_RECEIPT;
  const tbody = document.getElementById('sell-confirm-tbody');
  tbody.innerHTML = receipt.lines.map(l => `
    <tr>
      <td>${escapeHtml(l.label)}</td>
      <td>${l.quantity}</td>
      <td>${fmt.format(l.subtotal)}</td>
    </tr>`).join('');
  document.getElementById('sell-confirm-total').textContent = fmt.format(receipt.total);
  const changeEl = document.getElementById('sell-confirm-change');
  changeEl.textContent = receipt.cash > 0
    ? `Efectivo recibido: ${fmt.format(receipt.cash)} — Cambio: ${fmt.format(Math.max(0, receipt.cash - receipt.total))}`
    : '';
}

async function loadVenderToday() {
  const startOfToday = new Date(new Date().toDateString()).toISOString();
  const { data: sales, error: salesErr } = await supabase
    .from('sales')
    .select('id, total')
    .eq('channel', 'fisica')
    .neq('payment_method', 'apartado')
    .gte('created_at', startOfToday);
  if (salesErr) { console.error(salesErr); return; }

  let pieces = 0;
  if (sales.length > 0) {
    const { data: items, error: itemsErr } = await supabase
      .from('sale_items_view')
      .select('sale_id, quantity')
      .in('sale_id', sales.map(s => s.id));
    if (itemsErr) { console.error(itemsErr); return; }
    pieces = items.reduce((s, i) => s + i.quantity, 0);
  }

  VENDER_TODAY = {
    total: sales.reduce((s, r) => s + Number(r.total), 0),
    count: sales.length,
    pieces,
  };
}

function renderSellHome() {
  const isAdmin = CURRENT_ROLE === 'admin';
  const statsEl = document.getElementById('sell-today-stats');
  const avgTicket = VENDER_TODAY.count > 0 ? VENDER_TODAY.total / VENDER_TODAY.count : null;
  if (isAdmin) {
    statsEl.innerHTML = `
      <div class="stat-tile"><strong>${fmt.format(VENDER_TODAY.total)}</strong><span>Vendido hoy</span></div>
      <div class="stat-tile"><strong>${avgTicket === null ? '—' : fmt.format(avgTicket)}</strong><span>Ticket promedio</span></div>
      <div class="stat-tile"><strong>${VENDER_TODAY.pieces}</strong><span>Piezas vendidas hoy</span></div>
      <div class="stat-tile"><strong>${VENDER_TODAY.count}</strong><span>Ventas del día</span></div>`;
  } else {
    statsEl.innerHTML = `
      <div class="stat-tile"><strong>${VENDER_TODAY.pieces}</strong><span>Piezas vendidas hoy</span></div>
      <div class="stat-tile"><strong>${VENDER_TODAY.count}</strong><span>Ventas del día</span></div>`;
  }
}

function stopSellCamera() {
  // La Tarea 3 reemplaza este cuerpo por el manejo real de la cámara.
  // Se define aquí, sin operación, para que setSellView()/setActiveTab()
  // ya puedan llamarla sin error antes de que exista la cámara.
}

function setSellView(view) {
  document.getElementById('sell-home').hidden = view !== 'home';
  document.getElementById('sell-sale').hidden = view !== 'sale';
  document.getElementById('sell-sale-confirm').hidden = view !== 'sale-confirm';
  document.getElementById('sell-history').hidden = view !== 'history';
  if (view !== 'sale') stopSellCamera();
}

function resetSellView() {
  SELL_CART = [];
  document.getElementById('sell-search').value = '';
  document.getElementById('sell-suggestions').hidden = true;
  document.getElementById('sell-suggestions').innerHTML = '';
  document.getElementById('sell-free-form').hidden = true;
  document.getElementById('sell-free-error').textContent = '';
  document.getElementById('sell-error').textContent = '';
  document.getElementById('sell-cash').value = '';
  renderSellCart();
  setSellView('home');
}

document.getElementById('sell-start-btn').addEventListener('click', () => setSellView('sale'));
document.getElementById('sell-sale-back-btn').addEventListener('click', () => resetSellView());
document.getElementById('sell-goto-history-btn').addEventListener('click', () => setSellView('history'));
document.getElementById('sell-goto-layaways-btn').addEventListener('click', () => setActiveTab('layaways'));
document.getElementById('sell-confirm-new-btn').addEventListener('click', () => resetSellView());
document.getElementById('sell-confirm-history-btn').addEventListener('click', () => setSellView('history'));
document.getElementById('sell-history-back-btn').addEventListener('click', () => setSellView('home'));
```

`stopSellCamera()` queda como una función vacía en esta tarea a propósito
— la Tarea 3 la reemplaza por el cuerpo real. No falta ningún cierre de
llave ni referencia rota: nada más en esta tarea depende de que la cámara
realmente se detenga.

- [ ] **Step 4: Enganchar Vender a `setActiveTab()` y a `loadEverything()`**

En `app/js/admin.js`, busca:

```javascript
function setActiveTab(tabKey) {
  document.querySelectorAll('.tab-btn').forEach(b => b.setAttribute('aria-selected', String(b.dataset.tab === tabKey)));
  document.querySelectorAll('.tab-panel').forEach(p => { p.hidden = p.id !== `tab-${tabKey}`; });
  if (tabKey !== 'count') stopCountCamera();
  closeMoreSheet();
}
```

Reemplázalo con:

```javascript
function setActiveTab(tabKey) {
  document.querySelectorAll('.tab-btn').forEach(b => b.setAttribute('aria-selected', String(b.dataset.tab === tabKey)));
  document.querySelectorAll('.tab-panel').forEach(p => { p.hidden = p.id !== `tab-${tabKey}`; });
  if (tabKey !== 'count') stopCountCamera();
  if (tabKey !== 'sell') stopSellCamera();
  if (tabKey === 'sell') resetSellView();
  closeMoreSheet();
}
```

Ahora busca, dentro de `loadEverything()`:

```javascript
    await loadLayaways();
    await loadRecentSales();

    initInventoryForm();
```

Reemplázalo con:

```javascript
    await loadLayaways();
    await loadVenderToday();

    initInventoryForm();
```

Y más abajo, dentro de la misma función, busca:

```javascript
    renderLayaways();
    renderRecentSales();
    renderDashboard();
```

Reemplázalo con:

```javascript
    renderLayaways();
    renderSellHome();
    renderDashboard();
```

- [ ] **Step 5: Quitar las llamadas restantes a `refreshSellProductOptions()`**

Esa función ya no existe (se borró en el Step 2 junto con el resto del
bloque viejo, que ya se llevó consigo 3 de sus 7 llamadas originales) —
pero todavía se llama desde 4 lugares fuera de ese bloque. Ejecuta:

```bash
grep -n "refreshSellProductOptions" app/js/admin.js
```

Debe listar exactamente 4 líneas (una por cada llamada, sin ninguna
definición). Borra cada una de esas 4 líneas — son siempre una línea
completa de la forma `    refreshSellProductOptions();` dentro de un
bloque que también llama a `refreshTransferProductOptions()` y/o
`refreshLayawayProductOptions()` y `renderDashboard()`; no borres esas
otras llamadas, solo la línea de `refreshSellProductOptions();`. Vuelve a
correr el mismo `grep` y confirma que ya no imprime nada.

También queda huérfana la variable `RECENT_PHYSICAL_SALES` — su única
declaración (fuera del bloque borrado en el Step 2) es esta línea cerca
del inicio del archivo:

```javascript
let RECENT_PHYSICAL_SALES = [];
```

Bórrala. Ejecuta `grep -n "RECENT_PHYSICAL_SALES" app/js/admin.js` y
confirma que ya no imprime nada.

- [ ] **Step 6: Verificación manual**

Ejecuta `node --check app/js/admin.js` (debe salir sin error — confirma
que no quedó ninguna llave o paréntesis sin cerrar tras los borrados).

Luego, en el navegador (con sesión de admin):
1. Entra a Vender: debe verse la pantalla de inicio con "Tu tienda hoy" —
   al principio con guiones (`—`) y, tras un instante, con números reales
   (`renderSellHome()` corre después de `loadVenderToday()` dentro de
   `loadEverything()`).
2. Con el usuario vendedor: "Tu tienda hoy" debe mostrar solo "Piezas
   vendidas hoy" y "Ventas del día", sin ningún monto en pesos.
3. Toca "Registrar venta": debe abrir la pantalla de venta (buscador
   visible, carrito vacío, sin productos que agregar todavía — el
   buscador en sí llega en la Tarea 3). Presiona "Cobrar" con el carrito
   vacío: debe mostrar "Agrega al menos un producto." sin llamar a
   Supabase.
4. Toca "‹ Cancelar": debe volver a la pantalla de inicio.
5. Toca "Historial": debe abrir esa vista (aunque todavía sin datos ni
   filtro funcional — eso llega en la Tarea 5); toca "‹ Volver" y
   confirma que regresa a la pantalla de inicio.
6. Toca "Apartados": debe salir de Vender por completo y abrir la
   pestaña Apartados ya existente, sin ningún cambio ahí.
7. Cambia a cualquier otra pestaña (por ejemplo Inventario) y regresa a
   Vender: debe volver a mostrar la pantalla de inicio (no quedarte en
   "sale" ni en "history").

- [ ] **Step 7: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Rediseñar Vender: pantalla de inicio, vistas y carrito base"
```

---

### Task 3: Vender — buscador y escaneo de cámara

**Files:**
- Modify: `app/js/admin.js` (agrega el buscador y la cámara de la
  pantalla de venta, y reemplaza el cuerpo vacío de `stopSellCamera()` de
  la Tarea 2)

**Interfaces:**
- Consumes: `addToSellCart(productId)`, `PRODUCTS`, `showToast(msg, isError)`,
  todas de la Tarea 2 o anteriores.
- Produces: `stopSellCamera()` con su cuerpo real (ya declarada como
  no-operación en la Tarea 2; esta tarea la reemplaza por completo).
  Nada más de esta tarea es consumido por tareas posteriores.

- [ ] **Step 1: Reemplazar el `stopSellCamera()` vacío y agregar el buscador y la cámara**

En `app/js/admin.js`, busca el `stopSellCamera()` vacío agregado en la
Tarea 2:

```javascript
function stopSellCamera() {
  // La Tarea 3 reemplaza este cuerpo por el manejo real de la cámara.
  // Se define aquí, sin operación, para que setSellView()/setActiveTab()
  // ya puedan llamarla sin error antes de que exista la cámara.
}
```

Reemplázalo con (copia línea por línea el patrón ya probado de Conteo —
mismas variables y misma lógica, con nombres e ids propios de Vender, tal
como permite el punto 7 del spec):

```javascript
function renderSellSuggestions(query) {
  const list = document.getElementById('sell-suggestions');
  const q = query.trim().toLowerCase();
  if (!q) { list.hidden = true; list.innerHTML = ''; return; }
  const matches = PRODUCTS.filter(p => p.name.toLowerCase().includes(q)).slice(0, 8);
  if (matches.length === 0) { list.hidden = true; list.innerHTML = ''; return; }
  list.innerHTML = matches.map(p =>
    `<button type="button" class="autocomplete-item" data-id="${p.id}">${escapeHtml(p.name)}</button>`
  ).join('');
  list.hidden = false;
}

document.getElementById('sell-search').addEventListener('input', (e) => {
  const raw = e.target.value;
  const q = raw.trim().toLowerCase();
  const list = document.getElementById('sell-suggestions');
  if (!q) { list.hidden = true; list.innerHTML = ''; return; }

  const exact = PRODUCTS.find(p => (p.code || '').toLowerCase() === q);
  const ambiguous = exact && PRODUCTS.some(p => {
    const c = (p.code || '').toLowerCase();
    return c !== q && c.startsWith(q);
  });
  if (exact && !ambiguous) {
    addToSellCart(exact.id);
    e.target.value = '';
    list.hidden = true;
    list.innerHTML = '';
    return;
  }
  renderSellSuggestions(raw);
});

document.getElementById('sell-search').addEventListener('keydown', (e) => {
  if (e.key !== 'Enter') return;
  const raw = e.target.value.trim();
  if (!raw) return;
  const list = document.getElementById('sell-suggestions');
  const exactOnEnter = PRODUCTS.find(p => (p.code || '').toLowerCase() === raw.toLowerCase());
  if (exactOnEnter) {
    addToSellCart(exactOnEnter.id);
    e.target.value = '';
    list.hidden = true;
    list.innerHTML = '';
    return;
  }
  if (!list.hidden && list.children.length > 0) return; // hay coincidencias por nombre, se elige con clic
  showToast('Producto no encontrado', true);
  e.target.value = '';
  list.hidden = true;
  list.innerHTML = '';
});

document.getElementById('sell-suggestions').addEventListener('click', (e) => {
  const btn = e.target.closest('[data-id]');
  if (!btn) return;
  addToSellCart(btn.dataset.id);
  document.getElementById('sell-search').value = '';
  document.getElementById('sell-suggestions').hidden = true;
  document.getElementById('sell-suggestions').innerHTML = '';
  document.getElementById('sell-search').focus();
});

document.addEventListener('click', (e) => {
  const wrap = document.getElementById('sell-search-wrap');
  const list = document.getElementById('sell-suggestions');
  if (!list.hidden && !wrap.contains(e.target)) list.hidden = true;
});

let sellCameraStream = null;
let sellBarcodeDetector = null;
let sellScanLoopActive = false;
let lastSellScannedCode = null;
let lastSellScannedAt = 0;
let sellCameraGen = 0;

if ('BarcodeDetector' in window) {
  document.getElementById('sell-camera-btn').hidden = false;
}

function handleSellScanValue(raw) {
  const q = raw.trim().toLowerCase();
  const match = PRODUCTS.find(p => (p.code || '').toLowerCase() === q);
  if (match) { addToSellCart(match.id); return; }
  showToast('Producto no encontrado', true);
}

async function scanSellCameraLoop(myGen) {
  const video = document.getElementById('sell-camera-video');
  let failureCount = 0;
  while (sellScanLoopActive && myGen === sellCameraGen) {
    try {
      const codes = await sellBarcodeDetector.detect(video);
      if (!sellScanLoopActive || myGen !== sellCameraGen) break;
      if (codes.length > 0) {
        const raw = codes[0].rawValue;
        const now = Date.now();
        if (raw !== lastSellScannedCode || now - lastSellScannedAt > 1500) {
          lastSellScannedCode = raw;
          lastSellScannedAt = now;
          handleSellScanValue(raw);
        }
      }
      failureCount = 0;
    } catch (err) {
      failureCount++;
      if (failureCount === 1 || failureCount % 20 === 0) {
        console.error('Vender: fallo en detect() de código de barras', err);
      }
    }
    await new Promise(resolve => setTimeout(resolve, 250));
  }
}

async function startSellCamera() {
  const myGen = ++sellCameraGen;
  const btn = document.getElementById('sell-camera-btn');
  btn.disabled = true;

  if (!sellBarcodeDetector) {
    try {
      sellBarcodeDetector = new BarcodeDetector();
    } catch (err) {
      showToast('No se pudo iniciar el lector de códigos', true);
      console.error(err);
      if (myGen === sellCameraGen) btn.disabled = false;
      return;
    }
  }

  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
  } catch (err) {
    showToast('No se pudo acceder a la cámara', true);
    console.error(err);
    if (myGen === sellCameraGen) btn.disabled = false;
    return;
  }
  if (myGen !== sellCameraGen) {
    stream.getTracks().forEach(track => track.stop());
    return;
  }
  sellCameraStream = stream;
  const video = document.getElementById('sell-camera-video');
  video.srcObject = sellCameraStream;
  video.hidden = false;
  btn.textContent = 'Cerrar cámara';
  btn.disabled = false;
  sellScanLoopActive = true;
  scanSellCameraLoop(myGen);
}

function stopSellCamera() {
  sellCameraGen++;
  sellScanLoopActive = false;
  lastSellScannedCode = null;
  if (sellCameraStream) {
    sellCameraStream.getTracks().forEach(track => track.stop());
    sellCameraStream = null;
  }
  const video = document.getElementById('sell-camera-video');
  video.srcObject = null;
  video.hidden = true;
  const btn = document.getElementById('sell-camera-btn');
  btn.textContent = 'Escanear con cámara';
  btn.disabled = false;
}

document.getElementById('sell-camera-btn').addEventListener('click', () => {
  if (sellCameraStream) stopSellCamera();
  else startSellCamera();
});
```

- [ ] **Step 2: Verificación manual**

Requiere que la migración de la Tarea 1 ya esté aplicada al proyecto de
Supabase (confírmalo con el humano a cargo antes de seguir).

Ejecuta `node --check app/js/admin.js`. Luego, con sesión de admin:
1. En Vender → "Registrar venta", escribe el nombre de un producto:
   deben aparecer sugerencias; haz clic en una y confirma que se agrega
   al carrito con cantidad 1.
2. Escribe el código exacto de un producto y presiona Enter: debe
   agregarse directo, sin mostrar sugerencias.
3. Repite la búsqueda o el clic del mismo producto: la cantidad en el
   carrito debe subir a 2 (no duplicar el renglón).
4. Escribe un código que no exista y presiona Enter: debe mostrar
   "Producto no encontrado" y no agregar nada.
5. Desde un celular Android con Chrome, toca "Escanear con cámara",
   apunta a un código de barras real: debe agregarse al carrito
   automáticamente.
6. Con el carrito con al menos un producto, presiona "Cobrar": debe
   completarse la venta, mostrar la pantalla de confirmación con el
   resumen correcto, y "Tu tienda hoy" debe reflejar la venta nueva al
   volver a "Nueva venta".
7. Cambia a otra pestaña mientras la cámara está abierta: debe apagarse
   (mismo mecanismo ya usado por Conteo).

- [ ] **Step 3: Commit**

```bash
git add app/js/admin.js
git commit -m "Agregar buscador y escaneo de cámara a Vender"
```

---

### Task 4: Vender — línea libre

**Files:**
- Modify: `app/js/admin.js` (agrega el mini-formulario de línea libre)

**Interfaces:**
- Consumes: `SELL_CART`, `renderSellCart()` de la Tarea 2 —
  `SELL_CART.push({ kind: 'free', description, amount })` es el único
  cambio de estado que hace esta tarea.
- Produces: nada consumido por otra tarea de este plan.

- [ ] **Step 1: Agregar el mini-formulario de línea libre**

En `app/js/admin.js`, en cualquier punto dentro de la sección
`// ---------- Vender tab (POS física) ----------` (por ejemplo, justo
después de la función `addToSellCart`), agrega:

```javascript
document.getElementById('sell-free-toggle-btn').addEventListener('click', () => {
  const form = document.getElementById('sell-free-form');
  form.hidden = !form.hidden;
  document.getElementById('sell-free-error').textContent = '';
  if (!form.hidden) document.getElementById('sell-free-desc').focus();
});

document.getElementById('sell-free-add-btn').addEventListener('click', () => {
  const descEl = document.getElementById('sell-free-desc');
  const amountEl = document.getElementById('sell-free-amount');
  const errEl = document.getElementById('sell-free-error');
  const description = descEl.value.trim();
  const amount = Number(amountEl.value);
  errEl.textContent = '';
  if (!description) { errEl.textContent = 'Escribe una descripción.'; return; }
  if (!(amount > 0)) { errEl.textContent = 'El monto debe ser mayor a cero.'; return; }
  SELL_CART.push({ kind: 'free', description, amount });
  descEl.value = '';
  amountEl.value = '';
  document.getElementById('sell-free-form').hidden = true;
  renderSellCart();
});
```

- [ ] **Step 2: Verificación manual**

Requiere la migración de la Tarea 1 ya aplicada. Con sesión de admin:
1. En "Nueva venta", toca "+ Agregar línea libre": debe abrir el
   mini-formulario.
2. Deja la descripción vacía y presiona "Agregar": debe mostrar "Escribe
   una descripción." sin agregar nada.
3. Escribe una descripción y deja el monto vacío o en 0: debe mostrar
   "El monto debe ser mayor a cero." sin agregar nada.
4. Escribe "Envoltura de regalo" y monto 30, presiona "Agregar": debe
   aparecer en el carrito con cantidad 1 y subtotal $30.00, y el
   mini-formulario debe cerrarse.
5. Agrega también un producto del catálogo (Tarea 3) al mismo carrito y
   presiona "Cobrar": la venta debe completarse con ambas líneas, y el
   inventario del producto de catálogo debe descontarse mientras que la
   línea libre no afecta ningún stock.
6. En Reportes (pestaña "Negocio → Reportes", solo admin), confirma que
   el total del mes incluye esta venta, y que el desglose por producto no
   lista "Envoltura de regalo" como si fuera un producto del catálogo
   (mismo comportamiento ya existente para productos borrados).

- [ ] **Step 3: Commit**

```bash
git add app/js/admin.js
git commit -m "Agregar línea libre al carrito de Vender"
```

---

### Task 5: Vender — pantalla de Historial con filtro de fechas

**Files:**
- Modify: `app/js/admin.js` (agrega la carga y el filtrado de Historial;
  también hace el único cambio de infraestructura de este plan:
  `app/sw.js`)
- Modify: `app/sw.js` (bump de `CACHE_NAME`)

**Interfaces:**
- Consumes: `supabase`, `fmt`, `CURRENT_ROLE`, `showToast`,
  `askForDeletePin`, `reloadProducts`, `renderTable`, `renderDashboard`,
  `loadVenderToday`, `renderSellHome`, `setSellView` — todas de tareas
  anteriores o ya existentes.
- Produces: `loadPhysicalSalesRange(fromStr, toStr)`,
  `loadAndRenderSellHistory()`, `renderSellHistory()`, `todayDateStr()` —
  nada de esto es consumido por otra tarea de este plan (es la última).

- [ ] **Step 1: Agregar la carga y el render del Historial**

En `app/js/admin.js`, agrega esto dentro de la sección de Vender (por
ejemplo, al final, justo antes de
`// ---------- Pedidos tab (online orders) ----------`):

```javascript
function todayDateStr() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

let SELL_HISTORY_ROWS = [];

async function loadPhysicalSalesRange(fromStr, toStr) {
  const fromISO = new Date(`${fromStr}T00:00:00`).toISOString();
  const toISO = new Date(`${toStr}T23:59:59.999`).toISOString();
  const { data, error } = await supabase
    .from('sales')
    .select('id, total, created_at')
    .eq('channel', 'fisica')
    .neq('payment_method', 'apartado')
    .gte('created_at', fromISO)
    .lte('created_at', toISO)
    .order('created_at', { ascending: false });
  if (error) { console.error(error); return null; }
  return data;
}

function renderSellHistory() {
  document.getElementById('sell-history-action-header').hidden = CURRENT_ROLE !== 'admin';
  const tbody = document.getElementById('sell-history-tbody');
  tbody.innerHTML = SELL_HISTORY_ROWS.length === 0
    ? `<tr><td colspan="3" style="color:var(--ink-soft);">Sin ventas físicas en este rango.</td></tr>`
    : SELL_HISTORY_ROWS.map(s => `
      <tr data-id="${s.id}">
        <td>${new Date(s.created_at).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' })}</td>
        <td>${fmt.format(s.total)}</td>
        <td>
          ${CURRENT_ROLE === 'admin' ? `<button class="icon-mini danger" data-role="sale-delete" type="button" aria-label="Eliminar venta">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>
          </button>` : ''}
        </td>
      </tr>`).join('');
  tbody.querySelectorAll('[data-role="sale-delete"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.closest('tr').dataset.id;
      if (!askForDeletePin('¿Eliminar esta venta? El stock vendido regresa al inventario.')) return;
      const { error } = await supabase.rpc('delete_sale', { p_sale_id: id });
      if (error) { showToast(error.message, true); return; }
      showToast('Venta eliminada');
      await loadAndRenderSellHistory();
      await reloadProducts();
      renderTable();
      await loadVenderToday();
      renderSellHome();
      renderDashboard();
    });
  });
}

async function loadAndRenderSellHistory() {
  const fromEl = document.getElementById('sell-history-from');
  const toEl = document.getElementById('sell-history-to');
  const errEl = document.getElementById('sell-history-error');
  errEl.textContent = '';
  if (fromEl.value && toEl.value && fromEl.value > toEl.value) {
    errEl.textContent = 'La fecha "Desde" no puede ser posterior a "Hasta".';
    return;
  }
  const rows = await loadPhysicalSalesRange(fromEl.value, toEl.value);
  if (rows === null) { errEl.textContent = 'No se pudo cargar el historial.'; return; }
  SELL_HISTORY_ROWS = rows;
  renderSellHistory();
}

document.getElementById('sell-history-from').addEventListener('change', loadAndRenderSellHistory);
document.getElementById('sell-history-to').addEventListener('change', loadAndRenderSellHistory);
```

- [ ] **Step 2: Hacer que `setSellView('history')` cargue el rango de hoy por defecto**

En `app/js/admin.js`, busca la función `setSellView` agregada en la
Tarea 2:

```javascript
function setSellView(view) {
  document.getElementById('sell-home').hidden = view !== 'home';
  document.getElementById('sell-sale').hidden = view !== 'sale';
  document.getElementById('sell-sale-confirm').hidden = view !== 'sale-confirm';
  document.getElementById('sell-history').hidden = view !== 'history';
  if (view !== 'sale') stopSellCamera();
}
```

Reemplázala con:

```javascript
function setSellView(view) {
  document.getElementById('sell-home').hidden = view !== 'home';
  document.getElementById('sell-sale').hidden = view !== 'sale';
  document.getElementById('sell-sale-confirm').hidden = view !== 'sale-confirm';
  document.getElementById('sell-history').hidden = view !== 'history';
  if (view !== 'sale') stopSellCamera();
  if (view === 'history') {
    const fromEl = document.getElementById('sell-history-from');
    const toEl = document.getElementById('sell-history-to');
    if (!fromEl.value) fromEl.value = todayDateStr();
    if (!toEl.value) toEl.value = todayDateStr();
    loadAndRenderSellHistory();
  }
}
```

- [ ] **Step 3: Bump de `CACHE_NAME` en el service worker**

En `app/sw.js`, busca:

```javascript
const CACHE_NAME = 'lemus-shell-v3';
```

Reemplázalo con:

```javascript
const CACHE_NAME = 'lemus-shell-v4';
```

Este proyecto ya tiene el hábito de subir esta versión cuando un deploy
cambia JS/CSS de forma incompatible con la caché vieja (se hizo en el
rediseño del panel) — este plan reestructura por completo el HTML/JS de
la pestaña Vender, así que aplica el mismo criterio aquí, al final del
plan.

- [ ] **Step 4: Verificación manual**

Con sesión de admin:
1. Entra a Vender → "Historial": debe abrir mostrando el rango "Desde" y
   "Hasta" ya puestos en la fecha de hoy, con las ventas físicas de hoy
   listadas.
2. Cambia "Desde" a una fecha de la semana pasada: la lista debe
   actualizarse sola, sin necesidad de un botón "Buscar" aparte.
3. Pon "Desde" después de "Hasta": debe mostrar el mensaje de rango
   inválido y no cambiar la lista.
4. Como admin, elimina una venta de prueba desde Historial: confirma que
   pide el PIN, que la venta desaparece de la lista, que el stock del
   producto regresa al inventario, y que "Tu tienda hoy" se actualiza si
   la venta eliminada era de hoy.
5. Con el usuario vendedor, confirma que no aparece el botón de eliminar
   en ninguna fila del Historial.
6. Desde la pantalla de confirmación de una venta nueva, toca "Ver
   historial": debe abrir Historial ya con la venta recién hecha
   visible en el rango de hoy.
7. En el navegador, confirma en las herramientas de desarrollador
   (Application → Service Workers / Cache Storage) que la próxima carga
   usa la caché `lemus-shell-v4` y que la anterior (`lemus-shell-v3`) se
   borra — o simplemente confirma que tras este deploy el panel carga
   sin JS/CSS viejo mezclado con HTML nuevo.

- [ ] **Step 5: Commit**

```bash
git add app/js/admin.js app/sw.js
git commit -m "Agregar Historial de Vender con filtro de fechas"
```
