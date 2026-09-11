-- Traspasos between Online and Física, with an atomic RPC so a transfer
-- can never partially apply (decrement one side without crediting the other).

create table if not exists public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  from_location text not null check (from_location in ('online', 'fisica')),
  to_location text not null check (to_location in ('online', 'fisica')),
  quantity integer not null check (quantity > 0),
  note text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists stock_transfers_product_idx on public.stock_transfers (product_id);

alter table public.stock_transfers enable row level security;

drop policy if exists "authenticated read" on public.stock_transfers;
create policy "authenticated read" on public.stock_transfers for select to authenticated using (true);
drop policy if exists "authenticated insert" on public.stock_transfers;
create policy "authenticated insert" on public.stock_transfers for insert to authenticated with check (true);

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

revoke all on function public.transfer_stock(uuid, text, text, integer, text) from public;
grant execute on function public.transfer_stock(uuid, text, text, integer, text) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'stock_transfers'
  ) then
    alter publication supabase_realtime add table public.stock_transfers;
  end if;
end;
$$;
