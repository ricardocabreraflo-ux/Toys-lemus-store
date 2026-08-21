-- supabase/migrations/0021_borrado_protegido.sql
-- Ricardo wants a short PIN (separate from his login password) that
-- guards accidental deletion of products and sales, plus the ability
-- to delete a sale at all (doesn't exist yet) — deleting a sale
-- restores the stock it sold. See
-- docs/superpowers/specs/2026-08-21-borrado-protegido-design.md.

create table if not exists public.security_settings (
  id          boolean primary key default true,
  delete_pin  text not null default '0000',
  constraint security_settings_single_row check (id)
);

insert into public.security_settings (id) values (true) on conflict (id) do nothing;

alter table public.security_settings enable row level security;

drop policy if exists "admin only" on public.security_settings;
create policy "admin only" on public.security_settings for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'security_settings'
  ) then
    alter publication supabase_realtime add table public.security_settings;
  end if;
end;
$$;

-- Deleting a sale restores the stock it sold (stock_online for
-- 'online' sales, stock_fisica for 'fisica' sales), then deletes the
-- sale (sale_items cascades). Known, accepted limitation: an 'online'
-- sale marked 'revisar_sin_stock' was oversold, so its real stock
-- deduction at the time was less than sale_items.quantity (clamped to
-- 0) — deleting it restores the full sale_items quantity, which can
-- over-restore by a few units in that one edge case. Those sales
-- already require manual review, so this isn't solved here.
create or replace function public.delete_sale(p_sale_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_channel text;
  v_item record;
begin
  if not public.is_admin() then
    raise exception 'No autorizado';
  end if;

  select channel into v_channel from public.sales where id = p_sale_id;
  if v_channel is null then
    raise exception 'Venta no encontrada';
  end if;

  for v_item in
    select product_id, quantity from public.sale_items
    where sale_id = p_sale_id and product_id is not null
  loop
    if v_channel = 'online' then
      update public.products set stock_online = stock_online + v_item.quantity where id = v_item.product_id;
    else
      update public.products set stock_fisica = stock_fisica + v_item.quantity where id = v_item.product_id;
    end if;
  end loop;

  delete from public.sales where id = p_sale_id;
end;
$$;

revoke all on function public.delete_sale(uuid) from public;
grant execute on function public.delete_sale(uuid) to authenticated;

notify pgrst, 'reload schema';
