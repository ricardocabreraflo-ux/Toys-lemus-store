function showUpdateBanner() {
  if (document.getElementById('pwa-update-banner')) return;
  const banner = document.createElement('div');
  banner.id = 'pwa-update-banner';
  const label = document.createElement('span');
  label.textContent = 'Hay una versión nueva disponible';
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.textContent = 'Actualizar';
  btn.addEventListener('click', () => location.reload());
  banner.appendChild(label);
  banner.appendChild(btn);
  document.body.appendChild(banner);
}

// The service worker already activates a new version immediately
// (skipWaiting + clients.claim in sw.js) — this only tells the person
// using an already-open tab that fresh code is ready, since the page's
// own already-running JS doesn't reload itself.
export function registerServiceWorkerWithUpdatePrompt() {
  if (!('serviceWorker' in navigator)) return;

  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').then((registration) => {
      registration.addEventListener('updatefound', () => {
        const newWorker = registration.installing;
        if (!newWorker) return;
        newWorker.addEventListener('statechange', () => {
          if (newWorker.state === 'installed' && navigator.serviceWorker.controller) {
            showUpdateBanner();
          }
        });
      });
    }).catch(() => {});
  });
}
