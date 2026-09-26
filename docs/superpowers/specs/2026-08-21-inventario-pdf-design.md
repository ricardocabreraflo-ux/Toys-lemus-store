# Exportar inventario a PDF

## Contexto

Del lote de pendientes de Admin, este es el quinto. Ricardo quiere
exportar el inventario a un PDF, pudiendo elegir qué columnas incluir.

Este proyecto no usa ninguna librería de JavaScript más allá de la de
Supabase — todo lo demás es HTML/CSS/JS plano. Generar el PDF con el
diálogo de impresión del navegador ("Guardar como PDF") no requiere
agregar ninguna dependencia nueva, funciona igual en celular y
computadora, y es el enfoque confirmado con Ricardo.

## Alcance

Incluido:
- Botón "Exportar a PDF" en Inventario, que abre un panel con casillas
  para elegir columnas.
- Columnas que se pueden incluir/quitar: Línea/Categoría, Código,
  Precio, Stock online, Stock física, Publicado — todas marcadas por
  defecto. Nombre siempre se incluye, no es opcional.
- El PDF respeta los filtros activos en ese momento en Inventario
  (línea, categoría, búsqueda) — exporta exactamente lo que se ve en
  pantalla, no todo el catálogo si hay un filtro puesto.
- Vista de impresión limpia (solo tabla, sin menús ni botones de
  Admin), con encabezado "Inventario — Lemus Store" y la fecha de
  generación.

Fuera de alcance:
- **Costo nunca es una opción** — no aparece en el panel de columnas ni
  puede incluirse en el PDF bajo ninguna circunstancia, es información
  sensible.
- Cualquier librería de generación de PDF — se usa el diálogo de
  impresión del navegador, no un archivo generado por JS.
- Exportar otra cosa que no sea la lista de productos de Inventario
  (ventas, reportes, etc. — no se pidió).

## Diseño

**Panel de columnas:** un botón "Exportar a PDF" junto a los filtros de
Inventario abre/cierra un panel con seis casillas (todas marcadas por
defecto) y un botón "Generar PDF" adentro.

**Generación:** al hacer clic en "Generar PDF":
1. Se toma la lista de productos ya filtrada en pantalla
   (`PRODUCTS.filter(matchesFilters)` — la misma función que ya usa la
   tabla de Inventario, sin duplicar lógica de filtrado).
2. Se arma una tabla HTML con Nombre + las columnas marcadas, dentro de
   un contenedor `#print-inventory` que existe en la página pero está
   oculto (`display: none`) en pantalla normal.
3. Se llama a `window.print()`.

**CSS de impresión:** una regla `@media print` oculta todo lo demás
(`body > *:not(#print-inventory) { display: none !important; }`) y
muestra solo `#print-inventory`, con estilos de tabla legibles para
papel (bordes, texto más chico). `#print-inventory` es un `<div>`
colocado directamente como hijo de `<body>` en `admin.html` (mismo
nivel que el `#toast` ya existente), para que el selector `body > *`
funcione correctamente.

## Manejo de errores

- Ninguna columna marcada (solo Nombre): el PDF se genera igual, tabla
  angosta — no es un error.
- Filtro activo sin resultados: la tabla del PDF sale vacía con el
  mensaje "Sin productos con este filtro" en vez de una tabla en
  blanco sin explicación.
- No hay ninguna consulta de red nueva — usa los productos ya cargados
  en memoria (`PRODUCTS`), no hay caso de fallo de conexión que manejar
  aquí.

## Pruebas

Sin suite automatizada — en vivo con Ricardo:

1. Sin filtros, exportar con las seis columnas marcadas — confirmar
   que se abre el diálogo de impresión con todo el catálogo.
2. Filtrar por una línea específica y exportar — confirmar que el PDF
   solo trae esa línea.
3. Desmarcar un par de columnas y confirmar que no aparecen en la
   vista de impresión.
4. Confirmar que "Costo" nunca aparece como opción en el panel ni en
   el PDF.
5. Buscar algo que no exista (cero resultados) y exportar — confirmar
   el mensaje de "Sin productos con este filtro" en vez de una tabla
   vacía.
