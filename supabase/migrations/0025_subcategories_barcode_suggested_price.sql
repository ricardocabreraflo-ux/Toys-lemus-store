-- supabase/migrations/0025_subcategories_barcode_suggested_price.sql
-- Adds a third taxonomy level (subcategoría, under categoría) for the new
-- non-toy catalogs (Shein, Cosméticos, Electrónica, ...), plus two new
-- optional product fields: `barcode` (a real scannable code, separate from
-- `code` — which stays the short internal reference/"clave corta" always
-- used for display and text search) and `suggested_price` (an internal
-- reference price, masked the same way cost_price already is: never
-- exposed to the public catalog, visible to any signed-in user).

create table if not exists public.subcategories (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories(id) on delete cascade,
  name text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (category_id, name)
);

create index if not exists subcategories_category_idx on public.subcategories (category_id);

alter table public.subcategories enable row level security;

drop policy if exists "public read" on public.subcategories;
create policy "public read" on public.subcategories for select to anon, authenticated using (true);
drop policy if exists "authenticated write" on public.subcategories;
create policy "authenticated write" on public.subcategories for all to authenticated using (true) with check (true);

alter table public.products
  add column if not exists subcategory_id uuid references public.subcategories(id),
  add column if not exists barcode text,
  add column if not exists suggested_price numeric(10,2);

create index if not exists products_subcategory_idx on public.products (subcategory_id);

-- Same masking mechanism as 0008 for cost_price: anon/authenticated lose
-- direct table-level select on the two sensitive columns, re-granted
-- column-by-column without them, so products_view's CASE expressions are
-- the only way anyone reads cost_price/suggested_price.
revoke select on public.products from anon, authenticated;
grant select (
  id, code, name, product_line_id, category_id, subcategory_id, barcode, price,
  stock_online, stock_fisica, published_online, created_at, updated_at
) on public.products to anon, authenticated;

-- CREATE OR REPLACE VIEW can only append new columns at the end (it
-- matches the old definition positionally) — the pre-existing columns
-- must stay in their original order, new ones (subcategory_id, barcode,
-- suggested_price) go after cost_price.
create or replace view public.products_view as
select
  id, code, name, product_line_id, category_id, price,
  stock_online, stock_fisica, published_online, created_at, updated_at,
  case when public.is_admin() then cost_price else null end as cost_price,
  subcategory_id, barcode,
  case when auth.uid() is not null then suggested_price else null end as suggested_price
from public.products;

grant select on public.products_view to anon, authenticated;
