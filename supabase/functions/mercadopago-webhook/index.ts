import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MP_ACCESS_TOKEN = Deno.env.get('MP_ACCESS_TOKEN')!;
const MP_WEBHOOK_SECRET = Deno.env.get('MP_WEBHOOK_SECRET')!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Verifica x-signature: "ts=<timestamp_ms>,v1=<hmac_hex>". El manifest a
// firmar es "id:{dataId en minúsculas};request-id:{x-request-id};ts:{ts};",
// HMAC-SHA256 con el secreto de webhook de la cuenta de Mercado Pago.
async function verifySignature(xSignature: string, xRequestId: string, dataId: string, secret: string): Promise<boolean> {
  const parts: Record<string, string> = {};
  for (const piece of xSignature.split(',')) {
    const [k, v] = piece.split('=');
    if (k && v) parts[k.trim()] = v.trim();
  }
  const ts = parts['ts'];
  const v1 = parts['v1'];
  if (!ts || !v1) return false;

  const manifest = `id:${dataId.toLowerCase()};request-id:${xRequestId};ts:${ts};`;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const sigBuffer = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(manifest));
  const expectedHex = Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  if (expectedHex.length !== v1.length) return false;
  let diff = 0;
  for (let i = 0; i < expectedHex.length; i++) {
    diff |= expectedHex.charCodeAt(i) ^ v1.charCodeAt(i);
  }
  return diff === 0;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const dataIdFromQuery = url.searchParams.get('data.id') ?? url.searchParams.get('id');

  const xSignature = req.headers.get('x-signature');
  const xRequestId = req.headers.get('x-request-id');
  const body = await req.json().catch(() => null);

  const dataId = dataIdFromQuery ?? body?.data?.id;
  if (!dataId) {
    return new Response('ok', { status: 200 });
  }

  if (!xSignature || !xRequestId) {
    return new Response('Falta firma', { status: 401 });
  }

  const valid = await verifySignature(xSignature, xRequestId, String(dataId), MP_WEBHOOK_SECRET);
  if (!valid) {
    return new Response('Firma inválida', { status: 401 });
  }

  if (body?.type && body.type !== 'payment') {
    return new Response('ok', { status: 200 });
  }

  const paymentRes = await fetch(`https://api.mercadopago.com/v1/payments/${dataId}`, {
    headers: { Authorization: `Bearer ${MP_ACCESS_TOKEN}` },
  });
  if (!paymentRes.ok) {
    const bodyText = await paymentRes.text();
    console.error('No se pudo consultar el pago', dataId, paymentRes.status, bodyText);
    if (paymentRes.status === 404) {
      return new Response('ok', { status: 200 });
    }
    return new Response('Error al consultar el pago', { status: 500 });
  }
  const payment = await paymentRes.json();

  if (payment.status !== 'approved') {
    return new Response('ok', { status: 200 });
  }

  const pendingId = payment.external_reference;
  const { data: pending, error: pendingErr } = await supabase
    .from('pending_checkouts')
    .select('*')
    .eq('id', pendingId)
    .single();

  if (pendingErr && pendingErr.code !== 'PGRST116') {
    console.error('Error al buscar pending_checkouts', pendingId, pendingErr);
    return new Response('Error al buscar el pedido pendiente', { status: 500 });
  }
  if (!pending) {
    console.error('pending_checkouts no encontrado para external_reference', pendingId);
    return new Response('ok', { status: 200 });
  }

  const payload = pending.payload as Record<string, unknown>;

  if (pending.kind === 'apartado') {
    const { error } = await supabase.rpc('record_online_layaway_deposit', {
      p_payment_id: String(dataId),
      p_customer_name: payload.customer_name,
      p_customer_phone: payload.customer_phone,
      p_customer_email: payload.customer_email,
      p_total: payload.total,
      p_deposit_amount: payload.deposit_amount,
      p_items: payload.items,
    });
    if (error) {
      console.error('record_online_layaway_deposit failed', error);
      return new Response('Error al registrar el apartado', { status: 500 });
    }
  } else {
    const { error } = await supabase.rpc('record_online_sale', {
      p_payment_id: String(dataId),
      p_customer_name: payload.customer_name,
      p_customer_phone: payload.customer_phone,
      p_customer_email: payload.customer_email,
      p_items: payload.items,
    });
    if (error) {
      console.error('record_online_sale failed', error);
      return new Response('Error al registrar la venta', { status: 500 });
    }
  }

  await supabase.from('pending_checkouts').update({ status: 'confirmado' }).eq('id', pendingId);

  return new Response('ok', { status: 200 });
});
