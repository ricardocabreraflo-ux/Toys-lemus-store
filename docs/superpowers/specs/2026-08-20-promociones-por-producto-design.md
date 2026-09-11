# Promociones por producto específico

## Contexto

Ricardo probó el banner de promociones recién entregado (bloque "Catálogo
público") y pidió dos cosas relacionadas:

1. El campo "Nombre" al crear una promoción no le deja buscar/seleccionar
   productos escribiendo la primera letra.
2. El banner de promoción se ve muy pequeño — quiere algo grande y
   llamativo, con la imagen del producto.

Al confirmar con Ricardo, ambas piden lo mismo de fondo: hoy una
promoción solo puede aplicar a **toda una línea** o **toda una
categoría** — no existe forma de descontar un solo producto. Ricardo
había estado escribiendo el nombre del producto en el campo "Nombre"
(pensado como una etiqueta libre para la promoción) y aplicándola a la
línea completa como solución alterna, porque no había opción de
"producto específico". Este grupo agrega esa tercera opción y usa el
producto elegido para mostrar un banner grande en la página pública.

**Nota sobre "imagen del producto":** esta tienda no guarda fotos de
producto — las tarjetas del catálogo usan un ícono de línea dibujado
(el mismo esquema de íconos/color que ya se usa en cada tarjeta,
`iconKeyFor`/`accentFor`). El banner grande reutiliza exactamente ese
mismo ícono y color a tamaño grande, no una fotografía — mantiene
consistencia visual con el resto del catálogo.

## Alcance

Incluido:
- Nuevo `scope_type = 'product'` en `promotions`, con columna
  `product_id`.
- En Admin → Promociones: al elegir "Aplica a: Producto específico",
  el selector "¿Cuál?" se convierte en un buscador con autocompletado
  (escribe, ve sugerencias filtradas por nombre, hace clic para elegir).
- Al elegir un producto, si el campo "Nombre" está vacío se rellena
  automáticamente con el nombre del producto (Ricardo lo puede editar
  después) — así no tiene que escribirlo dos veces.
- En el catálogo público: las promociones de producto específico se
  muestran en una tarjeta de banner grande (ícono grande a color, nombre
  del producto, precio tachado + precio con descuento, badge de %) en
  vez de la pastilla de texto actual.
- Las promociones por línea/categoría existentes **no cambian** — siguen
  mostrándose como pastilla de texto pequeña, porque no hay un solo
  producto que ilustrar.
- Si hay varias promociones de producto activas a la vez, se muestran
  todas en fila (o apiladas en pantallas angostas), igual que hoy pasa
  con las pastillas.

Fuera de alcance: subir fotos reales de producto (no existe ese campo
hoy, y agregarlo es un cambio bastante más grande — no se pidió);
cambiar cómo se ven o comportan las promociones de línea/categoría.

## Modelo de datos

`public.promotions` gana una columna y su regla de consistencia se
amplía a tres formas válidas:

```sql
alter table public.promotions
  add column if not exists product_id uuid references public.products(id) on delete cascade;

-- Drop whatever the scope_type check constraint actually ended up named
-- (Postgres auto-names an inline column check, and we'd rather not guess
-- wrong and leave a stale constraint blocking 'product' rows) by finding
-- it dynamically instead of hardcoding a name.
do $$
declare
  con record;
begin
  for con in
    select c.conname
    from pg_constraint c
    join pg_class rel on rel.oid = c.conrelid
    where rel.relname = 'promotions'
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%scope_type%'
  loop
    execute format('alter table public.promotions drop constraint %I', con.conname);
  end loop;
end;
$$;

alter table public.promotions add constraint promotions_scope_type_check
  check (scope_type in ('line', 'category', 'product'));

alter table public.promotions drop constraint if exists promotions_scope_matches_target;
alter table public.promotions add constraint promotions_scope_matches_target check (
  (scope_type = 'line' and product_line_id is not null and category_id is null and product_id is null) or
  (scope_type = 'category' and category_id is not null and product_line_id is null and product_id is null) or
  (scope_type = 'product' and product_id is not null and product_line_id is null and category_id is null)
);
```

`on delete cascade` en `product_id` sigue el mismo patrón que
`product_line_id`/`category_id` ya usan en esta tabla: si el producto se
borra, la promoción que lo apuntaba se borra con él (no tiene sentido
dejarla huérfana).

No se toca RLS — las políticas de `promotions` ya son de lectura
pública / escritura autenticada, sin distinción por `scope_type`.

## Componentes

### 1. Cálculo de descuento (`catalog-data.js`)

`bestPromotionFor(product, promotions)` gana una tercera condición de
coincidencia:

```javascript
(p.scope_type === 'product' && p.product_id === product.id)
```

Si un producto coincide con más de una promoción activa (ej. su línea
Y él mismo específicamente), sigue ganando la de mayor `%` — mismo
criterio que ya existe hoy entre línea y categoría, sin agregar un caso
especial de prioridad por tipo.

### 2. Admin → Promociones: buscador de producto

- "Aplica a" gana una tercera opción: "Producto específico".
- Al elegir "Producto específico", el `<select id="promo-scope-target">`
  se reemplaza (mostrar/ocultar, no un elemento nuevo en el DOM) por un
  buscador: `<input type="text">` con una lista de sugerencias debajo
  que se filtra en vivo contra `PRODUCTS` (ya cargado en Admin) por
  substring de `name`, sin distinguir mayúsculas/acentos exactos —
  basta un `includes()` case-insensitive simple, sin necesidad de una
  librería nueva. Se muestran máximo 8 sugerencias a la vez.
- Al hacer clic en una sugerencia: se guarda el `id` del producto en un
  campo oculto (el valor que se manda como `product_id` al crear), el
  buscador muestra el nombre elegido, y si `#promo-name` está vacío se
  rellena con ese mismo nombre.
- Si Ricardo cambia "Aplica a" de vuelta a línea/categoría, se restaura
  el `<select>` normal (comportamiento actual, sin cambios).

### 3. Banner grande en el catálogo público (`catalog.js` + `styles.css`)

- `renderPromoBanner()` separa las promociones activas en dos grupos:
  las de producto (`scope_type === 'product'`) y el resto
  (línea/categoría, comportamiento actual sin cambios).
- Cada promoción de producto se renderiza como una tarjeta ancha:
  ícono grande a color (mismo `iconKeyFor`/`accentFor` que ya usan las
  tarjetas del catálogo, aplicado al producto promovido), nombre del
  producto, precio tachado + precio con descuento (mismo cálculo que ya
  usa `cardHtml` vía `discountedPrice`), y el badge de "-X%".
- Un producto oculto (línea apagada desde Ajustes) no debe mostrar su
  banner — mismo filtro `visibleLineIds` que ya se aplica al resto de
  `PROMOTIONS` en `loadAll()`, extendido para cubrir también el caso
  `scope_type === 'product'` (comprobando la línea del producto
  apuntado).

## Manejo de errores

- Si el producto referenciado por una promoción fue borrado, la fila de
  `promotions` se borra en cascada (ver modelo de datos) — no hay estado
  "promoción huérfana" que manejar en el frontend.
- El buscador de producto en Admin no depende de red adicional: filtra
  sobre `PRODUCTS`, que Admin ya tiene cargado en memoria.

## Pruebas

Sin suite automatizada — se prueba en vivo con Ricardo:

1. Crear una promoción con "Aplica a: Producto específico", buscar un
   producto por las primeras letras de su nombre, confirmar que aparece
   en las sugerencias y que elegirlo rellena "Nombre" si estaba vacío.
2. Confirmar que el catálogo público muestra esa promoción como tarjeta
   grande (ícono, nombre, precio tachado, % de descuento) y no como
   pastilla.
3. Confirmar que una promoción de línea/categoría existente se sigue
   viendo igual que antes (pastilla pequeña).
4. Ocultar la línea del producto promovido desde Ajustes y confirmar que
   el banner grande desaparece junto con el resto del catálogo de esa
   línea.
5. Borrar el producto promovido desde Inventario y confirmar que la
   promoción desaparece sola de la lista en Admin (por el `on delete
   cascade`).
