# Catálogo y Admin instalables como app (PWA) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the public catalog (`app/index.html`) and the admin panel (`app/admin.html`) installable as two separate apps from the browser, each with its own icon/name, plus a simple offline fallback.

**Architecture:** One shared minimal service worker (`app/sw.js`, root scope) caches the static shell and serves a self-contained offline page when navigation fails without network. Two separate `manifest.json` files give each HTML page its own install identity (name, icons, start_url) while sharing the same service worker underneath. No existing URLs, redirects, or Supabase/Mercado Pago integration are touched.

**Tech Stack:** Vanilla JS/HTML/CSS (no build step), Web App Manifest, Service Worker API, Playwright (dev-time only, to rasterize the SVG icon design into PNGs).

## Global Constraints

- Zero changes to existing URLs, query params, or redirect targets — in particular `index.html?checkout=success/cancel` and `index.html?apartado=success/cancel` (used as Mercado Pago `back_urls`) must keep working exactly as before.
- The service worker must NOT cache Supabase API responses or any dynamic data — only the static shell (HTML/CSS/JS/fonts/icons/manifests) and the offline fallback page.
- Icon design is final and approved: white background (`#ffffff`), rounded corners on the app icon (NOT on the maskable variant, which must be a full-bleed square), black (`#000000`) line-art game controller. Admin variant adds a small circular badge (white fill, `#111318` border, black gear glyph) in the bottom-right corner. Do not restyle, recolor, or "improve" this design.
- `app/` is the Netlify publish directory (see `netlify.toml`) — every new file referenced by the app must live under `app/`.

---

## File Structure

- Create: `scripts/generate-pwa-icons.mjs` — one-time dev script (not deployed, `scripts/` is outside the `app/` publish dir) that rasterizes the four SVG icon templates into PNGs at the required sizes for both variants.
- Create: `app/icons/catalogo/icon-192.png`, `app/icons/catalogo/icon-512.png`, `app/icons/catalogo/icon-maskable-512.png`, `app/icons/catalogo/apple-touch-icon.png`
- Create: `app/icons/admin/icon-192.png`, `app/icons/admin/icon-512.png`, `app/icons/admin/icon-maskable-512.png`, `app/icons/admin/apple-touch-icon.png`
- Create: `app/offline.html` — self-contained (inline CSS, no external requests) fallback page shown when a navigation fails offline.
- Create: `app/sw.js` — the shared service worker.
- Create: `app/manifest-catalogo.json`, `app/manifest-admin.json`
- Modify: `app/index.html` — add manifest link, theme-color, apple-touch-icon, service worker registration.
- Modify: `app/admin.html` — same, pointing at the admin manifest/icons.

---

### Task 1: Generate the PWA icon assets

**Files:**
- Create: `scripts/generate-pwa-icons.mjs`
- Create: `app/icons/catalogo/icon-192.png`, `app/icons/catalogo/icon-512.png`, `app/icons/catalogo/icon-maskable-512.png`, `app/icons/catalogo/apple-touch-icon.png`
- Create: `app/icons/admin/icon-192.png`, `app/icons/admin/icon-512.png`, `app/icons/admin/icon-maskable-512.png`, `app/icons/admin/apple-touch-icon.png`

**Interfaces:**
- Produces: 8 PNG files at `app/icons/catalogo/*.png` and `app/icons/admin/*.png`, consumed by Task 4 (manifests) and Tasks 5-6 (apple-touch-icon links).

This environment has Playwright installed globally at `/opt/node22/lib/node_modules` with Chromium at `/opt/pw-browsers/chromium` — no `npm install` needed. If executing this plan in a different environment, run `npm install -D playwright && npx playwright install chromium` first and drop the `NODE_PATH`/`executablePath` overrides below.

- [ ] **Step 1: Write the icon generator script**

Create `scripts/generate-pwa-icons.mjs`:

