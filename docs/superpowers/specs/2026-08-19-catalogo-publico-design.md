# Mejoras al catálogo público

## Contexto

Ricardo pidió un lote de cambios para la página principal del catálogo
(`app/index.html`), como parte de una lista más grande de 14 peticiones que
se decidió abordar por grupos. Este es el primer grupo, "Catálogo público":

1. Controlar qué líneas de producto son visibles al público (solo "Toys"
   por ahora), con el control desde Admin.
2. Paginar el catálogo (15 productos por página) en vez de mostrarlo todo
   de un jalón.
3. Un banner debajo del catálogo con las promociones activas.
4. Ocultar el contador de "Productos activos" en la página pública, con
   un interruptor en Admin para reactivarlo.
5. Tema claro/oscuro automático según la hora de Ciudad de México, solo
   en el catálogo público (el Admin conserva su botón manual).

Todo esto es aditivo sobre el catálogo/admin existentes — no toca ventas,
apartados, pagos, ni ninguna de las tablas o funciones ya construidas.

## Alcance

Incluido en este grupo:
- Visibilidad por línea de producto (tabla `product_lines` + pestaña
  Ajustes en Admin).
- Paginación client-side del catálogo público (15 por página).
- Banner de promociones activas debajo del catálogo.
- Interruptor para mostrar/ocultar el contador de productos activos.
- Tema automático día/noche en el catálogo público.
- Pestaña nueva "Ajustes" en Admin, que reúne los tres interruptores de
  arriba (líneas, contador, y — a futuro — cualquier otro ajuste general
  del sitio).

Fuera de alcance (son grupos aparte, ya anotados en la lista de
pendientes): reportes, finanzas, roles de vendedor, clientes, compras de
inventario. Este grupo no los toca.

## Modelo de datos

**`product_lines`** gana una columna nueva:

```sql
alter table public.product_lines
  add column visible_public boolean not null default true;
```

Se agrega con `default true` para no romper líneas creadas después de este
cambio (una línea nueva es visible por defecto, a menos que Ricardo la
apague). Una migración de datos aparte pone `Toys` en `true` y **todas las
demás líneas existentes en `false`**, para arrancar exactamente como
Ricardo pidió.

**`site_settings`** es una tabla nueva, de una sola fila fija (patrón
típico para "un solo conjunto de ajustes globales"):

```sql
create table public.site_settings (
  id                     boolean primary key default true,
  show_products_stat     boolean not null default false,
  constraint site_settings_single_row check (id)
);

insert into public.site_settings (id) values (true);
```

El `check (id)` más la primary key en una columna `boolean` garantiza que
nunca pueda existir más de una fila. `show_products_stat` arranca en
`false` (oculto), tal como pidió Ricardo.

**Permisos:** lectura pública (`anon`, `authenticated`) en ambas — son
ajustes de visualización, no datos sensibles. Escritura solo para
`authenticated` con rol admin (mismo patrón de guardas ya usado en el
resto del Admin — revisar `role = 'admin'` vía el perfil del usuario,
igual que las demás tablas admin-only del proyecto).

## Componentes

### 1. Visibilidad de líneas

- `catalog-data.js` (`loadProductLines`) filtra a `visible_public = true`
  al pedirle las líneas a Supabase — una línea apagada no aparece como
  pestaña de filtro.
- El fetch de productos del catálogo público también excluye productos
  cuya línea esté apagada (join o filtro adicional sobre
  `product_line_id`), para que ni siquiera aparezcan bajo "Todo".
- Pestaña "Ajustes" en Admin: lista las líneas con un interruptor cada
  una, escribiendo directo a `product_lines.visible_public`. Cambios en
  vivo vía la suscripción realtime que ya existe sobre esa tabla.
- El resto del Admin (Inventario, Vender, Reportes, Traspasos, etc.) seguirá
  mostrando y permitiendo operar sobre TODAS las líneas sin importar
  `visible_public` — el apagado es una restricción exclusiva de la vista
  pública, nunca del inventario real.

### 2. Paginación

