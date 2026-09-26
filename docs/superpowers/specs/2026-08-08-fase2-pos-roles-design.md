# Fase 2: Punto de venta (en línea + física) y roles de usuario

Fecha: 2026-08-08
Estado: aprobado por Ricardo, pendiente de plan de implementación

## Contexto

La Fase 1 (inventario multi-línea, stock por ubicación, traspasos, promociones,
reportes de inventario) ya está en producción. Lo que falta, según quedó
documentado en el propio código:

- `app/js/catalog.js`: el botón de pagar del carrito público solo muestra un
  toast — `showToast('Demo — el pago se conectaría aquí')`.
- `app/admin.html` (pestaña Reportes): "Los reportes de ventas por mes... van
  a aparecer aquí una vez que conectemos el punto de venta."
- No existe ningún concepto de roles: cualquier cuenta autenticada tiene
  acceso total vía RLS `to authenticated using (true)` en todas las tablas.
  El login del admin (`app/js/admin.js`) además permite auto-registro público
  (`supabase.auth.signUp`) sin restricción.

Esta fase construye: (1) checkout en línea real con Stripe, (2) una pantalla
de venta física (POS) en el panel para ventas en efectivo, y (3) roles
admin/vendedor con permisos distintos.

Cuenta existente en el proyecto Supabase real (`iatyvxljzrcdfmmtesig`) al
momento de escribir esto: una sola, `ricardo.cabreraflo@gmail.com`
(`6c22a4d2-dcdf-4dab-a688-2bcd4396734a`). Esa cuenta se vuelve el admin
fundador vía la migración de backfill.

## Decisiones ya tomadas con Ricardo

- Punto de venta cubre **ambos canales**: en línea (Stripe) y física (POS en
  el admin).
- Cobro en línea es **real, con tarjeta, vía Stripe** — no solo "registrar
  pedido y cobrar aparte". Como la cuenta de Stripe de Ricardo está pendiente
  por trámites fiscales, se construye todo contra **Stripe en modo prueba**;
  pasar a cobros reales después es solo cambiar las llaves, sin tocar código.
- Entrega en línea: **solo recoger en tienda**, sin envío a domicilio.
- Datos que se piden al cliente en el checkout en línea: nombre, teléfono,
  correo. Sin cuenta de cliente (compra como invitado).
- Estados de un pedido en línea después del pago: **pagado → entregado**
  (dos pasos, sin "preparando" intermedio).
- Tanto admin como vendedor pueden ver y marcar como entregados los pedidos
  en línea.
- Venta física: **solo efectivo** (sin integrar terminal de tarjeta ni
  transferencia en esta fase), **sin recibo imprimible** — solo queda
  registrada en el sistema.
- El vendedor puede: vender en la pantalla POS, marcar pedidos en línea como
  entregados, y **ver** (no editar) inventario y stock. El vendedor **no**
  hace traspasos y **no** ve `cost_price` (costo) en ningún lado, ni en
  pantalla ni por API — se enmascara a nivel de base de datos.
- Cuentas de vendedor se crean **solo** desde una pestaña "Usuarios" del
  panel admin (tú escribes el correo, se le invita). El auto-registro
  público del login se elimina.
- `stock_online` y `stock_fisica` son bolsas separadas (ya lo eran desde la
  Fase 1) — una venta física nunca compite por la misma unidad que una venta
  en línea. El único caso de sobreventa posible es dentro del mismo canal en
  línea (dos compradores por la última pieza de `stock_online` casi
  simultáneamente). Cuando eso pase, la venta se registra igual (nunca se
  pierde el rastro de un pago ya cobrado) pero queda marcada como
  "revisar — sin stock" en Pedidos, para que Ricardo decida: reembolsar, o
  surtir traspasando desde `stock_fisica`.

## Arquitectura

Se agregan al proyecto Supabase existente:

- 3 tablas nuevas: `profiles`, `sales`, `sale_items`; más dos vistas de solo
  lectura para el enmascarado de costo: `products_view` y `sale_items_view`.
- 2 funciones RPC (`security definer`, mismo patrón que `transfer_stock` de
  la Fase 1): `create_sale_fisica` y `mark_sale_delivered`.
