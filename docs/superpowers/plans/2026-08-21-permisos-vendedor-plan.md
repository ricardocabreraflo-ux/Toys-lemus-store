# Permisos configurables para el rol vendedor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Ricardo toggle, from Admin → Usuarios, whether vendedores
can cancel apartados (off by default) — a real, server-enforced
permission, not just a hidden button.

**Architecture:** One new admin-write/authenticated-read singleton
table (`vendedor_permissions`) holding a single boolean today, read by
both roles and written only by admin. `cancel_layaway` gains a
permission check at the top (admin always allowed; vendedor only if the
flag is on). The frontend hides the "Cancelar" button entirely for
vendedor when the flag is off, and exposes the toggle in Usuarios.

**Tech Stack:** Same as the rest of this project — Supabase (Postgres + RLS + RPC), vanilla JS ES modules, no new dependencies.

## Global Constraints

- Fail-closed: if `vendedor_permissions` can't be loaded, the in-memory
  default (`can_cancel_layaways: false`) applies — never fail open.
- The server-side check in `cancel_layaway` is the real boundary; the
  hidden button is a UX nicety on top of it, not a substitute for it.
- Admin can always cancel, regardless of this flag.
- Only `can_cancel_layaways` is in scope — do not add any other
  permission toggle, and do not change what registrar-abono,
  marcar-entregado, extender, or vender can do for vendedor (all stay
  exactly as they are today).
- One shared setting for all vendedores — no per-user permissions.
- Do not touch sales, Mercado Pago checkout, Promociones, Finanzas, or
  the borrado-protegido (PIN/delete_sale) code.
- No new dependencies.

---

### Task 1: Migration — `vendedor_permissions` table and `cancel_layaway` guard

**Files:**
- Create: `supabase/migrations/0022_permisos_vendedor.sql`

**Interfaces:**
- Produces: `public.vendedor_permissions` (columns: `id`,
  `can_cancel_layaways`), consumed by Task 2's frontend.
- Modifies: `public.cancel_layaway(uuid)` — same signature, same
  return type, only its authorization check changes.

- [ ] **Step 1: Write the migration file**

```sql
-- supabase/migrations/0022_permisos_vendedor.sql
-- Ricardo wants a way to grant/revoke specific permissions to the
-- vendedor role from Admin, instead of them being fixed in code. This
-- adds the first one — canceling an apartado (it releases reserved
-- stock, a more consequential action than recording a payment) — off
-- by default, structured so more toggles can be added later as more
-- columns on this same table. See
-- docs/superpowers/specs/2026-08-21-permisos-vendedor-design.md.

create table if not exists public.vendedor_permissions (
  id                    boolean primary key default true,
  can_cancel_layaways   boolean not null default false,
  constraint vendedor_permissions_single_row check (id)
);

insert into public.vendedor_permissions (id) values (true) on conflict (id) do nothing;

alter table public.vendedor_permissions enable row level security;

drop policy if exists "authenticated read" on public.vendedor_permissions;
create policy "authenticated read" on public.vendedor_permissions
  for select to authenticated using (true);

drop policy if exists "admin write" on public.vendedor_permissions;
create policy "admin write" on public.vendedor_permissions for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'vendedor_permissions'
  ) then
    alter publication supabase_realtime add table public.vendedor_permissions;
  end if;
end;
$$;

-- Add the permission check to the existing cancel_layaway function —
-- everything else about it (finding the layaway, restoring stock,
-- marking it cancelled) is unchanged.
create or replace function public.cancel_layaway(p_layaway_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_channel text;
  v_item record;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;

  if not public.is_admin() then
    if not exists (select 1 from public.vendedor_permissions where can_cancel_layaways) then
      raise exception 'No autorizado para cancelar apartados';
    end if;
  end if;

  select status, channel into v_status, v_channel from public.layaways where id = p_layaway_id for update;
  if v_status is null then
    raise exception 'Apartado no encontrado';
  end if;
  if v_status not in ('activo', 'revisar_sin_stock') then
    raise exception 'Este apartado ya no se puede cancelar';
  end if;

  for v_item in select product_id, quantity from public.layaway_items where layaway_id = p_layaway_id
  loop
    if v_item.product_id is not null then
      if v_channel = 'fisica' then
        update public.products set stock_fisica = stock_fisica + v_item.quantity where id = v_item.product_id;
      else
        update public.products set stock_online = stock_online + v_item.quantity where id = v_item.product_id;
      end if;
    end if;
  end loop;

  update public.layaways
    set status = 'cancelado', cancelled_by = auth.uid(), cancelled_at = now()
    where id = p_layaway_id;
end;
$$;

revoke all on function public.cancel_layaway(uuid) from public, anon, authenticated;
grant execute on function public.cancel_layaway(uuid) to authenticated;

notify pgrst, 'reload schema';
```

