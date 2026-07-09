/**
 * Dream Look — Admin Scan Lookup Logic
 * Reuses the exact same RPCs as the Admin Panel queue table
 * (mark_arrived / mark_in_service / complete_booking / mark_no_show) — no
 * new booking-status logic is introduced here.
 */

(function adminScanPage() {
  let bookingId = null;
  let current = null;

  const els = {};

  document.addEventListener('DOMContentLoaded', async () => {
    const admin = await window.dreamLook.auth.requireAdmin();
    if (!admin) return;

    cacheEls();
    document.getElementById('lookup-btn').addEventListener('click', () => {
      const id = document.getElementById('manual-booking-id').value.trim();
      if (id) lookup(id);
    });

    const urlId = new URLSearchParams(window.location.search).get('booking');
    if (urlId) {
      document.getElementById('manual-booking-id').value = urlId;
      lookup(urlId);
    }
  });

  function cacheEls() {
    els.alert = document.getElementById('scan-alert');
    els.loadingNote = document.getElementById('loading-note');
    els.resultCard = document.getElementById('result-card');
    els.actions = document.getElementById('scan-actions');
  }

  async function lookup(id) {
    els.alert.classList.remove('is-visible');
    els.resultCard.style.display = 'none';
    els.actions.style.display = 'none';
    els.loadingNote.style.display = 'block';

    const { data, error } = await window.dreamLook.supabase.rpc('get_booking_receipt', { p_booking_id: id });

    els.loadingNote.style.display = 'none';

    if (error || !data || data.length === 0) {
      els.alert.textContent = 'No booking found with that ID.';
      els.alert.classList.add('is-visible');
      return;
    }

    bookingId = id;
    current = data[0];
    render();
  }

  function render() {
    const bk = window.dreamLook.booking;
    document.getElementById('s-booking-id').textContent = current.booking_id.slice(0, 8).toUpperCase();
    document.getElementById('s-customer').textContent = current.customer_name || '—';
    document.getElementById('s-service').textContent = current.service_name || '—';
    document.getElementById('s-barber').textContent = current.barber_name || '—';
    document.getElementById('s-date').textContent = bk.formatDate(current.booking_date);
    document.getElementById('s-time').textContent = `${bk.formatTime12h(current.start_time)} – ${bk.formatTime12h(current.end_time)}`;
    document.getElementById('s-queue').textContent = current.queue_number ? `#${current.queue_number}` : '—';
    document.getElementById('s-payment').textContent = window.dreamLook.receipt.statusLabel(current.payment_status || 'pending');

    const badge = document.getElementById('s-status-badge');
    badge.textContent = window.dreamLook.receipt.statusLabel(current.status);
    badge.className = `status-badge status-badge--${current.status}`;

    els.resultCard.style.display = 'block';
    renderActions();
  }

  function renderActions() {
    const status = current.status;
    const buttons = [];

    if (status === 'pending' || status === 'confirmed') {
      buttons.push({ label: 'Mark Arrived', action: 'arrive', cls: 'btn--gold-outline' });
      buttons.push({ label: 'No Show', action: 'noshow', cls: 'btn--danger-outline' });
    }
    if (status === 'arrived') {
      buttons.push({ label: 'Start Service', action: 'start', cls: 'btn--dark' });
      buttons.push({ label: 'No Show', action: 'noshow', cls: 'btn--danger-outline' });
    }
    if (status === 'in_service') {
      buttons.push({ label: 'Complete', action: 'complete', cls: 'btn--primary' });
    }

    if (buttons.length === 0) {
      els.actions.style.display = 'none';
      return;
    }

    els.actions.style.display = 'flex';
    els.actions.innerHTML = buttons.map((b) => `<button type="button" class="btn ${b.cls} btn--sm" data-action="${b.action}">${b.label}</button>`).join('');

    els.actions.querySelectorAll('[data-action]').forEach((btn) => {
      btn.addEventListener('click', () => runAction(btn.dataset.action));
    });
  }

  async function runAction(action) {
    const btn = els.actions.querySelector(`[data-action="${action}"]`);
    window.dreamLook.setButtonLoading(btn, true, 'Please wait…');

    let result;
    if (action === 'arrive') result = await window.dreamLook.supabase.rpc('mark_arrived', { p_booking_id: bookingId });
    if (action === 'start') result = await window.dreamLook.supabase.rpc('mark_in_service', { p_booking_id: bookingId });
    if (action === 'complete') result = await window.dreamLook.supabase.rpc('complete_booking', { p_booking_id: bookingId });
    if (action === 'noshow') result = await window.dreamLook.supabase.rpc('mark_no_show', { p_booking_id: bookingId });

    if (result.error) {
      window.dreamLook.setButtonLoading(btn, false);
      window.dreamLook.showToast(result.error.message || 'Action failed.', 'error');
      return;
    }

    window.dreamLook.showToast('Updated.', 'success');
    await lookup(bookingId);
  }
})();
