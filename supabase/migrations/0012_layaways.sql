-- supabase/migrations/0012_layaways.sql
-- Apartados (layaway): a customer reserves products with a deposit and
-- pays the rest later. See
-- docs/superpowers/specs/2026-08-10-apartados-design.md.
--
-- Security note (lesson from Fase 2's final review): every grant below is
-- explicit for anon/authenticated, not just `from public` — a bare
-- `revoke ... from public` does NOT remove Supabase's automatic
-- `alter default privileges ... grant all to anon, authenticated`
-- bootstrap grant on new tables, since those are separate ACL records.

create table if not exists public.layaways (
  id                          uuid primary key default gen_random_uuid(),
  channel                     text not null check (channel in ('online', 'fisica')),
  status                      text not null check (status in ('activo', 'completado', 'cancelado', 'revisar_sin_stock')),
  customer_name               text not null,
  customer_phone              text not null,
  customer_email              text,
  total                       numeric(10, 2) not null check (total >= 0),
  deposit_percent             numeric(5, 2) not null default 50,
  due_date                    date not null,
  stripe_checkout_session_id  text unique,
  completed_sale_id           uuid references public.sales(id),
  created_by                  uuid references auth.users(id),
  cancelled_by                uuid references auth.users(id),
  cancelled_at                timestamptz,
  created_at                  timestamptz not null default now()
);

create index if not exists layaways_status_idx on public.layaways (status);
create index if not exists layaways_due_date_idx on public.layaways (due_date);

alter table public.layaways enable row level security;

drop policy if exists "authenticated read" on public.layaways;
create policy "authenticated read" on public.layaways for select to authenticated using (true);

-- No insert/update/delete policy: all writes go through the RPCs in
-- migrations 0013/0014, which are security definer.

create table if not exists public.layaway_items (
  id                uuid primary key default gen_random_uuid(),
  layaway_id        uuid not null references public.layaways(id) on delete cascade,
  product_id        uuid references public.products(id) on delete set null,
  product_name      text not null,
  quantity          integer not null check (quantity > 0),
  unit_price        numeric(10, 2) not null check (unit_price >= 0),
  unit_cost_price   numeric(10, 2) not null check (unit_cost_price >= 0)
);

create index if not exists layaway_items_layaway_idx on public.layaway_items (layaway_id);

alter table public.layaway_items enable row level security;

drop policy if exists "authenticated read" on public.layaway_items;
create policy "authenticated read" on public.layaway_items for select to authenticated using (true);

-- Cost masking, same table-level-revoke + column-level-re-grant pattern as
-- products (0008) and sale_items (0011) — applied from day one this time.
revoke select on public.layaway_items from anon, authenticated;
grant select (
  id, layaway_id, product_id, product_name, quantity, unit_price
) on public.layaway_items to authenticated;

create or replace view public.layaway_items_view as
select
  id, layaway_id, product_id, product_name, quantity, unit_price,
  case when public.is_admin() then unit_cost_price else null end as unit_cost_price
from public.layaway_items;

grant select on public.layaway_items_view to authenticated;

create table if not exists public.layaway_payments (
  id            uuid primary key default gen_random_uuid(),
  layaway_id    uuid not null references public.layaways(id) on delete cascade,
  amount        numeric(10, 2) not null check (amount > 0),
  method        text not null check (method in ('stripe', 'efectivo')),
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now()
);

create index if not exists layaway_payments_layaway_idx on public.layaway_payments (layaway_id);

alter table public.layaway_payments enable row level security;

drop policy if exists "authenticated read" on public.layaway_payments;
create policy "authenticated read" on public.layaway_payments for select to authenticated using (true);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'layaways'
  ) then
    alter publication supabase_realtime add table public.layaways;
  end if;
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'layaway_payments'
  ) then
    alter publication supabase_realtime add table public.layaway_payments;
  end if;
end;
$$;