The `revoke`/`grant` pair above restates exactly what
`0013_layaway_functions.sql` already set on this function (harmless to
repeat — grants are keyed by function name+signature, unaffected by
`create or replace function`'s body change, so this isn't strictly
required, but including it keeps this migration file self-contained and
matches this repo's convention of every migration that touches a
function's body also showing its grants).

This body is transcribed verbatim from the actual current
`public.cancel_layaway` in `supabase/migrations/0013_layaway_functions.sql`
(confirmed to be its only definition in the repo — no later migration
replaces it), with only the new permission-check block inserted right
after the existing `auth.uid() is null` check and before the
`select status, channel ...` line. Do not alter anything else in the
function body — the stock-restore loop and the final `update
public.layaways ... cancelled_by/cancelled_at` line must stay exactly
as shown.

- [ ] **Step 2: Sanity-check the migration text**

No local Supabase instance or automated tests in this project — Ricardo
runs this by hand via the Supabase Dashboard SQL editor. Re-read the
file once against these checks:
1. Every statement ends with a semicolon.
2. The `do $$ ... $$;` publication guard matches the exact pattern
   already used in `0021_borrado_protegido.sql`.
3. The new permission-check block in `cancel_layaway` is placed BEFORE
   any stock-restoring logic runs (fail fast, before any side effect).
4. `create or replace function` preserves the exact same parameter
   list and return type as the function it replaces (`p_layaway_id
   uuid`, `returns void`) — a signature change would break existing
   callers.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0022_permisos_vendedor.sql
git commit -m "Add vendedor_permissions table and gate cancel_layaway on it"
```

---

### Task 2: Admin frontend — permissions toggle and conditional Cancelar button

**Files:**
- Modify: `app/admin.html` (Usuarios → new permissions row)
- Modify: `app/js/admin.js` (state, load function, toggle wiring, the
  Apartados Cancelar button's render condition, `loadEverything()`/
  `subscribeRealtime()` wiring)

**Interfaces:**
- Consumes: `public.vendedor_permissions` (Task 1); the existing
  `showToast`/`CURRENT_ROLE`/`supabase` helpers already in `admin.js`.
- Produces: `VENDEDOR_PERMISSIONS` module state, read only by this
  task's own Apartados render change — no other task depends on it.

- [ ] **Step 1: Add the permissions row to Usuarios**

In `app/admin.html`, inside `#tab-users`, right before the section's
closing `</section>` (after the existing "Vendedores" table), add:

```html
    <div class="grid-head" style="margin-top:32px;"><h2>Permisos</h2></div>
    <div class="table-wrap">
      <table class="admin-table">
        <tbody>
          <tr>
            <td>Los vendedores pueden cancelar apartados</td>
            <td><input type="checkbox" id="permission-cancel-layaways"></td>
          </tr>
        </tbody>
      </table>
    </div>
```

- [ ] **Step 2: Add `VENDEDOR_PERMISSIONS` state and `loadVendedorPermissions()`**

In `app/js/admin.js`, find the module-level state block (it currently
ends with lines like `let SECURITY_SETTINGS = { delete_pin: '0000' };`
and `let RECENT_PHYSICAL_SALES = [];` — read the file to find its exact
current end) and add:

```javascript
let VENDEDOR_PERMISSIONS = { can_cancel_layaways: false };
```

Add this function near `loadSecuritySettings()` (same small-helper
area):

```javascript
async function loadVendedorPermissions() {
  const { data, error } = await supabase.from('vendedor_permissions').select('*').single();
  if (error) throw error;
  return data;
}
```

- [ ] **Step 3: Wire the toggle in `renderUsers()`**

In `app/js/admin.js`'s `renderUsers()` function, add this at the end
(after the existing `tbody.innerHTML = ...` assignment — note the
function currently has an early `return` in its empty-VENDEDORES
branch; the toggle wiring must run in BOTH cases, so read the current
function carefully and place this after the `if`/`return` block, not
inside it, so it always executes):

```javascript
  const cancelCb = document.getElementById('permission-cancel-layaways');
  cancelCb.checked = VENDEDOR_PERMISSIONS.can_cancel_layaways;
  cancelCb.onchange = async () => {
    const { error } = await supabase.from('vendedor_permissions').update({ can_cancel_layaways: cancelCb.checked }).eq('id', true);
    if (error) { showToast('No se pudo actualizar', true); cancelCb.checked = !cancelCb.checked; return; }
    VENDEDOR_PERMISSIONS.can_cancel_layaways = cancelCb.checked;
    showToast('Permiso actualizado');
    renderLayaways();
  };
```

`renderLayaways()` is called at the end so an admin toggling the
permission sees the Apartados Cancelar button appear/disappear without
needing to switch tabs and back (it only affects the local admin's own
view of the button — the real enforcement is server-side per Task 1,
and any actual vendedor session picks up the change on its own next
`loadEverything()`/realtime reload).

- [ ] **Step 4: Make the Cancelar button conditional in `renderLayaways()`**

In `app/js/admin.js`'s `renderLayaways()`, find the active-row
template's action cell:

```javascript
        <td>
          <button class="btn btn-primary btn-sm" type="button" data-role="abono">Abonar</button>
          <button class="btn btn-sm" type="button" data-role="extend">Extender</button>
          <button class="btn btn-danger btn-sm" type="button" data-role="cancel">Cancelar</button>
        </td>
```

Replace with:

```javascript
        <td>
          <button class="btn btn-primary btn-sm" type="button" data-role="abono">Abonar</button>
          <button class="btn btn-sm" type="button" data-role="extend">Extender</button>
          ${(CURRENT_ROLE === 'admin' || VENDEDOR_PERMISSIONS.can_cancel_layaways) ? `<button class="btn btn-danger btn-sm" type="button" data-role="cancel">Cancelar</button>` : ''}
        </td>
```

Do not change the `activeTbody.querySelectorAll('[data-role="cancel"]')...`
listener-attachment block below it — it already safely no-ops when no
matching button exists in the DOM (same behavior every other
conditionally-rendered button in this file already relies on).

- [ ] **Step 5: Wire into `loadEverything()`**

In `app/js/admin.js`'s `loadEverything()`, find:

```javascript
    try {
      SECURITY_SETTINGS = await loadSecuritySettings();
    } catch (err) {
      console.error('No se pudo cargar security_settings, usando el PIN por defecto', err);
    }
```

Add a matching isolated block right after it (same fail-closed,
non-critical posture — per the Global Constraints, a failed load must
leave `can_cancel_layaways` at its safe default of `false`, which the
initial state declaration already provides):

```javascript
    try {
      VENDEDOR_PERMISSIONS = await loadVendedorPermissions();
    } catch (err) {
      console.error('No se pudo cargar vendedor_permissions, vendedor sin permisos extra por defecto', err);
    }
```

`renderLayaways()` is already called later in `loadEverything()` (no
new call needed there) — it will already read the freshly-loaded
`VENDEDOR_PERMISSIONS` by the time it runs, since this block runs
before it in the function body.

- [ ] **Step 6: Add `vendedor_permissions` to the realtime subscription**

In `app/js/admin.js`'s `subscribeRealtime()`, find the chain ending in:

```javascript
    .on('postgres_changes', { event: '*', schema: 'public', table: 'security_settings' }, scheduleReload)
    .subscribe();
```

Add one line before `.subscribe()`:

```javascript
    .on('postgres_changes', { event: '*', schema: 'public', table: 'security_settings' }, scheduleReload)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'vendedor_permissions' }, scheduleReload)
    .subscribe();
```

This is how a vendedor's own already-open session picks up an admin's
toggle change live — `scheduleReload` triggers `loadEverything()`,
which re-fetches `VENDEDOR_PERMISSIONS` and re-renders Apartados.

- [ ] **Step 7: Manual verification (no automated test suite in this project)**

Run `node --check app/js/admin.js`. Then trace through by hand:
1. With `VENDEDOR_PERMISSIONS.can_cancel_layaways === false` and
   `CURRENT_ROLE === 'vendedor'`, the Cancelar button is absent from
   the row's HTML entirely (not just hidden via CSS).
2. With `CURRENT_ROLE === 'admin'`, the Cancelar button always renders
   regardless of the flag's value.
3. Toggling the checkbox in Usuarios saves to Supabase, reverts on
   failure (never leaves the checkbox showing something that wasn't
   actually saved), and re-renders Apartados immediately for that
   admin's own session.
4. A failed `loadVendedorPermissions()` call leaves
   `VENDEDOR_PERMISSIONS` at its safe `{ can_cancel_layaways: false }`
   default — confirm this by reading the initial `let` declaration and
   confirming the isolated try/catch never assigns a partial/undefined
   value on failure.

- [ ] **Step 8: Commit**

```bash
git add app/admin.html app/js/admin.js
git commit -m "Add a toggle for whether vendedores can cancel apartados"
```
