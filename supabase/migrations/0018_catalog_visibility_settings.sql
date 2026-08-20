-- supabase/migrations/0018_catalog_visibility_settings.sql
-- Ricardo wants only "Toys" visible on the public catalog for now, with a
-- per-line on/off switch in Admin, plus a place to hide/show the
-- "Productos activos" stat. Both are pure display settings — RLS follows
-- the exact same public-read / admin-write pattern already used for
-- product_lines/categories/promotions (see 0008_admin_only_writes.sql).

alter table public.product_lines
  add column if not exists visible_public boolean not null default true;

-- Toys stays visible; every other existing line starts hidden, matching
-- exactly what Ricardo asked for. New lines created after this migration
-- default to visible (see the column default above) unless an admin turns
-- them off from the new Ajustes tab.
update public.product_lines set visible_public = (name = 'Toys');

create table if not exists public.site_settings (
  id                  boolean primary key default true,
  show_products_stat  boolean not null default false,
  constraint site_settings_single_row check (id)
);

insert into public.site_settings (id) values (true) on conflict (id) do nothing;

alter table public.site_settings enable row level security;

drop policy if exists "public read" on public.site_settings;
create policy "public read" on public.site_settings
  for select to anon, authenticated using (true);

drop policy if exists "admin write" on public.site_settings;
create policy "admin write" on public.site_settings for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

notify pgrst, 'reload schema';
