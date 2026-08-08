import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const SITE_URL = Deno.env.get('SITE_URL') ?? 'https://lemus-store.netlify.app';

const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2024-06-20' });
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
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
      .select('id, name, price, stock_online, published_online')
      .in('id', ids);
    if (prodErr) throw prodErr;

    // Aggregate quantities per product_id to prevent overselling
    const qtyMap = new Map<string, number>();
    for (const item of items) {
      const qty = Number(item.quantity) || 0;
      const current = qtyMap.get(item.product_id) ?? 0;
      qtyMap.set(item.product_id, current + qty);
    }

    // Validate and build line items from aggregated quantities
    const lineItems = [];
    for (const [productId, totalQty] of qtyMap.entries()) {
      const p = products.find((x: { id: string }) => x.id === productId);
      if (!p || !p.published_online) {
        return json({ error: 'Un producto de tu carrito ya no está disponible.' }, 409);
      }
      if (totalQty <= 0 || totalQty > p.stock_online) {
        return json({ error: `Solo quedan ${p.stock_online} de "${p.name}" — actualiza tu carrito.` }, 409);
      }
      lineItems.push({
        quantity: totalQty,
        price_data: {
          currency: 'mxn',
          unit_amount: Math.round(p.price * 100),
          product_data: { name: p.name },
        },
      });
    }

    const cartMetadata = JSON.stringify(
      Array.from(qtyMap.entries()).map(([productId, totalQty]) => ({ product_id: productId, quantity: totalQty }))
    );
    if (cartMetadata.length > 500) {
      return json({ error: 'Carrito con demasiados productos distintos para procesar de una vez.' }, 400);
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      line_items: lineItems,
      success_url: `${SITE_URL}/index.html?checkout=success`,
      cancel_url: `${SITE_URL}/index.html?checkout=cancel`,
      customer_email,
      metadata: { cart: cartMetadata, customer_name, customer_phone, customer_email },
    });

    return json({ url: session.url });
  } catch (err) {
    return json({ error: String(err) }, 500);
  }
});