```javascript
import { chromium } from 'playwright';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const APP_DIR = path.join(__dirname, '..', 'app');

const CONTROLLER_GROUP = `
  <g transform="translate(38,42)" fill="none" stroke="#000000" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M-2-14c3-1 3-3 1-5s-3-4 0-6"/>
    <rect x="-20" y="-9" width="40" height="22" rx="11"/>
    <path d="M-13 0h7M-9.5-3.5v7" stroke-width="3"/>
    <circle cx="8" cy="-4.5" r="2" fill="#000000" stroke="none"/>
    <circle cx="13.5" cy="1" r="2" fill="#000000" stroke="none"/>
    <circle cx="8" cy="6.5" r="2" fill="#000000" stroke="none"/>
    <circle cx="2.5" cy="1" r="2" fill="#000000" stroke="none"/>
  </g>`;

const CONTROLLER_GROUP_MASKABLE = `
  <g transform="translate(38,40) scale(0.78)" fill="none" stroke="#000000" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M-2-14c3-1 3-3 1-5s-3-4 0-6"/>
    <rect x="-20" y="-9" width="40" height="22" rx="11"/>
    <path d="M-13 0h7M-9.5-3.5v7" stroke-width="3"/>
    <circle cx="8" cy="-4.5" r="2" fill="#000000" stroke="none"/>
    <circle cx="13.5" cy="1" r="2" fill="#000000" stroke="none"/>
    <circle cx="8" cy="6.5" r="2" fill="#000000" stroke="none"/>
    <circle cx="2.5" cy="1" r="2" fill="#000000" stroke="none"/>
  </g>`;

const ADMIN_BADGE = `
  <circle cx="60" cy="60" r="13" fill="#ffffff" stroke="#111318" stroke-width="2.5"/>
  <g transform="translate(48,48) scale(0.5)">
    <path fill="#000000" d="M19.14 12.94a7.14 7.14 0 0 0 .06-.94 7.14 7.14 0 0 0-.06-.94l2.03-1.58a.5.5 0 0 0 .12-.64l-1.92-3.32a.5.5 0 0 0-.6-.22l-2.39.96a7.3 7.3 0 0 0-1.62-.94l-.36-2.54a.5.5 0 0 0-.5-.42h-3.84a.5.5 0 0 0-.5.42l-.36 2.54c-.59.24-1.13.56-1.62.94l-2.39-.96a.5.5 0 0 0-.6.22L2.71 8.84a.5.5 0 0 0 .12.64l2.03 1.58a7.14 7.14 0 0 0 0 1.88l-2.03 1.58a.5.5 0 0 0-.12.64l1.92 3.32c.14.24.42.32.6.22l2.39-.96c.49.38 1.03.7 1.62.94l.36 2.54a.5.5 0 0 0 .5.42h3.84a.5.5 0 0 0 .5-.42l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.24.1.46.02.6-.22l1.92-3.32a.5.5 0 0 0-.12-.64zM12 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7z"/>
  </g>`;

function svg(bodyRect, group, badge = '') {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 76 76">${bodyRect}${group}${badge}</svg>`;
}

const ICONS = [
  // variant, filename, sizePx, svgMarkup
  ['catalogo', 'icon-192.png', 192, svg('<rect width="76" height="76" rx="18" fill="#ffffff"/>', CONTROLLER_GROUP)],
  ['catalogo', 'icon-512.png', 512, svg('<rect width="76" height="76" rx="18" fill="#ffffff"/>', CONTROLLER_GROUP)],
  ['catalogo', 'icon-maskable-512.png', 512, svg('<rect width="76" height="76" fill="#ffffff"/>', CONTROLLER_GROUP_MASKABLE)],
  ['catalogo', 'apple-touch-icon.png', 180, svg('<rect width="76" height="76" fill="#ffffff"/>', CONTROLLER_GROUP)],
  ['admin', 'icon-192.png', 192, svg('<rect width="76" height="76" rx="18" fill="#ffffff"/>', CONTROLLER_GROUP, ADMIN_BADGE)],
  ['admin', 'icon-512.png', 512, svg('<rect width="76" height="76" rx="18" fill="#ffffff"/>', CONTROLLER_GROUP, ADMIN_BADGE)],
  ['admin', 'icon-maskable-512.png', 512, svg('<rect width="76" height="76" fill="#ffffff"/>', CONTROLLER_GROUP_MASKABLE, ADMIN_BADGE)],
  ['admin', 'apple-touch-icon.png', 180, svg('<rect width="76" height="76" fill="#ffffff"/>', CONTROLLER_GROUP, ADMIN_BADGE)],
];

