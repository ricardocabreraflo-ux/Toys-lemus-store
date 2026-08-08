-- supabase/migrations/0010_sale_functions.sql

-- ---------- Venta física (POS) ----------
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
      raise exception 'No hay suficiente stock física de "%" (% disponibles)', v_name, v_stock;
    end if;

    update public.products set stock_fisica = stock_fisica - v_item.quantity where id = v_item.product_id;

    insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_sale_id, v_item.product_id, v_name, v_item.quantity, v_price, v_cost);

    v_total := v_total + v_price * v_item.quantity;
  end loop;

  update public.sales set total = v_total where id = v_sale_id;

  return v_sale_id;
end;
$$;

revoke all on function public.create_sale_fisica(jsonb) from public;
grant execute on function public.create_sale_fisica(jsonb) to authenticated;

-- ---------- Marcar pedido en línea como entregado ----------
create or replace function public.mark_sale_delivered(p_sale_id uuid)
returns void
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

  select status into v_status from public.sales where id = p_sale_id for update;
  if v_status is null then
    raise exception 'Pedido no encontrado';
  end if;
  if v_status <> 'pagado' then
    raise exception 'Este pedido no está pendiente de entrega';
  end if;

  update public.sales
    set status = 'entregado', delivered_by = auth.uid(), delivered_at = now()
    where id = p_sale_id;
end;
$$;

revoke all on function public.mark_sale_delivered(uuid) from public;
grant execute on function public.mark_sale_delivered(uuid) to authenticated;

-- ---------- Registrar venta en línea (llamada solo por el webhook) ----------
create or replace function public.record_online_sale(
  p_stripe_checkout_session_id text,
  p_stripe_payment_intent_id text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_items jsonb
) returns uuid
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
  v_oversold boolean := false;
begin
  -- Idempotencia: Stripe puede reenviar el mismo evento más de una vez.
  select id into v_sale_id from public.sales where stripe_checkout_session_id = p_stripe_checkout_session_id;
  if v_sale_id is not null then
    return v_sale_id;
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Sin productos en el pedido';
  end if;

  insert into public.sales (
    channel, status, customer_name, customer_phone, customer_email,
    payment_method, stripe_checkout_session_id, stripe_payment_intent_id, total
  ) values (
    'online', 'pagado', p_customer_name, p_customer_phone, p_customer_email,
    'stripe', p_stripe_checkout_session_id, p_stripe_payment_intent_id, 0
  ) returning id into v_sale_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer)
  loop
    select stock_online, price, cost_price, name
      into v_stock, v_price, v_cost, v_name
      from public.products where id = v_item.product_id for update;

    if v_stock is null then
      v_oversold := true;
      insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
      values (v_sale_id, v_item.product_id, '(producto ya no existe)', v_item.quantity, 0, 0);
      continue;
    end if;

    if v_stock < v_item.quantity then
      v_oversold := true;
      update public.products set stock_online = 0 where id = v_item.product_id;
    else
      update public.products set stock_online = stock_online - v_item.quantity where id = v_item.product_id;
    end if;

    insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_sale_id, v_item.product_id, v_name, v_item.quantity, v_price, v_cost);

    v_total := v_total + v_price * v_item.quantity;
  end loop;

  update public.sales
    set total = v_total, status = case when v_oversold then 'revisar_sin_stock' else 'pagado' end
    where id = v_sale_id;

  return v_sale_id;
end;
$$;

revoke all on function public.record_online_sale(text, text, text, text, text, jsonb) from public;
grant execute on function public.record_online_sale(text, text, text, text, text, jsonb) to service_role;
