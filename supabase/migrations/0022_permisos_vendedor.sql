-- supabase/migrations/0022_permisos_vendedor.sql
-- Ricardo wants a way to grant/revoke specific permissions to the
-- vendedor role from Admin, instead of them being fixed in code. This
-- adds the first one — canceling an apartado (it releases reserved
-- stock, a more consequential action than recording a payment) — off
-- by default, structured so more toggles can be added later as more
-- columns on this same table. See
-- docs/superpowers/specs/2026-08-21-permisos-vendedor-design.md.

create table if not exists public.vendedor_permissions (
  id                    boolean primary key default true,
  can_cancel_layaways   boolean not null default false,
  constraint vendedor_permissions_single_row check (id)
);

insert into public.vendedor_permissions (id) values (true) on conflict (id) do nothing;

alter table public.vendedor_permissions enable row level security;

drop policy if exists "authenticated read" on public.vendedor_permissions;
create policy "authenticated read" on public.vendedor_permissions
  for select to authenticated using (true);

drop policy if exists "admin write" on public.vendedor_permissions;
create policy "admin write" on public.vendedor_permissions for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'vendedor_permissions'
  ) then
    alter publication supabase_realtime add table public.vendedor_permissions;
  end if;
end;
$$;

-- Add the permission check to the existing cancel_layaway function —
-- everything else about it (finding the layaway, restoring stock,
-- marking it cancelled) is unchanged.
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

  if not public.is_admin() then
    if not exists (select 1 from public.vendedor_permissions where can_cancel_layaways) then
      raise exception 'No autorizado para cancelar apartados';
    end if;
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

notify pgrst, 'reload schema';
