-- supabase/migrations/0024_venta_libre.sql
-- Amplía create_sale_fisica para aceptar, además de líneas de catálogo,
-- líneas "libres" (una descripción y un monto, sin producto ni efecto en
-- inventario) — ver docs/superpowers/specs/2026-09-11-vender-rediseno-design.md
-- punto 6. No requiere cambios de esquema: sale_items.product_id ya acepta
-- null (se usa cuando un producto de una venta antigua se borra del
-- catálogo) y product_name ya es texto libre.

create or replace function public.create_sale_fisica(p_items jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale_id uuid;
  v_item record;
  v_stock integer;
  v_price numeric(10,2);
  v_cost numeric(10,2);
  v_name text;
  v_total numeric(10,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión para vender';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Agrega al menos un producto';
  end if;

  insert into public.sales (channel, status, payment_method, total, created_by)
  values ('fisica', 'completada', 'efectivo', 0, auth.uid())
  returning id into v_sale_id;

  for v_item in
    select * from jsonb_to_recordset(p_items)
      as x(product_id uuid, quantity integer, description text, amount numeric)
  loop
    if v_item.product_id is not null then
      if v_item.quantity is null or v_item.quantity <= 0 then
        raise exception 'Cantidad inválida';
      end if;

      select stock_fisica, price, cost_price, name
        into v_stock, v_price, v_cost, v_name
        from public.products where id = v_item.product_id for update;

      if v_stock is null then
        raise exception 'Producto no encontrado';
      end if;
      if v_stock < v_item.quantity then
        raise exception 'No hay suficiente stock física de "%" (% disponibles)', v_name, v_stock;
      end if;

      update public.products set stock_fisica = stock_fisica - v_item.quantity where id = v_item.product_id;

      insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
      values (v_sale_id, v_item.product_id, v_name, v_item.quantity, v_price, v_cost);

      v_total := v_total + v_price * v_item.quantity;
    else
      if v_item.description is null or btrim(v_item.description) = '' then
        raise exception 'La línea libre necesita una descripción';
      end if;
      if v_item.amount is null or v_item.amount <= 0 then
        raise exception 'La línea libre necesita un monto mayor a cero';
      end if;

      insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
      values (v_sale_id, null, v_item.description, 1, v_item.amount, 0);

      v_total := v_total + v_item.amount;
    end if;
  end loop;

  update public.sales set total = v_total where id = v_sale_id;

  return v_sale_id;
end;
$$;

revoke all on function public.create_sale_fisica(jsonb) from public;
grant execute on function public.create_sale_fisica(jsonb) to authenticated;
