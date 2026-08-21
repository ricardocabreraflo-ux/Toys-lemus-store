# Permisos configurables para el rol vendedor

## Contexto

Del lote de pendientes de Admin, este es el tercero. Al explorar el
proyecto se confirmó que el rol vendedor ya está bastante restringido
hoy: en Inventario solo puede ver (ningún campo editable, no ve el
costo ni el botón de borrar), y no ve las pestañas de Promociones,
Reportes, Usuarios, Ajustes, Finanzas ni Traspasos.

Lo que sí puede hacer sin restricción hoy: vender (Vender), marcar
pedidos como entregados (Pedidos), y en Apartados registrar abonos Y
cancelar apartados.

Ricardo confirmó dos cosas (vía preguntas de aclaración):
1. Quiere que **cancelar un apartado** requiera permiso — cancelar
   libera el stock reservado, una acción más delicada que cobrar un
   abono.
2. Quiere un lugar en Admin donde él pueda **prender o apagar**
   permisos del vendedor, no que queden fijos en el código — un
   interruptor, no una restricción de una sola vez.
3. Un solo conjunto de permisos aplica igual a **todos** los vendedores
   (no permisos individuales por persona — confirmado explícitamente,
   más simple y cubre su caso actual).

## Alcance

Incluido:
- Tabla de permisos del vendedor, con un primer interruptor: cancelar
  apartados (apagado por defecto).
- Interruptor en la pestaña Usuarios (ya exclusiva de admin).
- El botón "Cancelar" en Apartados desaparece para el vendedor cuando
  el permiso está apagado — no solo se deshabilita, no se renderiza.
- La función `cancel_layaway` verifica el permiso del lado del
  servidor también — la protección real no depende solo del botón.
- Arquitectura pensada para agregar más interruptores después sin
  rehacer la tabla ni el patrón (una columna booleana más, un
  interruptor más en Usuarios) — pero **no se agrega ningún otro
  interruptor en este bloque**, solo el de cancelar apartados.

Fuera de alcance:
- Permisos individuales por vendedor (confirmado explícitamente que no
  se quiere por ahora).
- Cualquier otro permiso además de cancelar apartados (registrar
  abono, marcar entregado, vender, etc. — todos siguen abiertos para
  el vendedor exactamente como hoy).
- Cambios a lo que el admin puede hacer (el admin siempre puede
  cancelar, sin importar el interruptor).

## Modelo de datos

```sql
create table public.vendedor_permissions (
  id                    boolean primary key default true,
  can_cancel_layaways   boolean not null default false,
  constraint vendedor_permissions_single_row check (id)
);

insert into public.vendedor_permissions (id) values (true) on conflict (id) do nothing;
```

**Permisos:** lectura para cualquier usuario autenticado (admin
necesita verlo para configurarlo; vendedor necesita verlo para saber
si le toca mostrar el botón de Cancelar) — escritura solo para admin.
Mismo patrón de dos políticas que ya usa `site_settings`
(`0018_catalog_visibility_settings.sql`): una de lectura amplia, una de
escritura restringida a `public.is_admin()`.

```sql
create policy "authenticated read" on public.vendedor_permissions
  for select to authenticated using (true);
create policy "admin write" on public.vendedor_permissions for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
```

**`cancel_layaway`** (RPC existente, se modifica) gana la verificación
al inicio, antes de cualquier otra lógica:

```sql
if not public.is_admin() then
  if not exists (select 1 from public.vendedor_permissions where can_cancel_layaways) then
    raise exception 'No autorizado para cancelar apartados';
  end if;
end if;
```

El resto de la función (buscar el apartado, regresar el stock,
marcarlo cancelado) no cambia.

## Componentes

### 1. Usuarios → interruptor

Nueva fila en la pestaña Usuarios (ya admin-only): "Los vendedores
pueden cancelar apartados", con un checkbox que guarda directo a
`vendedor_permissions.can_cancel_layaways` — mismo patrón de guardado
inmediato al cambiar que ya usan otros interruptores del proyecto
(ej. `setting-show-stat` en Ajustes).

### 2. Apartados → botón condicional

El botón "Cancelar" en la tabla de apartados activos se muestra si
`CURRENT_ROLE === 'admin'` **o** `VENDEDOR_PERMISSIONS.can_cancel_layaways`
es verdadero. El botón "Abonar" y el resto de la pestaña no cambian.

## Manejo de errores

- Si un vendedor de alguna forma llega a invocar `cancel_layaway` sin
  el permiso (el botón no debería estar visible, pero el servidor no
  confía solo en eso), la función responde "No autorizado para
  cancelar apartados" y no cancela nada — ni toca stock ni cambia el
  estado del apartado.
- Si falla la carga de `vendedor_permissions` (red, etc.), el valor en
  memoria se queda en su default (`false` / apagado) — **fail-closed**:
  ante la duda, el vendedor no ve el botón, nunca al revés.

## Pruebas

Sin suite automatizada — en vivo con Ricardo:

1. Con el interruptor apagado (default tras correr la migración),
   confirmar que un vendedor no ve el botón "Cancelar" en Apartados.
2. Prenderlo desde Usuarios y confirmar que el botón aparece para el
   vendedor.
3. Confirmar que el admin siempre puede cancelar, sin importar el
   interruptor.
4. Confirmar que registrar abono y marcar entregado siguen funcionando
   igual para el vendedor, sin cambios.
