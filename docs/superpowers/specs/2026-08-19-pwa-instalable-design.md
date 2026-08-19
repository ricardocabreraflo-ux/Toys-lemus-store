# Catálogo y Admin instalables como app (PWA)

## Contexto

Ricardo quiere poder instalar tanto el catálogo público (`index.html`) como
el panel de administrador (`admin.html`) como apps independientes en el
celular — cada una con su propio ícono y nombre en la pantalla de inicio,
que abran en pantalla completa (sin la barra del navegador).

Hoy ninguna de las dos páginas tiene lo necesario para esto: no hay
manifest, no hay íconos en imagen (el logo actual es un SVG en línea), no
hay comportamiento definido para cuando no hay conexión.

## Alcance

- Instalar el catálogo y el admin como **dos apps separadas**, cada una con
  su propio ícono, nombre y pantalla de instalación.
- Mensaje simple de "sin conexión" si se abre la app instalada sin
  internet (sin guardar el catálogo para verlo offline — eso queda anotado
  como mejora futura).
- **Cero cambios** a las URLs, rutas o comportamiento existente — en
  particular, no se tocan `index.html?checkout=...` /
  `?apartado=...`, que ya están configuradas como `back_urls` en Mercado
  Pago.

Fuera de alcance (anotado como pendiente futuro, no se construye ahora):
- Ver el catálogo guardado sin conexión (más allá del mensaje simple).

## Diseño de los íconos

Un control de videojuego dibujado en línea (cordón enrollado arriba,
cruz de dirección a la izquierda, 4 botones en rombo a la derecha),
aprobado por Ricardo tras varias iteraciones:

- **Fondo:** blanco (`#ffffff`), esquinas redondeadas.
- **Trazo del control:** negro (`#000000`), grosor de línea uniforme.
- **Catálogo:** el ícono tal cual, sin ningún elemento adicional.
- **Admin:** el mismo ícono, con una insignia circular pequeña en la
  esquina inferior derecha (fondo blanco, borde oscuro, engranaje negro)
  para distinguirlo del catálogo a simple vista en la pantalla de inicio.

Ambos comparten nombre corto de marca pero texto distinto bajo el ícono:
"Lemus Store" (catálogo) y "Lemus Store Admin" (admin).

### Tamaños de archivo a generar

Para que Android/iOS acepten instalar la app se necesitan íconos PNG en
varios tamaños, generados a partir del diseño SVG aprobado:

- `icon-192.png` (192×192) — mínimo requerido por Chrome/Android.
- `icon-512.png` (512×512) — usado en la pantalla de "splash" al abrir.
- `icon-maskable-512.png` (512×512, con margen de seguridad) — para que
  Android no recorte el ícono en formas raras (círculo, gota, etc.).
- `apple-touch-icon.png` (180×180) — el que usa iOS al agregar a inicio.

Cada set se genera dos veces (catálogo y admin), en
`app/icons/catalogo/` y `app/icons/admin/`.

## Arquitectura técnica

**Un solo service worker compartido** (`app/sw.js`), registrado por ambas
páginas, con alcance en la raíz del sitio. Su única función por ahora:

1. Cachear el "cascarón" estático de la app (HTML, CSS, JS, íconos) para
   que abra rápido.
2. Si una petición de navegación falla por falta de red y no hay nada en
   caché, mostrar una página simple de "Sin conexión — revisa tu internet
   e intenta de nuevo" en vez del error nativo del navegador.

Explícitamente **no** cachea datos de Supabase (productos, pedidos, etc.)
— cada carga muestra la información más reciente cuando hay conexión. Esa
mejora (guardar catálogo para verlo offline) queda para una fase futura.

**Dos manifests separados:**

- `app/manifest-catalogo.json` — `name: "Lemus Store"`, `short_name:
  "Lemus Store"`, `start_url: "/index.html"`, `scope: "/"`, `display:
  "standalone"`, íconos del set catálogo.
- `app/manifest-admin.json` — `name: "Lemus Store Admin"`, `short_name:
  "Lemus Admin"`, `start_url: "/admin.html"`, `scope: "/"`, `display:
  "standalone"`, íconos del set admin.

`index.html` enlaza únicamente su manifest; `admin.html` enlaza
únicamente el suyo. Aunque comparten el mismo service worker por debajo
(invisible para el usuario), cada página se instala e identifica por
separado gracias a su propio manifest.

**Cambios en cada HTML:**

```html
<link rel="manifest" href="manifest-catalogo.json"> <!-- o manifest-admin.json -->
<meta name="theme-color" content="#FF5A36">
<link rel="apple-touch-icon" href="icons/catalogo/apple-touch-icon.png"> <!-- o admin -->
<script>
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js');
  }
</script>
```

## Manejo de errores

- Si el navegador no soporta service workers (muy poco común hoy), la
  página sigue funcionando normal — simplemente no se puede "instalar", y
  no se ofrece el mensaje de sin conexión (cae al error nativo del
  navegador). No es un caso que haya que manejar especialmente.
- Si falla el registro del service worker (error de red al cargar
  `sw.js`), se ignora silenciosamente — la página sigue funcionando como
  sitio web normal, sin capacidad de "instalar" hasta que cargue bien.

## Pruebas

No hay suite automatizada en este proyecto — se prueba en vivo con
Ricardo, igual que el resto del proyecto:

1. Abrir el catálogo en el celular, confirmar que aparece la opción de
   instalar / agregar a inicio, y que el ícono/nombre correctos aparecen
   en la pantalla previa a instalar.
2. Repetir para el admin, confirmando que su ícono (con engranaje) y
   nombre ("Lemus Store Admin") sean distintos a los del catálogo.
3. Instalar ambas, confirmar que abren en pantalla completa sin la barra
   del navegador.
4. Activar modo avión con la app instalada abierta, recargar, confirmar
   que se ve el mensaje simple de "sin conexión" en vez de un error feo.
5. Confirmar que el flujo de compra/apartado con Mercado Pago sigue
   funcionando exactamente igual que antes, dentro de la app instalada.
