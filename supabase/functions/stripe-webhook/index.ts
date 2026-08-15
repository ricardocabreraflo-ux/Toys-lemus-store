// REEMPLAZADA por mercadopago-webhook — no desplegar esta función. Se conserva solo como referencia histórica.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'npm:stripe@17';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const STRIPE_WEBHOOK_SECRET = Deno.env.get('STRIPE_WEBHOOK_SECRET')!;

const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: '2024-06-20' });
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

Deno.serve(async (req) => {
  const signature = req.headers.get('stripe-signature');
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature!, STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    return new Response(`Firma inválida: ${err}`, { status: 400 });
  }

  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session;
    const meta = session.metadata!;
    const items = JSON.parse(meta.cart);

    if (meta.kind === 'layaway_deposit') {
      const { error } = await supabase.rpc('record_online_layaway_deposit', {
        p_stripe_checkout_session_id: session.id,
        p_customer_name: meta.customer_name,
        p_customer_phone: meta.customer_phone,
        p_customer_email: meta.customer_email,
        p_total: Number(meta.total),
        p_deposit_amount: Number(meta.deposit_amount),
        p_items: items,
      });
      if (error) {
        console.error('record_online_layaway_deposit failed', error);
        return new Response('Error al registrar el apartado', { status: 500 });
      }
      return new Response('ok', { status: 200 });
    }

    const { error } = await supabase.rpc('record_online_sale', {
      p_stripe_checkout_session_id: session.id,
      p_stripe_payment_intent_id: (session.payment_intent as string) ?? null,
      p_customer_name: meta.customer_name,
      p_customer_phone: meta.customer_phone,
      p_customer_email: meta.customer_email,
      p_items: items,
    });
    if (error) {
      console.error('record_online_sale failed', error);
      return new Response('Error al registrar la venta', { status: 500 });
    }
  }

  return new Response('ok', { status: 200 });
});
