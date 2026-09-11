# Finanzas — punto de equilibrio

## Contexto

Del lote de 9 pendientes de Admin que Ricardo dejó en pausa mientras se
terminaba "Catálogo público", este es el primero: una pestaña de
"Finanzas" que le permita registrar sus gastos fijos mensuales (renta,
sueldos, servicios) y ver, de un vistazo, si ya cubrió esos gastos con
la ganancia del mes en curso — su "punto de equilibrio".

Hoy el proyecto ya tiene, en la pestaña Reportes, ganancia por línea de
producto y por mes (ventas menos costo), pero no existe ningún lugar
para registrar gastos del negocio — sin eso no se puede calcular un
punto de equilibrio real.

## Alcance

Incluido:
- Tabla nueva de gastos fijos mensuales (recurrentes, no gastos sueltos
  con fecha — confirmado con Ricardo).
- Pestaña "Finanzas" en Admin (solo rol admin, igual que Reportes/
  Promociones/Ajustes — el rol vendedor no la ve).
- Editor de gastos fijos: agregar, editar monto/nombre, activar/
  desactivar, borrar.
- Tarjeta de "punto de equilibrio del mes en curso": ganancia real del
  mes (ventas completadas menos su costo) comparada contra el total de
  gastos fijos activos.

Fuera de alcance (confirmado con Ricardo):
- Gastos sueltos/no recurrentes con fecha propia — todo gasto es un
  monto fijo mensual.
- Vista histórica de punto de equilibrio por meses pasados — solo el
  mes en curso.
- Cualquier cambio a Reportes, Promociones, Vender, o cualquier otra
  pestaña existente.

## Modelo de datos

```sql
create table public.fixed_expenses (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  monthly_amount numeric(10,2) not null check (monthly_amount >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
```

`active` permite pausar un gasto (ej. se dejó de pagar un servicio) sin
perder el registro de que existió — mismo patrón que `visible_public`
en `product_lines`.

**Permisos:** a diferencia de `site_settings`/`promotions` (que sí
tienen lectura pública porque son ajustes de visualización), esto es
información financiera interna — lectura y escritura solo para
`authenticated` con rol admin, vía `public.is_admin()` (mismo patrón de
guardas que el resto del Admin, ver `0008_admin_only_writes.sql`). Nada
de esto es legible por `anon` ni por el rol vendedor.

## Componentes

### 1. Pestaña "Finanzas"

Nueva pestaña en Admin (`data-tab="finance"`, `data-role-admin` — sin
`data-role-vendedor`, igual que Reportes/Promociones/Ajustes), con dos
secciones:

**Gastos fijos** — tabla editable, mismo patrón visual que "Líneas y
categorías": fila de alta arriba (nombre + monto), lista abajo con
edición inline del monto/nombre, interruptor de activo/inactivo, y
botón de borrar.

**Punto de equilibrio de este mes** — tarjeta resumen (no una tabla)
que muestra tres números:
- Ganancia real del mes en curso: se calcula igual que ya hace
  `renderSalesReport()` en Reportes (ventas con `status in
  ('completada', 'entregado')`, `total` menos la suma de
  `unit_cost_price * quantity` de `sale_items_view`), pero filtrado
  solo al mes calendario actual en vez de agrupado por todos los meses.
- Total de gastos fijos activos (`sum(monthly_amount) where active`).
- El resultado: si ganancia ≥ gastos fijos → "Ya cubriste tus gastos
  fijos de este mes — llevas $X de ganancia neta"; si no → "Te faltan
  $X en ganancia para cubrir tus gastos fijos de este mes" (mostrando
  la diferencia positiva).

### 2. Cálculo

Reutiliza el mismo par de consultas que ya usa `renderSalesReport()`
(`sales` + `sale_items_view`), filtrando el rango de fechas al mes
calendario en curso (desde el día 1 del mes actual hasta ahora) en vez
de agrupar todos los meses — no se necesita ninguna función/RPC nueva
en la base de datos, es el mismo cálculo ya usado, con un filtro de
fecha distinto.

## Manejo de errores

- Sin gastos fijos activos capturados todavía: la tarjeta no compara
  contra $0 (sería engañoso decir "ya cubriste tus gastos" cuando no
  hay ninguno registrado) — en su lugar muestra un mensaje neutral:
  "Agrega tus gastos fijos para ver tu punto de equilibrio este mes".
- Sin ventas todavía este mes: no es un caso de error — se compara $0
  de ganancia contra los gastos fijos normalmente, mostrando "Te faltan
  $X…".
- Falla de red al cargar ventas/gastos: mensaje de error existente
  (`showToast`), mismo patrón que el resto de Admin — esta pestaña no
  es parte de ningún flujo crítico (venta, pago), así que no necesita
  manejo especial más allá de eso.

## Pruebas

Sin suite automatizada — se prueba en vivo con Ricardo:

1. Agregar un gasto fijo (ej. "Renta" $3000/mes), confirmar que aparece
   en la lista y se suma al total.
2. Desactivar ese gasto y confirmar que la tarjeta de punto de
   equilibrio deja de contarlo.
3. Con ventas reales del mes en curso, confirmar que la ganancia
   mostrada coincide con lo que ya muestra Reportes para ese mismo mes
   (mismo cálculo, filtrado a un solo mes).
4. Sin gastos fijos capturados, confirmar el mensaje neutral en vez de
   "ya cubriste tus gastos".
5. Confirmar que el rol vendedor no ve la pestaña "Finanzas" en
   absoluto.
