const CACHE_NAME = 'lemus-shell-v5';

const SHELL_URLS = [
  '/index.html',
  '/admin.html',
  '/offline.html',
  '/manifest-catalogo.json',
  '/manifest-admin.json',
  '/css/styles.css',
  '/js/admin.js',
  '/js/catalog-data.js',
  '/js/catalog.js',
  '/js/config.js',
  '/js/icons.js',
  '/js/pwa-update.js',
  '/js/supabase-client.js',
  '/js/theme.js',
  '/js/vendor/supabase.umd.js',
  '/fonts/Baloo2-700.ttf',
  '/fonts/Karla-400.ttf',
  '/fonts/Karla-700.ttf',
  '/icons/catalogo/icon-192.png',
  '/icons/catalogo/icon-512.png',
  '/icons/catalogo/icon-maskable-512.png',
  '/icons/catalogo/apple-touch-icon.png',
  '/icons/admin/icon-192.png',
  '/icons/admin/icon-512.png',
  '/icons/admin/icon-maskable-512.png',
  '/icons/admin/apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(SHELL_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;

  // Navigations (loading a page): try the network, fall back to the
  // offline page. Never cache API/Supabase responses.
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request).catch(() =>
        caches.match('/offline.html').then((cached) =>
          cached || new Response(
            '<h1>Sin conexión</h1><p>Revisa tu internet e intenta de nuevo.</p>',
            { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
          )
        )
      )
    );
    return;
  }

  // Static shell assets only: stale-while-revalidate so a future deploy's
  // new CSS/JS reaches existing visitors on the next load.
  const url = new URL(request.url);
  if (request.method === 'GET' && url.origin === self.location.origin && SHELL_URLS.includes(url.pathname)) {
    event.respondWith(
      caches.match(request).then((cached) => {
        const network = fetch(request).then((res) => {
          if (res && res.ok) {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((c) => c.put(request, copy));
          }
          return res;
        });
        return cached || network;
      })
    );
  }
});
