# Conteo físico de inventario

## Contexto

Del lote de pendientes de Admin, este es el sexto. Ricardo quiere una
forma rápida de hacer conteo físico de inventario — escaneando o
escribiendo el código/nombre de cada producto conforme lo va contando
en la tienda — y comparar el resultado contra el stock actual antes de
actualizarlo.

El proyecto ya usa un patrón de "escáner como teclado" implícito en
otras partes (el campo de código en Vender ya recibe la entrada de un
lector de código de barras USB/Bluetooth como si fuera texto tecleado),
así que este conteo reutiliza esa misma idea.

## Alcance

Incluido:
- Nueva pestaña "Conteo" en Admin, visible tanto para admin como para
  vendedor (igual que Vender, Pedidos y Apartados).
- Un cuadro de búsqueda por código exacto o por nombre, con lista de
  coincidencias cuando el nombre no es único.
- Una lista de productos ya contados, con su cantidad editable a mano y
  la opción de quitar una línea.
- Una pantalla de "Finalizar conteo" con una tabla comparativa: stock
  actual vs. lo contado vs. la diferencia.
- Un botón "Aplicar todo" que actualiza `stock_fisica` de todos los
  productos contados en un solo paso, todo o nada.

Fuera de alcance:
- El conteo en progreso no se guarda en la base de datos — vive solo en
  el navegador mientras se trabaja. Si se recarga la página a medio
  conteo, se pierde y hay que empezar de nuevo. Para el tamaño de esta
  tienda debería alcanzar con hacerlo en una sola sesión; si algún día
  se vuelve un problema real, se ajusta.
- No se toca `stock_online` — este conteo es exclusivamente del stock
  física de la tienda.
- No hay historial de conteos pasados, solo el conteo actual en curso.
- No se pueden dar de alta productos nuevos desde este flujo — solo
  cuenta productos que ya existen en el catálogo.

## Diseño

**1. Cómo se cuenta**

Un solo cuadro de texto arriba de la pestaña "Conteo": escaneas el
código de barras (si el escáner ya está configurado como teclado, esto
funciona solo) o escribes el nombre.

- Si el código coincide exacto con un producto, se agrega 1 a su
  conteo automáticamente y el cuadro queda listo para el siguiente
  escaneo — sin clics extra, para que el escaneo sea rápido de verdad.
- Si escribes un nombre y hay varias coincidencias, se muestra una
  lista chica para elegir cuál es.
- Si el producto elegido/escaneado ya estaba en la lista de contados,
  su cantidad sube 1 en vez de crear una línea duplicada.
- Cada producto contado aparece abajo en una lista con su cantidad
  (editable a mano por si te equivocas), y se puede quitar una línea
  si fue un error.

**2. Terminar y aplicar**

Un botón "Finalizar conteo" muestra una tabla comparando: Producto |
Stock actual | Contado | Diferencia — resaltando las filas donde no
coinciden. Un botón "Aplicar todo" actualiza el stock física de todos
los productos contados a lo que realmente se contó, en un solo paso.

**3. Datos y permisos**

No se crea ninguna tabla nueva — el conteo en progreso vive solo en
memoria del navegador, reutilizando la lista de productos (`PRODUCTS`)
que Admin ya tiene cargada, hasta que se aplica.

Para aplicar el conteo se agrega una función en la base de datos,
`apply_inventory_count`, que recibe la lista completa de productos
contados (id + cantidad) y actualiza el `stock_fisica` de cada uno
dentro de una sola transacción — si cualquier fila falla, toda la
operación se revierte (mismo patrón ya usado en este proyecto por
`delete_sale` y `cancel_layaway`). A diferencia de esas dos funciones,
que son solo para admin, esta la puede llamar también el vendedor,
porque el conteo es una tarea operativa que él también hace.

## Manejo de errores

- Escaneas/escribes un código o nombre que no coincide con ningún
  producto: aviso "Producto no encontrado", no se agrega nada a la
  lista.
- Escribes un nombre que coincide con varios productos: se muestra la
  lista para elegir, no se asume ninguno.
- Cantidad contada en cero o negativa (si la editas a mano): no se
  permite, mínimo 0.
- Si falla la conexión al aplicar el conteo final, ningún producto se
  actualiza a medias — se aplica todo o nada.

## Pruebas

Sin suite automatizada — en vivo con Ricardo:

1. Escanear/escribir un código exacto y confirmar que se agrega 1
   automáticamente, sin clics extra.
2. Escribir un nombre parcial con varias coincidencias y confirmar que
   aparece la lista para elegir.
3. Editar a mano la cantidad de un producto ya contado.
4. Finalizar conteo y confirmar que la tabla de diferencias muestra
   correctamente Actual/Contado/Diferencia.
5. Aplicar todo y confirmar que el stock física de esos productos queda
   igual a lo contado.
6. Confirmar que el vendedor también puede usar la pestaña "Conteo".
