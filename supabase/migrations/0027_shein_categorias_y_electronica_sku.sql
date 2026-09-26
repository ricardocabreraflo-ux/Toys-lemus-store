-- supabase/migrations/0027_shein_categorias_y_electronica_sku.sql
-- Corrección de datos para la línea Shein (catálogo PDF reordenado por Ricardo)
-- y extracción del SKU/Modelo de Electrónica que había quedado temporalmente
-- pegado al nombre del producto.
--
-- Shein:
--   1) products.barcode tenía en realidad el SKU (bug del import original) y
--      products.sku estaba vacío. Se mueve el valor actual de barcode a sku,
--      y se escribe en barcode el "Código de Barras" real tomado del PDF
--      (o NULL cuando el PDF no trae ese dato para esa fila).
--   2) Se aplana Pulseras (Caballero/Dama como subcategoría) en dos
--      categorías propias "Pulseras Caballero" / "Pulseras Dama", se crea
--      "Varios" para los artículos misceláneos del final del catálogo, y se
--      corrige el nombre de "Cartera y Bolsos" a "Carteras Y Bolsos" (tal
--      cual aparece la SUBCATEGORIA en el PDF).
--   3) Para Ropa y Ropa Interior (las únicas líneas de Shein con Talla en el
--      PDF) se crea una subcategoría "pass-through" del mismo nombre que la
--      categoría, solo para poder colgar de ahí la tabla sizes (que exige
--      subcategory_id). Se crean los valores de Talla vistos en el PDF y se
--      enlazan los productos vía size_id.
--   4) El nombre del producto se corrige para llevar solo el color entre
--      paréntesis cuando corresponde -- nunca la talla (el import original
--      había dejado "Color/Talla" completo pegado al nombre en la sección
--      ROPA, y en 6 productos de Ropa Interior del rack usado había dejado
--      solo la talla entre paréntesis por error).
--
-- Electrónica:
--   El texto de SKU/Modelo (p.ej. "XC-1821") se había pegado temporalmente
--   al nombre como " (XC-1821)". Se restaura ese valor en products.sku y se
--   limpia el nombre.

-- ============================================================
-- 1. Renombrar "Cartera y Bolsos" -> "Carteras Y Bolsos"
-- ============================================================
update public.categories
set name = 'Carteras Y Bolsos'
where product_line_id = 'f70cedc9-9ead-4d40-baf0-944e3d5d5aff'
  and name = 'Cartera y Bolsos';

-- ============================================================
-- 2. Nuevas categorías planas para Shein
-- ============================================================
insert into public.categories (id, product_line_id, name)
select gen_random_uuid(), 'f70cedc9-9ead-4d40-baf0-944e3d5d5aff', v.name
from (values ('Pulseras Caballero'), ('Pulseras Dama'), ('Varios')) as v(name)
where not exists (
  select 1 from public.categories c
  where c.product_line_id = 'f70cedc9-9ead-4d40-baf0-944e3d5d5aff' and c.name = v.name
);

-- ============================================================
-- 3. Subcategorías "pass-through" (mismo nombre que la categoría) para
--    poder enlazar tallas en Ropa y Ropa Interior
-- ============================================================
insert into public.subcategories (id, category_id, name)
select gen_random_uuid(), c.id, c.name
from public.categories c
where c.product_line_id = 'f70cedc9-9ead-4d40-baf0-944e3d5d5aff'
  and c.name in ('Ropa', 'Ropa Interior')
  and not exists (
    select 1 from public.subcategories s where s.category_id = c.id and s.name = c.name
  );

-- ============================================================
-- 4. Tallas para la subcategoría "Ropa"
-- ============================================================
insert into public.sizes (id, subcategory_id, name)
select gen_random_uuid(), sub.id, v.name
from (values
  ('164CM'), ('L'), ('S'), ('122CM'), ('M'), ('7-8Y'), ('Unitalla'), ('110CM'),
  ('134CM'), ('116CM'), ('128CM'), ('152CM'), ('5-6Y'), ('4-5Y'), ('36-39'), ('XS')
) as v(name)
cross join (
  select s.id
  from public.subcategories s
  join public.categories c on c.id = s.category_id
  where c.product_line_id = 'f70cedc9-9ead-4d40-baf0-944e3d5d5aff'
    and c.name = 'Ropa' and s.name = 'Ropa'
) sub
where not exists (select 1 from public.sizes sz where sz.subcategory_id = sub.id and sz.name = v.name);

