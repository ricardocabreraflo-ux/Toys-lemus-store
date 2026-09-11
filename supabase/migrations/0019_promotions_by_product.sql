-- supabase/migrations/0019_promotions_by_product.sql
-- Ricardo wants promotions that target one specific product (searchable
-- by name in Admin), not just a whole line or category. Adds the column
-- and widens the scope_type/scope-matches-target constraints to a
-- three-way check. See docs/superpowers/specs/2026-08-20-promociones-por-producto-design.md.

alter table public.promotions
  add column if not exists product_id uuid references public.products(id) on delete cascade;

-- Drop whatever the scope_type check constraint actually ended up named
-- (Postgres auto-names an inline column check; find it dynamically
-- instead of guessing, so a wrongly-guessed name can't leave a stale
-- constraint behind that still blocks 'product' rows).
do $$
declare
  con record;
begin
  for con in
    select c.conname
    from pg_constraint c
    join pg_class rel on rel.oid = c.conrelid
    where rel.relname = 'promotions'
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%scope_type%'
  loop
    execute format('alter table public.promotions drop constraint %I', con.conname);
  end loop;
end;
$$;

alter table public.promotions add constraint promotions_scope_type_check
  check (scope_type in ('line', 'category', 'product'));

alter table public.promotions drop constraint if exists promotions_scope_matches_target;
alter table public.promotions add constraint promotions_scope_matches_target check (
  (scope_type = 'line' and product_line_id is not null and category_id is null and product_id is null) or
  (scope_type = 'category' and category_id is not null and product_line_id is null and product_id is null) or
  (scope_type = 'product' and product_id is not null and product_line_id is null and category_id is null)
);

notify pgrst, 'reload schema';