- 1 función RPC adicional `record_online_sale`, invocable solo por el rol de
  servicio (usada por el webhook, nunca directo desde el navegador).
- 3 Supabase Edge Functions (Deno): `invite-vendedor`,
  `create-checkout-session`, `stripe-webhook`.
- Cambios de frontend: `catalog.js` (checkout real), `admin.js`/`admin.html`
  (pestañas nuevas: Vender, Pedidos, Usuarios; ocultar pestañas y columna de
  costo según rol; quitar auto-registro).

No se toca Netlify más que las variables de entorno necesarias para las
llaves públicas de Stripe; las Edge Functions viven en Supabase, no en
Netlify.

## Modelo de datos

### `profiles`

Une cada cuenta de `auth.users` con un rol.

```
id          uuid primary key references auth.users(id) on delete cascade
email       text not null          -- copiado al invitar, para listarlo sin otra función
role        text not null check (role in ('admin', 'vendedor'))
created_at  timestamptz not null default now()
```

RLS: cualquier usuario autenticado puede leer su propia fila
(`id = auth.uid()`); solo admin puede leer todas (para la pestaña Usuarios).
Sin policy de escritura directa — las filas se crean únicamente vía la
función `invite-vendedor` (con la service role key) y la migración de
backfill del admin fundador.

Función auxiliar `public.is_admin()` (`security definer`, `stable`):
existe una fila en `profiles` con `id = auth.uid()` y `role = 'admin'`. Se
usa en el resto de las policies nuevas y modificadas.

### `products_view`

Vista de solo lectura sobre `products` que oculta `cost_price` para quien no
sea admin:

```sql
select
  id, code, name, product_line_id, category_id, price,
  stock_online, stock_fisica, published_online, created_at, updated_at,
  case when public.is_admin() then cost_price else null end as cost_price
from public.products;
```

Se revoca `select` de la columna `cost_price` directo sobre `products` para
`authenticated` **y para `anon`**, así que la única forma de leerla (aun
para admin) es a través de esta vista. El admin panel se actualiza para leer
de `products_view` en vez de `products` (las escrituras — precio, stock,
costo — se quedan sobre `products`, y su policy de `update`/`insert`/`delete`
pasa a requerir `is_admin()`, ya que el vendedor no edita inventario).

Hallazgo adicional revisando el código actual: el catálogo público
(`catalog.js:246`) hoy hace `select('*')` sobre `products`, lo que expone
`cost_price` a cualquier visitante que inspeccione las llamadas de red del
navegador — no es un problema nuevo de esta fase, ya existe en producción
desde la Fase 1. Como parte de este trabajo, `catalog.js` también se cambia
para leer de `products_view` (que ya siempre devuelve `cost_price` en null
para visitantes anónimos), cerrando esa fuga de una vez.

### `sales`

Una sola tabla para los dos canales.

```
id                        uuid primary key default gen_random_uuid()
channel                   text not null check (channel in ('online', 'fisica'))
status                    text not null check (status in ('pagado', 'entregado', 'completada', 'revisar_sin_stock'))
customer_name             text        -- solo channel='online'
customer_phone            text
customer_email            text
payment_method            text not null check (payment_method in ('stripe', 'efectivo'))
stripe_checkout_session_id text unique -- solo channel='online'; también sirve de llave de idempotencia del webhook
stripe_payment_intent_id  text
total                     numeric(10,2) not null check (total >= 0)
created_by                uuid references auth.users(id)  -- vendedor/admin que cobró (solo física)
delivered_by              uuid references auth.users(id)
delivered_at              timestamptz
created_at                timestamptz not null default now()
```

Reglas de `status` por canal:
- `fisica` nace y se queda en `completada`.
- `online` nace en `pagado`; pasa a `entregado` vía `mark_sale_delivered`; o
  queda en `revisar_sin_stock` si `record_online_sale` detecta que ya no
  había `stock_online` suficiente al momento de aplicar el descuento (la
  venta se registra de todas formas, nunca se descarta un pago real).

RLS: `select` para cualquier autenticado (admin y vendedor necesitan ver
Pedidos; los reportes con costo real se calculan aparte — ver más abajo).
Sin policy de `insert`/`update` directa: todo pasa por las funciones RPC.

### `sale_items`