const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
const tmpDir = path.join(__dirname, '.icon-render-tmp');
mkdirSync(tmpDir, { recursive: true });

for (const [variant, filename, sizePx, markup] of ICONS) {
  const outDir = path.join(APP_DIR, 'icons', variant);
  mkdirSync(outDir, { recursive: true });

  const html = `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0;}</style></head><body>${markup.replace('<svg ', `<svg width="${sizePx}" height="${sizePx}" `)}</body></html>`;
  const tmpFile = path.join(tmpDir, `${variant}-${filename}.html`);
  writeFileSync(tmpFile, html);

  const page = await browser.newPage({ viewport: { width: sizePx, height: sizePx } });
  await page.goto('file://' + tmpFile);
  await page.screenshot({ path: path.join(outDir, filename) });
  await page.close();

  console.log(`Wrote ${path.join('app', 'icons', variant, filename)} (${sizePx}x${sizePx})`);
}

await browser.close();
rmSync(tmpDir, { recursive: true, force: true });
```

- [ ] **Step 2: Run the generator**

```bash
cd /home/user/Toys-lemus-store
NODE_PATH=/opt/node22/lib/node_modules node scripts/generate-pwa-icons.mjs
```

Expected: 8 lines of `Wrote app/icons/...` output, no errors.

- [ ] **Step 3: Verify the files exist and look right**

```bash
ls -la app/icons/catalogo/ app/icons/admin/
file app/icons/catalogo/icon-512.png
```

Expected: 4 PNG files in each directory; `file` reports `PNG image data, 512 x 512`.

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-pwa-icons.mjs app/icons/
git commit -m "Generate PWA icon assets for catalog and admin apps"
```

---

### Task 2: Offline fallback page

**Files:**
- Create: `app/offline.html`

**Interfaces:**
- Produces: `/offline.html`, a fully self-contained page (no external CSS/JS/font requests) consumed by `app/sw.js` (Task 3) as the fetch-failure fallback.

- [ ] **Step 1: Write the offline page**

Create `app/offline.html`:

```html
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sin conexión — Lemus Store</title>
<style>
  html, body { margin: 0; height: 100%; }
  body {
    display: flex; align-items: center; justify-content: center;
    background: #FFFBF2; color: #2B2F38;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    text-align: center; padding: 24px; box-sizing: border-box;
  }
  .card { max-width: 360px; }
  h1 { font-size: 20px; margin: 0 0 8px; }
  p { font-size: 15px; color: #6B6F76; margin: 0 0 20px; }
  button {
    font: inherit; font-weight: 600; font-size: 15px;
    background: #FF5A36; color: #fff; border: none;
    padding: 12px 24px; border-radius: 999px; cursor: pointer;
  }
  button:active { opacity: 0.85; }
</style>
</head>
<body>
  <div class="card">
    <h1>Sin conexión</h1>
    <p>Revisa tu internet e intenta de nuevo.</p>
    <button onclick="location.reload()">Reintentar</button>
  </div>
</body>
</html>
```

- [ ] **Step 2: Verify it opens standalone**

```bash
NODE_PATH=/opt/node22/lib/node_modules node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const page = await browser.newPage();
  await page.goto('file://$(pwd)/app/offline.html');
  const text = await page.textContent('h1');
  console.log('h1 text:', text);
  await browser.close();
})();
"
```

Expected: `h1 text: Sin conexión`

- [ ] **Step 3: Commit**

```bash
git add app/offline.html
git commit -m "Add self-contained offline fallback page"
```

---

