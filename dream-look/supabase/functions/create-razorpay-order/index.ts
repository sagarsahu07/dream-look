// Deno Edge Function — deploy with: supabase functions deploy create-razorpay-order
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { handleOptions, jsonResponse } from '../_shared/cors.ts';

Deno.serve(async (req) => {
  const optionsResponse = handleOptions(req);
  if (optionsResponse) return optionsResponse;

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return jsonResponse({ error: 'Missing Authorization header.' }, 401);
    }

    const { payment_id } = await req.json();
    if (!payment_id) {
      return jsonResponse({ error: 'payment_id is required.' }, 400);
    }

    // Client scoped to the CALLER's own JWT — RLS (payments_select_own)
    // guarantees this can only ever return a payment that belongs to them.
    const callerClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: payment, error } = await callerClient
      .from('payments')
      .select('id, amount, status, transaction_id, method')
      .eq('id', payment_id)
      .single();

    if (error || !payment) {
      return jsonResponse({ error: 'Payment not found or does not belong to you.' }, 404);
    }

    if (payment.status !== 'pending') {
      return jsonResponse({ error: 'This payment is not awaiting payment.' }, 400);
    }

    const keyId = Deno.env.get('RAZORPAY_KEY_ID');
    const keySecret = Deno.env.get('RAZORPAY_KEY_SECRET');

    if (!keyId || !keySecret) {
      return jsonResponse({ error: 'Razorpay is not configured on the server yet.' }, 503);
    }

    const amountPaise = Math.round(Number(payment.amount) * 100);
    const basicAuth = btoa(`${keyId}:${keySecret}`);

    const orderRes = await fetch('https://api.razorpay.com/v1/orders', {
      method: 'POST',
      headers: {
        Authorization: `Basic ${basicAuth}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        amount: amountPaise,
        currency: 'INR',
        receipt: payment.transaction_id,
        payment_capture: 1,
      }),
    });

    if (!orderRes.ok) {
      const errText = await orderRes.text();
      console.error('Razorpay order creation failed:', errText);
      return jsonResponse({ error: 'Could not create payment order.' }, 502);
    }

    const order = await orderRes.json();

    return jsonResponse({
      order_id: order.id,
      amount: amountPaise,
      currency: 'INR',
      key_id: keyId,
    });
  } catch (err) {
    console.error('create-razorpay-order error:', err);
    return jsonResponse({ error: String(err) }, 500);
  }
});
