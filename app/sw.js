const CACHE_NAME = 'lemus-shell-v1';

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
      fetch(request).catch(() => caches.match('/offline.html'))
    );
    return;
  }

  // Static shell assets only: cache-first, network as backup.
  const url = new URL(request.url);
  if (request.method === 'GET' && url.origin === self.location.origin && SHELL_URLS.includes(url.pathname)) {
    event.respondWith(
      caches.match(request).then((cached) => cached || fetch(request))
    );
  }
});
