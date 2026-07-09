/**
 * Dream Look — Book Slot Page Logic
 * -----------------------------------------------------------------------
 * Flow: pick one or more services -> pick a date -> fetch only the
 * genuinely open slots for that COMBINED duration -> pick a slot ->
 * confirm. All availability math and validation happens server-side (see
 * sql/008_multi_service_smart_allocation.sql); this file only renders
 * results and calls the RPCs — it never trusts the client to decide
 * what's bookable, and never assumes the slot it requested is the slot it
 * gets (the backend may smart-allocate a different time/barber if the
 * requested one is taken by the time the request lands).
 * -----------------------------------------------------------------------
 */

(function bookSlotPage() {
  let services = [];
  let closedDates = new Set();
  let shopSettings = null;      // { opening_time, closing_time, weekly_off, ... }
  let selectedServiceIds = new Set();
  let selectedDate = '';        // 'YYYY-MM-DD'
  let selectedTime = '';        // 'HH:MM:SS'
  let pingChannel = null;

  const els = {};

  document.addEventListener('DOMContentLoaded', async () => {
    const session = await window.dreamLook.auth.requireAuth();
    if (!session) return;

    cacheEls();
    await Promise.all([loadServices(), loadClosedDates(), loadShopSettings()]);

    els.dateInput.disabled = false;
    els.dateInput.min = window.dreamLook.booking.todayStr();
    els.dateHint.textContent = 'Select at least one service, then a date.';

    els.dateInput.addEventListener('change', onDateChange);
    els.confirmBtn.addEventListener('click', onConfirm);

    window.addEventListener('beforeunload', () => {
      window.dreamLook.booking.unsubscribe(pingChannel);
    });
  });

  async function loadShopSettings() {
    const { data } = await window.dreamLook.booking.fetchShopSettings();
    shopSettings = data || null;
  }

  function isWeeklyOff(dateStr) {
    if (!shopSettings || !shopSettings.weekly_off || shopSettings.weekly_off.length === 0) return false;
    const dow = new Date(`${dateStr}T00:00:00`).getDay(); // 0=Sunday..6=Saturday, matches Postgres extract(dow)
    return shopSettings.weekly_off.includes(dow);
  }

  function cacheEls() {
    els.alert = document.getElementById('booking-alert');
    els.serviceOptions = document.getElementById('service-options');
    els.dateInput = document.getElementById('booking-date');
    els.dateHint = document.getElementById('date-hint');
    els.slotGrid = document.getElementById('slot-grid');
    els.slotsHint = document.getElementById('slots-hint');
    els.confirmBtn = document.getElementById('confirm-booking-btn');
    els.step1 = document.getElementById('step-1');
    els.step2 = document.getElementById('step-2');
    els.step3 = document.getElementById('step-3');
    els.summaryService = document.getElementById('summary-service');
    els.summaryDuration = document.getElementById('summary-duration');
    els.summaryDate = document.getElementById('summary-date');
    els.summaryTime = document.getElementById('summary-time');
    els.summaryTotal = document.getElementById('summary-total');
  }

  function showAlert(message) {
    els.alert.textContent = message;
    els.alert.classList.add('is-visible');
  }

  function clearAlert() {
    els.alert.classList.remove('is-visible');
  }

  async function loadServices() {
    const { data, error } = await window.dreamLook.booking.fetchActiveServices();
    const loadingNote = document.getElementById('services-loading');

    if (error || !data) {
      if (loadingNote) loadingNote.textContent = 'Could not load services. Please refresh the page.';
      return;
    }

    services = data;
    renderServices();
  }

  async function loadClosedDates() {
    const { data } = await window.dreamLook.booking.fetchClosedDates();
    closedDates = new Set((data || []).map((row) => row.closed_date));
  }

  function renderServices() {
    if (services.length === 0) {
      els.serviceOptions.innerHTML = '<p class="field-hint">No services are available right now.</p>';
      return;
    }

    els.serviceOptions.innerHTML = services.map((s) => `
      <div class="service-select-card" data-id="${s.id}" tabindex="0" role="checkbox" aria-checked="false">
        <div>
          <div class="service-select-card__name">${s.name}</div>
          <div class="service-select-card__meta">${s.duration_mins} min</div>
        </div>
        <span class="service-select-card__price">₹${Number(s.price).toFixed(0)}</span>
      </div>
    `).join('');

    els.serviceOptions.querySelectorAll('.service-select-card').forEach((card) => {
      card.addEventListener('click', () => toggleService(card.dataset.id));
      card.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          toggleService(card.dataset.id);
        }
      });
    });
  }

  function toggleService(serviceId) {
    if (selectedServiceIds.has(serviceId)) {
      selectedServiceIds.delete(serviceId);
    } else {
      selectedServiceIds.add(serviceId);
    }

    selectedTime = '';
    clearAlert();

    const card = els.serviceOptions.querySelector(`[data-id="${serviceId}"]`);
    const isSelected = selectedServiceIds.has(serviceId);
    card.classList.toggle('is-selected', isSelected);
    card.setAttribute('aria-checked', String(isSelected));

    renderSummaryForSelection();
    els.step1.classList.toggle('is-active', selectedServiceIds.size > 0);
    els.step2.classList.toggle('is-active', selectedServiceIds.size > 0);

    if (selectedServiceIds.size === 0) {
      els.slotGrid.innerHTML = '';
      els.slotsHint.textContent = 'Select at least one service to see open times.';
      window.dreamLook.booking.unsubscribe(pingChannel);
      pingChannel = null;
    } else if (selectedDate) {
      loadSlots();
    } else {
      els.dateHint.textContent = 'Now pick a date.';
    }

    updateConfirmState();
  }

  function selectedServices() {
    return services.filter((s) => selectedServiceIds.has(s.id));
  }

  function renderSummaryForSelection() {
    const chosen = selectedServices();

    if (chosen.length === 0) {
      els.summaryService.textContent = 'Not selected';
      els.summaryDuration.textContent = '—';
      els.summaryTotal.textContent = '₹0';
      return;
    }

    const totalDuration = chosen.reduce((sum, s) => sum + s.duration_mins, 0);
    const totalPrice = chosen.reduce((sum, s) => sum + Number(s.price), 0);

    els.summaryService.textContent = chosen.map((s) => s.name).join(' + ');
    els.summaryDuration.textContent = `${totalDuration} min`;
    els.summaryTotal.textContent = `₹${totalPrice.toFixed(0)}`;
  }

  function onDateChange() {
    selectedTime = '';
    clearAlert();
    selectedDate = els.dateInput.value;

    window.dreamLook.booking.unsubscribe(pingChannel);
    pingChannel = null;

    if (!selectedDate) return;

    if (closedDates.has(selectedDate)) {
      els.dateHint.textContent = 'The shop is closed on this date. Please pick another date.';
      els.slotGrid.innerHTML = '';
      els.slotsHint.textContent = '';
      updateConfirmState();
      return;
    }

    if (isWeeklyOff(selectedDate)) {
      els.dateHint.textContent = 'The shop is closed that day of the week. Please pick another date.';
      els.slotGrid.innerHTML = '';
      els.slotsHint.textContent = '';
      updateConfirmState();
      return;
    }

    els.dateHint.textContent = '';
    els.summaryDate.textContent = window.dreamLook.booking.formatDate(selectedDate);

    if (selectedServiceIds.size > 0) {
      loadSlots();
    } else {
      els.slotsHint.textContent = 'Select at least one service to see open times.';
    }
  }

  async function loadSlots() {
    els.slotGrid.innerHTML = '';
    els.slotsHint.textContent = 'Checking availability…';
    updateConfirmState();

    // Live Slot Refresh: re-check availability automatically if another
    // customer books/cancels a slot on this same date while this page is open.
    window.dreamLook.booking.unsubscribe(pingChannel);
    pingChannel = window.dreamLook.booking.subscribeToSlotPings(selectedDate, () => {
      loadSlots();
    });

    const serviceIds = Array.from(selectedServiceIds);
    const { data, error } = await window.dreamLook.booking.fetchAvailableSlots(serviceIds, selectedDate);

    if (error) {
      els.slotsHint.textContent = '';
      showAlert(error.message || 'Could not load available slots. Please try again.');
      return;
    }

    const slots = (data || []).map((row) => row.slot_time);

    if (slots.length === 0) {
      els.slotsHint.textContent = 'No open slots for this combination on this date — try another date or fewer services.';
      return;
    }

    els.slotsHint.textContent = '';
    els.slotGrid.innerHTML = slots.map((t) => `
      <button type="button" class="slot-btn" data-time="${t}">${window.dreamLook.booking.formatTime12h(t)}</button>
    `).join('');

    els.slotGrid.querySelectorAll('.slot-btn').forEach((btn) => {
      btn.addEventListener('click', () => selectSlot(btn));
      if (btn.dataset.time === selectedTime) {
        btn.classList.add('is-selected');
      }
    });

    // A live refresh may have removed the slot the customer had selected —
    // if so, clear the selection instead of silently keeping a stale one.
    if (selectedTime && !slots.includes(selectedTime)) {
      selectedTime = '';
      els.summaryTime.textContent = '—';
      showAlert('Your selected time is no longer available — please pick another.');
    }

    updateConfirmState();
  }

  function selectSlot(btn) {
    els.slotGrid.querySelectorAll('.slot-btn').forEach((b) => b.classList.remove('is-selected'));
    btn.classList.add('is-selected');
    selectedTime = btn.dataset.time;
    els.summaryTime.textContent = btn.textContent;
    els.step3.classList.add('is-active');
    updateConfirmState();
  }

  function updateConfirmState() {
    els.confirmBtn.disabled = !(selectedServiceIds.size > 0 && selectedDate && selectedTime && !closedDates.has(selectedDate));
  }

  async function onConfirm() {
    if (selectedServiceIds.size === 0 || !selectedDate || !selectedTime) return;

    clearAlert();
    window.dreamLook.setButtonLoading(els.confirmBtn, true, 'Booking…');

    const requestedTime = selectedTime;

    const { data, error } = await window.dreamLook.booking.createBooking({
      serviceIds: Array.from(selectedServiceIds),
      date: selectedDate,
      startTime: requestedTime,
    });

    window.dreamLook.setButtonLoading(els.confirmBtn, false);

    if (error) {
      showAlert(error.message || 'Could not complete your booking. Please try another slot.');
      // The slot may have just been taken by someone else — refresh the list.
      loadSlots();
      return;
    }

    const waitLabel = window.dreamLook.booking.formatWait(data.estimated_wait_mins);

    // Smart Slot Allocation: the backend may have assigned a different
    // time/barber than requested if the exact slot was taken in the
    // moment between loading the grid and submitting. Be upfront about it.
    const wasReassigned = data.start_time !== requestedTime;
    const message = wasReassigned
      ? `Your requested time (${window.dreamLook.booking.formatTime12h(requestedTime)}) was just taken. You've been automatically booked for ${window.dreamLook.booking.formatTime12h(data.start_time)} instead — you're #${data.queue_number} in the queue, estimated wait ${waitLabel}.`
      : `Booked! You're #${data.queue_number} in the queue — estimated wait ${waitLabel}.`;

    window.dreamLook.showToast(message, 'success');

    setTimeout(() => {
      window.location.href = `booking-success.html?booking=${data.id}`;
    }, wasReassigned ? 2600 : 1200);
  }
})();
