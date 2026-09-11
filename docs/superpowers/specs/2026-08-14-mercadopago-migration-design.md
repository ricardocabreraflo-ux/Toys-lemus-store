# Migración de pagos: Stripe → Mercado Pago

Fecha: 2026-08-14
Estado: aprobado por Ricardo, pendiente de plan de implementación

## Contexto

El checkout en línea (Fase 2) y el anticipo de apartados (recién construido en esta
sesión) usan Stripe. Ricardo no puede completar el trámite fiscal (RFC/factura)
que Stripe pide para activar cobros reales en México, y prefiere no depender de
Stripe en absoluto — quiere migrar a **Mercado Pago**, que ya tiene cuenta creada
y cuyo onboarding para personas físicas/negocios pequeños suele ser más rápido.
No es urgente esta semana, pero se decide migrar ya, de una vez, antes de mover
nada a cobros reales.

## Decisiones ya tomadas con Ricardo

- **Reemplazo total de Stripe** — no conviven los dos proveedores.
- Se migran **los dos flujos** de una vez: el checkout normal del catálogo y el
  anticipo de apartados.
- Ricardo **ya tiene cuenta de Mercado Pago** para el negocio.
- Igual que con Stripe, se construye y prueba todo primero en **modo prueba** de
  Mercado Pago (sin cobrar dinero real, sin trámite fiscal); pasar a cobros
  reales después es solo cambiar 2 llaves, sin tocar código.
- **Solo tarjeta** — sin OXXO ni transferencia SPEI, para no tener que manejar
  pagos que quedan "pendientes" por horas o días.

## Arquitectura

