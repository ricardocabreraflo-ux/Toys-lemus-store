// supabase/functions/create-layaway-checkout-session/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const SITE_URL = Deno.env.get('SITE_URL') ?? 'https://lemus-store.netlify.app';

const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2024-06-20' });
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const DEPOSIT_PERCENT = 50;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });

  try {
    const { items, customer_name, customer_phone, customer_email } = await req.json();

    if (!Array.isArray(items) || items.length === 0) {
      return json({ error: 'El carrito está vacío' }, 400);
    }
    if (!customer_name || !customer_phone || !customer_email) {
      return json({ error: 'Faltan tus datos de contacto' }, 400);
    }

    const ids = items.map((i: { product_id: string }) => i.product_id);
    const { data: products, error: prodErr } = await supabase
      .from('products')
      .select('id, name, price, stock_online, published_online, product_line_id, category_id')
      .in('id', ids);
    if (prodErr) throw prodErr;

    const nowIso = new Date().toISOString();
    const { data: promotions, error: promoErr } = await supabase
      .from('promotions')
      .select('*')
      .eq('active', true)
      .or(`starts_at.is.null,starts_at.lte.${nowIso}`)
      .or(`ends_at.is.null,ends_at.gte.${nowIso}`);
    if (promoErr) throw promoErr;

    // Same "best active promotion" logic as app/js/catalog-data.js and
    // create-checkout-session, kept in sync manually since Edge Functions
    // can't import frontend modules.
    function discountedPrice(p: { price: number; product_line_id: string | null; category_id: string | null }) {
      const matches = (promotions ?? []).filter((promo: { scope_type: string; product_line_id: string | null; category_id: string | null; discount_percent: number }) =>
        (promo.scope_type === 'line' && promo.product_line_id === p.product_line_id) ||
        (promo.scope_type === 'category' && promo.category_id === p.category_id)
      );
      if (matches.length === 0) return p.price;
      const best = matches.reduce((a, b) => (b.discount_percent > a.discount_percent ? b : a), matches[0]);
      return Math.round(p.price * (1 - best.discount_percent / 100) * 100) / 100;
    }

    const qtyMap = new Map<string, number>();
    for (const item of items) {
      const qty = Number(item.quantity) || 0;
      const current = qtyMap.get(item.product_id) ?? 0;
      qtyMap.set(item.product_id, current + qty);
    }

    const cartItems = [];
    let total = 0;
    for (const [productId, totalQty] of qtyMap.entries()) {
      const p = products.find((x: { id: string }) => x.id === productId);
      if (!p || !p.published_online) {
        return json({ error: 'Un producto de tu carrito ya no está disponible.' }, 409);
      }
      if (totalQty <= 0 || totalQty > p.stock_online) {
        return json({ error: `Solo quedan ${p.stock_online} de "${p.name}" — actualiza tu carrito.` }, 409);
      }
      const unitPrice = discountedPrice(p);
      total += unitPrice * totalQty;
      cartItems.push({ product_id: productId, quantity: totalQty, unit_price: unitPrice });
    }

    total = Math.round(total * 100) / 100;
    const depositAmount = Math.round(total * (DEPOSIT_PERCENT / 100) * 100) / 100;

    const cartMetadata = JSON.stringify(cartItems);
    if (cartMetadata.length > 500) {
      return json({ error: 'Carrito con demasiados productos distintos para procesar de una vez.' }, 400);
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      line_items: [{
        quantity: 1,
        price_data: {
          currency: 'mxn',
          unit_amount: Math.round(depositAmount * 100),
          product_data: { name: `Anticipo de apartado (${DEPOSIT_PERCENT}% de $${total.toFixed(2)})` },
        },
      }],
      success_url: `${SITE_URL}/index.html?apartado=success`,
      cancel_url: `${SITE_URL}/index.html?apartado=cancel`,
      customer_email,
      metadata: {
        kind: 'layaway_deposit',
        cart: cartMetadata,
        customer_name,
        customer_phone,
        customer_email,
        total: total.toFixed(2),
        deposit_amount: depositAmount.toFixed(2),
      },
    });

    return json({ url: session.url });
  } catch (err) {
    return json({ error: String(err) }, 500);
  }
});
