/**
 * Dream Look — Email Templates
 * Simple, table-based HTML so it renders consistently across email clients.
 */

interface BookingEmailData {
  customerName: string;
  serviceName: string;
  barberName: string;
  bookingDate: string; // already formatted, e.g. "5 Jul 2026"
  timeLabel: string;    // already formatted, e.g. "2:30 PM"
  queueNumber: number | null;
  estimatedWait: string | null;
}

function shell(title: string, bodyHtml: string): string {
  return `
  <div style="font-family: Arial, Helvetica, sans-serif; background:#faf9f6; padding:32px 16px;">
    <div style="max-width:480px; margin:0 auto; background:#ffffff; border-radius:12px; overflow:hidden; border:1px solid #e5e5e5;">
      <div style="background:#0b0b0b; padding:24px; text-align:center;">
        <span style="display:inline-block; width:36px; height:36px; border-radius:50%; border:1px solid #d4af37; color:#d4af37; line-height:34px; font-weight:700; font-size:14px;">DL</span>
        <div style="color:#ffffff; font-size:18px; font-weight:600; margin-top:8px;">Dream Look</div>
      </div>
      <div style="padding:28px 24px;">
        <h2 style="margin:0 0 12px; font-size:20px; color:#0b0b0b;">${title}</h2>
        ${bodyHtml}
      </div>
      <div style="padding:16px 24px; border-top:1px solid #e5e5e5; font-size:12px; color:#6b6b6b; text-align:center;">
        Dream Look · 21 Marigold Street, Camp Area, Indore, Madhya Pradesh
      </div>
    </div>
  </div>`;
}

function detailsTable(d: BookingEmailData): string {
  const rows: [string, string][] = [
    ['Service', d.serviceName],
    ['Barber', d.barberName],
    ['Date', d.bookingDate],
    ['Time', d.timeLabel],
  ];
  if (d.queueNumber) rows.push(['Queue Number', `#${d.queueNumber}`]);
  if (d.estimatedWait) rows.push(['Estimated Wait', d.estimatedWait]);

  return `
    <table style="width:100%; border-collapse:collapse; font-size:14px; color:#1f1f1f;">
      ${rows.map(([label, value]) => `
        <tr>
          <td style="padding:8px 0; border-bottom:1px solid #f2f1ee; color:#6b6b6b;">${label}</td>
          <td style="padding:8px 0; border-bottom:1px solid #f2f1ee; text-align:right; font-weight:600;">${value}</td>
        </tr>
      `).join('')}
    </table>`;
}

export function bookingCreatedEmail(d: BookingEmailData): { subject: string; html: string } {
  return {
    subject: 'Your Dream Look booking is confirmed',
    html: shell('Booking Confirmed', `
      <p style="color:#1f1f1f; margin:0 0 16px;">Hi ${d.customerName}, your appointment is confirmed.</p>
      ${detailsTable(d)}
      <p style="color:#6b6b6b; font-size:13px; margin-top:20px;">See you soon! If your plans change, you can cancel or reschedule anytime from your dashboard.</p>
    `),
  };
}

export function bookingCancelledEmail(d: BookingEmailData): { subject: string; html: string } {
  return {
    subject: 'Your Dream Look booking was cancelled',
    html: shell('Booking Cancelled', `
      <p style="color:#1f1f1f; margin:0 0 16px;">Hi ${d.customerName}, this appointment has been cancelled.</p>
      ${detailsTable(d)}
      <p style="color:#6b6b6b; font-size:13px; margin-top:20px;">Whenever you're ready, you're welcome to book a new slot.</p>
    `),
  };
}

export function bookingRescheduledEmail(d: BookingEmailData): { subject: string; html: string } {
  return {
    subject: 'Your Dream Look booking was rescheduled',
    html: shell('Booking Rescheduled', `
      <p style="color:#1f1f1f; margin:0 0 16px;">Hi ${d.customerName}, your appointment has a new time.</p>
      ${detailsTable(d)}
    `),
  };
}

export function bookingReminderEmail(d: BookingEmailData): { subject: string; html: string } {
  return {
    subject: 'Reminder: your Dream Look appointment is coming up',
    html: shell('Appointment Reminder', `
      <p style="color:#1f1f1f; margin:0 0 16px;">Hi ${d.customerName}, this is a reminder about your upcoming appointment.</p>
      ${detailsTable(d)}
    `),
  };
}

export function paymentPaidEmail(d: BookingEmailData & { amount: string; transactionId: string }): { subject: string; html: string } {
  return {
    subject: 'Payment received — Dream Look',
    html: shell('Payment Received', `
      <p style="color:#1f1f1f; margin:0 0 16px;">Hi ${d.customerName}, we've received your payment of ${d.amount}.</p>
      ${detailsTable(d)}
      <table style="width:100%; border-collapse:collapse; font-size:14px; margin-top:12px;">
        <tr><td style="padding:8px 0; color:#6b6b6b;">Transaction ID</td><td style="padding:8px 0; text-align:right; font-weight:600;">${d.transactionId}</td></tr>
      </table>
    `),
  };
}