Mercado Pago funciona de forma similar a Stripe (se crea una "preferencia de
pago", se redirige al cliente a pagar, y un webhook confirma el pago), pero su
webhook solo manda `{type: "payment", data: {id}}` — no incluye el carrito
completo como sí hacían los `metadata` de Stripe Checkout Sessions. Para no
perder esa información entre que el cliente empieza a pagar y el webhook
confirma, se guarda el carrito en una tabla nueva (`pending_checkouts`) antes de
redirigir al cliente, y el webhook la consulta al confirmar.

Cambios:
- `supabase/functions/create-checkout-session/index.ts` y
  `supabase/functions/create-layaway-checkout-session/index.ts` (mismos
  nombres — el frontend no cambia): se reescribe su contenido para crear una
  preferencia de Mercado Pago en vez de una Stripe Checkout Session, guardando
  el pedido en `pending_checkouts` primero.
- `supabase/functions/stripe-webhook/index.ts` se elimina; se crea
  `supabase/functions/mercadopago-webhook/index.ts` en su lugar.
- 1 migración: tabla `pending_checkouts`, renombrar/ajustar columnas en
  `sales`/`layaways` que hoy tienen nombre específico de Stripe, y actualizar
  `record_online_sale`/`record_online_layaway_deposit` para recibir el ID de
  pago de Mercado Pago en vez del de Stripe.
- `app/js/catalog.js`, `app/index.html`, `app/js/admin.js`, `app/admin.html`:
  **sin cambios** — siguen llamando a las mismas funciones por su mismo
  nombre, y las páginas de regreso (`?checkout=success/cancel`,
  `?apartado=success/cancel`) las sigue controlando nuestro propio código, no
  Mercado Pago.
- Vender (POS física) y apartar en tienda (efectivo): **sin cambios**, nunca
  tocaron Stripe.

## Modelo de datos

### `pending_checkouts` (tabla nueva)

```
id            uuid primary key default gen_random_uuid()
kind          text not null check (kind in ('venta', 'apartado'))
payload       jsonb not null   -- carrito + datos de contacto (+ total/anticipo si es apartado)
status        text not null default 'pendiente' check (status in ('pendiente', 'confirmado'))
created_at    timestamptz not null default now()
```

Sin política de RLS alguna (ni para `anon` ni para `authenticated`) — solo la
tocan las Edge Functions con la llave de servicio, que ignora RLS. Nadie más
necesita leerla ni escribirla.

### Cambios a `sales` y `layaways`

- `stripe_checkout_session_id` → renombrada a **`payment_id`** en ambas tablas
  (mismo propósito: identificar el pago y evitar registrarlo dos veces; ahora
  guarda el ID de pago de Mercado Pago en vez del de Stripe). Las compras de
  prueba que ya se hicieron por Stripe conservan su ID viejo en esa misma
  columna renombrada — no se pierde ni se toca el historial.
- `sales.stripe_payment_intent_id` se elimina — Mercado Pago no separa
  "intento de pago" y "pago" como sí hacía Stripe; es un solo objeto.
- `sales.payment_method` y `layaway_payments.method` ganan la opción
  `'mercadopago'`. La opción `'stripe'` **se conserva** (no se borra) para que
  las ventas de prueba que ya se registraron con Stripe sigan siendo válidas
  en la base de datos tal cual pasaron — no se reescribe el historial.

### RPCs existentes (se actualizan, mismo comportamiento)

`record_online_sale` y `record_online_layaway_deposit`: su parámetro que
recibía el ID de sesión de Stripe pasa a llamarse `p_payment_id` y a insertar
`payment_method`/`method` como `'mercadopago'`. `record_online_sale` pierde el
parámetro del "payment intent" de Stripe (ya no aplica). El resto de su lógica
interna (validar stock, descontar, marcar `revisar_sin_stock` si se sobrevendió,
candado de service_role, idempotencia) no cambia.

## Flujo: checkout en línea y anticipo de apartado

1. El cliente arma su carrito y da clic en "Ir a pagar" o "Apartar" (sin
   cambios en el catálogo).
2. La Edge Function correspondiente vuelve a leer precio/stock/promociones
   **desde la base de datos** (nunca confía en lo que mande el navegador,
   igual que con Stripe), calcula el total (o el anticipo del 50%, aplicando
   la misma lógica de promociones que ya existe).
3. Inserta una fila en `pending_checkouts` con el carrito y los datos de
   contacto.
4. Crea una preferencia de pago en Mercado Pago (`POST
   /checkout/preferences`) con: los productos (o una sola línea "Anticipo de
   apartado" para el caso de apartados), las URLs de regreso apuntando a
   nuestras mismas páginas de siempre (`?checkout=success/cancel` o
   `?apartado=success/cancel`), la URL de nuestro webhook, y el `id` de la
   fila de `pending_checkouts` como referencia.
5. Responde con la URL de pago de Mercado Pago; el navegador redirige ahí
   (modo prueba usa la URL de sandbox de Mercado Pago).
6. Si el cliente paga, Mercado Pago lo regresa automáticamente a la página de
   éxito. Si cancela, regresa sin cambios — mismo comportamiento visible que
   hoy.
7. Por separado, Mercado Pago llama a `mercadopago-webhook` cuando el pago se
   confirma. Esa función:
   - **verifica la firma** del aviso (`x-signature`/`x-request-id`, HMAC-SHA256
     con un secreto propio de la cuenta de Mercado Pago) — si no coincide,
     rechaza el aviso sin hacer nada más;
   - **confirma el pago consultando directo a la API de Mercado Pago**
     (`GET /v1/payments/{id}`) — nunca confía solo en el contenido del aviso;
   - si el pago está aprobado, busca la fila de `pending_checkouts` por la
     referencia recibida, y llama a `record_online_sale` o
     `record_online_layaway_deposit` con esos datos — mismo registro de
     siempre (descuenta stock, marca `revisar_sin_stock` si ya no había,
     etc.), usando el ID de pago de Mercado Pago como llave de idempotencia
     (evita duplicar si Mercado Pago reenvía el mismo aviso).

## Manejo de errores

- **Firma inválida**: se rechaza el aviso de inmediato, nada se registra.
- **Pago no aprobado** (rechazado/cancelado en Mercado Pago): no se registra
  nada; si después llega un aviso de que sí se aprobó, se procesa normal.
- **Reenvíos del mismo aviso**: idempotente por `payment_id`, igual que con
  Stripe.
- **Precio/stock desincronizado al pagar**: se valida contra la base de datos
  al crear la preferencia, igual que hoy.
- **Sobreventa en el canal en línea**: mismo criterio ya existente — la venta
  se registra igual (nunca se pierde un pago ya cobrado), marcada
  `revisar_sin_stock` para resolver a mano.
- **Aviso sin `pending_checkouts` correspondiente** (no debería ocurrir): se
  registra en los logs de la función para investigar, respondiendo 200 para
  no generar reintentos infinitos de algo que nunca se va a resolver solo.

## Fuera de alcance de esta migración

- Pagos en OXXO o transferencia SPEI.
- Reembolsos automáticos.
- Mantener Stripe como alternativa disponible.
- Activar cobros reales (lo hace Ricardo cuando tenga su RFC — cambio de
  llaves, sin tocar código).
- Cualquier cambio a Vender o a apartar en tienda (pagos en efectivo).
- Migrar o reetiquetar las ventas ya registradas con Stripe — quedan tal cual
  en el historial.

## Qué necesito de Ricardo antes/durante la implementación

1. El **Access Token de prueba** de Mercado Pago (se saca del panel de
   desarrolladores de su cuenta) — se guarda como secreto de la Edge
   Function, nunca en el código ni en el repo. Se lo pido cuando lleguemos a
   esa parte de la implementación.
2. Una vez desplegado el webhook, configurar la URL de notificaciones en el
   panel de Mercado Pago y pasarme la **clave secreta de firma** (para
   verificar `x-signature`) que Mercado Pago genera — también va como
   secreto de la función.
