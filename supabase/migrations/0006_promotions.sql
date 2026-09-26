-- Discounts scoped to a whole product line or a single category, with an
-- optional validity window. The catalog and admin both read only "active"
-- (flag + within window) promotions to compute a discounted price.

create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  scope_type text not null check (scope_type in ('line', 'category')),
  product_line_id uuid references public.product_lines(id) on delete cascade,
  category_id uuid references public.categories(id) on delete cascade,
  discount_percent numeric(5, 2) not null check (discount_percent > 0 and discount_percent <= 100),
  starts_at timestamptz,
  ends_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint promotions_scope_matches_target check (
    (scope_type = 'line' and product_line_id is not null and category_id is null) or
    (scope_type = 'category' and category_id is not null and product_line_id is null)
  )
);

alter table public.promotions enable row level security;

drop policy if exists "public read" on public.promotions;
create policy "public read" on public.promotions for select to anon, authenticated using (true);
drop policy if exists "authenticated write" on public.promotions;
create policy "authenticated write" on public.promotions for all to authenticated using (true) with check (true);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'promotions'
  ) then
    alter publication supabase_realtime add table public.promotions;
  end if;
end;
$$;
