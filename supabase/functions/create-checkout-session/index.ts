import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MP_ACCESS_TOKEN = Deno.env.get('MP_ACCESS_TOKEN')!;
const SITE_URL = Deno.env.get('SITE_URL') ?? 'https://lemus-store.netlify.app';

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

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

    // Same "best active promotion" logic as app/js/catalog-data.js.
    function discountedPrice(p: { price: number; product_line_id: string | null; category_id: string | null }) {
      const matches = (promotions ?? []).filter((promo: { scope_type: string; product_line_id: string | null; category_id: string | null; discount_percent: number }) =>
        (promo.scope_type === 'line' && promo.product_line_id === p.product_line_id) ||
        (promo.scope_type === 'category' && promo.category_id === p.category_id)
      );
      if (matches.length === 0) return p.price;
      const best = matches.reduce((a, b) => (b.discount_percent > a.discount_percent ? b : a), matches[0]);
      return Math.round(p.price * (1 - best.discount_percent / 100) * 100) / 100;
    }

    // Aggregate quantities per product_id to prevent overselling.
    const qtyMap = new Map<string, number>();
    for (const item of items) {
      const qty = Number(item.quantity) || 0;
      const current = qtyMap.get(item.product_id) ?? 0;
      qtyMap.set(item.product_id, current + qty);
    }

    const mpItems = [];
    const cartItems = [];
    for (const [productId, totalQty] of qtyMap.entries()) {
      const p = products.find((x: { id: string }) => x.id === productId);
      if (!p || !p.published_online) {
        return json({ error: 'Un producto de tu carrito ya no está disponible.' }, 409);
      }
      if (totalQty <= 0 || totalQty > p.stock_online) {
        return json({ error: `Solo quedan ${p.stock_online} de "${p.name}" — actualiza tu carrito.` }, 409);
      }
      const unitPrice = discountedPrice(p);
      mpItems.push({
        title: p.name,
        quantity: totalQty,
        unit_price: unitPrice,
        currency_id: 'MXN',
      });
      cartItems.push({ product_id: productId, quantity: totalQty, unit_price: unitPrice });
    }

    const { data: pending, error: pendingErr } = await supabase
      .from('pending_checkouts')
      .insert({
        kind: 'venta',
        payload: { items: cartItems, customer_name, customer_phone, customer_email },
      })
      .select('id')
      .single();
    if (pendingErr) throw pendingErr;

    const mpRes = await fetch('https://api.mercadopago.com/checkout/preferences', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${MP_ACCESS_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        items: mpItems,
        payer: { email: customer_email },
        back_urls: {
          success: `${SITE_URL}/index.html?checkout=success`,
          failure: `${SITE_URL}/index.html?checkout=cancel`,
          pending: `${SITE_URL}/index.html?checkout=cancel`,
        },
        auto_return: 'approved',
        notification_url: `${SUPABASE_URL}/functions/v1/mercadopago-webhook`,
        external_reference: pending.id,
        payment_methods: {
          excluded_payment_types: [{ id: 'ticket' }, { id: 'atm' }],
        },
      }),
    });
    const mpData = await mpRes.json();
    if (!mpRes.ok) {
      console.error('Mercado Pago preference error', mpData);
      return json({ error: 'No se pudo iniciar el pago' }, 500);
    }

    const isTestMode = MP_ACCESS_TOKEN.startsWith('TEST-');
    const checkoutUrl = (isTestMode ? mpData.sandbox_init_point : null) ?? mpData.init_point;
    if (!checkoutUrl) {
      console.error('Mercado Pago no devolvió una URL de pago', mpData);
      return json({ error: 'No se pudo iniciar el pago' }, 500);
    }

    return json({ url: checkoutUrl });
  } catch (err) {
    return json({ error: String(err) }, 500);
  }
});
