# Rediseño de "Vender" — punto de venta

## Enmienda (después de ver la primera versión en vivo)

Al ver la primera versión ya publicada, Ricardo pidió recuperar la hoja de
opciones de Treinta que se había descartado durante el diseño original (ver
Contexto): al presionar **"Registrar venta"** ahora se abre una hoja (la
misma que ya usa "Más" en la navegación) con tres opciones — **Venta de
productos**, **Venta libre**, **Apartado** — en vez de ir directo al
buscador. Elegir "Venta de productos" lleva a la pantalla con buscador y
escaneo de cámara (sin línea libre). Elegir "Venta libre" lleva a esa misma
pantalla pero mostrando solo el formulario de descripción + monto (sin
buscador ni cámara) — ambas comparten el mismo carrito y el mismo "Cobrar".
Elegir "Apartado" abre la pestaña Apartados que ya existe, igual que el
acceso rápido de la pantalla de inicio. El resto de este documento (Alcance,
Diseño, Manejo de errores, Pruebas) describe la versión anterior a esta
enmienda — donde dice "una sola pantalla mezclada" para Venta de
productos/Venta libre, ahora son dos modos de la misma pantalla, elegidos
desde la hoja.

## Contexto

La pestaña **Vender** de hoy es un formulario simple: eliges un producto de
una lista desplegable, escribes cantidad, das "Agregar", y así se arma una
tabla-carrito con un botón "Confirmar venta" al final. Debajo hay una lista
fija de las últimas 20 ventas físicas ("Ventas recientes"). No hay buscador,
no hay escáner de cámara, no hay forma de vender algo que no esté en el
catálogo, y no hay pantalla de confirmación — solo un mensaje breve
("Venta registrada") que limpia el carrito.

Ricardo pidió que "Vender" se sienta como el punto de venta de **Treinta**
(una app de gestión para negocios pequeños que usó de referencia) y como un
punto de venta con buscador en general. Se le mostraron tres direcciones
visuales y una combinación en un Artifact ("Vitrina del Punto de Venta"), y
eligió la dirección de "Centro de ventas" (tarjeta de resumen del día + un
botón grande para vender), simplificada después de varias preguntas: en vez
de una hoja con tres caminos separados, "Venta de productos" y "Venta libre"
se fusionan en una sola pantalla con buscador, y "Apartado" se resuelve
enlazando a la pestaña Apartados que ya existe — sin duplicar su lógica.

Esta pestaña vive dentro de la navegación ya rediseñada del panel (spec
`2026-08-24-panel-rediseno-design.md`): sidebar agrupado en computadora,
barra de accesos abajo en celular con "Vender" centrado. Ese acomodo no
cambia — este documento es solo sobre el contenido de la pestaña Vender.

## Alcance

Incluido:
- Una **pantalla de inicio** nueva para Vender, con una tarjeta "Tu tienda
  hoy" (resumen del día) y dos accesos rápidos: **Historial** y
  **Apartados**.
- Un botón grande **"Registrar venta"** que lleva directo a una pantalla de
  venta con buscador (sin pasos intermedios).
- La pantalla de venta fusiona lo que antes iban a ser "Venta de productos"
  y "Venta libre": un buscador (nombre/código, con opción de escanear con
  cámara) agrega productos del catálogo al carrito, y un botón separado
  agrega una línea libre (descripción + monto, sin producto de catálogo).
  Ambos tipos de línea conviven en el mismo carrito y se cobran juntos.
- Una función nueva en Supabase que permita registrar una venta física con
  líneas mixtas (de catálogo y libres) — hoy `create_sale_fisica` solo
  acepta líneas de catálogo.
- Una **pantalla de confirmación** después de cobrar, con el resumen de la
  venta (en vez del mensaje breve de hoy).
- Una pantalla de **Historial** propia (hoy es una lista fija al fondo de
  Vender) con búsqueda por rango de fechas.
