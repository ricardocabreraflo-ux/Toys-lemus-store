# Rediseño del panel — Dashboard y navegación

## Contexto

El panel de Admin creció de 5 pestañas a 12 a lo largo de este proyecto
(Inventario, Vender, Pedidos, Apartados, Conteo, Traspasos,
Promociones, Líneas y categorías, Reportes, Finanzas, Usuarios,
Ajustes), todas amontonadas en una sola fila que se envuelve arriba de
la pantalla, con una franja fija de 4 números (Productos, Valor de
inventario, Con 1 pieza, Agotados) siempre visible encima. Ricardo
pidió verlo "más acorde a la venta de juguetes" y que en celular la
barra de navegación no ocupe espacio innecesario.

Después de ver 7 direcciones visuales distintas (documentadas como
mockups, no como código) y combinarlas, quedó aprobada una mezcla
concreta: menú lateral agrupado en computadora, un tablero de inicio
con gráfica de ventas, y una barra de accesos abajo en celular.

## Alcance

Incluido:
- Una pestaña nueva **Dashboard**, que se convierte en la vista de
  inicio (la que se ve al entrar a Admin, en vez de Inventario).
- La fila de 12 botones + la franja de 4 números que hoy están
  siempre visibles arriba de todo se eliminan de ahí — esos 4 números
  se mueven adentro de la pestaña Dashboard.
- En computadora: un menú lateral fijo, agrupado en tres bloques —
  **Operación diaria** (Vender, Pedidos, Apartados, Conteo),
  **Catálogo y precios** (Inventario, Traspasos, Promociones, Líneas y
  categorías), **Negocio** (Reportes, Finanzas, Usuarios, Ajustes) —
  con Dashboard como primer botón, fuera de cualquier grupo.
- En celular (mismo punto de quiebre de 640px que ya usa el resto del
  sitio): el menú lateral se esconde. En su lugar, una barra de
  accesos fija abajo con 5 botones — Dashboard, Vender, Conteo,
  Inventario, y **Más**. "Más" abre una hoja que sube desde abajo con
  el resto de las secciones, agrupadas igual que en computadora.
- Cada botón de navegación (lateral o en la hoja "Más") sigue
  mostrándose u ocultándose para el vendedor exactamente con las
  mismas reglas de hoy — este cambio es solo de acomodo, no de
  permisos.

Fuera de alcance:
- No se agrega ninguna consulta nueva a Supabase — el contenido de
  Dashboard se arma con datos que Admin ya carga hoy
  (`PRODUCTS`, `ORDERS`, `LAYAWAYS`, y — solo para admin —
  `SALES_REPORT_SALES`, que ya se obtiene siempre al cargar el panel).
- No se toca la lógica interna de ninguna de las 12 pestañas
  existentes — Vender, Inventario, Reportes, etc. siguen funcionando
  exactamente igual, solo cambia cómo llegas a ellas.
- No hay modo "colapsar" el menú lateral en computadora — siempre se
  ve expandido, con nombres. Colapsarlo queda para más adelante si
  hace falta.
- No se guarda un historial de qué tan seguido usas cada sección ni
  nada personalizado — el menú es el mismo para todos, no se reordena
  solo.

## Diseño

**1. Qué trae la pestaña Dashboard**

Para **admin**:
- 4 tarjetas: Vendido hoy, Vendido esta semana, Valor de inventario
  (mismo cálculo que ya usa `renderStats()`), y Necesitan atención
  (número).
- Una gráfica de barras "Ventas de la semana" (lunes a domingo),
  calculada agrupando `SALES_REPORT_SALES` por día — el mismo dato que
  ya arma Reportes, solo agrupado por día en vez de por mes.
- Una tarjeta "Atención hoy" con hasta cuatro renglones, cada uno con
  un enlace directo a su pestaña: productos agotados (online),
  productos con 1 pieza (online), apartados que vencen hoy, pedidos
  pendientes por revisar. Un renglón que esté en cero no se muestra.
  (Los dos primeros son los mismos "Agotados"/"Con 1 pieza" que hoy
  viven como tarjetas propias arriba de todo — se mudan aquí en vez de
  desaparecer.)

