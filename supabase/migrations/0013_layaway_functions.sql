-- supabase/migrations/0013_layaway_functions.sql
-- RPCs for the physical/manual side of apartados: creating one in-store,
-- registering cash abonos (which graduate the layaway into a real `sales`
-- row once fully paid), cancelling, and extending the due date. All
-- callable by admin or vendedor, same as create_sale_fisica.

-- A completed layaway becomes a normal sale so it shows up in Reportes
-- like any other — payment_method='apartado' is added here (rather than
-- reusing 'efectivo' or 'stripe') so reports don't misreport a sale that
-- was actually part deposit + part cash as 100% one or the other.
alter table public.sales drop constraint if exists sales_payment_method_check;
alter table public.sales add constraint sales_payment_method_check
  check (payment_method in ('stripe', 'efectivo', 'apartado'));

create or replace function public.create_layaway_fisica(
  p_items jsonb,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_layaway_id uuid;
  v_item record;
  v_stock integer;
  v_price numeric(10,2);
  v_cost numeric(10,2);
  v_name text;
  v_total numeric(10,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Sin productos en el apartado';
  end if;
  if p_customer_name is null or p_customer_name = '' or p_customer_phone is null or p_customer_phone = '' then
    raise exception 'Nombre y teléfono del cliente son obligatorios';
  end if;

  insert into public.layaways (
    channel, status, customer_name, customer_phone, customer_email,
    total, deposit_percent, due_date, created_by
  ) values (
    'fisica', 'activo', p_customer_name, p_customer_phone, nullif(p_customer_email, ''),
    0, 50, current_date + 15, auth.uid()
  ) returning id into v_layaway_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  loop
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
      raise exception 'Solo hay % disponibles de "%"', v_stock, v_name;
    end if;

    update public.products set stock_fisica = stock_fisica - v_item.quantity where id = v_item.product_id;

    insert into public.layaway_items (layaway_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_layaway_id, v_item.product_id, v_name, v_item.quantity, v_price, v_cost);

    v_total := v_total + v_price * v_item.quantity;
  end loop;

  update public.layaways set total = v_total where id = v_layaway_id;

  insert into public.layaway_payments (layaway_id, amount, method, created_by)
  values (v_layaway_id, round(v_total * 0.5, 2), 'efectivo', auth.uid());

  return v_layaway_id;
end;
$$;

revoke all on function public.create_layaway_fisica(jsonb, text, text, text) from public, anon, authenticated;
grant execute on function public.create_layaway_fisica(jsonb, text, text, text) to authenticated;

create or replace function public.record_layaway_abono(
  p_layaway_id uuid,
  p_amount numeric
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_channel text;
  v_total numeric(10,2);
  v_paid numeric(10,2);
  v_pending numeric(10,2);
  v_sale_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'El monto debe ser mayor a cero';
  end if;

  select status, channel, total into v_status, v_channel, v_total
    from public.layaways where id = p_layaway_id for update;
  if v_status is null then
    raise exception 'Apartado no encontrado';
  end if;
  if v_status not in ('activo', 'revisar_sin_stock') then
    raise exception 'Este apartado ya no admite abonos';
  end if;

  select coalesce(sum(amount), 0) into v_paid from public.layaway_payments where layaway_id = p_layaway_id;
  v_pending := v_total - v_paid;
  if p_amount > v_pending then
    raise exception 'El abono no puede ser mayor al saldo pendiente ($%)', v_pending;
  end if;

  insert into public.layaway_payments (layaway_id, amount, method, created_by)
  values (p_layaway_id, p_amount, 'efectivo', auth.uid());

  if v_paid + p_amount >= v_total then
    insert into public.sales (
      channel, status, customer_name, customer_phone, customer_email,
      payment_method, total, created_by
    )
    select channel, 'completada', customer_name, customer_phone, customer_email,
      'apartado', total, auth.uid()
    from public.layaways where id = p_layaway_id
    returning id into v_sale_id;

    insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    select v_sale_id, product_id, product_name, quantity, unit_price, unit_cost_price
    from public.layaway_items where layaway_id = p_layaway_id;

    update public.layaways set status = 'completado', completed_sale_id = v_sale_id where id = p_layaway_id;
    return 'completado';
  end if;

  return v_status;
end;
$$;

revoke all on function public.record_layaway_abono(uuid, numeric) from public, anon, authenticated;
grant execute on function public.record_layaway_abono(uuid, numeric) to authenticated;

create or replace function public.cancel_layaway(p_layaway_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_channel text;
  v_item record;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;

  select status, channel into v_status, v_channel from public.layaways where id = p_layaway_id for update;
  if v_status is null then
    raise exception 'Apartado no encontrado';
  end if;
  if v_status not in ('activo', 'revisar_sin_stock') then
    raise exception 'Este apartado ya no se puede cancelar';
  end if;

  for v_item in select product_id, quantity from public.layaway_items where layaway_id = p_layaway_id
  loop
    if v_item.product_id is not null then
      if v_channel = 'fisica' then
        update public.products set stock_fisica = stock_fisica + v_item.quantity where id = v_item.product_id;
      else
        update public.products set stock_online = stock_online + v_item.quantity where id = v_item.product_id;
      end if;
    end if;
  end loop;

  update public.layaways
    set status = 'cancelado', cancelled_by = auth.uid(), cancelled_at = now()
    where id = p_layaway_id;
end;
$$;

revoke all on function public.cancel_layaway(uuid) from public, anon, authenticated;
grant execute on function public.cancel_layaway(uuid) to authenticated;

create or replace function public.extend_layaway_due_date(
  p_layaway_id uuid,
  p_new_due_date date
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;
  if p_new_due_date <= current_date then
    raise exception 'La nueva fecha debe ser futura';
  end if;

  select status into v_status from public.layaways where id = p_layaway_id for update;
  if v_status is null then
    raise exception 'Apartado no encontrado';
  end if;
  if v_status not in ('activo', 'revisar_sin_stock') then
    raise exception 'Este apartado ya no se puede modificar';
  end if;

  update public.layaways set due_date = p_new_due_date where id = p_layaway_id;
end;
$$;

revoke all on function public.extend_layaway_due_date(uuid, date) from public, anon, authenticated;
grant execute on function public.extend_layaway_due_date(uuid, date) to authenticated;
