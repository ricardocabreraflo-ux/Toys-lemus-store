# Escanear con cámara en Conteo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Escanear con cámara" button to the Conteo tab that opens
the phone's camera, continuously reads barcodes with the browser's
native `BarcodeDetector` API, and feeds each decoded code through the
exact same exact-code-match logic Conteo already uses for the physical
scanner — so a match auto-adds with no extra click, and a miss shows
the existing "Producto no encontrado" toast.

**Architecture:** No new dependency and no backend change — this is a
frontend-only addition to the existing Conteo tab built in the prior
plan. Feature-detected at load (`'BarcodeDetector' in window`); when
unsupported, the button stays hidden and nothing else changes. When
supported, a small `<video>` element streams `getUserMedia({video:
{facingMode:'environment'}})`, and a polling loop calls
`BarcodeDetector.detect(video)` every 250ms, reusing `addToCount()`
(already defined) on a match. The camera's `MediaStream` is torn down
whenever the button is toggled off or the user switches to any other
Admin tab.

**Tech Stack:** Same as the rest of this project — vanilla JS ES modules, the browser's native `BarcodeDetector`/`getUserMedia` APIs, no new dependencies.

## Global Constraints

- No new dependencies — only the browser's native `BarcodeDetector` and
  `navigator.mediaDevices.getUserMedia` APIs, nothing installed.
- No new Supabase migration, table, or RPC — this reuses the existing
  `addToCount()`/`PRODUCTS` lookup from the prior Conteo plan exactly
  as the physical-scanner path already does.
- The "Escanear con cámara" button stays entirely hidden (not disabled,
  not shown-with-an-error) when `BarcodeDetector` isn't supported by
  the browser — no dead button, no message.
- The camera must stop (all `MediaStreamTrack`s stopped, `video.srcObject`
  cleared) whenever: the user toggles the button off, or switches to
  any other Admin tab. Never left running in the background.
- The same decoded value must not be added twice within ~1.5 seconds of
  its own previous add — a barcode held in frame for a couple of
  seconds adds once, not repeatedly.
- A denied or failed camera permission shows the toast "No se pudo
  acceder a la cámara" and leaves the rest of Conteo (physical scanner,
  manual search, finalize/apply) working normally.
- A decoded value with no matching product shows the exact same
  "Producto no encontrado" toast Conteo's existing keyboard/scanner
  path already uses, and the camera stays open for the next attempt.
- Do not touch `apply_inventory_count`, the diff/finalize flow, or any
  other tab — this only adds a third way to get a product into
  `COUNT_ITEMS`, everything downstream of `addToCount()` is unchanged.

---

### Task 1: Conteo — camera barcode scanning

**Files:**
- Modify: `app/admin.html` (camera button + video element next to the
  Conteo search box)
- Modify: `app/js/admin.js` (feature detection, camera start/stop,
  scan loop, and one small addition to the existing generic tab-switch
  handler so switching tabs stops the camera)

**Interfaces:**
- Consumes: `addToCount(productId)`, `PRODUCTS`, `showToast(msg,
  isError)`, all already defined in `admin.js` from the prior Conteo
  plan — do not redefine or reimplement any of them.
- Produces: nothing consumed elsewhere — this is the only task in this
  plan.

- [ ] **Step 1: Add the camera button and video element to `admin.html`**

In `app/admin.html`, find the Conteo search box:

```html
    <div class="autocomplete-wrap" id="count-search-wrap">
      <input class="cell-input" id="count-search" type="text" autocomplete="off" placeholder="Escanea el código o escribe el nombre del producto…">
      <div class="autocomplete-list" id="count-suggestions" hidden></div>
    </div>

    <div class="table-wrap" style="margin-top:16px;">
```

Replace it with (adds the camera button and a hidden video element
right after the search box, before the counted-items table):

```html
    <div class="autocomplete-wrap" id="count-search-wrap">
      <input class="cell-input" id="count-search" type="text" autocomplete="off" placeholder="Escanea el código o escribe el nombre del producto…">
      <div class="autocomplete-list" id="count-suggestions" hidden></div>
    </div>

    <button class="btn btn-sm" type="button" id="count-camera-btn" hidden style="margin-top:8px;">Escanear con cámara</button>
    <video id="count-camera-video" autoplay playsinline muted hidden style="display:block;width:100%;max-width:360px;margin-top:8px;border-radius:10px;background:#000;"></video>

    <div class="table-wrap" style="margin-top:16px;">
```

`#count-camera-btn` starts `hidden` — Step 3 below only un-hides it
when the browser actually supports `BarcodeDetector`. No new CSS
classes are introduced; sizing is inline, matching how the rest of
`admin.html` already handles one-off layout tweaks.

- [ ] **Step 2: Stop the camera when switching to any other Admin tab**

In `app/js/admin.js`, find the existing generic tab-switch handler near
the top of the file:

```javascript
document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.setAttribute('aria-selected', String(b === btn)));
    document.querySelectorAll('.tab-panel').forEach(p => { p.hidden = p.id !== `tab-${btn.dataset.tab}`; });
  });
});
```

Replace it with (adds one line — `stopCountCamera` is defined in Step
3 below; `function` declarations are hoisted within the module, so the
call here resolves regardless of source order):

```javascript
document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.setAttribute('aria-selected', String(b === btn)));
    document.querySelectorAll('.tab-panel').forEach(p => { p.hidden = p.id !== `tab-${btn.dataset.tab}`; });
    if (btn.dataset.tab !== 'count') stopCountCamera();
  });
});
```

