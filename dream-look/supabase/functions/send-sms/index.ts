// Deno Edge Function — deploy with: supabase functions deploy send-sms
import { handleOptions, jsonResponse } from '../_shared/cors.ts';
import { sendSms } from '../_shared/notify.ts';

Deno.serve(async (req) => {
  const optionsResponse = handleOptions(req);
  if (optionsResponse) return optionsResponse;

  try {
    const expectedSecret = Deno.env.get('INTERNAL_WEBHOOK_SECRET');
    const providedSecret = req.headers.get('x-internal-secret');
    if (expectedSecret && providedSecret !== expectedSecret) {
      return jsonResponse({ error: 'Invalid internal secret.' }, 401);
    }

    const { to, message } = await req.json();
    if (!to || !message) {
      return jsonResponse({ error: 'to and message are required.' }, 400);
    }

    const result = await sendSms(to, message);
    return jsonResponse(result);
  } catch (err) {
    console.error('send-sms error:', err);
    return jsonResponse({ error: String(err) }, 500);
  }
});
