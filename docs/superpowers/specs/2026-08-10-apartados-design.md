# Apartados (layaway): reservar un producto y pagarlo por abonos

Fecha: 2026-08-10
Estado: aprobado por Ricardo, pendiente de plan de implementación

## Contexto

Fase 2 (punto de venta + roles) está cerrada y verificada en producción.
Ricardo pidió seguir con el resto de fases pendientes, excepto pasar Stripe a
modo real (eso queda para después de forma explícita). De las pendientes, la
de mayor prioridad es **apartados**: un cliente reserva uno o más productos
pagando un anticipo, y paga el resto después — en tienda física, en efectivo
— antes de recogerlo.

## Decisiones ya tomadas con Ricardo

- Se puede apartar **por los dos canales**: en tienda física (admin/vendedor
  lo registra con el cliente presente) y en línea desde el catálogo público.
- El anticipo es **50% del total**, fijo a nivel sistema (no se captura a
  mano ni varía por apartado). El anticipo en línea se cobra con Stripe; el
  anticipo físico, en efectivo.
- El **saldo restante siempre se paga en efectivo, en tienda** — sin importar
  el canal donde se apartó. No hay cobro en línea para completar un apartado.
- Después del anticipo, el cliente puede ir abonando **varias veces** antes
  de completar el pago (no tiene que ser todo de una sola vez).
- Cada apartado tiene una **fecha límite fija de 15 días** desde que se creó.
  Vencer la fecha **no cancela nada automáticamente** — el apartado se marca
  visualmente como vencido y Ricardo/el vendedor deciden a mano si cancelan
  (liberando el stock) o le dan más tiempo al cliente.
- Al apartar, el producto se **reserva de inmediato** (se resta del stock
  correspondiente) para que no se pueda vender a otra persona mientras tanto.
- Si un apartado se cancela o vence sin completarse, **el dinero ya pagado no
  se reembolsa automáticamente** — el sistema solo libera el stock y marca el
  apartado como cancelado; cualquier devolución la maneja Ricardo por fuera.
- Tanto admin como vendedor pueden crear y gestionar apartados (igual que las
  ventas físicas normales).
- Al completarse un apartado (saldo en $0), se **gradúa automáticamente a una
  venta normal** en `sales`/`sale_items` — aparece en Reportes como cualquier
  otra venta, sin que Ricardo tenga que hacer nada extra.

## Arquitectura

Se agregan al proyecto Supabase existente:

- 3 tablas nuevas: `layaways`, `layaway_items`, `layaway_payments`; más una
  vista `layaway_items_view` que enmascara el costo igual que
  `sale_items_view`.
- 4 funciones RPC (`security definer`, mismo patrón que `create_sale_fisica`
  y `mark_sale_delivered` de Fase 2): `create_layaway_fisica`,
  `record_layaway_abono`, `cancel_layaway`, `extend_layaway_due_date`.
- 1 función RPC adicional `record_online_layaway_deposit`, invocable solo por
  el rol de servicio (usada por el webhook, nunca directo desde el
  navegador) — mismo candado que `record_online_sale` (revocado de
  `anon`/`authenticated` explícitamente, más una verificación interna del
  rol, no solo de `public`, aprendiendo del hallazgo de la revisión final de
  Fase 2).
- 1 Edge Function nueva: `create-layaway-checkout-session` (mismo patrón que
  `create-checkout-session`, pero cobra solo el 50%).
- El webhook existente `stripe-webhook` gana una rama nueva: distingue una
  sesión de apartado de una venta normal por un campo en los `metadata` de
  Stripe, y llama a `record_online_layaway_deposit` en vez de
  `record_online_sale`.
- Cambios de frontend: `admin.js`/`admin.html` (pestaña nueva "Apartados"),
  `catalog.js`/`index.html` (botón "Apartar" en el carrito público).

## Modelo de datos

### `layaways`

```
id                          uuid primary key default gen_random_uuid()
channel                     text not null check (channel in ('online', 'fisica'))
status                      text not null check (status in ('activo', 'completado', 'cancelado', 'revisar_sin_stock'))
customer_name               text not null
customer_phone              text not null
customer_email              text
total                       numeric(10,2) not null check (total >= 0)
deposit_percent             numeric(5,2) not null default 50
due_date                    date not null           -- created_at + 15 días
stripe_checkout_session_id  text unique             -- solo channel='online'
completed_sale_id           uuid references public.sales(id)
created_by                  uuid references auth.users(id)
cancelled_by                uuid references auth.users(id)
cancelled_at                timestamptz
created_at                  timestamptz not null default now()
```

