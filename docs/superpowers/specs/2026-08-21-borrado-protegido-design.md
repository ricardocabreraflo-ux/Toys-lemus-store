# Borrado protegido de ventas y productos

## Contexto

Del lote de pendientes de Admin, este es el segundo: proteger el
borrado de ventas y productos con un código de seguridad, para evitar
borrados accidentales.

Al explorar el proyecto se confirmó que:
- Borrar un producto ya existe hoy (pestaña Inventario) y ya es
  exclusivo de admin — el rol vendedor ni ve el botón.
- Borrar una venta **no existe como función todavía**. Hoy no hay
  manera de eliminar una venta ya registrada, ni una lista de ventas
  físicas individuales (solo aparecen agregadas en Reportes).

Ricardo confirmó (vía preguntas de aclaración): quiere agregar la
función de borrar ventas (tanto en línea como físicas), que borrar una
venta regrese el stock vendido al inventario, y que el código de
seguridad sea un PIN corto y separado de su contraseña de acceso
(no su login), configurable por él mismo.

## Alcance

Incluido:
- Código de seguridad (PIN) configurable desde Ajustes, admin-only.
- Función nueva: borrar una venta (en línea o física), que regresa el
  stock de los productos vendidos.
- Lista nueva de "Ventas recientes" en la pestaña Vender (no existe
  hoy ninguna lista de ventas físicas individuales).
- Botón de borrar en Pedidos (ventas en línea) — pendientes y ya
  entregadas.
- El código se pide antes de borrar, tanto para ventas como para
  productos (el borrado de producto ya existente ahora también lo
  pide).

Fuera de alcance:
- Apartados/layaways — ya tienen su propio flujo de "cancelar" (no es
  un borrado, y no se toca en este bloque).
- Roles de vendedor (tarea aparte, #71) — aquí el borrado sigue siendo
  100% exclusivo de admin, como ya es hoy.
- Cualquier capa de seguridad más allá de "evitar un clic accidental"
  (ver nota de modelo de amenaza abajo).

## Modelo de datos

```sql
create table public.security_settings (
  id          boolean primary key default true,
  delete_pin  text not null default '0000',
  constraint security_settings_single_row check (id)
);

insert into public.security_settings (id) values (true) on conflict (id) do nothing;
```

Solo lectura/escritura de admin — mismo patrón de una sola política
`for all using (public.is_admin())` que ya usa `fixed_expenses`, sin
lectura pública. El PIN se guarda en texto plano, protegido únicamente
por RLS — ver la nota de modelo de amenaza más abajo sobre por qué esto
es suficiente para lo que se está pidiendo.

**Función `delete_sale`** (SECURITY DEFINER, admin-only por dentro):

```sql
create or replace function public.delete_sale(p_sale_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_channel text;
  v_item record;
begin
  if not public.is_admin() then
    raise exception 'No autorizado';
  end if;

  select channel into v_channel from public.sales where id = p_sale_id;
  if v_channel is null then
    raise exception 'Venta no encontrada';
  end if;

  for v_item in
    select product_id, quantity from public.sale_items
    where sale_id = p_sale_id and product_id is not null
  loop
    if v_channel = 'online' then
      update public.products set stock_online = stock_online + v_item.quantity where id = v_item.product_id;
    else
      update public.products set stock_fisica = stock_fisica + v_item.quantity where id = v_item.product_id;
    end if;
  end loop;

  delete from public.sales where id = p_sale_id; -- sale_items se borra en cascada
end;
$$;
```

**Limitación conocida, aceptada:** si una venta en línea quedó marcada
"Revisar — sin stock" (se vendió más de lo que realmente había), el
stock real descontado en su momento fue menor a la cantidad guardada en
`sale_items` (se limitó a lo disponible). Al borrar esa venta, el
sistema regresa la cantidad completa de `sale_items`, no solo lo que
realmente se descontó — puede sobre-restaurar unas piezas en ese caso
puntual. Es una venta que de por sí ya requiere revisión manual, así
que no se resuelve aquí; no aplica a ventas normales ni a ventas
físicas (esas nunca se sobrevenden, `create_sale_fisica` ya lo impide).

## Componentes

### 1. Ajustes → Seguridad

Nueva sección en la pestaña Ajustes (ya admin-only) con un campo de
texto para el PIN actual — guarda al cambiar, mismo patrón que el resto
de Ajustes.

### 2. Pedidos — borrar venta en línea

Tanto la tabla de pendientes como la de entregadas ganan una columna
con botón de borrar (icono, mismo estilo que el resto de la app). Al
hacer clic: confirmación de siempre → si acepta, pide el PIN → si
coincide, llama a `delete_sale` vía RPC y refresca la lista.

### 3. Vender — "Ventas recientes" (nuevo)

Debajo del carrito de venta física, una tabla nueva con las últimas 20
ventas del canal físico (fecha, total, botón de borrar) — no existe hoy
ninguna forma de ver ventas físicas individuales, así que esto es
aditivo puro, no reemplaza nada. Mismo flujo de confirmación + PIN que
Pedidos.

### 4. Inventario — borrar producto (ya existe, se le agrega el PIN)

`deleteProduct()` ya tiene su `confirm()` — se le agrega el mismo paso
de PIN antes de llamar a `supabase.from('products').delete()`, sin
cambiar el resto de su comportamiento (sigue fallando igual si el
producto tiene referencias que lo impiden).

### 5. El flujo del PIN (compartido)

Una función de ayuda `askForDeletePin()` reutilizada por los cuatro
puntos de borrado de arriba:

1. `confirm()` de siempre ("¿Seguro que quieres borrar...?").
2. Si acepta: `prompt()` pidiendo el PIN.
3. Si cancela el prompt (`null`) o el texto no coincide con el PIN
   guardado: aviso "Código incorrecto" (o nada si canceló), no se borra
   nada.
4. Si coincide: procede con el borrado real.

**Modelo de amenaza, explícito:** este PIN evita un clic accidental
(ej. el teléfono desbloqueado en otras manos) — no es una barrera
"a prueba de todo". El PIN viaja al cliente ya autenticado como admin
(protegido por RLS, no público), y la comparación ocurre en el
navegador; un admin que ya entró al panel podría en teoría saltárselo
con herramientas de programador. Como hoy solo Ricardo entra como
admin, esto cubre exactamente lo que pidió. No se agrega verificación
del PIN del lado del servidor — sería una capa de seguridad real contra
un admin malicioso, que no es el problema que se está resolviendo aquí.

## Manejo de errores

- PIN incorrecto: aviso claro, nada se borra.
- `delete_sale` sin permisos (no admin): la función ya rechaza con
  "No autorizado" — no debería alcanzarse desde la UI (el botón de
  borrar ya es admin-only), pero la función se protege de todos modos.
- Falla de red en cualquier punto: aviso de error existente
  (`showToast`), nada se pierde.

## Pruebas

Sin suite automatizada — en vivo con Ricardo:

1. Configurar un PIN nuevo en Ajustes → Seguridad.
2. Borrar un producto: confirmar que pide el PIN, y que un PIN
   incorrecto cancela sin borrar.
3. Borrar una venta en línea desde Pedidos (pendiente y entregada):
   confirmar que el stock del producto regresa.
4. Hacer una venta física de prueba, verla aparecer en "Ventas
   recientes" en Vender, borrarla y confirmar que el stock física
   regresa.
5. Confirmar que el rol vendedor no ve ningún botón de borrar venta ni
   tiene forma de llegar al PIN.
