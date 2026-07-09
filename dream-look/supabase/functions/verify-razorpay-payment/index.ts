// Deno Edge Function — deploy with: supabase functions deploy verify-razorpay-payment
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { handleOptions, jsonResponse } from '../_shared/cors.ts';
import { sendEmail, sendWhatsApp } from '../_shared/notify.ts';
import { paymentPaidEmail } from '../_shared/emailTemplates.ts';

Deno.serve(async (req) => {
  const optionsResponse = handleOptions(req);
  if (optionsResponse) return optionsResponse;

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return jsonResponse({ error: 'Missing Authorization header.' }, 401);
    }

    const { payment_id, razorpay_order_id, razorpay_payment_id, razorpay_signature } = await req.json();

    if (!payment_id || !razorpay_order_id || !razorpay_payment_id || !razorpay_signature) {
      return jsonResponse({ error: 'Missing required fields.' }, 400);
    }

    // Confirm the caller actually owns this payment before doing anything else.
    const callerClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: payment, error: paymentError } = await callerClient
      .from('payments')
      .select('id, booking_id, status')
      .eq('id', payment_id)
      .single();

    if (paymentError || !payment) {
      return jsonResponse({ error: 'Payment not found or does not belong to you.' }, 404);
    }

    const keySecret = Deno.env.get('RAZORPAY_KEY_SECRET');
    if (!keySecret) {
      return jsonResponse({ error: 'Razorpay is not configured on the server yet.' }, 503);
    }

    // ---- The actual security boundary: verify the HMAC-SHA256 signature
    // ---- Razorpay generated using ITS secret key, which never leaves this
    // ---- server. A forged/tampered client response will fail this check.
    const expectedSignature = await hmacSha256Hex(keySecret, `${razorpay_order_id}|${razorpay_payment_id}`);
    const isValid = timingSafeEqual(expectedSignature, razorpay_signature);

    // Service-role client — the ONLY client capable of calling
    // mark_payment_paid / mark_payment_failed (see migration 005 grants).
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    if (!isValid) {
      await adminClient.rpc('mark_payment_failed', { p_payment_id: payment_id, p_reason: 'Signature verification failed' });
      return jsonResponse({ error: 'Payment verification failed.' }, 400);
    }

    const { data: updatedPayment, error: markError } = await adminClient.rpc('mark_payment_paid', {
      p_payment_id: payment_id,
      p_provider: 'razorpay',
      p_provider_ref_id: razorpay_payment_id,
    });

    if (markError) {
      return jsonResponse({ error: markError.message }, 400);
    }

    // Best-effort confirmation email/WhatsApp — never block the response on this.
    try {
      const { data: booking } = await adminClient
        .from('bookings')
        .select('booking_date, start_time, queue_number, estimated_wait_mins, services(name), barbers(full_name), users(full_name, email, phone)')
        .eq('id', payment.booking_id)
        .single();

      if (booking?.users?.email) {
        const bookingDate = new Date(`${booking.booking_date}T00:00:00`).toLocaleDateString('en-IN', {
          day: 'numeric', month: 'short', year: 'numeric',
        });
        const emailContent = paymentPaidEmail({
          customerName: booking.users.full_name || 'there',
          serviceName: booking.services?.name || 'Service',
          barberName: booking.barbers?.full_name || 'our team',
          bookingDate,
          timeLabel: formatTime12h(booking.start_time),
          queueNumber: booking.queue_number,
          estimatedWait: booking.estimated_wait_mins ? `${booking.estimated_wait_mins} min` : null,
          amount: `₹${Number(updatedPayment.amount).toFixed(0)}`,
          transactionId: updatedPayment.transaction_id,
        });
        await sendEmail(booking.users.email, emailContent.subject, emailContent.html);
        if (booking.users.phone) {
          await sendWhatsApp(booking.users.phone, `Dream Look: payment of ₹${Number(updatedPayment.amount).toFixed(0)} received. Thank you!`);
        }
      }
    } catch (notifyErr) {
      console.error('Post-payment notification failed (non-blocking):', notifyErr);
    }

    return jsonResponse({ success: true, payment: updatedPayment });
  } catch (err) {
    console.error('verify-razorpay-payment error:', err);
    return jsonResponse({ error: String(err) }, 500);
  }
});

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, enc.encode(message));
  return Array.from(new Uint8Array(signature)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

function formatTime12h(timeStr: string): string {
  const [h, m] = timeStr.split(':').map(Number);
  const period = h >= 12 ? 'PM' : 'AM';
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${String(m).padStart(2, '0')} ${period}`;
}
