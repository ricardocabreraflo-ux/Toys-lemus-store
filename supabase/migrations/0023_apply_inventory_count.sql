-- supabase/migrations/0023_apply_inventory_count.sql

-- Aplica un conteo físico de inventario: actualiza stock_fisica de cada
-- producto contado al valor realmente contado, todo dentro de una sola
-- transacción (si cualquier producto falla, ninguno se actualiza).
-- A diferencia de delete_sale/cancel_layaway (solo-admin), esta función
-- la puede llamar también el vendedor: el conteo es una tarea operativa
-- que él también hace.
create or replace function public.apply_inventory_count(p_items jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item record;
  v_exists boolean;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Agrega al menos un producto al conteo';
  end if;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, counted integer)
  loop
    if v_item.counted is null or v_item.counted < 0 then
      raise exception 'Cantidad contada inválida';
    end if;

    select exists(select 1 from public.products where id = v_item.product_id for update) into v_exists;
    if not v_exists then
      raise exception 'Producto no encontrado';
    end if;

    update public.products set stock_fisica = v_item.counted where id = v_item.product_id;
  end loop;
end;
$$;

revoke all on function public.apply_inventory_count(jsonb) from public;
grant execute on function public.apply_inventory_count(jsonb) to authenticated;

notify pgrst, 'reload schema';
