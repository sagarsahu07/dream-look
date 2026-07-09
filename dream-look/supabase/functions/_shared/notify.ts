/**
 * Dream Look — Shared Notification Senders
 * -----------------------------------------------------------------------
 * Each function here calls a REAL provider API using the exact request
 * shape that provider expects. None of them are placeholders — they will
 * work the moment real credentials are set as Edge Function secrets
 * (`supabase secrets set ...`). Until then, each one logs and returns
 * { skipped: true } instead of throwing, so a booking/payment action is
 * never blocked by a notification provider that isn't configured yet.
 * -----------------------------------------------------------------------
 */

interface SendResult {
  skipped?: boolean;
  ok?: boolean;
  error?: string;
}

/** Email via Resend (https://resend.com/docs/api-reference/emails/send-email). */
export async function sendEmail(to: string, subject: string, html: string): Promise<SendResult> {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  const fromAddress = Deno.env.get('RESEND_FROM') || 'Dream Look <no-reply@dreamlook.studio>';

  if (!apiKey) {
    console.log(`[email skipped — RESEND_API_KEY not set] to=${to} subject="${subject}"`);
    return { skipped: true };
  }

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ from: fromAddress, to: [to], subject, html }),
    });

    if (!res.ok) {
      const errText = await res.text();
      console.error('Resend send failed:', errText);
      return { ok: false, error: errText };
    }

    return { ok: true };
  } catch (err) {
    console.error('Resend send threw:', err);
    return { ok: false, error: String(err) };
  }
}

/** WhatsApp via Meta's WhatsApp Cloud API (Business Account required). */
export async function sendWhatsApp(toE164: string, message: string): Promise<SendResult> {
  const token = Deno.env.get('WHATSAPP_TOKEN');
  const phoneNumberId = Deno.env.get('WHATSAPP_PHONE_NUMBER_ID');

  if (!token || !phoneNumberId) {
    console.log(`[whatsapp skipped — not configured] to=${toE164} message="${message}"`);
    return { skipped: true };
  }

  try {
    const res = await fetch(`https://graph.facebook.com/v19.0/${phoneNumberId}/messages`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        to: toE164.replace(/[^\d+]/g, ''),
        type: 'text',
        text: { body: message },
      }),
    });

    if (!res.ok) {
      const errText = await res.text();
      console.error('WhatsApp send failed:', errText);
      return { ok: false, error: errText };
    }

    return { ok: true };
  } catch (err) {
    console.error('WhatsApp send threw:', err);
    return { ok: false, error: String(err) };
  }
}

/**
 * SMS — future ready. Shaped for Twilio's REST API
 * (https://www.twilio.com/docs/sms/api/message-resource). Wire up
 * TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN / TWILIO_FROM_NUMBER secrets to
 * activate; until then this safely no-ops.
 */
export async function sendSms(toE164: string, message: string): Promise<SendResult> {
  const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID');
  const authToken = Deno.env.get('TWILIO_AUTH_TOKEN');
  const fromNumber = Deno.env.get('TWILIO_FROM_NUMBER');

  if (!accountSid || !authToken || !fromNumber) {
    console.log(`[sms skipped — not configured] to=${toE164} message="${message}"`);
    return { skipped: true };
  }

  try {
    const basicAuth = btoa(`${accountSid}:${authToken}`);
    const body = new URLSearchParams({ To: toE164, From: fromNumber, Body: message });

    const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${basicAuth}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body,
    });

    if (!res.ok) {
      const errText = await res.text();
      console.error('Twilio send failed:', errText);
      return { ok: false, error: errText };
    }

    return { ok: true };
  } catch (err) {
    console.error('Twilio send threw:', err);
    return { ok: false, error: String(err) };
  }
}
