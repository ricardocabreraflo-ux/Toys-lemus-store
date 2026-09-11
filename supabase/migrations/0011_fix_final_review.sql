-- supabase/migrations/0011_fix_final_review.sql
-- Fixes 3 issues found in the Fase 2 final whole-branch review:
--
-- 1) record_online_sale was only `revoke ... from public`, which does NOT
--    remove the automatic `grant execute on functions to anon, authenticated`
--    that Supabase's `alter default privileges` bootstrap applies to every
--    new function. Confirmed live: anon could call the RPC directly via
--    PostgREST. Fix: revoke from anon/authenticated explicitly too, AND add
--    an internal guard so only the service_role JWT (used by the
--    stripe-webhook Edge Function) can execute it, mirroring the pattern
--    already used for products.cost_price in migration 0008.
--
-- 2) sale_items had the same gap as products did before 0008: a table-level
--    grant survives even though the column-masking is meant to happen via
--    sale_items_view. A vendedor session could read unit_cost_price by
--    querying the base table directly. Fix: full revoke + column-level
--    re-grant excluding unit_cost_price, same pattern as 0008.
--
-- 3) mark_sale_delivered only accepted status = 'pagado', so orders that
--    landed in 'revisar_sin_stock' (oversold online orders) had no way to
--    ever be marked resolved/delivered. Fix: also accept that status.
--
-- Also fixes the companion bug to (2) below: create-checkout-session now
-- computes the promotion-discounted price per item and charges that in
-- Stripe. record_online_sale used to re-look-up the live products.price
-- (full price, ignoring promotions) when recording the sale, which would
-- make bookkeeping disagree with what Stripe actually charged. It now
-- trusts the unit_price captured in cart metadata at checkout time (the
-- price Stripe actually charged), and only re-reads stock/cost/name live.

-- ---------- 1) record_online_sale: lock down to service_role only,
--              and trust the checkout-time unit_price ----------
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

-- ---------- 2) sale_items: block direct reads of unit_cost_price ----------
revoke select on public.sale_items from anon, authenticated;
grant select (
  id, sale_id, product_id, product_name, quantity, unit_price
) on public.sale_items to authenticated;

-- ---------- 3) mark_sale_delivered: also resolve revisar_sin_stock orders ----------
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
  if v_status not in ('pagado', 'revisar_sin_stock') then
    raise exception 'Este pedido no está pendiente de entrega';
  end if;

  update public.sales
    set status = 'entregado', delivered_by = auth.uid(), delivered_at = now()
    where id = p_sale_id;
end;
$$;

revoke all on function public.mark_sale_delivered(uuid) from public;
grant execute on function public.mark_sale_delivered(uuid) to authenticated;
