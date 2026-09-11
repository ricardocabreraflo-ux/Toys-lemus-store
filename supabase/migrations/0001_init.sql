-- Lemus Store: product catalog + inventory
-- Public can read; only authenticated (admin) users can write.

create extension if not exists "pgcrypto";

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  code text not null default '',
  name text not null,
  category text not null check (
    category in ('munecas', 'accion', 'vehiculos', 'juegosmesa', 'nerf', 'creativos')
  ),
  price numeric(10, 2) not null check (price >= 0),
  stock integer not null default 0 check (stock >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists products_category_idx on public.products (category);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists products_set_updated_at on public.products;
create trigger products_set_updated_at
  before update on public.products
  for each row
  execute function public.set_updated_at();

alter table public.products enable row level security;

drop policy if exists "public read" on public.products;
create policy "public read"
  on public.products for select
  to anon, authenticated
  using (true);

drop policy if exists "authenticated write" on public.products;
create policy "authenticated write"
  on public.products for all
  to authenticated
  using (true)
  with check (true);

-- Realtime: allow the catalog and admin panel to subscribe to live changes.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'products'
  ) then
    alter publication supabase_realtime add table public.products;
  end if;
end;
$$;