- El acceso rápido **Apartados** navega a la pestaña Apartados que ya
  existe (`setActiveTab('layaways')) — cero cambios a su lógica o su
  formulario.
- El vendedor no ve montos de dinero en la tarjeta "Tu tienda hoy" — mismo
  criterio que ya aplica en el Dashboard.

Fuera de alcance:
- **Cotizaciones** — Ricardo decidió dejarlo fuera de este trabajo y
  hacerlo como un proyecto aparte más adelante. No se agrega ese acceso
  rápido ni ningún soporte para armar una cotización sin venta.
- No se crea una tabla `customers` — "Venta libre" no pide ni guarda datos
  de cliente (solo descripción y monto). Apartados sigue guardando
  nombre/teléfono/correo directamente en `layaways`, como ya hace hoy.
- No hay recibo o ticket imprimible — la pantalla de confirmación es solo
  en pantalla, no genera un PDF ni manda a imprimir.
- No se agregan botones +/− para editar cantidad dentro del carrito —
  repetir la búsqueda o el escaneo del mismo producto suma cantidad (igual
  que Conteo), y "Quitar" elimina el renglón completo. Bajar la cantidad
  se hace quitando el renglón y volviendo a agregarlo.
- No se toca el formulario ni la lógica de Apartados — solo se le agrega un
  acceso directo desde Vender.
- No cambia la navegación general del panel (sidebar/bottom-nav) — "Vender"
  sigue siendo la misma entrada de siempre, solo cambia lo que hay dentro.
- El vendedor puede registrar ventas y ventas libres igual que hoy — no se
  agrega ningún permiso nuevo ni restricción nueva de rol para vender
  (`VENDEDOR_PERMISSIONS` no cambia en este trabajo).

## Diseño

**1. Estructura de la pestaña**

La pestaña Vender (`#tab-sell`) pasa a tener cuatro vistas internas que se
muestran una a la vez, controladas por una función `setSellView(view)`
(`'home' | 'sale' | 'sale-confirm' | 'history'`), igual en espíritu a como
Conteo alterna entre su modo manual y su modo cámara:

- `#sell-home` — la pantalla de inicio (punto 2).
- `#sell-sale` — la pantalla de venta con buscador (punto 3).
- `#sell-sale-confirm` — la pantalla de confirmación tras cobrar (punto 4).
- `#sell-history` — la pantalla de historial (punto 5).

Cada vez que `setActiveTab('sell')` activa esta pestaña, se vuelve a
`'home'` y se refresca "Tu tienda hoy" — así nunca se entra a mitad de una
venta anterior. Salir de la pestaña Vender (ir a otra) también detiene la
cámara del buscador, igual que ya hace `setActiveTab` con la cámara de
Conteo.

**2. Pantalla de inicio (`#sell-home`)**

Una tarjeta "Tu tienda hoy" arriba, con los números de **hoy** de ventas
físicas de mostrador (no en línea) — se excluyen apartados sin completar,
mismo criterio que ya usa "Ventas recientes"
(`payment_method != 'apartado'`):

- Para **admin**: Vendido hoy, Ticket promedio (vendido hoy ÷ número de
  ventas de hoy, o "—" si no ha habido ninguna), Piezas vendidas hoy, y
  Ventas del día (número de tickets).
- Para **vendedor**: solo Piezas vendidas hoy y Ventas del día — sin
  ningún monto en pesos, igual que su Dashboard ya oculta dinero.

Estos números salen de una función nueva `loadVenderToday()` que consulta
`sales` (con sus `sale_items` anidados) filtrando `channel = 'fisica'`,
`payment_method <> 'apartado'` y `created_at` de hoy — una consulta chica y
aparte de `SALES_REPORT_SALES` (que es solo para admin y cubre todo el
histórico), para que el vendedor también pueda calcular sus piezas de hoy
sin cargar el reporte completo. El resultado se guarda en un objeto
`VENDER_TODAY = { total, count, pieces }` y se vuelve a pedir cada vez que
se entra a Vender o se confirma una venta nueva.

Debajo de la tarjeta, dos accesos rápidos:
- **Historial** → `setSellView('history')`.
- **Apartados** → `setActiveTab('layaways')` (sale de Vender por completo,
  entra a la pestaña ya existente).

Y el botón grande **"Registrar venta"** → `setSellView('sale')`.

**3. Pantalla de venta (`#sell-sale`)**

Arriba, un buscador (mismo patrón que `#count-search` de Conteo): escribes
nombre o código y aparecen sugerencias; escribir un código exacto y dar
Enter, o escanear con la cámara (mismo botón/mecanismo de
`startCountCamera()`/`handleCountScanValue()`, adaptado a esta pantalla),
agrega el producto al carrito con cantidad 1; repetir la búsqueda o el
escaneo del mismo producto suma 1 a su cantidad ya en el carrito — igual
que en Conteo.

Junto al buscador, un botón **"Agregar línea libre"** abre un mini-formulario
en línea con dos campos (Descripción, Monto) y un botón "Agregar"; al
confirmarlo se agrega una línea al carrito con esa descripción y ese monto,
sin producto ni afectar inventario. Descripción vacía o monto ≤ 0 no se
agrega (ver Manejo de errores).

El carrito (una sola lista, mezclando líneas de catálogo y libres) muestra
por renglón: nombre/descripción, cantidad (las libres siempre muestran
cantidad 1, no aplica sumar), precio, subtotal, y un botón "Quitar" que
elimina el renglón completo. Abajo, el total.

La sección de cobro se mantiene como hoy: un campo "Efectivo recibido"
(opcional) que calcula el cambio en vivo, y un botón **"Cobrar"** con el
total (ej. "Cobrar $1,426"). Si el carrito está vacío, "Cobrar" no hace
nada y muestra el mismo error que hoy ("Agrega al menos un producto").

Al presionar "Cobrar" con el carrito lleno, se llama a la función de
Supabase (ver punto 6) con el arreglo mixto de líneas. Si tiene éxito:
guarda una copia del carrito y el total para la pantalla de confirmación,
limpia el carrito y el campo de efectivo, refresca `VENDER_TODAY`,
`PRODUCTS` y las opciones del buscador (igual que hoy hace
`sell-confirm-btn` con `reloadProducts()`/`refreshSellProductOptions()`), y
pasa a `setSellView('sale-confirm')`.

**4. Pantalla de confirmación (`#sell-sale-confirm`)**

Muestra el resumen de la venta que se acaba de hacer: cada línea (nombre o
descripción, cantidad, subtotal), el total, y si se capturó efectivo
recibido, el cambio calculado. Dos botones: **"Nueva venta"** (vuelve a
`#sell-home`) y **"Ver historial"** (`setSellView('history')`). Esta vista
es de solo lectura — no se puede editar una venta ya cobrada desde aquí
(para eso ya existe eliminar una venta desde Historial, ver punto 5).

**5. Pantalla de historial (`#sell-history`)**

Reemplaza a la lista fija "Ventas recientes" de hoy. Dos campos de fecha
("Desde" y "Hasta", tipo `date`), con "Desde" y "Hasta" precargados en el
día de hoy. Al cambiar cualquiera de los dos, se vuelve a consultar y
mostrar la lista — sin necesidad de un botón "Buscar" aparte. La consulta
(`loadPhysicalSalesRange(from, to)`) es la misma que ya hace
`loadRecentSales()` (channel `fisica`, `payment_method <> 'apartado'`),
pero filtrando por rango de `created_at` en vez de limitar a 20 filas, y
sin ese límite.

La tabla es la misma de hoy: fecha, total, y (solo admin) un botón
eliminar que llama a `delete_sale` — comportamiento sin cambios, incluida
la confirmación por PIN ya existente (`askForDeletePin`).

**6. Función de Supabase: ventas con líneas mixtas**

Se modifica `create_sale_fisica(p_items jsonb)` (migración nueva) para que
cada elemento de `p_items` pueda ser de dos formas:

- Línea de catálogo (como hoy): `{ "product_id": "<uuid>", "quantity": N }`
  — mismo comportamiento de siempre: valida stock física, la descuenta, y
  registra el renglón con el precio y costo del producto en ese momento.
- Línea libre (nueva): `{ "description": "texto", "amount": N }` — sin
  `product_id`, no toca inventario, y registra un renglón en `sale_items`
  con `product_id = null`, `product_name = <description>`, `quantity = 1`,
  `unit_price = <amount>`, `unit_cost_price = 0`.

Esto no requiere cambios de esquema: `sale_items.product_id` ya acepta
`null` (se usa hoy cuando un producto de una venta antigua se borra del
catálogo) y `product_name` ya es texto libre. Los reportes (`Reportes` y
`Finanzas`) ya excluyen explícitamente los renglones con `product_id` nulo
de los desgloses por producto/categoría (`if (!item.product_id) return;`
en `renderSalesDetailReport`), así que una línea libre entra al total del
mes igual que cualquier venta, pero no aparece como "producto vendido" en
esos desgloses — comportamiento ya existente, no hay que tocar esas
pantallas.

`create_layaway_fisica` y la pestaña Apartados no se tocan.

**7. Reutilización del escáner de cámara**

El botón de cámara del buscador de `#sell-sale` reutiliza el mismo
mecanismo ya construido para Conteo (`BarcodeDetector`, manejo de
permisos, y el arreglo de errores silenciosos ya corregido en su revisión
final) en vez de duplicar el código — se factoriza a una función
compartida si el código de Conteo lo permite sin romper su pantalla
actual; si no, se copia el patrón ya probado (misma lógica, nuevos ids de
elemento) para no introducir una implementación distinta.

## Manejo de errores

- Buscador sin resultados (nombre no encontrado, código no encontrado): se
  muestra el mismo mensaje que hoy usa Conteo ("Producto no encontrado"),
  sin agregar nada al carrito.
- Cámara sin permiso, no soportada, o `BarcodeDetector` no disponible: se
  reutiliza el mismo comportamiento ya corregido en Conteo — el botón de
  cámara no rompe la pantalla, cae de vuelta a búsqueda manual.
- Línea libre con descripción vacía o monto vacío/≤ 0: no se agrega al
  carrito, se marca el campo inválido en el propio mini-formulario.
- Carrito vacío al presionar "Cobrar": mismo error de hoy ("Agrega al
  menos un producto"), sin llamar a Supabase.
- Stock insuficiente al cobrar (alguien vendió el mismo producto mientras
  tanto): se muestra el mensaje de error que ya devuelve
  `create_sale_fisica` tal cual, el carrito no se pierde, se puede ajustar
  cantidad y reintentar — mismo comportamiento de hoy.
- "Tu tienda hoy" no ha terminado de cargar o falla su consulta: las
  cifras muestran "—" en vez de un número incorrecto o quedar en blanco,
  igual que ya hacen las tarjetas del Dashboard.
- Rango de fechas inválido en Historial ("Desde" posterior a "Hasta"): se
  muestra un mensaje breve y no se ejecuta la consulta; se conserva la
  última lista mostrada.
- Sin ventas físicas en el rango de Historial seleccionado: se muestra un
  mensaje ("Sin ventas físicas en este rango.") en vez de una tabla vacía
  sin explicación.

## Pruebas

Sin suite automatizada — en vivo con Ricardo (rol admin) y con el usuario
vendedor:

1. Entrar a Vender: confirmar que abre en la pantalla de inicio (no
   directo al carrito), con "Tu tienda hoy" mostrando cifras reales.
2. Como admin, confirmar que "Tu tienda hoy" muestra Vendido hoy, Ticket
   promedio, Piezas vendidas hoy y Ventas del día. Como vendedor, confirmar
   que solo se ven Piezas vendidas hoy y Ventas del día, sin montos.
3. Tocar "Registrar venta": confirmar que lleva directo a la pantalla con
   buscador, sin ningún paso intermedio.
4. Buscar un producto por nombre y por código, agregarlo, y repetir la
   búsqueda del mismo producto: confirmar que la cantidad sube en vez de
   duplicar el renglón.
5. Probar el escaneo con cámara (en un celular real) para agregar un
   producto al carrito.
6. Agregar una línea libre (ej. "Envoltura de regalo", $30) y confirmar que
   aparece en el carrito junto con productos de catálogo, sin afectar el
   inventario de ningún producto.
7. Quitar un renglón del carrito y confirmar que el total se recalcula.
8. Capturar efectivo recibido y confirmar que el cambio se calcula
   correctamente.
9. Presionar "Cobrar": confirmar que aparece la pantalla de confirmación
   con el resumen correcto, y que el carrito de la pantalla de venta queda
   vacío al volver a entrar.
10. Desde la pantalla de confirmación, probar "Nueva venta" y "Ver
    historial".
11. En Historial, cambiar el rango de fechas y confirmar que la lista se
    actualiza; como admin, eliminar una venta de prueba y confirmar que el
    stock regresa al inventario (comportamiento ya existente de
    `delete_sale`).
12. Tocar el acceso rápido "Apartados" desde la pantalla de inicio de
    Vender y confirmar que abre la pestaña Apartados ya existente, sin
    cambios visibles ahí.
13. Confirmar que Reportes y Finanzas siguen sumando correctamente el mes
    con una venta que incluye una línea libre (el total del mes la
    incluye; el desglose por producto/categoría no la lista, igual que ya
    pasa con productos borrados).