"Vencido" no es un valor de `status` guardado — se calcula comparando
`due_date < hoy` sobre los que siguen en `activo`, tanto en la consulta del
panel como visualmente en la tabla.

### `layaway_items`

Mismo patrón que `sale_items`: precio y costo quedan congelados al momento
de apartar, y `layaway_items_view` oculta `unit_cost_price` a quien no sea
admin (tabla base con el mismo revoke + grant por columna que ya se usa en
`products` y `sale_items`, para no repetir el hallazgo de la revisión final
de Fase 2 de dejarlo para después).

```
id                uuid primary key default gen_random_uuid()
layaway_id        uuid not null references public.layaways(id) on delete cascade
product_id        uuid references public.products(id) on delete set null
product_name      text not null
quantity          integer not null check (quantity > 0)
unit_price        numeric(10,2) not null check (unit_price >= 0)
unit_cost_price   numeric(10,2) not null check (unit_cost_price >= 0)
```

### `layaway_payments`

Cada fila es un pago: el anticipo inicial cuenta como el primero.

```
id            uuid primary key default gen_random_uuid()
layaway_id    uuid not null references public.layaways(id) on delete cascade
amount        numeric(10,2) not null check (amount > 0)
method        text not null check (method in ('stripe', 'efectivo'))
created_by    uuid references auth.users(id)   -- null cuando lo registra el webhook (service_role)
created_at    timestamptz not null default now()
```

RLS de las 3 tablas: lectura para cualquier autenticado (igual que
`sales`/`sale_items`), sin policy de escritura directa — todo pasa por las
funciones RPC.

## Roles y permisos

Igual que las ventas físicas: admin y vendedor pueden crear apartados,
registrar abonos, cancelar y extender fecha. El costo (`unit_cost_price`)
sigue oculto para vendedor, igual que en ventas.

## Flujo: apartar en tienda física

1. En la pestaña "Apartados", arriba de la lista, un formulario igual al de
   "Vender": buscar/agregar productos al carrito, capturar nombre/teléfono/
   correo del cliente. Se muestra el total y el anticipo calculado (50%)
   antes de confirmar.
2. "Registrar apartado" llama a `create_layaway_fisica(items, customer_*)`:
   - por cada línea, revisa `stock_fisica` con `for update` (mismo patrón
     que `create_sale_fisica`); si algo no alcanza, cancela toda la
     operación y avisa cuánto hay disponible;
   - descuenta `stock_fisica` de cada producto;
   - crea `layaways` (`status='activo'`, `due_date` = hoy + 15 días) +
     `layaway_items` + el primer `layaway_payments` (`method='efectivo'`,
     `amount` = 50% del total).

## Flujo: apartar en línea

1. En el carrito del catálogo público, junto al botón de pagar normal, un
   botón **"Apartar (paga 50% ahora)"**.
2. Llama a la Edge Function `create-layaway-checkout-session` con el carrito
   y los datos de contacto. La función:
   - valida stock y aplica promociones activas igual que
     `create-checkout-session` (mismo cálculo de precio con descuento);
   - calcula el anticipo (50% del total con descuento aplicado);
   - crea una Stripe Checkout Session **solo por el anticipo**, guardando el
     carrito completo (con precios ya calculados) y los datos del cliente en
     los `metadata` de la sesión, marcados como `kind: 'layaway_deposit'`.
   - el stock **no** se reserva en este paso — igual que el checkout normal,
     para no bloquear inventario por pagos abandonados.
3. Si el cliente paga, Stripe redirige de vuelta al catálogo
   (`index.html?apartado=success`) con un mensaje de confirmación y
   recordatorio de la fecha límite. Si cancela, regresa sin cambios.
4. El webhook `stripe-webhook`, al ver `kind: 'layaway_deposit'` en los
   metadata del evento `checkout.session.completed`, llama a
   `record_online_layaway_deposit(...)` en vez de `record_online_sale`:
   - re-valida `stock_online` con `for update`;
   - si alcanza: reserva el stock, crea `layaways` (`status='activo'`) +
     `layaway_items` + el primer `layaway_payments`
     (`method='stripe'`, `created_by=null`);
   - si ya no alcanza (alguien más compró mientras tanto): crea el apartado
     igual (el pago ya se cobró, nunca se descarta) pero con
     `status='revisar_sin_stock'`, para que Ricardo lo resuelva a mano —
     mismo criterio que ya existe hoy para pedidos en línea sobrevendidos;
   - idempotente por `stripe_checkout_session_id`, igual que
     `record_online_sale`.

