# Escanear con cámara en Conteo

## Contexto

Ricardo ya tiene "Conteo" funcionando con un escáner físico (configurado
como teclado) o escribiendo el código/nombre a mano. Preguntó si también
se puede usar la cámara del celular como escáner — confirmó que el
Admin siempre se usa desde Android para esta tarea.

Chrome en Android ya trae integrada una función para leer códigos de
barras desde la cámara (`BarcodeDetector`), así que esto no requiere
agregar ninguna librería nueva al proyecto — sigue la misma regla que
el resto del proyecto (sin dependencias nuevas).

## Alcance

Incluido:
- Un botón "Escanear con cámara" junto al cuadro de texto de Conteo,
  visible solo si el navegador soporta la función (en Android/Chrome,
  siempre).
- Al tocarlo, se abre una vista de cámara en vivo debajo del cuadro de
  texto. Cada código de barras detectado se agrega automáticamente al
  conteo (mismo comportamiento que ya existe hoy para el escáner
  físico) y la cámara se queda abierta para seguir escaneando, sin
  clics extra entre un producto y el siguiente.
- Una pequeña pausa (~1.5 segundos) antes de volver a aceptar el mismo
  código, para no contarlo dos veces si la cámara lo detecta en varios
  cuadros seguidos.
- Tocar el botón de nuevo cierra la cámara.
- La cámara se apaga sola si se cambia de pestaña dentro de Admin.

Fuera de alcance:
- Ninguna librería de escaneo de terceros (ZXing, QuaggaJS, etc.) — se
  usa únicamente la función nativa del navegador.
- Soporte para navegadores/celulares sin esta función (ej. iPhone) — el
  botón simplemente no aparece ahí; siguen disponibles el escáner
  físico y escribir a mano, como ya funciona hoy.
- No cambia nada del flujo ya existente de Conteo (búsqueda por nombre,
  lista de contados, Finalizar conteo, Aplicar todo) — esto solo agrega
  una tercera forma de meter un producto a la lista.

## Diseño

**Cómo se ve y cómo funciona**

Junto al cuadro de texto de Conteo, un botón "Escanear con cámara" que
solo aparece si el navegador soporta `BarcodeDetector` (se revisa al
cargar la pestaña). Al tocarlo:

1. El navegador pide permiso de cámara la primera vez.
2. Se abre una vista de cámara en vivo, chica, debajo del cuadro de
   texto.
3. En cuanto detecta un código de barras válido, se agrega 1 al conteo
   automáticamente (misma función que ya usa el escáner físico/manual
   para agregar un producto) y la cámara sigue abierta, lista para el
   siguiente.
4. Tocar el botón de nuevo cierra la cámara y libera el permiso.

**Anti-duplicados**

Después de cada escaneo exitoso, ese mismo código no se vuelve a
aceptar hasta que pasen ~1.5 segundos — evita contar el mismo producto
varias veces si sigue a la vista de la cámara, sin bloquear el
escaneo de un producto distinto de inmediato.

## Manejo de errores

- El navegador no soporta `BarcodeDetector`: el botón no aparece, sin
  ningún aviso — el resto de Conteo sigue igual.
- El usuario no da permiso de cámara (o lo revoca): aviso "No se pudo
  acceder a la cámara", el botón vuelve a su estado apagado, y el
  resto de Conteo sigue funcionando normal.
- La cámara detecta un código que no coincide con ningún producto:
  mismo aviso que ya existe hoy, "Producto no encontrado" — la cámara
  se queda abierta para el siguiente intento.
- Cambiar de pestaña dentro de Admin, o cerrar/recargar la página,
  apaga la cámara automáticamente.

## Pruebas

Sin suite automatizada — en vivo con Ricardo, desde un celular Android:

1. Tocar "Escanear con cámara", dar permiso, y confirmar que aparece
   la vista en vivo.
2. Apuntar a un código de barras real y confirmar que se agrega 1
   automáticamente sin tocar nada más.
3. Mantener el mismo código a la vista un par de segundos y confirmar
   que no se agrega varias veces de golpe.
4. Escanear dos productos distintos seguidos y confirmar que ambos se
   agregan.
5. Negar el permiso de cámara y confirmar el aviso de error, sin que
   se rompa el resto de Conteo.
6. Cambiar a otra pestaña de Admin y confirmar que la cámara se apaga.
