/**
 * Dream Look — Booking Success / Payment Page Logic
 * -----------------------------------------------------------------------
 * Payment truth lives entirely server-side: this file only calls
 * create_payment_record (RPC) and the create-razorpay-order /
 * verify-razorpay-payment Edge Functions. It never sets a payment's status
 * itself — that happens only after the Edge Function verifies Razorpay's
 * signature (see supabase/functions/verify-razorpay-payment).
 * -----------------------------------------------------------------------
 */

(function bookingSuccessPage() {
  let session = null;
  let bookingId = null;
  let receipt = null;
  let selectedMethod = null;

  const els = {};

  document.addEventListener('DOMContentLoaded', async () => {
    session = await window.dreamLook.auth.requireAuth();
    if (!session) return;

    cacheEls();

    bookingId = new URLSearchParams(window.location.search).get('booking');
    if (!bookingId) {
      els.loadingNote.textContent = 'No booking specified.';
      return;
    }

    wirePaymentUi();
    await loadReceipt();
  });

  function cacheEls() {
    els.loadingNote = document.getElementById('loading-note');
    els.container = document.getElementById('receipt-container');
    els.paymentSection = document.getElementById('payment-section');
    els.paymentAlert = document.getElementById('payment-alert');
    els.payNowBtn = document.getElementById('pay-now-btn');
  }

  async function loadReceipt() {
    const { data, error } = await window.dreamLook.supabase.rpc('get_booking_receipt', { p_booking_id: bookingId });

    if (error || !data || data.length === 0) {
      els.loadingNote.textContent = 'Could not load this booking.';
      return;
    }

    receipt = data[0];
    renderReceipt();

    els.loadingNote.style.display = 'none';
    els.container.style.display = 'block';

    if (receipt.payment_status === 'paid') {
      els.paymentSection.style.display = 'none';
    } else {
      els.paymentSection.style.display = 'block';
    }

    await window.dreamLook.receipt.renderQr(document.getElementById('receipt-qr'), receipt.booking_id);
  }

  function renderReceipt() {
    const bk = window.dreamLook.booking;

    document.getElementById('r-booking-id').textContent = receipt.booking_id.slice(0, 8).toUpperCase();
    document.getElementById('r-customer').textContent = receipt.customer_name || '—';
    document.getElementById('r-service').textContent = receipt.service_name || '—';
    document.getElementById('r-barber').textContent = receipt.barber_name || '—';
    document.getElementById('r-date').textContent = bk.formatDate(receipt.booking_date);
    document.getElementById('r-time').textContent = `${bk.formatTime12h(receipt.start_time)} – ${bk.formatTime12h(receipt.end_time)}`;
    document.getElementById('r-queue').textContent = receipt.queue_number ? `#${receipt.queue_number}` : '—';
    document.getElementById('r-wait').textContent = receipt.estimated_wait_mins != null ? bk.formatWait(bk.computeLiveWaitMins(receipt.booking_date, receipt.start_time)) : '—';

    const paymentStatus = receipt.payment_status || 'pending';
    document.getElementById('r-payment-status').textContent = window.dreamLook.receipt.statusLabel(paymentStatus);
    document.getElementById('r-amount').textContent = `₹${Number(receipt.amount || receipt.service_price || 0).toFixed(0)}`;

    if (receipt.transaction_id) {
      document.getElementById('r-txn-row').style.display = 'flex';
      document.getElementById('r-txn-id').textContent = receipt.transaction_id;
    }

    const statusBadge = document.getElementById('receipt-status-badge');
    statusBadge.textContent = window.dreamLook.receipt.statusLabel(receipt.status);
    statusBadge.className = `status-badge status-badge--${receipt.status}`;

    document.getElementById('print-btn').onclick = () => window.dreamLook.receipt.printReceipt();
    document.getElementById('download-btn').onclick = () => window.dreamLook.receipt.downloadPdf(receipt);
  }

  function wirePaymentUi() {
    document.querySelectorAll('.payment-method-card').forEach((card) => {
      card.addEventListener('click', () => {
        document.querySelectorAll('.payment-method-card').forEach((c) => c.classList.remove('is-selected'));
        card.classList.add('is-selected');
        selectedMethod = card.dataset.method;
        els.payNowBtn.disabled = false;
        els.payNowBtn.textContent = selectedMethod === 'cash' ? 'Confirm Cash Payment' : 'Pay Now';
      });
    });

    els.payNowBtn.addEventListener('click', onPayNow);
  }

  function showPaymentAlert(message) {
    els.paymentAlert.textContent = message;
    els.paymentAlert.classList.add('is-visible');
  }

  async function onPayNow() {
    if (!selectedMethod) return;
    els.paymentAlert.classList.remove('is-visible');
    window.dreamLook.setButtonLoading(els.payNowBtn, true, 'Please wait…');

    const { data: payment, error } = await window.dreamLook.supabase.rpc('create_payment_record', {
      p_booking_id: bookingId,
      p_method: selectedMethod,
    });

    if (error) {
      window.dreamLook.setButtonLoading(els.payNowBtn, false);
      showPaymentAlert(error.message || 'Could not start payment.');
      return;
    }

    if (selectedMethod === 'cash') {
      window.dreamLook.setButtonLoading(els.payNowBtn, false);
      window.dreamLook.showToast('Marked for cash payment — pay at the counter when you arrive.', 'success');
      await loadReceipt();
      return;
    }

    // razorpay / upi both go through Razorpay Checkout, which offers UPI as
    // one of its built-in payment methods alongside cards and netbanking.
    try {
      const order = await callEdgeFunction('create-razorpay-order', { payment_id: payment.id });

      const rzp = new Razorpay({
        key: order.key_id,
        order_id: order.order_id,
        amount: order.amount,
        currency: order.currency,
        name: 'Dream Look',
        description: receipt.service_name,
        theme: { color: '#d4af37' },
        prefill: { name: receipt.customer_name, email: receipt.customer_email || '' },
        method: selectedMethod === 'upi' ? { upi: true, card: false, netbanking: false, wallet: false } : undefined,
        handler: async (response) => {
          window.dreamLook.setButtonLoading(els.payNowBtn, true, 'Verifying payment…');
          try {
            await callEdgeFunction('verify-razorpay-payment', {
              payment_id: payment.id,
              razorpay_order_id: response.razorpay_order_id,
              razorpay_payment_id: response.razorpay_payment_id,
              razorpay_signature: response.razorpay_signature,
            });
            window.dreamLook.showToast('Payment successful!', 'success');
            await loadReceipt();
          } catch (verifyErr) {
            showPaymentAlert(verifyErr.message || 'Payment verification failed. Please contact support.');
          } finally {
            window.dreamLook.setButtonLoading(els.payNowBtn, false);
          }
        },
        modal: {
          ondismiss: () => {
            window.dreamLook.setButtonLoading(els.payNowBtn, false);
          },
        },
      });

      rzp.open();
    } catch (err) {
      window.dreamLook.setButtonLoading(els.payNowBtn, false);
      showPaymentAlert(err.message || 'Could not start Razorpay checkout.');
    }
  }

  /** Calls a Supabase Edge Function with the current session's JWT. */
  async function callEdgeFunction(name, body) {
    const res = await fetch(`${DREAM_LOOK_CONFIG.SUPABASE_URL}/functions/v1/${name}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${session.access_token}`,
        apikey: DREAM_LOOK_CONFIG.SUPABASE_ANON_KEY,
      },
      body: JSON.stringify(body),
    });

    const json = await res.json();
    if (!res.ok) {
      throw new Error(json.error || 'Request failed.');
    }
    return json;
  }
})();
