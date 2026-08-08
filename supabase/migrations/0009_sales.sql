-- supabase/migrations/0009_sales.sql
-- One table for both sales channels — see the design doc for the field
-- rationale. No insert/update policies: rows are only ever written by the
-- security-definer RPCs in migration 0010, which apply their own checks.

create table if not exists public.sales (
  id                          uuid primary key default gen_random_uuid(),
  channel                     text not null check (channel in ('online', 'fisica')),
  status                      text not null check (status in ('pagado', 'entregado', 'completada', 'revisar_sin_stock')),
  customer_name               text,
  customer_phone              text,
  customer_email              text,
  payment_method              text not null check (payment_method in ('stripe', 'efectivo')),
  stripe_checkout_session_id  text unique,
  stripe_payment_intent_id    text,
  total                       numeric(10, 2) not null default 0 check (total >= 0),
  created_by                  uuid references auth.users(id),
  delivered_by                uuid references auth.users(id),
  delivered_at                timestamptz,
  created_at                  timestamptz not null default now()
);

create index if not exists sales_channel_status_idx on public.sales (channel, status);
create index if not exists sales_created_at_idx on public.sales (created_at desc);

alter table public.sales enable row level security;

drop policy if exists "authenticated read" on public.sales;
create policy "authenticated read" on public.sales for select to authenticated using (true);

create table if not exists public.sale_items (
  id                uuid primary key default gen_random_uuid(),
  sale_id           uuid not null references public.sales(id) on delete cascade,
  product_id        uuid references public.products(id) on delete set null,
  product_name      text not null,
  quantity          integer not null check (quantity > 0),
  unit_price        numeric(10, 2) not null check (unit_price >= 0),
  unit_cost_price   numeric(10, 2) not null check (unit_cost_price >= 0)
);

create index if not exists sale_items_sale_idx on public.sale_items (sale_id);

alter table public.sale_items enable row level security;

drop policy if exists "authenticated read" on public.sale_items;
create policy "authenticated read" on public.sale_items for select to authenticated using (true);

create or replace view public.sale_items_view as
select
  id, sale_id, product_id, product_name, quantity, unit_price,
  case when public.is_admin() then unit_cost_price else null end as unit_cost_price
from public.sale_items;

grant select on public.sale_items_view to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sales'
  ) then
    alter publication supabase_realtime add table public.sales;
  end if;
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sale_items'
  ) then
    alter publication supabase_realtime add table public.sale_items;
  end if;
end;
$$;
