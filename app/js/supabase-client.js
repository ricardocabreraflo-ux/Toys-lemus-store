// Loaded from the vendored UMD bundle (js/vendor/supabase.umd.js), which
// must be included via a <script> tag before this module runs.
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

const { createClient } = window.supabase;
export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Product lines and categories are admin-editable (see catalog-data.js)
// instead of a fixed list, so a new line like "Shein" or "Betterware"
// doesn't need a code change.

export const fmt = new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN' });
