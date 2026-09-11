-- supabase/migrations/0026_sku_y_tallas.sql
-- Tercer identificador de producto: SKU / Modelo (junto a Clave y Código
-- de Barras). Y un 4to nivel de taxonomía, Talla, para la línea Shein
-- (Línea -> Categoría -> Subcategoría -> Talla), ya que la ropa necesita
-- distinguir tallas dentro de cada subcategoría.

alter table public.products add column if not exists sku text;

create table if not exists public.sizes (
  id uuid primary key default gen_random_uuid(),
  subcategory_id uuid not null references public.subcategories(id) on delete cascade,
  name text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (subcategory_id, name)
);

create index if not exists sizes_subcategory_idx on public.sizes (subcategory_id);

alter table public.sizes enable row level security;

drop policy if exists "public read" on public.sizes;
create policy "public read" on public.sizes for select to anon, authenticated using (true);
drop policy if exists "authenticated write" on public.sizes;
create policy "authenticated write" on public.sizes for all to authenticated using (true) with check (true);

alter table public.products add column if not exists size_id uuid references public.sizes(id);
create index if not exists products_size_idx on public.products (size_id);

-- sku y size_id no son sensibles (igual que barcode/code): se otorgan sin
-- máscara, sin necesidad de pasar por el CASE WHEN de products_view.
revoke select on public.products from anon, authenticated;
grant select (
  id, code, name, product_line_id, category_id, subcategory_id, barcode, price,
  stock_online, stock_fisica, published_online, created_at, updated_at, sku, size_id
) on public.products to anon, authenticated;

create or replace view public.products_view as
select
  id, code, name, product_line_id, category_id, price,
  stock_online, stock_fisica, published_online, created_at, updated_at,
  case when public.is_admin() then cost_price else null end as cost_price,
  subcategory_id, barcode,
  case when auth.uid() is not null then suggested_price else null end as suggested_price,
  sku, size_id
from public.products;

grant select on public.products_view to anon, authenticated;