### Task 3: Service worker

**Files:**
- Create: `app/sw.js`

**Interfaces:**
- Consumes: the exact list of static shell files (below), including `app/offline.html` from Task 2.
- Produces: `/sw.js`, registered by `app/index.html` and `app/admin.html` in Tasks 5-6.

- [ ] **Step 1: Write the service worker**

Create `app/sw.js`:

```javascript
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
```

- [ ] **Step 2: Verify it's syntactically valid**

```bash
node --check app/sw.js
```

Expected: no output (exit code 0 means valid syntax).

- [ ] **Step 3: Commit**

```bash
git add app/sw.js
git commit -m "Add shared service worker: cache the shell, offline fallback on navigation"
```

---

### Task 4: Web app manifests

**Files:**
- Create: `app/manifest-catalogo.json`
- Create: `app/manifest-admin.json`

**Interfaces:**
- Consumes: icon files from Task 1 (`app/icons/catalogo/*.png`, `app/icons/admin/*.png`).
- Produces: `/manifest-catalogo.json`, `/manifest-admin.json`, linked from `app/index.html` / `app/admin.html` in Tasks 5-6.

- [ ] **Step 1: Write the catalog manifest**

Create `app/manifest-catalogo.json`:

```json
{
  "name": "Lemus Store",
  "short_name": "Lemus Store",
  "description": "Catálogo de juguetes Lemus Store, con inventario en vivo.",
  "start_url": "/index.html",
  "scope": "/",
  "display": "standalone",
  "background_color": "#FFFBF2",
  "theme_color": "#FF5A36",
  "icons": [
    { "src": "icons/catalogo/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "icons/catalogo/icon-512.png", "sizes": "512x512", "type": "image/png" },
    { "src": "icons/catalogo/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
```

- [ ] **Step 2: Write the admin manifest**

Create `app/manifest-admin.json`:

```json
{
  "name": "Lemus Store Admin",
  "short_name": "Lemus Admin",
  "description": "Panel de administrador de Lemus Store.",
  "start_url": "/admin.html",
  "scope": "/",
  "display": "standalone",
  "background_color": "#FFFBF2",
  "theme_color": "#FF5A36",
  "icons": [
    { "src": "icons/admin/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "icons/admin/icon-512.png", "sizes": "512x512", "type": "image/png" },
    { "src": "icons/admin/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
```

- [ ] **Step 3: Verify both are valid JSON**

```bash
node -e "JSON.parse(require('fs').readFileSync('app/manifest-catalogo.json'))" && echo "catalogo OK"
node -e "JSON.parse(require('fs').readFileSync('app/manifest-admin.json'))" && echo "admin OK"
```

Expected: `catalogo OK` and `admin OK`.

- [ ] **Step 4: Commit**

```bash
git add app/manifest-catalogo.json app/manifest-admin.json
git commit -m "Add web app manifests for catalog and admin"
```

---

### Task 5: Wire up index.html

**Files:**
- Modify: `app/index.html`

**Interfaces:**
- Consumes: `app/manifest-catalogo.json` (Task 4), `app/icons/catalogo/apple-touch-icon.png` (Task 1), `app/sw.js` (Task 3).

- [ ] **Step 1: Add manifest/icon/theme-color links to `<head>`**

In `app/index.html`, find this line (currently the last line inside `<head>`):

```html
<link rel="stylesheet" href="css/styles.css">
```

Replace it with:

```html
<link rel="stylesheet" href="css/styles.css">
<link rel="manifest" href="manifest-catalogo.json">
<meta name="theme-color" content="#FF5A36">
<link rel="apple-touch-icon" href="icons/catalogo/apple-touch-icon.png">
```

- [ ] **Step 2: Register the service worker before `</body>`**

Find the closing `</body>` tag in `app/index.html` and insert this immediately before it:

```html
<script>
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js').catch(() => {});
    });
  }
</script>
</body>
```

(Replace the existing bare `</body>` with the block above — the script goes right before it.)

- [ ] **Step 3: Verify the page still loads without errors**