-- ============================================================
-- 5. Tallas para la subcategoría "Ropa Interior"
-- ============================================================
insert into public.sizes (id, subcategory_id, name)
select gen_random_uuid(), sub.id, v.name
from (values ('L'), ('M'), ('S'), ('36B'), ('Unitalla'), ('34B'), ('M-L')) as v(name)
cross join (
  select s.id
  from public.subcategories s
  join public.categories c on c.id = s.category_id
  where c.product_line_id = 'f70cedc9-9ead-4d40-baf0-944e3d5d5aff'
    and c.name = 'Ropa Interior' and s.name = 'Ropa Interior'
) sub
where not exists (select 1 from public.sizes sz where sz.subcategory_id = sub.id and sz.name = v.name);

-- ============================================================
-- 6. Productos Shein: barcode/sku swap + categoría/subcategoría/talla +
--    corrección de nombre (color sin talla)
--
--    Columnas de shein_data: (code, new_barcode, category_name,
--    subcategory_name, size_name, new_color, strip_paren)
--      - new_barcode: "Código de Barras" del PDF (GSHN...) o null si el PDF
--        no trae ese dato para esa fila.
--      - subcategory_name/size_name: solo se llenan para Ropa / Ropa
--        Interior cuando el PDF trae una Talla real.
--      - new_color: color a dejar entre paréntesis en el nombre (solo se
--        usa en la sección ROPA, donde el nombre había quedado con
--        "(Color/Talla)" completo).
--      - strip_paren: true en los 6 productos de Ropa Interior (rack usado)
--        donde el nombre había quedado con "(Talla)" por error y debe
--        quedar sin paréntesis.
-- ============================================================
with shein_data(code, new_barcode, category_name, subcategory_name, size_name, new_color, strip_paren) as (
  values
  ('5001', 'GSHN5G4210023TT', 'Mochilas', null, null, null, false),
  ('5002', 'GSHN5G4210023TT', 'Mochilas', null, null, null, false),
  ('5003', 'GSHN5G4210023TT', 'Mochilas', null, null, null, false),
  ('5004', 'GSHN5G4210023TT', 'Mochilas', null, null, null, false),
  ('5005', 'GSHN5G4210023TT', 'Mochilas', null, null, null, false),
  ('5006', 'GSHN5G4210023TT', 'Mochilas', null, null, null, false),
  ('5007', 'GSHN5G4210023TT', 'Mochilas', null, null, null, false),
  ('5008', 'GSHN5G4210023TT', 'Mochilas', null, null, null, false),
  ('5009', 'GSHN5G4210023TT', 'Mochilas', null, null, null, false),
  ('5015', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5017', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5018', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5027', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5042', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5047', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5050', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5053', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5061', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5065', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5066', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5068', 'GSHN5G4210023TQ', 'Carteras Y Bolsos', null, null, null, false),
  ('5072', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5073', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5074', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5075', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'L', 'Negro', false),
  ('5076', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'M', 'Multicolor', false),
  ('5077', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5080', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5082', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'M', 'Rosa Coral', false),
  ('5083', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'M', 'Negro', false),
  ('5086', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5087', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'L', 'Negro', false),
  ('5088', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5092', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5093', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5094', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5095', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'S', 'Multicolor', false),
  ('5097', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5098', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5101', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5102', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5103', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'M', 'Negro', false),
  ('5104', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5105', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5106', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5108', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5109', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5110', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5111', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5112', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5113', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', '36B', 'Negro', false),
  ('5114', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'L', 'Rosa Vieja', false),
  ('5115', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'L', 'Multicolor', false),
  ('5116', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5117', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5118', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5119', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'M', 'Gris', false),
  ('5121', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5122', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'M', 'Negro', false),
  ('5123', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'M', 'Negro', false),
  ('5124', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5125', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'M', 'Negro', false),
  ('5126', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5127', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5128', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5129', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5130', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5131', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5132', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5133', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'L', 'Rojo', false),
  ('5134', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5135', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'S', 'Negro', false),
  ('5136', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'S', 'Azul Marino', false),
  ('5137', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'M', 'Negro', false),
  ('5138', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5140', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5141', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5142', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'Unitalla', 'Rojo', false),
  ('5144', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', '34B', 'Burdeos', false),
  ('5147', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5149', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5151', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'M', 'Rosa Coral', false),
  ('5152', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5153', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5154', 'GSHN5V42Q0000RU', 'Ropa Interior', 'Ropa Interior', 'S', 'Burdeos', false),
  ('5155', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5156', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5158', 'GSHN5V42Q0000RU', 'Carteras Y Bolsos', null, null, null, false),
  ('5159', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5160', 'GSHN5V42Q0000RU', 'Hogar', null, null, null, false),
  ('5161', null, 'Aretes', null, null, null, false),
  ('5162', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5163', null, 'Pulseras Caballero', null, null, null, false),
  ('5166', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5167', null, 'Anillos', null, null, null, false),
  ('5169', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5170', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5171', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5174', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5182', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5184', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5185', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5186', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5189', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5190', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5195', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5201', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5210', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5211', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5219', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5220', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5224', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5229', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5231', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5234', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5235', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5238', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5239', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5246', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5249', null, 'Pulseras Caballero', null, null, null, false),
  ('5253', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5258', 'GSHN5D42Q002CQD', 'Pulseras Dama', null, null, null, false),
  ('5268', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5269', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5270', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5271', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5272', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5273', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5274', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5275', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5276', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5277', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5278', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5279', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5280', 'GSHN5E42M000N65', 'Mochilas', null, null, null, false),
  ('5283', 'GSHN5E42M000N6Q', 'Carteras Y Bolsos', null, null, null, false),
  ('5284', 'GSHN5E42M000N6Q', 'Carteras Y Bolsos', null, null, null, false),
  ('5285', 'GSHN5E42M000N6Q', 'Carteras Y Bolsos', null, null, null, false),
  ('5286', 'GSHN5E42M000N6Q', 'Carteras Y Bolsos', null, null, null, false),
  ('5287', 'GSHN5E42M000N6Q', 'Carteras Y Bolsos', null, null, null, false),
  ('5288', 'GSHN5E42M000N6Q', 'Carteras Y Bolsos', null, null, null, false),
  ('5289', 'GSHN5E42M000N6Q', 'Carteras Y Bolsos', null, null, null, false),
  ('5292', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5293', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'S', 'Azul', false),
  ('5294', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5297', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5299', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5300', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5301', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5302', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'M', 'Negro', false),
  ('5303', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5307', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5309', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5310', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5314', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'L', 'Negro', false),
  ('5315', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5316', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5317', null, 'Pulseras Caballero', null, null, null, false),
  ('5318', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5322', null, 'Pulseras Caballero', null, null, null, false),
  ('5323', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'L', 'Burdeos', false),
  ('5324', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'L', 'Negro', false),
  ('5325', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'L', 'Gris Claro', false),
  ('5328', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5329', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5330', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5331', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5332', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5338', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5339', null, 'Pulseras Caballero', null, null, null, false),
  ('5340', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'M', 'Burdeos', false),
  ('5341', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'M', 'Blanco', false),
  ('5342', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'L', 'Blanco', false),
  ('5343', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5344', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'L', 'Burdeos', false),
  ('5346', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5347', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'L', 'Negro', false),
  ('5348', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'M', 'Negro', false),
  ('5349', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'L', 'Blanco', false),
  ('5350', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'L', 'Multicolor', false),
  ('5351', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'M', 'Blanco', false),
  ('5352', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'M', 'Negro', false),
  ('5354', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'S', 'Negro', false),
  ('5358', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5360', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5361', 'GSHN5P424000TJM', 'Ropa Interior', 'Ropa Interior', 'M', 'Rosa Vieja', false),
  ('5362', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5363', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5364', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5365', 'GSHN5P424000TJM', 'Pulseras Dama', null, null, null, false),
  ('5366', 'GSHN69426000HS2', 'Ropa', 'Ropa', '164CM', 'Multicolor', false),
  ('5367', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'L', 'Multicolor', false),
  ('5368', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'S', 'Verde Menta', false),
  ('5369', 'GSHN69426000HS2', 'Ropa', 'Ropa', '122CM', 'Neblina Azul', false),
  ('5370', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'S', 'Gris', false),
  ('5371', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'M', 'Blanco', false),
  ('5372', 'GSHN69426000HS2', 'Ropa', 'Ropa', '7-8Y', 'Negro', false),
  ('5373', 'GSHN69426000HS2', 'Ropa', 'Ropa', '164CM', 'Multicolor', false),
  ('5374', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'M', 'Negro', false),
  ('5375', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'Unitalla', 'Multicolor', false),
  ('5376', 'GSHN69426000HS2', 'Ropa', 'Ropa', '110CM', 'Rosa Pálido', false),
  ('5377', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'L', 'Blanco', false),
  ('5378', 'GSHN69426000HS2', 'Ropa', 'Ropa', '134CM', 'Multicolor', false),
  ('5379', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'L', 'Negro', false),
  ('5380', 'GSHN69426000HS2', 'Ropa', 'Ropa', '116CM', 'Multicolor', false),
  ('5381', 'GSHN69426000HS2', 'Ropa', 'Ropa', '164CM', 'Negro', false),
  ('5382', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'S', 'Blanco y Negro', false),
  ('5383', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'Unitalla', 'Multicolor', false),
  ('5384', 'GSHN69426000HS2', 'Ropa', 'Ropa', '110CM', 'Verde Oscuro', false),
  ('5385', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'L', 'Caqui', false),
  ('5386', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'L', 'Rojo', false),
  ('5387', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'S', 'Blanco', false),
  ('5388', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'S', 'Negro', false),
  ('5389', 'GSHN69426000HS2', 'Ropa', 'Ropa', '122CM', 'Negro', false),
  ('5390', 'GSHN69426000HS2', 'Ropa', 'Ropa', '122CM', 'Blanco', false),
  ('5391', 'GSHN69426000HS2', 'Ropa', 'Ropa', '128CM', 'Negro', false),
  ('5392', 'GSHN69426000HS2', 'Ropa', 'Ropa', '164CM', 'Multicolor', false),
  ('5393', 'GSHN69426000HS2', 'Ropa', 'Ropa', '152CM', 'Azul y Blanco', false),
  ('5394', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'Unitalla', 'Multicolor', false),
  ('5395', 'GSHN69426000HS2', 'Ropa', 'Ropa', null, 'Multicolor', false),
  ('5396', 'GSHN69426000HS2', 'Ropa', 'Ropa', '5-6Y', 'Multicolor', false),
  ('5397', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'S', 'Gris', false),
  ('5398', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'S', 'Multicolor', false),
  ('5399', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'M', 'Multicolor', false),
  ('5400', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'S', 'Blanco y Negro', false),
  ('5401', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'L', 'Negro', false),
  ('5402', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'S', 'Negro', false),
  ('5403', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'Unitalla', 'Multicolor', false),
  ('5404', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'Unitalla', 'Multicolor', false),
  ('5405', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'Unitalla', 'Multicolor', false),
  ('5406', 'GSHN69426000HS2', 'Ropa', 'Ropa', '4-5Y', 'Multicolor', false),
  ('5407', 'GSHN69426000HS2', 'Ropa', 'Ropa', '7-8Y', 'Rosa Vieja', false),
  ('5408', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'M', 'Blanco', false),
  ('5409', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'L', 'Óxido Marrón', false),
  ('5410', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'M', 'Multicolor', false),
  ('5411', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'M', 'Blanco y Negro', false),
  ('5412', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'M', 'Blanco', false),
  ('5413', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'Unitalla', 'Multicolor', false),
  ('5414', 'GSHN69426000HS2', 'Ropa', 'Ropa', '36-39', 'Multicolor', false),
  ('5415', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'Unitalla', 'Multicolor', false),
  ('5416', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'S', 'Blanco', false),
  ('5417', 'GSHN69426000HS2', 'Ropa', 'Ropa', 'XS', 'Negro', false),
  ('5418', 'GSHN69426000HS2', 'Ropa', 'Ropa', '36-39', 'Multicolor', false),
  ('5419', null, 'Ropa', 'Ropa', 'M', 'Marrón', false),
  ('5420', null, 'Ropa', 'Ropa', 'M', 'Multicolor', false),
  ('5421', null, 'Ropa', 'Ropa', 'L', 'Blanco', false),
  ('5422', null, 'Ropa', 'Ropa', 'M', 'Blanco y Negro', false),
  ('5423', null, 'Ropa', 'Ropa', 'L', 'Negro', false),
  ('5424', null, 'Ropa', 'Ropa', 'L', 'Blanco', false),
  ('5425', null, 'Ropa', 'Ropa', 'L', 'Multicolor', false),
  ('5426', null, 'Ropa', 'Ropa', 'L', 'Blanco y Negro', false),
  ('5427', null, 'Ropa', 'Ropa', 'L', 'Rosa', false),
  ('5428', null, 'Ropa', 'Ropa', 'M', 'Burdeos', false),
  ('5429', null, 'Ropa', 'Ropa', 'M', 'Blanco', false),
  ('5430', null, 'Ropa', 'Ropa', 'M', 'Rojo', false),
  ('5431', null, 'Ropa', 'Ropa', 'L', 'Blanco y Negro', false),
  ('5432', null, 'Ropa', 'Ropa', 'L', 'Multicolor', false),
  ('5433', null, 'Ropa', 'Ropa', 'M', 'Blanco y Negro', false),
  ('5434', null, 'Ropa', 'Ropa', 'L', 'Rosa Vieja', false),
  ('5435', null, 'Ropa', 'Ropa', 'M', 'Multicolor', false),
  ('5436', null, 'Botellas', null, null, null, false),
  ('5437', null, 'Botellas', null, null, null, false),
  ('5438', null, 'Botellas', null, null, null, false),
  ('5439', null, 'Botellas', null, null, null, false),
  ('5440', null, 'Botellas', null, null, null, false),
  ('5441', null, 'Botellas', null, null, null, false),
  ('5442', null, 'Botellas', null, null, null, false),
  ('5494', 'GSHNSK42700N8MT', 'Ropa', 'Ropa', 'L', 'Púrpura Malva', false),
  ('5495', 'GSHNSK42700N8MT', 'Ropa', 'Ropa', 'L', 'Burdeos', false),
  ('5496', 'GSHNSK42700N8MT', 'Ropa', 'Ropa', 'M', 'Gris', false),
  ('5497', null, 'Bolsas', null, null, null, false),
  ('5498', null, 'Bolsas', null, null, null, false),
  ('5499', null, 'Bolsas', null, null, null, false),
  ('5500', null, 'Bolsas', null, null, null, false),
  ('5501', null, 'Bolsas', null, null, null, false),
  ('5502', null, 'Bolsas', null, null, null, false),
  ('5503', null, 'Bolsas', null, null, null, false),
  ('5504', null, 'Bolsas', null, null, null, false),
  ('5505', null, 'Bolsas', null, null, null, false),
  ('5506', null, 'Bolsas', null, null, null, false),
  ('5507', null, 'Bolsas', null, null, null, false),
  ('5508', null, 'Bolsas', null, null, null, false),
  ('5509', null, 'Bolsas', null, null, null, false),
  ('5510', null, 'Bolsas', null, null, null, false),
  ('5511', null, 'Bolsas', null, null, null, false),
  ('5512', null, 'Bolsas', null, null, null, false),
  ('5513', null, 'Ropa', null, null, null, false),
  ('5514', null, 'Ropa', null, null, null, false),
  ('5515', null, 'Ropa', null, null, null, false),
  ('5516', null, 'Ropa', null, null, null, false),
  ('5517', null, 'Ropa', null, null, null, false),
  ('5518', null, 'Ropa', null, null, null, false),
  ('5519', null, 'Ropa', null, null, null, false),
  ('5520', null, 'Ropa', null, null, null, false),
  ('5521', null, 'Ropa', null, null, null, false),
  ('5522', null, 'Ropa', null, null, null, false),
  ('5523', null, 'Ropa', null, null, null, false),
  ('5524', null, 'Ropa', null, null, null, false),
  ('5525', null, 'Ropa', null, null, null, false),
  ('5526', null, 'Ropa', null, null, null, false),
  ('5527', null, 'Ropa', null, null, null, false),
  ('5528', null, 'Ropa', null, null, null, false),
  ('5529', null, 'Ropa', null, null, null, false),
  ('5530', null, 'Ropa', null, null, null, false),
  ('5531', null, 'Ropa', null, null, null, false),
  ('5532', null, 'Ropa', null, null, null, false),
  ('5533', null, 'Ropa', null, null, null, false),
  ('5534', null, 'Ropa', null, null, null, false),
  ('5535', null, 'Ropa', null, null, null, false),
  ('5536', null, 'Ropa', null, null, null, false),
  ('5537', null, 'Ropa', null, null, null, false),
  ('5538', null, 'Ropa', null, null, null, false),
  ('5539', null, 'Ropa', null, null, null, false),
  ('5540', null, 'Ropa', null, null, null, false),
  ('5541', null, 'Ropa', null, null, null, false),
  ('5542', null, 'Ropa', null, null, null, false),
  ('5543', null, 'Ropa', null, null, null, false),
  ('5544', null, 'Ropa', null, null, null, false),
  ('5545', null, 'Ropa', null, null, null, false),
  ('5546', null, 'Ropa', null, null, null, false),
  ('5547', null, 'Ropa', null, null, null, false),
  ('5548', null, 'Ropa', null, null, null, false),
  ('5549', null, 'Ropa', null, null, null, false),
  ('5550', null, 'Ropa', null, null, null, false),
  ('5551', null, 'Ropa', null, null, null, false),
  ('5552', null, 'Ropa', null, null, null, false),
  ('5553', null, 'Ropa', null, null, null, false),
  ('5554', null, 'Ropa', null, null, null, false),
  ('5555', null, 'Ropa', null, null, null, false),
  ('5556', null, 'Ropa', null, null, null, false),
  ('5557', null, 'Varios', null, null, null, false),
  ('5558', null, 'Ropa', null, null, null, false),
  ('5559', null, 'Ropa', null, null, null, false),
  ('5560', null, 'Ropa', null, null, null, false),
  ('5561', null, 'Varios', null, null, null, false),
  ('5562', null, 'Varios', null, null, null, false),
  ('5563', null, 'Varios', null, null, null, false),
  ('5564', null, 'Varios', null, null, null, false),
  ('5565', null, 'Varios', null, null, null, false),
  ('5566', null, 'Ropa', null, null, null, false),
  ('5567', null, 'Ropa', null, null, null, false),
  ('5568', null, 'Varios', null, null, null, false),
  ('5569', null, 'Varios', null, null, null, false),
  ('5570', null, 'Varios', null, null, null, false),
  ('5571', null, 'Varios', null, null, null, false),
  ('5572', null, 'Varios', null, null, null, false),
  ('5573', null, 'Varios', null, null, null, false),
  ('5574', null, 'Varios', null, null, null, false),
  ('5575', null, 'Varios', null, null, null, false),
  ('5576', null, 'Varios', null, null, null, false),
  ('5577', null, 'Varios', null, null, null, false),
  ('5578', null, 'Varios', null, null, null, false),
  ('5579', null, 'Varios', null, null, null, false),
  ('5580', null, 'Varios', null, null, null, false),
  ('5581', null, 'Varios', null, null, null, false),
  ('5582', null, 'Varios', null, null, null, false),
  ('5583', null, 'Varios', null, null, null, false),
  ('5584', null, 'Ropa', null, null, null, false),
  ('5585', null, 'Ropa', null, null, null, false),
  ('5586', null, 'Ropa Interior', 'Ropa Interior', 'M-L', null, true),
  ('5587', null, 'Ropa Interior', 'Ropa Interior', 'M', null, true),
  ('5588', null, 'Ropa Interior', 'Ropa Interior', 'M', null, true),
  ('5589', null, 'Ropa Interior', 'Ropa Interior', 'L', null, true),
  ('5590', null, 'Ropa Interior', 'Ropa Interior', 'L', null, true),
  ('5591', null, 'Ropa Interior', 'Ropa Interior', 'L', null, true),
  ('5592', null, 'Usado Rack', null, null, null, false),
  ('5593', null, 'Usado Rack', null, null, null, false),
  ('5594', null, 'Usado Rack', null, null, null, false),
  ('5595', null, 'Usado Rack', null, null, null, false),
  ('5596', null, 'Usado Rack', null, null, null, false),
  ('5597', null, 'Usado Rack', null, null, null, false),
  ('5598', null, 'Usado Rack', null, null, null, false),
  ('5599', null, 'Usado Rack', null, null, null, false),
  ('5600', null, 'Usado Rack', null, null, null, false)
)
update public.products p
set
  sku = p.barcode,
  barcode = d.new_barcode,
  category_id = cat.id,
  subcategory_id = sub.id,
  size_id = sz.id,
  name = case
    when d.strip_paren then regexp_replace(p.name, '\s*\([^)]*\)\s*$', '')
    when d.new_color is not null then regexp_replace(p.name, '\s*\([^)]*\)\s*$', '') || ' (' || d.new_color || ')'
    else p.name
  end
from shein_data d
join public.categories cat
  on cat.name = d.category_name and cat.product_line_id = 'f70cedc9-9ead-4d40-baf0-944e3d5d5aff'
left join public.subcategories sub
  on d.subcategory_name is not null and sub.name = d.subcategory_name and sub.category_id = cat.id
left join public.sizes sz
  on d.size_name is not null and sub.id is not null and sz.subcategory_id = sub.id and sz.name = d.size_name
where p.code = d.code and p.product_line_id = 'f70cedc9-9ead-4d40-baf0-944e3d5d5aff';

-- ============================================================
-- 7. Limpieza: categoría "Pulseras" y subcategorías "Caballero"/"Dama"
--    quedan huérfanas una vez migrados los productos arriba.
-- ============================================================
delete from public.subcategories s
where s.category_id in (
  select id from public.categories
  where product_line_id = 'f70cedc9-9ead-4d40-baf0-944e3d5d5aff' and name = 'Pulseras'
)
and not exists (select 1 from public.products p where p.subcategory_id = s.id);

delete from public.categories c
where c.product_line_id = 'f70cedc9-9ead-4d40-baf0-944e3d5d5aff'
  and c.name = 'Pulseras'
  and not exists (select 1 from public.products p where p.category_id = c.id)
  and not exists (select 1 from public.subcategories s where s.category_id = c.id);

-- ============================================================
-- 8. Electrónica: restaurar el SKU/Modelo que había quedado pegado al
--    nombre entre paréntesis, y limpiar el nombre.
-- ============================================================
with elec_data(prod_code, sku_val) as (
  values
  ('101', 'XC-1821'), ('102', 'TX-23 MP3'), ('103', 'W-633 ES-12'), ('104', '6972542800162'),
  ('105', 'PI-H005 MP3'), ('106', 'P40s SELFIE'), ('107', '10M'), ('108', '4M'), ('109', 'C17'),
  ('110', 'P11'), ('111', 'P13'), ('112', 'AAA'), ('113', 'AA'), ('114', 'DE'), ('115', 'X31'),
  ('116', '15'), ('117', 'OTG'), ('118', 'GQX01'), ('119', 'HD5'), ('120', 'M14'), ('121', 'X81'),
  ('122', 'M4'), ('123', 'X16'), ('124', '12V'), ('125', 'LD9'), ('126', 'CT18'), ('127', 'X19'),
  ('128', 'CC1'), ('129', 'CLA'), ('130', 'V8'), ('131', 'SBM62'), ('132', 'SX'), ('133', 'MO'),
  ('134', 'CA5'), ('135', '32GB'), ('137', 'TWS 7'), ('138', 'E7s'), ('140', 'V8'),
  ('141', 'AY0520'), ('143', 'GAR063'), ('144', 'OTG-V8-C'), ('145', 'OTG-C'), ('146', 'OTG6 C-USB'),
  ('147', 'X80 IP-C'), ('148', 'HOLA'), ('149', 'CR289'), ('150', 'CR149'), ('151', 'MP3'),
  ('152', 'C30 USB C'), ('153', 'USB PORTS'), ('154', 'AUT C'), ('155', 'P9'), ('156', 'P11POWER'),
  ('157', 'J57 PAD'), ('158', 'SEB BT'), ('159', 'HU3.0'), ('160', 'GAR-DZ8C'), ('161', 'KL236'),
  ('162', 'BH-M1'), ('163', 'AUTM14'), ('164', 'CAB9003'), ('165', 'M33'), ('166', 'X2 HUD'),
  ('167', 'SB68'), ('168', 'P13 POWER BANK'), ('169', 'JSJ CALCULADORA'), ('170', 'CABLE 4M'),
  ('171', 'SB76'), ('172', 'C23 20W CUBO'), ('173', 'C19 CLAVIJA 5.1'), ('174', 'SE2308190540016661'),
  ('175', 'SE2306228268299281'), ('176', 'SE2309081915047566'), ('177', 'SE2302281146145482'),
  ('178', 'SH2302152900721222'), ('179', 'SH2302152900775173'), ('180', 'SE2303091291015255'),
  ('181', 'SE2308230307917288'), ('182', 'SE2309288111802431'), ('183', 'SE2309288111817410'),
  ('184', 'SR2309206571715125'), ('186', 'SE2309160298041242'), ('187', 'SE2402038204320834'),
  ('188', 'SE2312286642772243'), ('189', 'SV2312079558169013'), ('190', 'SE2401048662464276'),
  ('191', 'SH2308315180228717'), ('192', 'SE2312096054804676'), ('193', 'SE2206090586049611'),
  ('194', 'SE2304198709387777'), ('195', 'SQ2303048832678627'), ('196', 'SE2211274141981564'),
  ('197', 'SE2304198709354233'), ('198', 'L-12'), ('199', 'YCX-1'), ('200', 'P14'), ('201', 'P20'),
  ('202', 'FS-10'), ('203', 'BST-1'), ('204', 'WJC-7'), ('205', 'CHE-34'), ('206', '10336'),
  ('207', 'M-58'), ('209', 'H21'), ('210', 'G2-4'), ('211', 'SW01'), ('212', 'BOC03'),
  ('213', 'BOC04'), ('214', 'MK-C'), ('215', 'R1'), ('217', 'TWS02'), ('218', 'TWS03'),
  ('219', 'TWS04'), ('220', 'TL73'), ('221', 'J-12'), ('223', 'L-9'), ('224', 'MW-1'),
  ('225', 'KD35OMSC'), ('226', 'J-57'), ('227', 'PILAS REDONDAS'), ('228', 'J-13')
)
update public.products p
set
  sku = d.sku_val,
  name = case
    when right(p.name, length(d.sku_val) + 3) = ' (' || d.sku_val || ')'
      then left(p.name, length(p.name) - length(d.sku_val) - 3)
    else p.name
  end
from elec_data d
where p.code = d.prod_code and p.product_line_id = 'dc80d66e-be38-47eb-acd9-95e83459188c';
