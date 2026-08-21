# Reporte de ventas por categoría y producto

## Contexto

Del lote de pendientes de Admin, este es el cuarto. Reportes ya tiene
una tabla "Ventas por mes" (ventas, piezas, total, costo, ganancia
real) agrupada por mes calendario. Ricardo quiere el mismo nivel de
detalle, pero agrupado por categoría y por producto individual, para un
periodo que él elige.

## Alcance

Incluido:
- Selector de periodo (un mes específico, armado a partir de los meses
  que ya tienen ventas, o "Todos los periodos").
- Tabla nueva: ventas del periodo elegido agrupadas por categoría
  (mismas columnas que la tabla de mes: ventas, piezas, total, costo,
  ganancia).
- Tabla nueva: ventas del periodo elegido agrupadas por producto
  individual, mismas columnas, ordenada de mayor a menor ganancia,
  mostrando solo productos con al menos una venta en ese periodo.
- Recalculo en el navegador al cambiar el filtro, sin recargar.

Fuera de alcance:
- La tabla "Ventas por mes" que ya existe no cambia.
- Exportar este reporte (PDF, Excel, etc.) — no se pidió.
- Rango de fechas personalizado (solo mes calendario o todo el
  historial, igual que ya existe hoy en la tabla de mes).

## Diseño

**Datos:** reutiliza exactamente las mismas dos consultas que ya hace
`renderSalesReport()` (`sales` con `status in ('completada',
'entregado')`, `sale_items_view` para cantidad/precio/costo) — no hace
falta ninguna consulta ni vista nueva en la base de datos. Cada
`sale_item` ya trae `product_id`; para agrupar por categoría y línea se
cruza con el arreglo `PRODUCTS` que Admin ya tiene cargado en memoria
(cada producto ya trae `product_line_id`/`category_id`).

**Selector de periodo:** un `<select>` poblado con los mismos meses
(`YYYY-MM`) que ya calcula la tabla existente, más una opción "Todos
los periodos" (selección por defecto). Cambiar el filtro solo vuelve a
agrupar los datos ya cargados en memoria — no dispara ninguna consulta
nueva a Supabase.

**Agrupación:**
- Por categoría: `category_id` → nombre mostrado como "Línea —
  Categoría" (mismo formato que ya usan Promociones/Traspasos).
- Por producto: `product_id` → nombre del producto, ordenado por
  ganancia descendente.
- `sale_items` con `product_id = null` (producto borrado — el caso
  "producto ya no existe" que ya maneja `record_online_sale`) se
  excluyen de ambas tablas nuevas — siguen contando en el total general
  del mes en la tabla existente, que no cambia.

## Manejo de errores

- Sin ventas en el periodo elegido: ambas tablas muestran "Sin ventas
  en este periodo" en vez de quedar vacías sin explicación — mismo
  patrón que ya usan las demás tablas de Reportes/Admin.
- No hay ninguna consulta de red nueva que pueda fallar de forma
  independiente — esto reutiliza los mismos datos que
  `renderSalesReport()` ya carga; si esa carga falla, ya se maneja
  igual que hoy (consola + reporte vacío).

## Pruebas

Sin suite automatizada — en vivo con Ricardo:

1. Con "Todos los periodos", confirmar que las tablas por categoría y
   producto muestran datos acumulados de todo el historial.
2. Elegir un mes específico y confirmar que ambas tablas se recalculan
   a ese mes solamente, sin recargar la página.
3. Confirmar que la tabla por producto está ordenada de mayor a menor
   ganancia.
4. Confirmar que un producto sin ventas en el periodo elegido no
   aparece en la tabla.
5. Confirmar que la tabla "Ventas por mes" existente no cambió.