- Client-side: el catálogo ya carga todos los productos de una vez
  (`loadAll()`); la paginación solo corta el arreglo ya filtrado
  (por línea/categoría/búsqueda) en trozos de 15.
- Estado nuevo: página actual (empieza en 1). Cualquier cambio de línea,
  categoría o texto de búsqueda reinicia a la página 1.
- Controles debajo de la cuadrícula: "← Anterior", "Página X de Y",
  "Siguiente →". Si el resultado filtrado tiene 15 o menos, los controles
  no se muestran (nada que paginar).

### 3. Banner de promociones

- Debajo de los controles de paginación: si `PROMOTIONS` (ya cargado por
  `loadActivePromotions()`) tiene al menos una promoción activa, se
  muestra una franja por cada una, con su texto (ej. "20% de descuento en
  Electrónica"), reusando el mismo cálculo de alcance (línea/categoría)
  que ya usan las tarjetas de producto para mostrar el badge de
  descuento.
- Si no hay ninguna promoción activa, la sección no se renderiza —cero
  espacio reservado.

### 4. Contador de productos activos

- `index.html`: el bloque del contador de "Productos activos" solo se
  muestra si `site_settings.show_products_stat` es `true`. Los otros dos
  contadores (líneas, con 1 pieza disponible) no cambian.
- Pestaña Ajustes en Admin: un interruptor que escribe directo a esa
  columna.

### 5. Tema automático día/noche

- Nueva lógica en `theme.js`, usada solo por `index.html`: al cargar,
  calcula la hora actual en `America/Mexico_City` (vía
  `Intl.DateTimeFormat` con esa zona horaria — no depende de la zona
  horaria del dispositivo del visitante). Si son las 7:00–18:59, aplica
  tema claro; si no, oscuro. Se recalcula una vez por carga de página (no
  hace falta que cambie en vivo mientras alguien tiene la pestaña
  abierta).
- El botón de cambio manual de tema (`#theme-toggle`) se retira del
  `index.html` — ya no aplica, el automático manda. `admin.html` no
  cambia: conserva su botón y su lógica manual actuales, intactos.

## Manejo de errores

Si `site_settings` o los `visible_public` de `product_lines` no cargan
(falla de red, Supabase caído), el catálogo público usa valores seguros
por defecto en el propio código JS — nunca deja el catálogo vacío o
roto por un fallo de un ajuste secundario:

- Sin datos de `site_settings` → contador de productos **oculto**
  (comportamiento por defecto, ya es lo que Ricardo quiere de entrada).
- Sin datos de visibilidad por línea → **todas las líneas se muestran**
  (fail-open: mejor mostrar de más que dejar el catálogo vacío por un
  error técnico ajeno a las líneas mismas).
- Paginación y banner de promociones no dependen de red adicional más
  allá de lo que el catálogo ya carga hoy — no hay un caso de error nuevo
  que manejar ahí.

## Pruebas

Sin suite automatizada en este proyecto — igual que el resto, se prueba
en vivo con Ricardo:

1. Confirmar que el catálogo público solo muestra la línea "Toys" (pestaña
   de filtro y productos) recién aplicada la migración.
2. En Admin → Ajustes, encender otra línea (ej. Electrónica) y confirmar
   que aparece en el catálogo público en segundos (realtime).
3. Confirmar que con más de 15 productos visibles, aparecen los controles
   de paginación y funcionan; que buscar o cambiar de línea reinicia a la
   página 1.
4. Activar una promoción en Admin y confirmar que aparece el banner
   correspondiente debajo del catálogo; desactivarla y confirmar que el
   banner desaparece.
5. Confirmar que el contador de "Productos activos" está oculto por
   defecto, y que el interruptor en Ajustes lo muestra/oculta en vivo.
6. Confirmar que el catálogo público entra en modo oscuro fuera del
   horario 7am–7pm hora de Ciudad de México, y en modo claro dentro de
   ese rango — y que el botón manual de tema ya no aparece ahí. Confirmar
   que el Admin no cambió: sigue con su botón manual normal.
