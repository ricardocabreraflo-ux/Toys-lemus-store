-- supabase/migrations/0016_mercadopago_pending_checkouts.sql
-- Migración de pagos: Stripe -> Mercado Pago. Ver
-- docs/superpowers/specs/2026-08-14-mercadopago-migration-design.md.
--
-- pending_checkouts guarda el carrito + datos de contacto ANTES de mandar
-- al cliente a pagar, porque el webhook de Mercado Pago solo manda un id
-- de pago (no el carrito completo como sí hacían los metadata de Stripe
-- Checkout Sessions). Solo la tocan las Edge Functions con la llave de
-- servicio — sin política de RLS, nadie más puede leerla ni escribirla.

create table if not exists public.pending_checkouts (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('venta', 'apartado')),
  payload     jsonb not null,
  status      text not null default 'pendiente' check (status in ('pendiente', 'confirmado')),
  created_at  timestamptz not null default now()
);

alter table public.pending_checkouts enable row level security;
-- Sin policies: RLS habilitado + cero policies = nadie vía anon/authenticated
-- puede leer ni escribir. Solo service_role (que ignora RLS) la toca.

-- Renombrar la columna de "sesión de Stripe" a algo neutral: mismo
-- propósito (identificar el pago, evitar registrarlo dos veces), ahora
-- guarda el id de pago de Mercado Pago. Las filas viejas de pruebas hechas
-- con Stripe conservan su valor tal cual, solo cambia el nombre de columna.
alter table public.sales rename column stripe_checkout_session_id to payment_id;
alter table public.layaways rename column stripe_checkout_session_id to payment_id;

-- Mercado Pago no separa "intento de pago" y "pago" como sí hacía Stripe.
alter table public.sales drop column if exists stripe_payment_intent_id;

-- 'mercadopago' se agrega; 'stripe' se conserva para no invalidar el
-- historial de las ventas de prueba que ya se hicieron por Stripe.
alter table public.sales drop constraint if exists sales_payment_method_check;
alter table public.sales add constraint sales_payment_method_check
  check (payment_method in ('stripe', 'mercadopago', 'efectivo', 'apartado'));

alter table public.layaway_payments drop constraint if exists layaway_payments_method_check;
alter table public.layaway_payments add constraint layaway_payments_method_check
  check (method in ('stripe', 'mercadopago', 'efectivo'));