```
id                uuid primary key default gen_random_uuid()
sale_id           uuid not null references public.sales(id) on delete cascade
product_id        uuid references public.products(id)
product_name      text not null      -- copia, por si el producto cambia de nombre o se borra después
quantity          integer not null check (quantity > 0)
unit_price        numeric(10,2) not null check (unit_price >= 0)   -- precio de venta en ese momento
unit_cost_price   numeric(10,2) not null check (unit_cost_price >= 0) -- costo en ese momento
```

`unit_cost_price` se enmascara igual que `products.cost_price`: una vista
`sale_items_view` (mismo patrón `case when is_admin()`) es lo que lee el
panel; así los reportes de ganancia real (Fase 2 también los conecta a datos
reales, ya que la data ya existe) solo los puede calcular el admin.

## Roles y permisos (resumen)

| Acción                                    | admin | vendedor |
|--------------------------------------------|:-----:|:--------:|
| Ver inventario/stock                       | sí    | sí (sin costo) |
| Editar productos, precios, costo           | sí    | no |
| Traspasos entre online/física              | sí    | no |
| Promociones, líneas y categorías           | sí    | no |
| Vender en tienda física (POS)              | sí    | sí |
| Ver pedidos en línea y marcar entregado    | sí    | sí |
| Reportes (incluye ganancia/costo real)     | sí    | no |
| Invitar/gestionar cuentas de vendedor      | sí    | no |

## Flujo: checkout en línea (Stripe)

1. El cliente arma su carrito en el catálogo público (ya existe). Al dar
   "Pagar", en vez del toast demo, se le pide nombre, teléfono y correo.
2. El navegador llama a la Edge Function `create-checkout-session` con el
   carrito (ids + cantidades) y los datos de contacto. La función:
   - vuelve a leer precio y `stock_online` **desde la base de datos**, nunca
     confía en lo que mande el navegador;
   - si algo ya no está disponible o cambió de precio, responde con el error
     para que el cliente actualice su carrito antes de continuar;
   - crea una Stripe Checkout Session (modo pago único) con esos datos, y
     guarda el carrito + contacto en los `metadata` de la sesión de Stripe
     (no hace falta tabla de "pendientes" — Stripe guarda ese estado
     mientras el cliente paga);
   - responde con la URL de Stripe Checkout.
3. El navegador redirige al cliente a esa URL (página hospedada por Stripe:
   ahí captura la tarjeta, nunca pasa por nuestro servidor).
4. Si paga, Stripe redirige de vuelta al catálogo
   (`index.html?checkout=success`) mostrando confirmación: "pasa a recogerlo
   a la tienda". Si cancela, regresa al catálogo sin cambios.
5. En paralelo (no depende de que el cliente vuelva a nuestra página), Stripe
   llama a la Edge Function `stripe-webhook` cuando el pago se confirma
   (`checkout.session.completed`), firmada con `STRIPE_WEBHOOK_SECRET` para
   verificar que de verdad viene de Stripe. Esa función:
   - lee el carrito/contacto de los `metadata` de la sesión;
   - llama a `record_online_sale(...)` (RPC `security definer`, solo
     invocable con la service role key) que, en una sola transacción, crea
     la fila en `sales` (`status='pagado'`) + sus `sale_items`, y descuenta
     `stock_online` de cada producto;
   - si `stripe_checkout_session_id` ya existe en `sales` (Stripe reenvió el
     mismo webhook dos veces), no hace nada — responde OK sin duplicar.
6. En Pedidos (pestaña nueva del admin), admin y vendedor ven la lista de
   ventas `channel='online'` pendientes de atención: las de `status='pagado'`
   con un botón "Marcar entregado" (llama a `mark_sale_delivered`, que exige
   `status='pagado'` y pone `status='entregado'`, `delivered_by`,
   `delivered_at`), y las de `status='revisar_sin_stock'` marcadas aparte
   para que el admin decida cómo resolverlas. Las ya `entregado` quedan
   disponibles como historial, no en la lista activa.

## Flujo: venta física (POS)

Pestaña nueva "Vender" en el admin (visible a admin y vendedor):

1. Buscar/agregar productos a un carrito en pantalla (mismo patrón visual
   que el carrito del catálogo público, reutilizando componentes donde se
   pueda).
