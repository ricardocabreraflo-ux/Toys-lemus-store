-- supabase/migrations/0008_admin_only_writes.sql
-- Vendedor (and anonymous catalog visitors) must never be able to read
-- cost_price, and only admin can edit products/taxonomy/promotions or run
-- traspasos — vendedor only sells and views.

-- --- Cost price masking ---
-- Column-level revoke blocks reading cost_price directly off the base
-- table (including via a REST call that bypasses the app's UI). The view
-- below is the only way anyone reads it — and it nulls it out unless
-- is_admin() is true for the caller.
revoke select (cost_price) on public.products from anon, authenticated;

create or replace view public.products_view as
select
  id, code, name, product_line_id, category_id, price,
  stock_online, stock_fisica, published_online, created_at, updated_at,
  case when public.is_admin() then cost_price else null end as cost_price
from public.products;

grant select on public.products_view to anon, authenticated;

-- --- Admin-only writes ---
drop policy if exists "authenticated write" on public.products;
drop policy if exists "admin write" on public.products;
create policy "admin write" on public.products for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "authenticated write" on public.product_lines;
drop policy if exists "admin write" on public.product_lines;
create policy "admin write" on public.product_lines for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "authenticated write" on public.categories;
drop policy if exists "admin write" on public.categories;
create policy "admin write" on public.categories for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "authenticated write" on public.promotions;
drop policy if exists "admin write" on public.promotions;
create policy "admin write" on public.promotions for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "authenticated insert" on public.stock_transfers;
drop policy if exists "admin insert" on public.stock_transfers;
create policy "admin insert" on public.stock_transfers for insert
  to authenticated with check (public.is_admin());

-- --- Guard transfer_stock() itself ---
-- The Fase 1 function is `security invoker` (default), so its internal
-- UPDATE on products already runs under the new admin-only RLS policy —
-- but an RLS-filtered UPDATE just matches 0 rows silently instead of
-- raising an error. Without this explicit check, a vendedor calling this
-- RPC directly would get a "successful" response, a bogus stock_transfers
-- audit row, and no actual stock movement. Re-create with a loud guard.
create or replace function public.transfer_stock(
  p_product_id uuid,
  p_from text,
  p_to text,
  p_quantity integer,
  p_note text default null
) returns void
language plpgsql
as $$
declare
  v_from_stock integer;
begin
  if not public.is_admin() then
    raise exception 'Solo el admin puede hacer traspasos';
  end if;
  if p_from = p_to then
    raise exception 'El origen y destino deben ser distintos';
  end if;
  if p_from not in ('online', 'fisica') or p_to not in ('online', 'fisica') then
    raise exception 'Ubicación inválida';
  end if;
  if p_quantity <= 0 then
    raise exception 'La cantidad debe ser mayor a cero';
  end if;

  if p_from = 'online' then
    select stock_online into v_from_stock from public.products where id = p_product_id for update;
  else
    select stock_fisica into v_from_stock from public.products where id = p_product_id for update;
  end if;

  if v_from_stock is null then
    raise exception 'Producto no encontrado';
  end if;
  if v_from_stock < p_quantity then
    raise exception 'No hay suficiente stock en % (% disponibles)', p_from, v_from_stock;
  end if;

  if p_from = 'online' then
    update public.products set stock_online = stock_online - p_quantity where id = p_product_id;
  else
    update public.products set stock_fisica = stock_fisica - p_quantity where id = p_product_id;
  end if;

  if p_to = 'online' then
    update public.products set stock_online = stock_online + p_quantity where id = p_product_id;
  else
    update public.products set stock_fisica = stock_fisica + p_quantity where id = p_product_id;
  end if;

  insert into public.stock_transfers (product_id, from_location, to_location, quantity, note, created_by)
  values (p_product_id, p_from, p_to, p_quantity, p_note, auth.uid());
end;
$$;

alter function public.transfer_stock(uuid, text, text, integer, text) set search_path = public;
