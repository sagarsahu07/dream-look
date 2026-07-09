/**
 * Dream Look — Dashboard Page Logic (Booking Engine, Phase 2)
 * -----------------------------------------------------------------------
 * Shows the customer's upcoming booking (with queue position and a live
 * wait estimate), full booking history, and lets them cancel or reschedule
 * any booking that is still pending/confirmed. Cancel/reschedule both go
 * through the same validated RPCs used on book-slot.html — there is no
 * separate, duplicated booking logic here.
 * -----------------------------------------------------------------------
 */

(function dashboardPage() {
  let session = null;
  let bookings = [];
  let reviewsByBooking = {};
  let liveWaitTimer = null;
  let bookingsChannel = null;
  let reloadDebounceTimer = null;

  const ACTIVE_STATUSES = ['pending', 'confirmed', 'arrived', 'in_service'];
  const TIMELINE_STAGES = [
    { key: 'confirmed', label: 'Booked' },
    { key: 'arrived', label: 'Arrived' },
    { key: 'in_service', label: 'In Service' },
    { key: 'completed', label: 'Done' },
  ];

  const els = {};

  document.addEventListener('DOMContentLoaded', async () => {
    session = await window.dreamLook.auth.requireAuth();
    if (!session) return;

    cacheEls();
    await loadProfile();
    await loadBookings();

    liveWaitTimer = setInterval(refreshLiveWaits, 30000);

    // Real-time Queue: if an admin marks an earlier booking that day as
    // completed/no-show, the database trigger recomputes queue_number for
    // every remaining booking — including this user's — and that UPDATE
    // arrives here instantly instead of waiting for a manual refresh.
    bookingsChannel = window.dreamLook.booking.subscribeToMyBookings(session.user.id, () => {
      clearTimeout(reloadDebounceTimer);
      reloadDebounceTimer = setTimeout(loadBookings, 400);
    });

    window.addEventListener('beforeunload', () => {
      window.dreamLook.booking.unsubscribe(bookingsChannel);
      clearInterval(liveWaitTimer);
    });
  });

  function cacheEls() {
    els.nameEl = document.getElementById('dash-user-name');
    els.emailEl = document.getElementById('dash-user-email');
    els.upcomingCountEl = document.getElementById('stat-upcoming');
    els.completedCountEl = document.getElementById('stat-completed');
    els.totalSpendEl = document.getElementById('stat-spend');
    els.listEl = document.getElementById('booking-list');
    els.emptyStateEl = document.getElementById('booking-empty-state');
    els.upcomingCardEl = document.getElementById('upcoming-appointment-card');
  }

  async function loadProfile() {
    const { data: profile } = await window.dreamLook.auth.getCurrentUserProfile();
    els.nameEl.textContent = (profile && profile.full_name) || 'there';
    els.emailEl.textContent = (profile && profile.email) || session.user.email;
  }

  async function loadBookings() {
    const [bookingsRes, reviewsRes] = await Promise.all([
      window.dreamLook.booking.fetchMyBookings(session.user.id),
      window.dreamLook.supabase.from('reviews').select('id, booking_id, rating, comment, admin_reply').eq('user_id', session.user.id),
    ]);

    if (bookingsRes.error) {
      window.dreamLook.showToast('Could not load your bookings.', 'error');
      return;
    }

    bookings = bookingsRes.data || [];
    reviewsByBooking = {};
    (reviewsRes.data || []).forEach((r) => { reviewsByBooking[r.booking_id] = r; });

    renderStats();
    renderUpcomingCard();
    renderList();
  }

  // ---- Upcoming Appointment hero card --------------------------------------

  function renderUpcomingCard() {
    const active = bookings
      .filter((b) => ACTIVE_STATUSES.includes(b.status))
      .sort((a, b) => (a.booking_date + a.start_time).localeCompare(b.booking_date + b.start_time));

    const next = active[0];

    if (!next) {
      els.upcomingCardEl.innerHTML = '';
      return;
    }

    const bk = window.dreamLook.booking;
    const serviceName = bk.formatServiceList(next);
    const stageIndex = TIMELINE_STAGES.findIndex((s) => s.key === next.status);
    const effectiveIndex = stageIndex === -1 ? 0 : stageIndex;

    els.upcomingCardEl.innerHTML = `
      <div class="upcoming-card">
        <div class="upcoming-card__eyebrow">Your Next Appointment</div>
        <div class="upcoming-card__top">
          <div>
            <div class="upcoming-card__service">${serviceName}</div>
            <div class="upcoming-card__meta">${bk.formatDate(next.booking_date)} · ${bk.formatTime12h(next.start_time)} – ${bk.formatTime12h(next.end_time)}</div>
          </div>
          ${next.queue_number ? `
            <div class="upcoming-card__queue">
              <div class="upcoming-card__queue-num">#${next.queue_number}</div>
              <div class="upcoming-card__queue-label" id="upcoming-wait" data-date="${next.booking_date}" data-time="${next.start_time}">
                ${bk.formatWait(bk.computeLiveWaitMins(next.booking_date, next.start_time))} wait
              </div>
            </div>
          ` : ''}
        </div>

        <div class="booking-timeline">
          ${TIMELINE_STAGES.map((stage, i) => `
            <div class="booking-timeline__step ${i <= effectiveIndex ? 'is-done' : ''}">
              <div class="booking-timeline__dot"></div>
              <div class="booking-timeline__label">${stage.label}</div>
            </div>
          `).join('')}
        </div>

        <div class="upcoming-card__actions">
          <a href="booking-success.html?booking=${next.id}" class="btn btn--outline btn--sm">View Receipt / QR</a>
          <button type="button" class="btn btn--outline btn--sm" id="upcoming-reschedule-btn">Reschedule</button>
          <button type="button" class="btn btn--primary btn--sm" id="upcoming-cancel-btn">Cancel</button>
        </div>
      </div>
    `;

    document.getElementById('upcoming-cancel-btn').addEventListener('click', () => handleCancel(next.id));
    document.getElementById('upcoming-reschedule-btn').addEventListener('click', () => {
      const rowBtn = document.getElementById(`reschedule-${next.id}`);
      if (rowBtn) {
        rowBtn.scrollIntoView({ behavior: 'smooth', block: 'center' });
        rowBtn.click();
      }
    });
  }

  function refreshUpcomingWait() {
    const chip = document.getElementById('upcoming-wait');
    if (!chip) return;
    const bk = window.dreamLook.booking;
    const mins = bk.computeLiveWaitMins(chip.dataset.date, chip.dataset.time);
    chip.textContent = `${bk.formatWait(mins)} wait`;
  }

  function renderStats() {
    const upcoming = bookings.filter((b) => ACTIVE_STATUSES.includes(b.status));
    const completed = bookings.filter((b) => b.status === 'completed');
    const totalSpend = completed.reduce((sum, b) => sum + window.dreamLook.booking.totalPrice(b), 0);

    els.upcomingCountEl.textContent = upcoming.length;
    els.completedCountEl.textContent = completed.length;
    els.totalSpendEl.textContent = `₹${totalSpend.toFixed(0)}`;
  }

  function renderList() {
    if (bookings.length === 0) {
      els.emptyStateEl.style.display = 'block';
      els.listEl.style.display = 'none';
      return;
    }

    els.emptyStateEl.style.display = 'none';
    els.listEl.style.display = 'block';
    els.listEl.innerHTML = bookings.map(rowMarkup).join('');

    bookings.forEach((b) => {
      const isActive = ACTIVE_STATUSES.includes(b.status);
      if (!isActive) return;

      const cancelBtn = document.getElementById(`cancel-${b.id}`);
      const rescheduleBtn = document.getElementById(`reschedule-${b.id}`);
      if (cancelBtn) cancelBtn.addEventListener('click', () => handleCancel(b.id));
      if (rescheduleBtn) rescheduleBtn.addEventListener('click', () => toggleReschedulePanel(b));
    });

    wireReviewWidgets();
  }

  function rowMarkup(b) {
    const bk = window.dreamLook.booking;
    const serviceName = bk.formatServiceList(b);
    const isActive = ACTIVE_STATUSES.includes(b.status);
    const isCompleted = b.status === 'completed';
    const dateLabel = bk.formatDate(b.booking_date);
    const timeLabel = `${bk.formatTime12h(b.start_time)} – ${bk.formatTime12h(b.end_time)}`;

    const queueMeta = isActive && b.queue_number
      ? `<span class="queue-chip">Queue #${b.queue_number}</span>
         <span class="wait-chip" id="wait-${b.id}" data-date="${b.booking_date}" data-time="${b.start_time}">
           ${bk.formatWait(bk.computeLiveWaitMins(b.booking_date, b.start_time))} wait
         </span>`
      : '';

    const actions = `
      <div class="booking-row__actions">
        <a href="booking-success.html?booking=${b.id}" class="btn btn--outline-dark btn--sm">Receipt</a>
        ${isActive ? `
          <button type="button" class="btn btn--outline-dark btn--sm" id="reschedule-${b.id}">Reschedule</button>
          <button type="button" class="btn btn--danger-outline btn--sm" id="cancel-${b.id}">Cancel</button>
        ` : ''}
      </div>`;

    return `
      <div class="booking-row-wrap" data-booking-id="${b.id}">
        <div class="booking-row">
          <div>
            <div class="booking-row__service">${serviceName}</div>
            <div class="booking-row__meta">${dateLabel} · ${timeLabel}</div>
            <div class="booking-row__queue">${queueMeta}</div>
          </div>
          <div style="display:flex; flex-direction:column; align-items:flex-end; gap: var(--space-2);">
            <span class="status-badge status-badge--${b.status}">${b.status.replace('_', ' ')}</span>
            ${actions}
          </div>
        </div>
        <div class="reschedule-panel" id="reschedule-panel-${b.id}" style="display:none;"></div>
        ${isCompleted ? `<div id="review-panel-${b.id}" style="padding: 0 0 var(--space-4);">${reviewMarkup(b)}</div>` : ''}
      </div>
    `;
  }

  function reviewMarkup(b) {
    const existing = reviewsByBooking[b.id];

    if (existing) {
      return `
        <div class="review-card" style="border:none; background:var(--color-off-white); padding: var(--space-3); margin:0;">
          <div class="review-stars">${'★'.repeat(existing.rating)}${'☆'.repeat(5 - existing.rating)}</div>
          ${existing.comment ? `<div class="review-card__comment" style="margin-top:6px;">"${window.dreamLook.escapeHtml(existing.comment)}"</div>` : ''}
          ${existing.admin_reply ? `
            <div class="review-reply" style="margin-top: var(--space-2);">
              <div class="review-reply__label">Dream Look Replied</div>
              ${window.dreamLook.escapeHtml(existing.admin_reply)}
            </div>` : ''}
        </div>`;
    }

    return `
      <div class="review-card" style="border:none; background:var(--color-off-white); padding: var(--space-3); margin:0;">
        <p class="field-hint" style="margin-bottom: var(--space-2);">How was your visit?</p>
        <div class="star-picker" id="star-picker-${b.id}">
          ${[1, 2, 3, 4, 5].map((n) => `<span class="star-picker__star" data-value="${n}">★</span>`).join('')}
        </div>
        <textarea id="review-comment-${b.id}" placeholder="Add a comment (optional)" style="min-height:60px; margin-bottom: var(--space-2);"></textarea>
        <button type="button" class="btn btn--dark btn--sm" id="review-submit-${b.id}" disabled>Submit Review</button>
      </div>`;
  }

  function wireReviewWidgets() {
    bookings.filter((b) => b.status === 'completed' && !reviewsByBooking[b.id]).forEach((b) => {
      const picker = document.getElementById(`star-picker-${b.id}`);
      const submitBtn = document.getElementById(`review-submit-${b.id}`);
      if (!picker || !submitBtn) return;

      let rating = 0;
      const stars = picker.querySelectorAll('.star-picker__star');

      stars.forEach((star) => {
        star.addEventListener('click', () => {
          rating = Number(star.dataset.value);
          stars.forEach((s) => s.classList.toggle('is-active', Number(s.dataset.value) <= rating));
          submitBtn.disabled = false;
        });
      });

      submitBtn.addEventListener('click', async () => {
        if (rating < 1) return;
        const comment = document.getElementById(`review-comment-${b.id}`).value.trim();

        window.dreamLook.setButtonLoading(submitBtn, true, 'Saving…');
        const { error } = await window.dreamLook.supabase.rpc('submit_review', {
          p_booking_id: b.id,
          p_rating: rating,
          p_comment: comment || null,
        });
        window.dreamLook.setButtonLoading(submitBtn, false);

        if (error) {
          window.dreamLook.showToast(error.message || 'Could not save your review.', 'error');
          return;
        }

        window.dreamLook.showToast('Thanks for your feedback!', 'success');
        await loadBookings();
      });
    });
  }

  function refreshLiveWaits() {
    const bk = window.dreamLook.booking;
    document.querySelectorAll('.wait-chip').forEach((chip) => {
      const mins = bk.computeLiveWaitMins(chip.dataset.date, chip.dataset.time);
      chip.textContent = `${bk.formatWait(mins)} wait`;
    });
    refreshUpcomingWait();
  }

  async function handleCancel(bookingId) {
    if (!window.confirm('Cancel this booking? This cannot be undone.')) return;

    const { error } = await window.dreamLook.booking.cancelBooking(bookingId);

    if (error) {
      window.dreamLook.showToast(error.message || 'Could not cancel this booking.', 'error');
      return;
    }

    window.dreamLook.showToast('Booking cancelled.', 'success');
    await loadBookings();
  }

  // ---- Reschedule panel ----------------------------------------------------

  function toggleReschedulePanel(b) {
    const panel = document.getElementById(`reschedule-panel-${b.id}`);
    const isOpen = panel.style.display !== 'none';

    // Close any other open panel first.
    document.querySelectorAll('.reschedule-panel').forEach((p) => { p.style.display = 'none'; p.innerHTML = ''; });

    if (isOpen) return;

    panel.style.display = 'block';
    panel.innerHTML = `
      <div class="field" style="max-width:260px;">
        <label for="resched-date-${b.id}">New date</label>
        <input type="date" id="resched-date-${b.id}" min="${window.dreamLook.booking.todayStr()}">
      </div>
      <div class="slot-grid" id="resched-slots-${b.id}"></div>
      <p class="field-hint" id="resched-hint-${b.id}">Pick a new date to see open times.</p>
      <div class="form-alert form-alert--error" id="resched-alert-${b.id}"></div>
      <button type="button" class="btn btn--primary btn--sm" id="resched-confirm-${b.id}" disabled style="margin-top: var(--space-2);">
        Confirm New Time
      </button>
    `;

    let chosenTime = '';
    const dateInput = document.getElementById(`resched-date-${b.id}`);
    const slotGrid = document.getElementById(`resched-slots-${b.id}`);
    const hint = document.getElementById(`resched-hint-${b.id}`);
    const alertBox = document.getElementById(`resched-alert-${b.id}`);
    const confirmBtn = document.getElementById(`resched-confirm-${b.id}`);

    dateInput.addEventListener('change', async () => {
      chosenTime = '';
      confirmBtn.disabled = true;
      alertBox.classList.remove('is-visible');

      if (!dateInput.value) return;

      hint.textContent = 'Checking availability…';
      slotGrid.innerHTML = '';

      const { data, error } = await window.dreamLook.booking.fetchAvailableSlots(b.services.id, dateInput.value);

      if (error) {
        hint.textContent = '';
        alertBox.textContent = error.message || 'Could not load available slots.';
        alertBox.classList.add('is-visible');
        return;
      }

      const slots = (data || []).map((row) => row.slot_time);

      if (slots.length === 0) {
        hint.textContent = 'No open slots on this date — try another date.';
        return;
      }

      hint.textContent = '';
      slotGrid.innerHTML = slots.map((t) => `
        <button type="button" class="slot-btn" data-time="${t}">${window.dreamLook.booking.formatTime12h(t)}</button>
      `).join('');

      slotGrid.querySelectorAll('.slot-btn').forEach((btn) => {
        btn.addEventListener('click', () => {
          slotGrid.querySelectorAll('.slot-btn').forEach((x) => x.classList.remove('is-selected'));
          btn.classList.add('is-selected');
          chosenTime = btn.dataset.time;
          confirmBtn.disabled = false;
        });
      });
    });

    confirmBtn.addEventListener('click', async () => {
      if (!dateInput.value || !chosenTime) return;

      window.dreamLook.setButtonLoading(confirmBtn, true, 'Saving…');
      const { error } = await window.dreamLook.booking.rescheduleBooking(b.id, dateInput.value, chosenTime);
      window.dreamLook.setButtonLoading(confirmBtn, false);

      if (error) {
        alertBox.textContent = error.message || 'Could not reschedule this booking.';
        alertBox.classList.add('is-visible');
        return;
      }

      window.dreamLook.showToast('Booking rescheduled.', 'success');
      await loadBookings();
    });
  }
})();
