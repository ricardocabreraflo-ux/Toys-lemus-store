-- Editable product lines (Toys, Electrónica, Cosméticos, Shein, ...) and
-- their categories, so new lines/categories can be added from the admin
-- panel without a code change.

create table if not exists public.product_lines (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  product_line_id uuid not null references public.product_lines(id) on delete cascade,
  name text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (product_line_id, name)
);

create index if not exists categories_line_idx on public.categories (product_line_id);

alter table public.product_lines enable row level security;
alter table public.categories enable row level security;

drop policy if exists "public read" on public.product_lines;
create policy "public read" on public.product_lines for select to anon, authenticated using (true);
drop policy if exists "authenticated write" on public.product_lines;
create policy "authenticated write" on public.product_lines for all to authenticated using (true) with check (true);

drop policy if exists "public read" on public.categories;
create policy "public read" on public.categories for select to anon, authenticated using (true);
drop policy if exists "authenticated write" on public.categories;
create policy "authenticated write" on public.categories for all to authenticated using (true) with check (true);

-- Seed the lines the owner named, and the existing toy categories as the
-- "Toys" line's subcategories (matching the values already used by
-- products.category before it's migrated in the next migration).
insert into public.product_lines (name, sort_order) values
  ('Toys', 0),
  ('Electrónica', 1),
  ('Cosméticos', 2),
  ('Shein', 3),
  ('Esquimal', 4),
  ('Terramar', 5),
  ('Betterware', 6)
on conflict (name) do nothing;

insert into public.categories (product_line_id, name, sort_order)
select pl.id, c.name, c.sort_order
from public.product_lines pl
cross join (values
  ('Muñecas y Princesas', 0),
  ('Acción y Superhéroes', 1),
  ('Vehículos y Pistas', 2),
  ('Juegos de Mesa', 3),
  ('Nerf y Aire Libre', 4),
  ('Creativos y Sensorial', 5)
) as c(name, sort_order)
where pl.name = 'Toys'
on conflict (product_line_id, name) do nothing;
