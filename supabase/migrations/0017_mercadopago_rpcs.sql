-- supabase/migrations/0017_mercadopago_rpcs.sql
-- Update record_online_sale and record_online_layaway_deposit for
-- Mercado Pago: they now receive a single payment id (Mercado Pago has no
-- separate "payment intent" concept like Stripe did) and record
-- payment_method/method as 'mercadopago'. Idempotency, the service_role-only
-- guard, and the oversell-handling logic are unchanged from migration 0015.
--
-- record_online_sale's parameter list SHRINKS (6 args -> 5 args: removed
-- p_stripe_payment_intent_id), which is a different function signature in
-- Postgres (identity = name + argument types) — the old 6-arg overload must
-- be dropped explicitly, `create or replace` alone would just add a second
-- overload instead of replacing it. record_online_layaway_deposit keeps the
-- same 7-argument shape (only a parameter NAME changed), so a plain
-- `create or replace` is enough for it.

drop function if exists public.record_online_sale(text, text, text, text, text, jsonb);

create or replace function public.record_online_sale(
  p_payment_id text,
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
  v_cost numeric(10,2);
  v_name text;
  v_total numeric(10,2) := 0;
  v_oversold boolean := false;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'No autorizado';
  end if;

  -- Idempotencia: Mercado Pago puede reenviar el mismo aviso más de una vez.
  select id into v_sale_id from public.sales where payment_id = p_payment_id;
  if v_sale_id is not null then
    return v_sale_id;
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Sin productos en el pedido';
  end if;

  insert into public.sales (
    channel, status, customer_name, customer_phone, customer_email,
    payment_method, payment_id, total
  ) values (
    'online', 'pagado', p_customer_name, p_customer_phone, p_customer_email,
    'mercadopago', p_payment_id, 0
  ) returning id into v_sale_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer, unit_price numeric)
  loop
    if v_item.unit_price is null or v_item.unit_price < 0 then
      raise exception 'Precio inválido en el pedido';
    end if;

    select stock_online, cost_price, name
      into v_stock, v_cost, v_name
      from public.products where id = v_item.product_id for update;

    if v_stock is null then
      v_oversold := true;
      insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
      values (v_sale_id, null, '(producto ya no existe)', v_item.quantity, 0, 0);
      continue;
    end if;

    if v_stock < v_item.quantity then
      v_oversold := true;
      update public.products set stock_online = 0 where id = v_item.product_id;
    else
      update public.products set stock_online = stock_online - v_item.quantity where id = v_item.product_id;
    end if;

    insert into public.sale_items (sale_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_sale_id, v_item.product_id, v_name, v_item.quantity, v_item.unit_price, v_cost);

    v_total := v_total + v_item.unit_price * v_item.quantity;
  end loop;

  update public.sales
    set total = v_total, status = case when v_oversold then 'revisar_sin_stock' else 'pagado' end
    where id = v_sale_id;

  return v_sale_id;
end;
$$;

revoke all on function public.record_online_sale(text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.record_online_sale(text, text, text, text, jsonb) to service_role;

create or replace function public.record_online_layaway_deposit(
  p_payment_id text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_total numeric,
  p_deposit_amount numeric,
  p_items jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_layaway_id uuid;
  v_item record;
  v_stock integer;
  v_cost numeric(10,2);
  v_name text;
  v_oversold boolean := false;
  v_reserved integer;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'No autorizado';
  end if;

  select id into v_layaway_id from public.layaways where payment_id = p_payment_id;
  if v_layaway_id is not null then
    return v_layaway_id;
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Sin productos en el apartado';
  end if;
  if p_deposit_amount is null or p_deposit_amount <= 0 then
    raise exception 'Anticipo inválido';
  end if;
  if p_total is null or p_total < p_deposit_amount then
    raise exception 'Total inválido';
  end if;

  insert into public.layaways (
    channel, status, customer_name, customer_phone, customer_email,
    total, deposit_percent, due_date, payment_id
  ) values (
    'online', 'activo', p_customer_name, p_customer_phone, p_customer_email,
    p_total, 50, current_date + 15, p_payment_id
  ) returning id into v_layaway_id;

  for v_item in select * from jsonb_to_recordset(p_items) as x(product_id uuid, quantity integer, unit_price numeric)
  loop
    if v_item.unit_price is null or v_item.unit_price < 0 then
      raise exception 'Precio inválido en el apartado';
    end if;

    select stock_online, cost_price, name
      into v_stock, v_cost, v_name
      from public.products where id = v_item.product_id for update;

    if v_stock is null then
      v_oversold := true;
      insert into public.layaway_items (layaway_id, product_id, product_name, quantity, unit_price, unit_cost_price)
      values (v_layaway_id, null, '(producto ya no existe)', v_item.quantity, 0, 0);
      continue;
    end if;

    if v_stock < v_item.quantity then
      v_oversold := true;
      v_reserved := v_stock;
      update public.products set stock_online = 0 where id = v_item.product_id;
    else
      v_reserved := v_item.quantity;
      update public.products set stock_online = stock_online - v_item.quantity where id = v_item.product_id;
    end if;

    insert into public.layaway_items (layaway_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_layaway_id, v_item.product_id, v_name, v_reserved, v_item.unit_price, v_cost);
  end loop;

  insert into public.layaway_payments (layaway_id, amount, method, created_by)
  values (v_layaway_id, p_deposit_amount, 'mercadopago', null);

  if v_oversold then
    update public.layaways set status = 'revisar_sin_stock' where id = v_layaway_id;
  end if;

  return v_layaway_id;
end;
$$;

revoke all on function public.record_online_layaway_deposit(text, text, text, text, numeric, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.record_online_layaway_deposit(text, text, text, text, numeric, numeric, jsonb) to service_role;