Para **vendedor**: la vendedor no ve ventas totales ni finanzas hoy
(Reportes y Finanzas son solo-admin), así que su Dashboard es más
corto — mismo criterio que ya se aplica en el resto del panel:
- 3 tarjetas: Productos, Valor de inventario, Necesitan atención.
- La misma tarjeta "Atención hoy" que ve admin.
- Sin gráfica de ventas ni "Vendido hoy/semana" — esos números vienen
  de la tabla `sales`, que hoy solo se consulta para admin
  (`renderSalesReport()` ya hace early-return para vendedor).

**2. Menú lateral (computadora)**

Fijo a la izquierda, siempre expandido con ícono + nombre. Primer
botón, fuera de cualquier grupo: Dashboard. Debajo, los tres bloques
descritos en Alcance, cada uno con su encabezado chico. El botón de la
pestaña activa se resalta igual que hoy (mismo mecanismo de
`aria-selected`, solo que ahora vive en una columna en vez de una
fila).

**3. Navegación en celular**

Barra fija abajo con 5 accesos: Dashboard, Vender, Conteo, Inventario,
Más. Tocar "Más" abre una hoja desde abajo con el resto de las
secciones (Pedidos, Apartados, Traspasos, Promociones, Líneas y
categorías, Reportes, Finanzas, Usuarios, Ajustes), agrupadas en los
mismos tres bloques que el menú de computadora. Se cierra tocando
fuera de la hoja o un botón de cerrar.

**4. Qué no cambia**

El mecanismo que ya existe para mostrar/ocultar botones según el rol
(`data-role-admin` / `data-role-vendedor`) seguirá siendo exactamente
el mismo, solo aplicado ahora a los botones del menú lateral y de la
hoja "Más" en vez de a la fila de pestañas de hoy. La lógica de
cambiar de pestaña (mostrar el panel correspondiente y ocultar los
demás) tampoco cambia de raíz — sigue siendo "un botón de navegación
con `data-tab` muestra la sección con ese id", solo que ahora hay más
de un lugar desde donde se puede disparar (lateral, barra de abajo, u
hoja "Más").

## Manejo de errores

- Si Dashboard carga antes de que termine de cargar `PRODUCTS`/
  `ORDERS`/`LAYAWAYS`/`SALES_REPORT_SALES` (por ejemplo justo al
  iniciar sesión), las tarjetas muestran "—" en vez de un número
  incorrecto, igual que ya hacen las tarjetas de arriba hoy mientras
  cargan.
- Si no hay ventas registradas esta semana, la gráfica se muestra con
  todas las barras en cero — no es un error, es el estado normal.
- Si "Atención hoy" no tiene nada que mostrar (cero en las cuatro
  señales), la tarjeta muestra un mensaje breve ("Todo al día") en vez
  de quedar vacía sin explicación.

## Pruebas

Sin suite automatizada — en vivo con Ricardo:

1. Al entrar a Admin, confirmar que la vista de inicio es Dashboard
   (no Inventario).
2. En computadora, confirmar que el menú lateral muestra Dashboard
   arriba y los tres bloques agrupados debajo, y que cambiar de
   sección resalta el botón correcto.
3. Confirmar que Dashboard (admin) muestra Vendido hoy, Vendido esta
   semana, la gráfica de la semana y "Atención hoy" con datos reales.
4. Entrar con el usuario vendedor y confirmar que su Dashboard es el
   más corto (sin cifras de ventas ni gráfica) y que el menú lateral
   solo le muestra las secciones que ya podía ver antes.
5. Achicar la ventana (o entrar desde el celular) por debajo de 640px
   y confirmar que el menú lateral desaparece y aparece la barra de
   accesos abajo.
6. Tocar "Más" en celular y confirmar que se abre la hoja con el resto
   de las secciones, agrupadas igual que en computadora.
7. Confirmar que ninguna de las 12 pestañas existentes cambió de
   comportamiento — solo la forma de llegar a ellas.
