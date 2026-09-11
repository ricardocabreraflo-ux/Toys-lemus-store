-- supabase/migrations/0015_fix_final_review_apartados.sql
-- Fixes 3 issues found in the final whole-branch review of the "apartados"
-- (layaway) feature:
--
-- 1) layaway_items_view and sale_items_view were only ever explicitly
--    `grant select ... to authenticated`, but never explicitly revoked from
--    anon — the same gap that migration 0011 had to close for
--    record_online_sale and sale_items (Supabase's automatic
--    `alter default privileges` bootstrap grants views to anon too). An
--    anonymous visitor with the public key could read every layaway/sale
--    line item's product name, quantity and price (unit_cost_price still
--    correctly masks to null via is_admin(), so this is a row-visibility
--    leak, not a cost leak). Fix: explicit `revoke all ... from anon` on
--    both views. Do NOT add security_invoker to these views — that would
--    break the cost-masking itself, since authenticated's own column grants
--    exclude unit_cost_price and a security-invoker view would fail to
--    evaluate the masking CASE expression even for admins. products_view has
--    its own separate protection (base-table revoke in 0008) and is out of
--    scope here.
--
-- 2) record_online_layaway_deposit's oversell branch reserved only the
--    stock that actually existed (stock_online -> 0) but inserted the
--    layaway_items row with the full ordered quantity. cancel_layaway later
--    adds back layaway_items.quantity unconditionally, so cancelling an
--    oversold online apartado released more stock than was ever reserved
--    (inventory corruption). Fix: track what was actually reserved
--    (v_reserved) and insert that into layaway_items.quantity instead of
--    the ordered quantity, in the oversold branch only.
--
-- 3) Both record_online_sale (0011) and record_online_layaway_deposit
--    (0014) have a "product was deleted" branch that inserted a
--    sale_items/layaway_items row with product_id = v_item.product_id — but
--    that id no longer exists in products, so the foreign key rejects the
--    insert and aborts the whole transaction, silently dropping an
--    already-charged Stripe payment. Fix: insert product_id = null instead
--    (the column is nullable, on delete set null) in both functions.

-- ---------- 1) lock down anon read access on the two views ----------
revoke all on public.layaway_items_view from anon;
revoke all on public.sale_items_view from anon;

-- ---------- 2) & 3) record_online_layaway_deposit: fix reserved-quantity
--              accounting and the deleted-product FK abort ----------
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
  v_reserved integer;
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
  values (v_layaway_id, p_deposit_amount, 'stripe', null);

  if v_oversold then
    update public.layaways set status = 'revisar_sin_stock' where id = v_layaway_id;
  end if;

  return v_layaway_id;
end;
$$;

revoke all on function public.record_online_layaway_deposit(text, text, text, text, numeric, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.record_online_layaway_deposit(text, text, text, text, numeric, numeric, jsonb) to service_role;

-- ---------- 3) record_online_sale: fix the deleted-product FK abort ----------
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
  v_cost numeric(10,2);
  v_name text;
  v_total numeric(10,2) := 0;
  v_oversold boolean := false;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'No autorizado';
  end if;

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

revoke all on function public.record_online_sale(text, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.record_online_sale(text, text, text, text, text, jsonb) to service_role;
