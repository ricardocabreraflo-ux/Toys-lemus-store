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

const ADMIN_BADGE_MASKABLE = `
  <circle cx="55" cy="55" r="10" fill="#ffffff" stroke="#111318" stroke-width="2"/>
  <g transform="translate(46,46) scale(0.38)">
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
  ['admin', 'icon-maskable-512.png', 512, svg('<rect width="76" height="76" fill="#ffffff"/>', CONTROLLER_GROUP_MASKABLE, ADMIN_BADGE_MASKABLE)],
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
