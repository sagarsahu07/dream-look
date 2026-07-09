// Deno Edge Function — deploy with: supabase functions deploy send-booking-email
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { handleOptions, jsonResponse } from '../_shared/cors.ts';
import { sendEmail, sendWhatsApp } from '../_shared/notify.ts';
import {
  bookingCreatedEmail,
  bookingCancelledEmail,
  bookingRescheduledEmail,
  bookingReminderEmail,
  paymentPaidEmail,
} from '../_shared/emailTemplates.ts';

Deno.serve(async (req) => {
  const optionsResponse = handleOptions(req);
  if (optionsResponse) return optionsResponse;

  try {
    const expectedSecret = Deno.env.get('INTERNAL_WEBHOOK_SECRET');
    const providedSecret = req.headers.get('x-internal-secret');

    if (expectedSecret && providedSecret !== expectedSecret) {
      return jsonResponse({ error: 'Invalid internal secret.' }, 401);
    }

    const { type, booking_id } = await req.json();

    if (!type || !booking_id) {
      return jsonResponse({ error: 'type and booking_id are required.' }, 400);
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    const { data: booking, error } = await supabase
      .from('bookings')
      .select('id, booking_date, start_time, queue_number, estimated_wait_mins, is_walk_in, walk_in_name, walk_in_phone, services(name), barbers(full_name), users(full_name, email, phone)')
      .eq('id', booking_id)
      .single();

    if (error || !booking) {
      return jsonResponse({ error: 'Booking not found.' }, 404);
    }

    // Walk-ins have no account/email — nothing to send to for now.
    const customerEmail = booking.users?.email;
    if (!customerEmail) {
      return jsonResponse({ skipped: true, reason: 'No email on file (walk-in or missing profile).' });
    }

    const bookingDate = new Date(`${booking.booking_date}T00:00:00`).toLocaleDateString('en-IN', {
      day: 'numeric', month: 'short', year: 'numeric',
    });
    const timeLabel = formatTime12h(booking.start_time);

    const baseData = {
      customerName: booking.users?.full_name || booking.walk_in_name || 'there',
      serviceName: booking.services?.name || 'Service',
      barberName: booking.barbers?.full_name || 'our team',
      bookingDate,
      timeLabel,
      queueNumber: booking.queue_number,
      estimatedWait: booking.estimated_wait_mins ? `${booking.estimated_wait_mins} min` : null,
    };

    let emailContent: { subject: string; html: string };

    switch (type) {
      case 'booking_created':
        emailContent = bookingCreatedEmail(baseData);
        break;
      case 'booking_cancelled':
        emailContent = bookingCancelledEmail(baseData);
        break;
      case 'booking_rescheduled':
        emailContent = bookingRescheduledEmail(baseData);
        break;
      case 'booking_reminder':
        emailContent = bookingReminderEmail(baseData);
        break;
      case 'payment_paid': {
        const { data: payment } = await supabase
          .from('payments')
          .select('amount, transaction_id')
          .eq('booking_id', booking_id)
          .single();
        emailContent = paymentPaidEmail({
          ...baseData,
          amount: `₹${Number(payment?.amount || 0).toFixed(0)}`,
          transactionId: payment?.transaction_id || '—',
        });
        break;
      }
      default:
        return jsonResponse({ error: `Unknown notification type: ${type}` }, 400);
    }

    const emailResult = await sendEmail(customerEmail, emailContent.subject, emailContent.html);

    let whatsappResult = { skipped: true } as Record<string, unknown>;
    const customerPhone = booking.users?.phone;
    if (customerPhone) {
      whatsappResult = await sendWhatsApp(
        customerPhone,
        `Dream Look: ${emailContent.subject} — ${baseData.serviceName} on ${bookingDate} at ${timeLabel}.`
      );
    }

    return jsonResponse({ email: emailResult, whatsapp: whatsappResult });
  } catch (err) {
    console.error('send-booking-email error:', err);
    return jsonResponse({ error: String(err) }, 500);
  }
});

function formatTime12h(timeStr: string): string {
  const [h, m] = timeStr.split(':').map(Number);
  const period = h >= 12 ? 'PM' : 'AM';
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}:${String(m).padStart(2, '0')} ${period}`;
}
