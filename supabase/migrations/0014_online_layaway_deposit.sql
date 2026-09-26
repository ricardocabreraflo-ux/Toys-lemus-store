-- supabase/migrations/0014_online_layaway_deposit.sql
-- Online apartado deposits: called only by stripe-webhook (service_role),
-- never directly from the browser. Locked down the same way
-- record_online_sale was fixed in migration 0011 — explicit revoke from
-- anon/authenticated (not just public) PLUS an internal role check, from
-- day one this time.

create or replace function public.record_online_layaway_deposit(
  p_stripe_checkout_session_id text,
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
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'No autorizado';
  end if;

  -- Idempotencia: Stripe puede reenviar el mismo evento más de una vez.
  select id into v_layaway_id from public.layaways where stripe_checkout_session_id = p_stripe_checkout_session_id;
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
    total, deposit_percent, due_date, stripe_checkout_session_id
  ) values (
    'online', 'activo', p_customer_name, p_customer_phone, p_customer_email,
    p_total, 50, current_date + 15, p_stripe_checkout_session_id
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
      values (v_layaway_id, v_item.product_id, '(producto ya no existe)', v_item.quantity, 0, 0);
      continue;
    end if;

    if v_stock < v_item.quantity then
      v_oversold := true;
      update public.products set stock_online = 0 where id = v_item.product_id;
    else
      update public.products set stock_online = stock_online - v_item.quantity where id = v_item.product_id;
    end if;

    insert into public.layaway_items (layaway_id, product_id, product_name, quantity, unit_price, unit_cost_price)
    values (v_layaway_id, v_item.product_id, v_name, v_item.quantity, v_item.unit_price, v_cost);
  end loop;

  insert into public.layaway_payments (layaway_id, amount, method, created_by)
  values (v_layaway_id, p_deposit_amount, 'stripe', null);

  if v_oversold then
    update public.layaways set status = 'revisar_sin_stock' where id = v_layaway_id;
  end if;

  return v_layaway_id;
end;
$$;

revoke all on function public.record_online_layaway_deposit(text, text, text, text, numeric, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.record_online_layaway_deposit(text, text, text, text, numeric, numeric, jsonb) to service_role;
