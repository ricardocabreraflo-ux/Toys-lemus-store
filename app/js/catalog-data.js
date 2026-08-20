import { supabase } from './supabase-client.js';

// Categories/lines are admin-editable now (no fixed enum), so give each one
// a stable-looking color + icon by hashing its id instead of storing a
// color in the database.
const ACCENTS = ['var(--accent-4)', 'var(--accent-5)', 'var(--accent-6)', 'var(--accent-2)', 'var(--accent-3)', 'var(--accent-7)', 'var(--accent)'];
const ICON_KEYS = ['doll', 'shield', 'car', 'dice', 'blaster', 'blob'];

function hashStr(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return h;
}

export function accentFor(id) { return ACCENTS[hashStr(String(id)) % ACCENTS.length]; }
export function iconKeyFor(id) { return ICON_KEYS[hashStr(String(id)) % ICON_KEYS.length]; }

export async function loadProductLines() {
  const { data, error } = await supabase.from('product_lines').select('*').order('sort_order');
  if (error) throw error;
  return data;
}

export async function loadCategories() {
  const { data, error } = await supabase.from('categories').select('*').order('sort_order');
  if (error) throw error;
  return data;
}

export async function loadSiteSettings() {
  const { data, error } = await supabase.from('site_settings').select('*').single();
  if (error) throw error;
  return data;
}

export async function loadActivePromotions() {
  const nowIso = new Date().toISOString();
  const { data, error } = await supabase
    .from('promotions')
    .select('*')
    .eq('active', true)
    .or(`starts_at.is.null,starts_at.lte.${nowIso}`)
    .or(`ends_at.is.null,ends_at.gte.${nowIso}`);
  if (error) throw error;
  return data;
}

// The best (highest %) active promotion that applies to this product, or null.
export function bestPromotionFor(product, promotions) {
  const matches = promotions.filter(p =>
    (p.scope_type === 'line' && p.product_line_id === product.product_line_id) ||
    (p.scope_type === 'category' && p.category_id === product.category_id) ||
    (p.scope_type === 'product' && p.product_id === product.id)
  );
  if (matches.length === 0) return null;
  return matches.reduce((best, p) => (p.discount_percent > best.discount_percent ? p : best), matches[0]);
}

export function discountedPrice(product, promotions) {
  const promo = bestPromotionFor(product, promotions);
  if (!promo) return { price: product.price, promo: null };
  const price = Math.round(product.price * (1 - promo.discount_percent / 100) * 100) / 100;
  return { price, promo };
}