2. Capturar el efectivo recibido (opcional, solo para que el vendedor calcule
   el cambio en pantalla — no se guarda como dato distinto del total).
3. "Confirmar venta" llama a `create_sale_fisica(items jsonb)` — RPC
   `security definer`, mismo patrón que `transfer_stock` de la Fase 1:
   - por cada línea, revisa `stock_fisica` disponible con `for update`;
   - si cualquier línea no alcanza, se cancela toda la operación (no se
     descuenta nada a medias) y se informa cuánto hay disponible;
   - si todo alcanza, descuenta `stock_fisica` de cada producto e inserta
     `sales` (`channel='fisica'`, `status='completada'`,
     `payment_method='efectivo'`, `created_by=auth.uid()`) + `sale_items`.
4. Sin recibo imprimible — la venta queda visible en Pedidos/Reportes.

## Invitación de vendedores

Pestaña nueva "Usuarios" (solo admin):

1. Admin escribe el correo del vendedor y da "Invitar".
2. El navegador llama a la Edge Function `invite-vendedor`, mandando el JWT
   del admin en el header. La función:
   - verifica que quien llama es admin (usando su JWT para leer su propia
     fila de `profiles` — si no es admin, rechaza);
   - usa la Admin API de Supabase (`auth.admin.inviteUserByEmail`, con la
     service role key) para crear la cuenta y mandarle un correo de
     invitación (Supabase ya maneja esa plantilla de correo);
   - inserta la fila en `profiles` (`role='vendedor'`, `email` copiado).
3. El vendedor recibe el correo, pone su contraseña, y entra directo al
   panel con su rol ya asignado.
4. La pestaña Usuarios lista los vendedores existentes (de `profiles`).
   Desactivar/borrar cuentas de vendedor no está en el alcance de esta fase
   (se puede pedir manualmente si hace falta).

Se elimina el flujo de auto-registro (`authMode === 'signup'`) del login del
admin — el login solo permite iniciar sesión, no crear cuenta.

## Manejo de errores

- **Reintentos de webhook de Stripe:** idempotencia vía el `unique` en
  `sales.stripe_checkout_session_id` — un segundo intento del mismo evento
  no duplica la venta.
- **Precio/stock desincronizado al pagar:** `create-checkout-session` valida
  contra la base de datos en el momento, no contra lo que mande el
  navegador.
- **Checkout abandonado:** si el cliente no completa el pago en Stripe, no
  se crea ninguna fila en `sales` — nada que limpiar.
- **Sobreventa dentro del canal en línea:** ver la sección de decisiones —
  la venta se registra igual, marcada `revisar_sin_stock`.
- **Venta física con stock insuficiente:** `create_sale_fisica` cancela toda
  la operación (transacción), igual que ya hace `transfer_stock` hoy.
- **Invitación a un correo ya registrado:** la función `invite-vendedor`
  deja que el error de Supabase Auth (correo duplicado) suba tal cual al
  admin, con un mensaje claro en pantalla.

## Fuera de alcance de esta fase (explícito)

- Envío a domicilio (solo recoger en tienda).
- Pago con tarjeta o transferencia en la venta física (solo efectivo).
- Recibo imprimible/PDF.
- Cuentas de cliente con historial de pedidos.
- Desactivar/eliminar cuentas de vendedor desde el panel.
- Reserva de stock mientras el cliente está pagando en Stripe (ver
  "sobreventa" arriba).
- Terminal de cobro con tarjeta físico integrado al sistema.
- Activar Stripe en modo real (requiere que Ricardo termine sus trámites
  fiscales con Stripe primero; el cambio de llave prueba → real no requiere
  tocar código).

## Qué necesito de Ricardo antes/durante la implementación

1. Crear una cuenta de Stripe (modo prueba no pide datos fiscales, solo
   correo) y darme la **llave secreta de prueba** (`sk_test_...`) — se
   guarda como secreto de la Edge Function, nunca en el código ni en el
   repo.
2. Una vez desplegado el webhook, configurar el endpoint en el dashboard de
   Stripe y pasarme el **firmante del webhook** (`whsec_...`) que Stripe
   genera — también va como secreto de la función.
