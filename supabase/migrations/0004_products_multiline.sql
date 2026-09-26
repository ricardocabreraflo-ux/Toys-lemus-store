-- Extend products for multi-line, multi-location inventory:
--   product_line_id / category_id  — replaces the old fixed `category` enum
--   cost_price                     — what the owner paid (separate from sale price)
--   stock_online / stock_fisica    — the two locations named by the owner
--   published_online               — show/hide from the public catalog,
--                                    independent of where the stock physically is

alter table public.products
  add column if not exists product_line_id uuid references public.product_lines(id),
  add column if not exists category_id uuid references public.categories(id),
  add column if not exists cost_price numeric(10, 2) not null default 0 check (cost_price >= 0),
  add column if not exists stock_online integer not null default 0 check (stock_online >= 0),
  add column if not exists stock_fisica integer not null default 0 check (stock_fisica >= 0),
  add column if not exists published_online boolean not null default true;

-- Backfill existing rows: all current inventory came from the toy shop's
-- physical count and has been driving the public catalog, so it becomes
-- the "Toys" line, keeps its old category mapped to the new categories
-- table, and its old `stock` becomes `stock_online` (stock_fisica starts
-- at 0 — the owner can transfer into it once they're ready).
update public.products p
set
  product_line_id = pl.id,
  category_id = c.id,
  stock_online = p.stock
from public.product_lines pl
join public.categories c on c.product_line_id = pl.id
where pl.name = 'Toys'
  and p.product_line_id is null
  and c.name = case p.category
    when 'munecas' then 'Muñecas y Princesas'
    when 'accion' then 'Acción y Superhéroes'
    when 'vehiculos' then 'Vehículos y Pistas'
    when 'juegosmesa' then 'Juegos de Mesa'
    when 'nerf' then 'Nerf y Aire Libre'
    when 'creativos' then 'Creativos y Sensorial'
  end;

alter table public.products
  alter column product_line_id set not null,
  alter column category_id set not null;

alter table public.products drop column if exists category;
alter table public.products drop column if exists stock;

create index if not exists products_line_idx on public.products (product_line_id);
create index if not exists products_category_idx on public.products (category_id);
create index if not exists products_published_idx on public.products (published_online);