## Flujo: abonar y completar

1. En la pestaña "Apartados" → sección "Activos", cada fila tiene un botón
   **"Registrar abono"** que pide un monto en efectivo.
2. Llama a `record_layaway_abono(p_layaway_id, p_amount)`:
   - rechaza si `p_amount` es mayor al saldo pendiente (total menos suma de
     pagos ya registrados), con mensaje claro del saldo real;
   - rechaza si el apartado no está `activo` o `revisar_sin_stock`;
   - inserta el `layaway_payments` (`method='efectivo'`,
     `created_by=auth.uid()`);
   - si con ese abono la suma de pagos llega al 100% del total: inserta la
     venta final en `sales` (mismo `channel` del apartado,
     `status='completada'`, `payment_method='apartado'` — se agrega este
     valor nuevo al check de `sales.payment_method` para no mentir en los
     reportes que fue 100% Stripe o 100% efectivo) + `sale_items` (copiando
     `layaway_items`), enlaza `completed_sale_id`, y marca el apartado
     `completado`. El stock no se vuelve a tocar — ya se había reservado al
     apartar.
3. Botón **"Extender fecha"**: llama a `extend_layaway_due_date(p_layaway_id,
   p_new_due_date)` — solo actualiza `due_date`, sin más efectos.
4. Botón **"Cancelar"**: llama a `cancel_layaway(p_layaway_id)` — libera el
   stock reservado (súmalo de vuelta a `stock_fisica` o `stock_online` según
   el canal), marca `cancelado`, `cancelled_by`, `cancelled_at`. Rechaza si
   el apartado ya está `completado` o `cancelado`.

## Interfaz

Pestaña nueva **"Apartados"** en el panel admin, junto a Vender/Pedidos,
visible para admin y vendedor:

- Formulario para apartar en tienda (arriba, como el de Vender).
- Sección **"Activos"**: cliente, productos, total, pagado, saldo pendiente,
  fecha límite (fila resaltada si ya venció, mismo estilo que los pedidos
  `revisar_sin_stock`). Botones: Registrar abono, Extender fecha, Cancelar.
- Sección **"Historial"**: apartados completados y cancelados, solo lectura.

En `index.html`, el cajón del carrito gana el botón "Apartar (paga 50%
ahora)" junto al de pagar normal, y una página de regreso de éxito/cancelado
igual que el checkout (`?apartado=success` / `?apartado=cancel`).

## Manejo de errores

- **Sobreventa en línea:** mismo criterio que el checkout normal — se valida
  al crear la sesión y otra vez (con bloqueo de fila) al confirmar el pago;
  si ya no alcanza, el apartado igual se crea, marcado `revisar_sin_stock`.
- **Sobreventa física:** no puede pasar — se valida y reserva en la misma
  operación síncrona.
- **Abono mayor al saldo pendiente:** rechazado con el saldo real en el
  mensaje.
- **Doble clic** en "Registrar apartado" o "Registrar abono": botón
  deshabilitado mientras se procesa (mismo patrón que Vender/checkout).
- **Cancelar o abonar a un apartado ya cerrado:** rechazado por la función.
- **Reenvíos de webhook de Stripe:** idempotencia vía
  `stripe_checkout_session_id`, igual que `record_online_sale`.
- **Producto eliminado después de apartado:** `layaway_items` conserva
  nombre/precio/costo congelados, no se rompe el historial.
- **Permisos desde el día uno:** todas las funciones nuevas revocan acceso
  explícito de `anon`/`authenticated` según corresponda (no solo de
  `public`) y verifican el rol/uid internamente, igual que el arreglo final
  de Fase 2 — no se repite ese hallazgo después.

## Fuera de alcance de esta fase (explícito)

- Reembolsos automáticos por Stripe.
- Recordatorios automáticos al cliente (SMS/correo) cerca de la fecha
  límite.
- % de anticipo o días de plazo configurables por apartado individual (quedan
  fijos a nivel sistema: 50% / 15 días).
- Pagar el saldo restante en línea o con tarjeta.
- Editar los productos de un apartado ya creado (se cancela y se crea uno
  nuevo).
- Reporte dedicado de "valor apartado pendiente" en la pestaña Reportes.
- Límite de apartados por cliente o por producto.

## Qué necesito de Ricardo antes/durante la implementación

Nada nuevo — reutiliza las mismas llaves de Stripe (modo prueba) y el mismo
proyecto de Supabase ya configurados en Fase 2. El despliegue sigue siendo
manual (SQL Editor, Edge Functions, Netlify Drop) igual que hasta ahora.