This is the only change to this shared handler — it fires on every tab
click, but `stopCountCamera()` (Step 3) is a no-op when the camera
isn't running, so switching between any two non-Conteo tabs stays
exactly as cheap as it is today.

- [ ] **Step 3: Add camera state, start/stop, and the scan loop to `admin.js`**

In `app/js/admin.js`, find the end of the "Conteo tab" section — the
`count-apply-btn` click handler and the start of the Promotions tab
section:

```javascript
    renderStats();
  } finally {
    btn.disabled = false;
  }
});

// ---------- Promotions tab ----------
```

Insert the new camera-scanning code between them:

```javascript
    renderStats();
  } finally {
    btn.disabled = false;
  }
});

let countCameraStream = null;
let countBarcodeDetector = null;
let countScanLoopActive = false;
let lastScannedCode = null;
let lastScannedAt = 0;

if ('BarcodeDetector' in window) {
  document.getElementById('count-camera-btn').hidden = false;
}

function handleCountScanValue(raw) {
  const q = raw.trim().toLowerCase();
  const match = PRODUCTS.find(p => (p.code || '').toLowerCase() === q);
  if (match) { addToCount(match.id); return; }
  showToast('Producto no encontrado', true);
}

async function scanCountCameraLoop() {
  const video = document.getElementById('count-camera-video');
  while (countScanLoopActive) {
    try {
      const codes = await countBarcodeDetector.detect(video);
      if (codes.length > 0) {
        const raw = codes[0].rawValue;
        const now = Date.now();
        if (raw !== lastScannedCode || now - lastScannedAt > 1500) {
          lastScannedCode = raw;
          lastScannedAt = now;
          handleCountScanValue(raw);
        }
      }
    } catch (err) {
      // detect() can throw transiently if the video frame isn't ready
      // yet (e.g. right after starting the stream) — ignore and retry
      // on the next tick rather than aborting the whole loop.
    }
    await new Promise(resolve => setTimeout(resolve, 250));
  }
}

async function startCountCamera() {
  try {
    countCameraStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
  } catch (err) {
    showToast('No se pudo acceder a la cámara', true);
    console.error(err);
    return;
  }
  const video = document.getElementById('count-camera-video');
  video.srcObject = countCameraStream;
  video.hidden = false;
  document.getElementById('count-camera-btn').textContent = 'Cerrar cámara';
  countBarcodeDetector = countBarcodeDetector || new BarcodeDetector();
  countScanLoopActive = true;
  scanCountCameraLoop();
}

function stopCountCamera() {
  countScanLoopActive = false;
  if (countCameraStream) {
    countCameraStream.getTracks().forEach(track => track.stop());
    countCameraStream = null;
  }
  const video = document.getElementById('count-camera-video');
  video.srcObject = null;
  video.hidden = true;
  document.getElementById('count-camera-btn').textContent = 'Escanear con cámara';
}

document.getElementById('count-camera-btn').addEventListener('click', () => {
  if (countCameraStream) stopCountCamera();
  else startCountCamera();
});

// ---------- Promotions tab ----------
```

`addToCount`, `PRODUCTS`, and `showToast` are all already defined
earlier in this file from the prior Conteo plan — do not redefine or
reimplement any of them. `handleCountScanValue` deliberately only
checks for an exact `code` match (never a name search) — a raw
barcode value has no reason to partially match a product's name, and
the spec's error case ("Producto no encontrado") only ever applies to
the code path here.

- [ ] **Step 4: Manual verification (no automated test suite in this project)**

Run `node --check app/js/admin.js`. Then, from an Android phone with
Chrome:
1. `#count-camera-btn` is hidden on page load in a browser without
   `BarcodeDetector` (e.g. desktop Firefox) and visible in Chrome on
   Android — confirm via the `'BarcodeDetector' in window` check.
2. Tapping the button prompts for camera permission, then shows a live
   video preview and the button's label changes to "Cerrar cámara".
3. Pointing the camera at a real product barcode adds 1 to that
   product's count automatically, with no further taps — trace this
   through `scanCountCameraLoop` → `handleCountScanValue` →
   `addToCount`, the same function the physical-scanner path already
   uses.
4. Holding the same barcode in frame for several seconds adds it only
   once — `lastScannedCode`/`lastScannedAt` block re-adds of the same
   value within 1500ms, but scanning a *different* code immediately
   after still adds right away (the 1.5s gate only applies to a
   repeat of the same value).
5. Pointing the camera at a barcode with no matching product shows
   "Producto no encontrado" (same message/behavior as the existing
   keyboard path) and the camera stays open — verify no code path
   calls `stopCountCamera()` on a miss.
6. Denying the camera permission (or simulating `getUserMedia`
   rejecting) shows "No se pudo acceder a la cámara" and leaves
   `#count-camera-btn` in its default label/state — the rest of Conteo
   (typing, the physical scanner, Finalizar conteo, Aplicar todo) is
   untouched by this failure.
7. Tapping "Cerrar cámara" stops all tracks on `countCameraStream`,
   clears `video.srcObject`, hides the video, and resets the button's
   label.
8. Switching to any other Admin tab while the camera is running stops
   it the same way (Step 2's addition) — confirm by checking that the
   camera's hardware indicator (or `countCameraStream`) turns off
   after switching to, say, "Inventario".
9. Switching between two *other* tabs (never having opened the camera)
   still works exactly as before — `stopCountCamera()` no-ops when
   `countCameraStream` is already `null`.

- [ ] **Step 5: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Add camera barcode scanning to the Conteo tab"
```
