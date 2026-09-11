# Aviso de "Próximamente" para promociones futuras

## Contexto

Al probar el bloque de promociones por producto, Ricardo creó una
promoción con fecha de inicio en el futuro (mañana) y notó que no
aparece en nada en la página pública hasta que arranca — quiere que se
vea un aviso de que "tal día aplicará esa promoción", sin mostrar el
precio con descuento todavía (confirmado con Ricardo vía pregunta
directa: texto simple, sin precio, para no confundir con el precio de
hoy).

## Alcance

- Nueva franja de texto en el catálogo público, debajo del banner de
  promociones activas, con una línea por cada promoción que todavía no
  ha empezado (`starts_at` en el futuro, `active = true`).
- Aplica a los tres tipos de promoción (línea, categoría, producto) —
  incluye el nombre de línea/categoría/producto según corresponda,
  igual que ya hace el banner de promociones activas.
- Mismo filtro de visibilidad que ya tienen las promociones activas: si
  la línea del producto/categoría/línea promovida está oculta del
  catálogo público (Ajustes), el aviso tampoco se muestra.
- Sin promociones futuras → la franja no se renderiza (cero espacio).
- Fuera de alcance: countdown en vivo, notificaciones, o mostrar el
  precio con descuento antes de tiempo (Ricardo lo pidió explícitamente
  sin precio).

## Diseño

**`catalog-data.js`** gana `loadUpcomingPromotions()`, misma forma que
`loadActivePromotions()` pero invertida (`starts_at` en el futuro en vez
de dentro de la ventana activa):

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

**`catalog.js`**: la lógica de "¿esta promoción aplica a algo visible?"
ya existe una vez para `PROMOTIONS` dentro de `loadAll()` — se extrae a
una función compartida `isPromoVisible(promo, ctx)` para no triplicarla
ahora que hay dos listas de promociones (activas y próximas) que
necesitan el mismo filtro:

```javascript
function isPromoVisible(promo, { visibleLineIds, categories, productsData }) {
  if (promo.scope_type === 'line') return visibleLineIds.has(promo.product_line_id);
  if (promo.scope_type === 'category') return categories.some(c => c.id === promo.category_id);
  const targetProduct = productsData.find(pr => pr.id === promo.product_id);
  return targetProduct ? visibleLineIds.has(targetProduct.product_line_id) : false;
}
```

`loadAll()` fetches `loadUpcomingPromotions()` alongside the isolated
`site_settings` call (same non-critical, cosmetic-failure isolation —
a failed fetch here shouldn't take down the catalog), filters it with
the shared helper, and calls a new `renderUpcomingPromos()` after
`renderPromoBanner()`.

Rendering, one line of text per promo, no price:

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
```

`index.html` gains `<div class="promo-upcoming" id="promo-upcoming" hidden></div>`
right after `#promo-banner`. New CSS is deliberately understated (small,
muted text, no badge, no price) — this is a heads-up, not a call to buy
yet.

## Manejo de errores

Same posture as the rest of `loadAll()`'s cosmetic fetches: isolated
try/catch, failure logs to console and leaves the upcoming-promos strip
empty/hidden rather than breaking the catalog.

## Pruebas

1. Crear una promoción de producto con fecha de inicio mañana — confirmar
   que aparece la línea "Próximamente: X% de descuento en <producto> a
   partir del <fecha>" en el catálogo público, sin precio.
2. Confirmar que una promoción activa hoy sigue apareciendo en el banner
   normal (grande o pastilla), no en la franja de "próximamente".
3. Ocultar la línea del producto/categoría de una promoción futura y
   confirmar que el aviso desaparece también.
4. Sin promociones futuras, confirmar que la franja no ocupa espacio.