```bash
NODE_PATH=/opt/node22/lib/node_modules node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('file://$(pwd)/app/index.html');
  const manifestHref = await page.getAttribute('link[rel=manifest]', 'href');
  console.log('manifest href:', manifestHref);
  console.log('page errors:', errors);
  await browser.close();
})();
"
```

Expected: `manifest href: manifest-catalogo.json` and `page errors: []`. (Supabase network calls will fail since this is a local `file://` load with no dev server — that's expected and unrelated to this change; we're only checking for JS syntax/parse errors here.)

- [ ] **Step 4: Commit**

```bash
git add app/index.html
git commit -m "Make the catalog installable: manifest, theme-color, service worker registration"
```

---

### Task 6: Wire up admin.html

**Files:**
- Modify: `app/admin.html`

**Interfaces:**
- Consumes: `app/manifest-admin.json` (Task 4), `app/icons/admin/apple-touch-icon.png` (Task 1), `app/sw.js` (Task 3).

- [ ] **Step 1: Add manifest/icon/theme-color links to `<head>`**

In `app/admin.html`, find this line (currently the last line inside `<head>`):

```html
<link rel="stylesheet" href="css/styles.css">
```

Replace it with:

```html
<link rel="stylesheet" href="css/styles.css">
<link rel="manifest" href="manifest-admin.json">
<meta name="theme-color" content="#FF5A36">
<link rel="apple-touch-icon" href="icons/admin/apple-touch-icon.png">
```

- [ ] **Step 2: Register the service worker before `</body>`**

Find the closing `</body>` tag in `app/admin.html` and insert this immediately before it:

```html
<script>
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js').catch(() => {});
    });
  }
</script>
</body>
```

- [ ] **Step 3: Verify the page still loads without errors**

```bash
NODE_PATH=/opt/node22/lib/node_modules node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('file://$(pwd)/app/admin.html');
  const manifestHref = await page.getAttribute('link[rel=manifest]', 'href');
  console.log('manifest href:', manifestHref);
  console.log('page errors:', errors);
  await browser.close();
})();
"
```

Expected: `manifest href: manifest-admin.json` and `page errors: []`.

- [ ] **Step 4: Commit**

```bash
git add app/admin.html
git commit -m "Make the admin panel installable: manifest, theme-color, service worker registration"
```

---

### Task 7: Deploy + live checklist with Ricardo

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything from Tasks 1-6, already live on Netlify (git push to `claude/artifact-webpage-hyhkrh` auto-deploys — Netlify is connected to GitHub as of this session).

- [ ] **Step 1: Push the branch**

```bash
git push origin claude/artifact-webpage-hyhkrh
```

- [ ] **Step 2: Confirm the Netlify deploy succeeded**

Check the Netlify dashboard (Deploys tab) shows a new "Published" deploy for this branch. If it's still "Building", wait for it to finish before the next step.

- [ ] **Step 3: Live checklist (on Ricardo's phone, real network — not this environment)**

1. Open `https://lemus-store.netlify.app` on the phone. Confirm the browser offers "Instalar app" / "Agregar a inicio". Confirm the icon/name shown before installing match the approved design ("Lemus Store", white icon with the black game controller).
2. Open `https://lemus-store.netlify.app/admin.html` on the phone. Confirm it offers to install separately, with name "Lemus Store Admin" and the same icon plus the gear badge.
3. Install both. Confirm each opens full-screen, no browser address bar.
4. With the installed catalog app open, turn on airplane mode and reload/reopen it. Confirm the "Sin conexión — revisa tu internet e intenta de nuevo" page appears (not a browser error page). Turn airplane mode back off and confirm "Reintentar" loads the catalog normally again.
5. Repeat step 4 for the installed admin app.
6. With connection restored, run through a normal catalog purchase (from the installed app) all the way to the Mercado Pago `?checkout=success` redirect, confirming it still works exactly as before installing.

No code changes in this task — it's confirmation that everything built in Tasks 1-6 works end-to-end on a real device.
