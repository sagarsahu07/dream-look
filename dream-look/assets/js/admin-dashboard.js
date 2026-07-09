/**
 * Dream Look — Admin Panel Logic (Phase 3 Frontend)
 * -----------------------------------------------------------------------
 * Every write action here calls the SECURITY DEFINER RPCs created in
 * sql/002_booking_engine.sql, sql/003_advanced_booking_features.sql and
 * sql/004_admin_panel.sql — this file contains no booking-engine business
 * logic of its own, only rendering and wiring. Direct table reads/writes
 * (services, barbers, shop_settings, shop_closed_dates, audit_logs, and
 * admin-cancel) rely on the admin RLS policies already defined in those
 * same migrations.
 * -----------------------------------------------------------------------
 */

(function adminDashboardPage() {
  const db = () => window.dreamLook.supabase;

  let profile = null;
  let loadedSections = new Set();
  let bookingsRealtimeChannel = null;
  let servicesCache = []; // used to populate the walk-in service dropdown

  const els = {};

  document.addEventListener('DOMContentLoaded', async () => {
    const admin = await window.dreamLook.auth.requireAdmin();
    if (!admin) return;
    profile = admin.profile;

    cacheEls();
    document.getElementById('admin-name').textContent = profile.full_name || 'Staff';
    document.getElementById('dashboard-date-label').textContent = window.dreamLook.booking.formatDate(todayStr());

    wireTabs();
    wireModals();
    wireQueueActions();
    wireWalkinForm();
    wireServiceForm();
    wireBarberForm();
    wireSettingsForm();
    wireHolidayForm();
    wireCustomerSearch();
    wireReports();
    wireAuditFilters();

    await loadDashboard();
    startRealtime();

    window.addEventListener('beforeunload', () => {
      window.dreamLook.booking.unsubscribe(bookingsRealtimeChannel);
    });
  });

  function todayStr() {
    return window.dreamLook.booking.todayStr();
  }

  function cacheEls() {
    els.tabs = document.querySelectorAll('.admin-tab');
    els.sections = document.querySelectorAll('.admin-section');
  }

  // ---------------------------------------------------------------------
  // Tabs
  // ---------------------------------------------------------------------
  function wireTabs() {
    els.tabs.forEach((tab) => {
      tab.addEventListener('click', () => activateTab(tab.dataset.tab));
    });
  }

  async function activateTab(name) {
    els.tabs.forEach((t) => t.classList.toggle('is-active', t.dataset.tab === name));
    els.sections.forEach((s) => s.classList.toggle('is-active', s.id === `section-${name}`));

    if (loadedSections.has(name)) return;
    loadedSections.add(name);

    if (name === 'queue') await loadQueue();
    if (name === 'services') await loadServices();
    if (name === 'barbers') await loadBarbers();
    if (name === 'settings') await loadSettings();
  }

  // ---------------------------------------------------------------------
  // Modal helpers
  // ---------------------------------------------------------------------
  function wireModals() {
    document.querySelectorAll('[data-close-modal]').forEach((btn) => {
      btn.addEventListener('click', () => closeModal(btn.dataset.closeModal));
    });
    document.querySelectorAll('.admin-modal-overlay').forEach((overlay) => {
      overlay.addEventListener('click', (e) => {
        if (e.target === overlay) closeModal(overlay.id);
      });
    });
  }

  function openModal(id) {
    document.getElementById(id).classList.add('is-open');
  }

  function closeModal(id) {
    document.getElementById(id).classList.remove('is-open');
  }

  // =======================================================================
  // DASHBOARD
  // =======================================================================
  async function loadDashboard() {
    const { data, error } = await db().rpc('admin_dashboard_stats', { p_date: todayStr() });

    if (error || !data || data.length === 0) {
      window.dreamLook.showToast('Could not load dashboard stats.', 'error');
      return;
    }

    const s = data[0];
    document.getElementById('stat-today-bookings').textContent = s.today_bookings;
    document.getElementById('stat-current-queue').textContent = s.current_queue_count;
    document.getElementById('stat-walk-ins').textContent = s.walk_in_count;
    document.getElementById('stat-revenue').textContent = `₹${Number(s.revenue_today).toFixed(0)}`;
    document.getElementById('stat-completed').textContent = s.completed_count;
    document.getElementById('stat-cancelled').textContent = s.cancelled_count;
    document.getElementById('stat-no-show').textContent = s.no_show_count;
    document.getElementById('stat-total-customers').textContent = s.total_customers;
  }

  // =======================================================================
  // QUEUE
  // =======================================================================
  function wireQueueActions() {
    document.getElementById('call-next-btn').addEventListener('click', async () => {
      const { error } = await db().rpc('call_next_customer', {});
      if (error) {
        showQueueAlert(error.message || 'Could not call next customer.');
        return;
      }
      window.dreamLook.showToast('Next customer called in.', 'success');
      await loadQueue();
    });

    document.getElementById('open-walkin-btn').addEventListener('click', async () => {
      await populateWalkinServiceOptions();
      openModal('walkin-modal-overlay');
    });
  }

  function showQueueAlert(message) {
    const el = document.getElementById('queue-alert');
    el.textContent = message;
    el.classList.add('is-visible');
    setTimeout(() => el.classList.remove('is-visible'), 5000);
  }

  async function loadQueue() {
    const tbody = document.getElementById('queue-table-body');
    const { data, error } = await db()
      .from('bookings')
      .select('id, queue_number, start_time, end_time, status, is_walk_in, walk_in_name, walk_in_phone, services(name), barbers(full_name), users(full_name, phone), booking_services(services(name))')
      .eq('booking_date', todayStr())
      .in('status', ['pending', 'confirmed', 'arrived', 'in_service', 'completed', 'cancelled', 'no_show'])
      .order('queue_number', { ascending: true, nullsFirst: false })
      .order('start_time', { ascending: true });

    if (error) {
      tbody.innerHTML = `<tr class="table-empty-row"><td colspan="7">Could not load the queue.</td></tr>`;
      return;
    }

    renderQueue(data || []);
  }

  function renderQueue(rows) {
    const tbody = document.getElementById('queue-table-body');

    if (rows.length === 0) {
      tbody.innerHTML = `<tr class="table-empty-row"><td colspan="7">No bookings for today yet.</td></tr>`;
      return;
    }

    const bk = window.dreamLook.booking;

    tbody.innerHTML = rows.map((r) => {
      const rawName = r.is_walk_in ? r.walk_in_name : (r.users ? r.users.full_name : '—');
      const customerName = window.dreamLook.escapeHtml(rawName);
      const walkTag = r.is_walk_in ? '<span class="walkin-tag">Walk-in</span>' : '';
      const queueChip = r.queue_number ? `<span class="queue-num-chip">${r.queue_number}</span>` : '—';
      const timeLabel = `${bk.formatTime12h(r.start_time)} – ${bk.formatTime12h(r.end_time)}`;
      const serviceName = (r.booking_services && r.booking_services.length > 0)
        ? r.booking_services.map((bs) => bs.services?.name).filter(Boolean).join(' + ')
        : (r.services ? r.services.name : '—');
      const barberName = r.barbers ? r.barbers.full_name : '—';

      return `
        <tr>
          <td>${queueChip}</td>
          <td>${customerName}${walkTag}</td>
          <td>${serviceName}</td>
          <td>${barberName}</td>
          <td>${timeLabel}</td>
          <td><span class="status-badge status-badge--${r.status}">${r.status.replace('_', ' ')}</span></td>
          <td><div class="data-table__actions">${queueActionButtons(r)}</div></td>
        </tr>
      `;
    }).join('');
  }

  function queueActionButtons(r) {
    const id = r.id;
    const btns = [];

    if (r.status === 'pending' || r.status === 'confirmed') {
      btns.push(`<button class="btn btn--gold-outline btn--xs" data-action="arrive" data-id="${id}">Mark Arrived</button>`);
      btns.push(`<button class="btn btn--danger-outline btn--xs" data-action="noshow" data-id="${id}">No Show</button>`);
    }
    if (r.status === 'arrived') {
      btns.push(`<button class="btn btn--dark btn--xs" data-action="start" data-id="${id}">Start Service</button>`);
      btns.push(`<button class="btn btn--danger-outline btn--xs" data-action="noshow" data-id="${id}">No Show</button>`);
    }
    if (r.status === 'in_service') {
      btns.push(`<button class="btn btn--primary btn--xs" data-action="complete" data-id="${id}">Complete</button>`);
    }
    if (['pending', 'confirmed', 'arrived', 'in_service'].includes(r.status)) {
      btns.push(`<button class="btn btn--outline-dark btn--xs" data-action="cancel" data-id="${id}">Cancel</button>`);
    }

    return btns.join('') || '—';
  }

  // Event delegation for queue action buttons — works for every re-render,
  // no per-row rebinding needed.
  document.addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-action]');
    if (!btn) return;
    const tbody = document.getElementById('queue-table-body');
    if (!tbody || !tbody.contains(btn)) return;

    const id = btn.dataset.id;
    const action = btn.dataset.action;
    if (!id || !action) return;

    let result;
    if (action === 'arrive') result = await db().rpc('mark_arrived', { p_booking_id: id });
    if (action === 'start') result = await db().rpc('mark_in_service', { p_booking_id: id });
    if (action === 'complete') result = await db().rpc('complete_booking', { p_booking_id: id });
    if (action === 'noshow') result = await db().rpc('mark_no_show', { p_booking_id: id });
    if (action === 'cancel') {
      if (!window.confirm('Cancel this booking?')) return;
      result = await db().rpc('admin_cancel_booking', { p_booking_id: id });
    }

    if (result && result.error) {
      showQueueAlert(result.error.message || 'Action failed.');
      return;
    }

    await loadQueue();
    if (loadedSections.has('dashboard')) await loadDashboard();
  });

  // =======================================================================
  // WALK-IN CUSTOMER
  // =======================================================================
  async function populateWalkinServiceOptions() {
    const select = document.getElementById('walkin-service');
    if (servicesCache.length === 0) {
      const { data } = await db().from('services').select('id, name, price').eq('is_active', true).order('price');
      servicesCache = data || [];
    }
    select.innerHTML = servicesCache.map((s) => `<option value="${s.id}">${s.name} — ₹${Number(s.price).toFixed(0)}</option>`).join('');
  }

  function wireWalkinForm() {
    const form = document.getElementById('walkin-form');
    const alertBox = document.getElementById('walkin-alert');
    const submitBtn = document.getElementById('walkin-submit-btn');

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      window.dreamLook.clearFormErrors(form);
      alertBox.classList.remove('is-visible');

      const name = document.getElementById('walkin-name').value.trim();
      const phone = document.getElementById('walkin-phone').value.trim();
      const serviceId = document.getElementById('walkin-service').value;

      let hasError = false;
      if (name.length < 2) {
        window.dreamLook.setFieldError('walkin-name', 'Enter the customer\'s name.');
        hasError = true;
      }
      if (phone && !window.dreamLook.isValidPhone(phone)) {
        window.dreamLook.setFieldError('walkin-phone', 'Enter a valid phone number.');
        hasError = true;
      }
      if (!serviceId) {
        alertBox.textContent = 'No active services available.';
        alertBox.classList.add('is-visible');
        hasError = true;
      }
      if (hasError) return;

      window.dreamLook.setButtonLoading(submitBtn, true, 'Adding…');
      const { data, error } = await db().rpc('admin_create_walk_in', {
        p_service_id: serviceId,
        p_name: name,
        p_phone: phone || null,
      });
      window.dreamLook.setButtonLoading(submitBtn, false);

      if (error) {
        alertBox.textContent = error.message || 'Could not add walk-in customer.';
        alertBox.classList.add('is-visible');
        return;
      }

      window.dreamLook.showToast(`Walk-in added — Queue #${data.queue_number}, slot ${window.dreamLook.booking.formatTime12h(data.start_time)}.`, 'success');
      form.reset();
      closeModal('walkin-modal-overlay');

      if (loadedSections.has('queue')) await loadQueue();
      if (loadedSections.has('dashboard')) await loadDashboard();
    });
  }

  // =======================================================================
  // SERVICES
  // =======================================================================
  async function loadServices() {
    const tbody = document.getElementById('services-table-body');
    const { data, error } = await db().from('services').select('*').order('created_at', { ascending: true });

    if (error) {
      tbody.innerHTML = `<tr class="table-empty-row"><td colspan="5">Could not load services.</td></tr>`;
      return;
    }

    servicesCache = (data || []).filter((s) => s.is_active);

    if (!data || data.length === 0) {
      tbody.innerHTML = `<tr class="table-empty-row"><td colspan="5">No services yet.</td></tr>`;
      return;
    }

    tbody.innerHTML = data.map((s) => `
      <tr>
        <td>${s.name}</td>
        <td>₹${Number(s.price).toFixed(0)}</td>
        <td>${s.duration_mins} min</td>
        <td><span class="status-badge status-badge--${s.is_active ? 'confirmed' : 'cancelled'}">${s.is_active ? 'Active' : 'Inactive'}</span></td>
        <td>
          <div class="data-table__actions">
            <button class="btn btn--outline-dark btn--xs" data-svc-edit="${s.id}">Edit</button>
            <button class="btn btn--danger-outline btn--xs" data-svc-toggle="${s.id}" data-svc-active="${s.is_active}">${s.is_active ? 'Delete' : 'Reactivate'}</button>
          </div>
        </td>
      </tr>
    `).join('');

    tbody.querySelectorAll('[data-svc-edit]').forEach((btn) => {
      btn.addEventListener('click', () => openServiceModal(data.find((s) => s.id === btn.dataset.svcEdit)));
    });
    tbody.querySelectorAll('[data-svc-toggle]').forEach((btn) => {
      btn.addEventListener('click', () => toggleServiceActive(btn.dataset.svcToggle, btn.dataset.svcActive === 'true'));
    });
  }

  function openServiceModal(service) {
    document.getElementById('service-modal-title').textContent = service ? 'Edit Service' : 'Add Service';
    document.getElementById('service-id').value = service ? service.id : '';
    document.getElementById('service-name').value = service ? service.name : '';
    document.getElementById('service-description').value = service ? (service.description || '') : '';
    document.getElementById('service-price').value = service ? service.price : '';
    document.getElementById('service-duration').value = service ? service.duration_mins : '';
    document.getElementById('service-active').checked = service ? service.is_active : true;
    document.getElementById('service-modal-alert').classList.remove('is-visible');
    openModal('service-modal-overlay');
  }

  function wireServiceForm() {
    document.getElementById('open-add-service-btn').addEventListener('click', () => openServiceModal(null));

    const form = document.getElementById('service-form');
    const alertBox = document.getElementById('service-modal-alert');
    const submitBtn = document.getElementById('service-submit-btn');

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      window.dreamLook.clearFormErrors(form);
      alertBox.classList.remove('is-visible');

      const id = document.getElementById('service-id').value;
      const name = document.getElementById('service-name').value.trim();
      const description = document.getElementById('service-description').value.trim();
      const price = Number(document.getElementById('service-price').value);
      const duration = Number(document.getElementById('service-duration').value);
      const isActive = document.getElementById('service-active').checked;

      let hasError = false;
      if (name.length < 2) { window.dreamLook.setFieldError('service-name', 'Enter a service name.'); hasError = true; }
      if (!(price >= 0)) { window.dreamLook.setFieldError('service-price', 'Enter a valid price.'); hasError = true; }
      if (!(duration > 0)) { window.dreamLook.setFieldError('service-duration', 'Enter a valid duration.'); hasError = true; }
      if (hasError) return;

      window.dreamLook.setButtonLoading(submitBtn, true, 'Saving…');

      const payload = { name, description: description || null, price, duration_mins: duration, is_active: isActive };
      const result = id
        ? await db().from('services').update(payload).eq('id', id)
        : await db().from('services').insert(payload);

      window.dreamLook.setButtonLoading(submitBtn, false);

      if (result.error) {
        alertBox.textContent = result.error.message || 'Could not save service.';
        alertBox.classList.add('is-visible');
        return;
      }

      window.dreamLook.showToast('Service saved.', 'success');
      closeModal('service-modal-overlay');
      await loadServices();
    });
  }

  async function toggleServiceActive(id, currentlyActive) {
    if (currentlyActive && !window.confirm('Remove this service from the public menu? Existing bookings are kept.')) return;

    const { error } = await db().from('services').update({ is_active: !currentlyActive }).eq('id', id);
    if (error) {
      window.dreamLook.showToast(error.message || 'Could not update service.', 'error');
      return;
    }
    window.dreamLook.showToast(currentlyActive ? 'Service removed from menu.' : 'Service reactivated.', 'success');
    await loadServices();
  }

  // =======================================================================
  // BARBERS
  // =======================================================================
  async function loadBarbers() {
    const tbody = document.getElementById('barbers-table-body');
    const { data, error } = await db().from('barbers').select('*').order('created_at', { ascending: true });

    if (error) {
      tbody.innerHTML = `<tr class="table-empty-row"><td colspan="3">Could not load barbers.</td></tr>`;
      return;
    }

    if (!data || data.length === 0) {
      tbody.innerHTML = `<tr class="table-empty-row"><td colspan="3">No barbers yet.</td></tr>`;
      return;
    }

    tbody.innerHTML = data.map((b) => `
      <tr>
        <td>${window.dreamLook.escapeHtml(b.full_name)}</td>
        <td><span class="status-badge status-badge--${b.is_active ? 'confirmed' : 'cancelled'}">${b.is_active ? 'Active' : 'Inactive'}</span></td>
        <td>
          <div class="data-table__actions">
            <button class="btn btn--outline-dark btn--xs" data-barber-edit="${b.id}">Edit</button>
            <button class="btn btn--danger-outline btn--xs" data-barber-toggle="${b.id}" data-barber-active="${b.is_active}">${b.is_active ? 'Deactivate' : 'Activate'}</button>
          </div>
        </td>
      </tr>
    `).join('');

    tbody.querySelectorAll('[data-barber-edit]').forEach((btn) => {
      btn.addEventListener('click', () => openBarberModal(data.find((b) => b.id === btn.dataset.barberEdit)));
    });
    tbody.querySelectorAll('[data-barber-toggle]').forEach((btn) => {
      btn.addEventListener('click', () => toggleBarberActive(btn.dataset.barberToggle, btn.dataset.barberActive === 'true'));
    });
  }

  function openBarberModal(barber) {
    document.getElementById('barber-modal-title').textContent = barber ? 'Edit Barber' : 'Add Barber';
    document.getElementById('barber-id').value = barber ? barber.id : '';
    document.getElementById('barber-name').value = barber ? barber.full_name : '';
    document.getElementById('barber-active').checked = barber ? barber.is_active : true;
    document.getElementById('barber-modal-alert').classList.remove('is-visible');
    openModal('barber-modal-overlay');
  }

  function wireBarberForm() {
    document.getElementById('open-add-barber-btn').addEventListener('click', () => openBarberModal(null));

    const form = document.getElementById('barber-form');
    const alertBox = document.getElementById('barber-modal-alert');
    const submitBtn = document.getElementById('barber-submit-btn');

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      window.dreamLook.clearFormErrors(form);
      alertBox.classList.remove('is-visible');

      const id = document.getElementById('barber-id').value;
      const name = document.getElementById('barber-name').value.trim();
      const isActive = document.getElementById('barber-active').checked;

      if (name.length < 2) {
        window.dreamLook.setFieldError('barber-name', 'Enter the barber\'s name.');
        return;
      }

      window.dreamLook.setButtonLoading(submitBtn, true, 'Saving…');

      const payload = { full_name: name, is_active: isActive };
      const result = id
        ? await db().from('barbers').update(payload).eq('id', id)
        : await db().from('barbers').insert(payload);

      window.dreamLook.setButtonLoading(submitBtn, false);

      if (result.error) {
        alertBox.textContent = result.error.message || 'Could not save barber.';
        alertBox.classList.add('is-visible');
        return;
      }

      window.dreamLook.showToast('Barber saved.', 'success');
      closeModal('barber-modal-overlay');
      await loadBarbers();
    });
  }

  async function toggleBarberActive(id, currentlyActive) {
    const { error } = await db().from('barbers').update({ is_active: !currentlyActive }).eq('id', id);
    if (error) {
      window.dreamLook.showToast(error.message || 'Could not update barber.', 'error');
      return;
    }
    window.dreamLook.showToast(currentlyActive ? 'Barber deactivated.' : 'Barber activated.', 'success');
    await loadBarbers();
  }

  // =======================================================================
  // SHOP SETTINGS
  // =======================================================================
  const DAY_LABELS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

  async function loadSettings() {
    const { data, error } = await window.dreamLook.booking.fetchShopSettings();
    const alertBox = document.getElementById('settings-alert');

    if (error || !data) {
      alertBox.textContent = 'Could not load shop settings.';
      alertBox.classList.add('form-alert--error', 'is-visible');
      return;
    }

    document.getElementById('setting-opening').value = data.opening_time.slice(0, 5);
    document.getElementById('setting-closing').value = data.closing_time.slice(0, 5);
    document.getElementById('setting-buffer').value = data.buffer_minutes;
    document.getElementById('setting-grace').value = data.grace_period_minutes;
    document.getElementById('setting-step').value = data.slot_step_minutes;
    document.getElementById('setting-timezone').value = data.shop_timezone;
    document.getElementById('setting-allow-multi').checked = data.allow_multiple_bookings_per_day;

    renderWeeklyOffGrid(data.weekly_off || []);
    await loadHolidays();
  }

  function renderWeeklyOffGrid(weeklyOff) {
    const grid = document.getElementById('weekly-off-grid');
    grid.innerHTML = DAY_LABELS.map((label, idx) => `
      <label class="day-toggle ${weeklyOff.includes(idx) ? 'is-off' : ''}" data-day="${idx}">
        <input type="checkbox" value="${idx}" ${weeklyOff.includes(idx) ? 'checked' : ''}>
        ${label}
      </label>
    `).join('');

    grid.querySelectorAll('.day-toggle').forEach((label) => {
      const checkbox = label.querySelector('input');
      checkbox.addEventListener('change', () => label.classList.toggle('is-off', checkbox.checked));
    });
  }

  function wireSettingsForm() {
    const form = document.getElementById('settings-form');
    const alertBox = document.getElementById('settings-alert');
    const submitBtn = document.getElementById('settings-save-btn');

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      alertBox.classList.remove('is-visible', 'form-alert--error', 'form-alert--success');

      const weeklyOff = Array.from(document.querySelectorAll('#weekly-off-grid input:checked')).map((el) => Number(el.value));

      const payload = {
        opening_time: document.getElementById('setting-opening').value,
        closing_time: document.getElementById('setting-closing').value,
        buffer_minutes: Number(document.getElementById('setting-buffer').value),
        grace_period_minutes: Number(document.getElementById('setting-grace').value),
        slot_step_minutes: Number(document.getElementById('setting-step').value),
        shop_timezone: document.getElementById('setting-timezone').value.trim() || 'Asia/Kolkata',
        allow_multiple_bookings_per_day: document.getElementById('setting-allow-multi').checked,
        weekly_off: weeklyOff,
      };

      window.dreamLook.setButtonLoading(submitBtn, true, 'Saving…');
      const { error } = await db().from('shop_settings').update(payload).eq('id', 1);
      window.dreamLook.setButtonLoading(submitBtn, false);

      if (error) {
        alertBox.textContent = error.message || 'Could not save settings.';
        alertBox.classList.add('form-alert--error', 'is-visible');
        return;
      }

      alertBox.textContent = 'Shop settings saved.';
      alertBox.classList.add('form-alert--success', 'is-visible');
      window.dreamLook.showToast('Shop settings updated.', 'success');
    });
  }

  async function loadHolidays() {
    const listEl = document.getElementById('holiday-list');
    const { data, error } = await db().from('shop_closed_dates').select('*').order('closed_date', { ascending: true });

    if (error) {
      listEl.innerHTML = '<p class="field-hint">Could not load holidays.</p>';
      return;
    }

    if (!data || data.length === 0) {
      listEl.innerHTML = '<p class="field-hint">No holidays added yet.</p>';
      return;
    }

    listEl.innerHTML = data.map((h) => `
      <div class="holiday-row">
        <span>${window.dreamLook.booking.formatDate(h.closed_date)}${h.reason ? ` — ${h.reason}` : ''}</span>
        <button type="button" class="btn btn--danger-outline btn--xs" data-holiday-remove="${h.closed_date}">Remove</button>
      </div>
    `).join('');

    listEl.querySelectorAll('[data-holiday-remove]').forEach((btn) => {
      btn.addEventListener('click', () => removeHoliday(btn.dataset.holidayRemove));
    });
  }

  function wireHolidayForm() {
    document.getElementById('add-holiday-btn').addEventListener('click', async () => {
      const alertBox = document.getElementById('holiday-alert');
      alertBox.classList.remove('is-visible');

      const date = document.getElementById('new-holiday-date').value;
      const reason = document.getElementById('new-holiday-reason').value.trim();

      if (!date) {
        alertBox.textContent = 'Pick a date to close.';
        alertBox.classList.add('is-visible');
        return;
      }

      const { error } = await db().from('shop_closed_dates').insert({ closed_date: date, reason: reason || null });

      if (error) {
        alertBox.textContent = error.message || 'Could not add holiday.';
        alertBox.classList.add('is-visible');
        return;
      }

      document.getElementById('new-holiday-date').value = '';
      document.getElementById('new-holiday-reason').value = '';
      window.dreamLook.showToast('Holiday added.', 'success');
      await loadHolidays();
    });
  }

  async function removeHoliday(dateStr) {
    const { error } = await db().from('shop_closed_dates').delete().eq('closed_date', dateStr);
    if (error) {
      window.dreamLook.showToast(error.message || 'Could not remove holiday.', 'error');
      return;
    }
    window.dreamLook.showToast('Holiday removed.', 'success');
    await loadHolidays();
  }

  // =======================================================================
  // CUSTOMERS
  // =======================================================================
  function wireCustomerSearch() {
    const input = document.getElementById('customer-search-input');
    let debounceTimer;

    input.addEventListener('input', () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => runCustomerSearch(input.value.trim()), 350);
    });
  }

  async function runCustomerSearch(term) {
    const resultsEl = document.getElementById('customer-search-results');

    if (term.length < 2) {
      resultsEl.innerHTML = '';
      return;
    }

    // PostgREST's .or() filter has its own mini-syntax where commas and
    // parentheses are structurally significant — strip them from the raw
    // search term so a pasted/typed value can't malform the filter.
    const safeTerm = term.replace(/[,()]/g, '');

    const { data, error } = await db()
      .from('users')
      .select('id, full_name, email, phone')
      .eq('role', 'customer')
      .or(`full_name.ilike.%${safeTerm}%,email.ilike.%${safeTerm}%,phone.ilike.%${safeTerm}%`)
      .limit(20);

    if (error) {
      resultsEl.innerHTML = '<p class="field-hint">Search failed.</p>';
      return;
    }

    if (!data || data.length === 0) {
      resultsEl.innerHTML = '<p class="field-hint">No matching customers.</p>';
      return;
    }

    resultsEl.innerHTML = data.map((c) => `
      <div class="customer-result-card" data-customer-id="${c.id}">
        <div>
          <div class="customer-result-card__name">${window.dreamLook.escapeHtml(c.full_name)}</div>
          <div class="customer-result-card__meta">${window.dreamLook.escapeHtml(c.email)}${c.phone ? ' · ' + window.dreamLook.escapeHtml(c.phone) : ''}</div>
        </div>
        <span class="btn btn--outline-dark btn--xs">View</span>
      </div>
    `).join('');

    resultsEl.querySelectorAll('[data-customer-id]').forEach((card) => {
      card.addEventListener('click', () => loadCustomerDetail(card.dataset.customerId, data.find((c) => c.id === card.dataset.customerId)));
    });
  }

  async function loadCustomerDetail(userId, customer) {
    const panel = document.getElementById('customer-detail-panel');
    panel.style.display = 'block';
    document.getElementById('customer-detail-name').textContent = customer.full_name;
    document.getElementById('customer-detail-meta').textContent = `${customer.email}${customer.phone ? ' · ' + customer.phone : ''}`;

    const { data, error } = await db()
      .from('bookings')
      .select('id, booking_date, start_time, status, services(name), booking_services(services(name))')
      .eq('user_id', userId)
      .order('booking_date', { ascending: false })
      .order('start_time', { ascending: false });

    const upcomingBody = document.getElementById('customer-upcoming-body');
    const historyBody = document.getElementById('customer-history-body');

    if (error || !data) {
      upcomingBody.innerHTML = '<tr class="table-empty-row"><td colspan="4">Could not load bookings.</td></tr>';
      historyBody.innerHTML = '<tr class="table-empty-row"><td colspan="4">Could not load bookings.</td></tr>';
      return;
    }

    const today = todayStr();
    const activeStatuses = ['pending', 'confirmed', 'arrived', 'in_service'];
    const upcoming = data.filter((b) => activeStatuses.includes(b.status) && b.booking_date >= today);
    const history = data.filter((b) => !activeStatuses.includes(b.status) || b.booking_date < today);

    const rowHtml = (b) => `
      <tr>
        <td>${window.dreamLook.booking.formatDate(b.booking_date)}</td>
        <td>${window.dreamLook.booking.formatTime12h(b.start_time)}</td>
        <td>${window.dreamLook.booking.formatServiceList(b)}</td>
        <td><span class="status-badge status-badge--${b.status}">${b.status.replace('_', ' ')}</span></td>
      </tr>
    `;

    upcomingBody.innerHTML = upcoming.length
      ? upcoming.map(rowHtml).join('')
      : '<tr class="table-empty-row"><td colspan="4">No upcoming bookings.</td></tr>';

    historyBody.innerHTML = history.length
      ? history.map(rowHtml).join('')
      : '<tr class="table-empty-row"><td colspan="4">No history yet.</td></tr>';
  }

  // =======================================================================
  // REPORTS
  // =======================================================================
  function wireReports() {
    const preset = document.getElementById('report-preset');
    preset.addEventListener('change', () => {
      const isCustom = preset.value === 'custom';
      document.getElementById('report-start-wrap').style.display = isCustom ? 'block' : 'none';
      document.getElementById('report-end-wrap').style.display = isCustom ? 'block' : 'none';
    });

    document.getElementById('run-report-btn').addEventListener('click', runReport);
  }

  function reportRange() {
    const preset = document.getElementById('report-preset').value;
    const today = new Date();
    const toStr = (d) => d.toISOString().slice(0, 10);

    if (preset === 'daily') return { start: toStr(today), end: toStr(today) };
    if (preset === 'weekly') {
      const start = new Date(today); start.setDate(start.getDate() - 6);
      return { start: toStr(start), end: toStr(today) };
    }
    if (preset === 'monthly') {
      const start = new Date(today); start.setDate(start.getDate() - 29);
      return { start: toStr(start), end: toStr(today) };
    }
    return {
      start: document.getElementById('report-start').value || toStr(today),
      end: document.getElementById('report-end').value || toStr(today),
    };
  }

  async function runReport() {
    const { start, end } = reportRange();

    const [revenueRes, popularRes] = await Promise.all([
      db().rpc('admin_revenue_report', { p_start: start, p_end: end }),
      db().rpc('admin_popular_services', { p_start: start, p_end: end }),
    ]);

    const revenueBody = document.getElementById('revenue-report-body');
    const popularBody = document.getElementById('popular-services-body');
    const summaryEl = document.getElementById('report-summary');

    if (revenueRes.error || !revenueRes.data) {
      revenueBody.innerHTML = '<tr class="table-empty-row"><td colspan="6">Could not load report.</td></tr>';
    } else {
      const rows = revenueRes.data;
      const totalRevenue = rows.reduce((sum, r) => sum + Number(r.revenue), 0);
      const totalBookings = rows.reduce((sum, r) => sum + Number(r.bookings_count), 0);
      const totalCompleted = rows.reduce((sum, r) => sum + Number(r.completed_count), 0);

      summaryEl.innerHTML = `
        <div class="stat-card"><div class="stat-card__label">Total Revenue</div><div class="stat-card__value stat-card__value--gold">₹${totalRevenue.toFixed(0)}</div></div>
        <div class="stat-card"><div class="stat-card__label">Total Bookings</div><div class="stat-card__value">${totalBookings}</div></div>
        <div class="stat-card"><div class="stat-card__label">Completed</div><div class="stat-card__value">${totalCompleted}</div></div>
      `;

      revenueBody.innerHTML = rows.length
        ? rows.map((r) => `
            <tr>
              <td>${window.dreamLook.booking.formatDate(r.report_date)}</td>
              <td>${r.bookings_count}</td>
              <td>${r.completed_count}</td>
              <td>${r.cancelled_count}</td>
              <td>${r.no_show_count}</td>
              <td>₹${Number(r.revenue).toFixed(0)}</td>
            </tr>
          `).join('')
        : '<tr class="table-empty-row"><td colspan="6">No data for this range.</td></tr>';
    }

    if (popularRes.error || !popularRes.data) {
      popularBody.innerHTML = '<tr class="table-empty-row"><td colspan="3">Could not load report.</td></tr>';
    } else {
      popularBody.innerHTML = popularRes.data.length
        ? popularRes.data.map((r) => `
            <tr>
              <td>${r.service_name}</td>
              <td>${r.bookings_count}</td>
              <td>₹${Number(r.revenue).toFixed(0)}</td>
            </tr>
          `).join('')
        : '<tr class="table-empty-row"><td colspan="3">No data for this range.</td></tr>';
    }
  }

  // =======================================================================
  // AUDIT LOG
  // =======================================================================
  function wireAuditFilters() {
    document.getElementById('run-audit-btn').addEventListener('click', runAuditFilter);
  }

  async function runAuditFilter() {
    const start = document.getElementById('audit-start').value;
    const end = document.getElementById('audit-end').value;
    const action = document.getElementById('audit-action').value;
    const tbody = document.getElementById('audit-table-body');

    let query = db().from('audit_logs').select('*').order('created_at', { ascending: false }).limit(200);

    if (start) query = query.gte('created_at', `${start}T00:00:00`);
    if (end) query = query.lte('created_at', `${end}T23:59:59`);
    if (action) query = query.eq('action', action);

    const { data, error } = await query;

    if (error) {
      tbody.innerHTML = '<tr class="table-empty-row"><td colspan="4">Could not load audit log.</td></tr>';
      return;
    }

    if (!data || data.length === 0) {
      tbody.innerHTML = '<tr class="table-empty-row"><td colspan="4">No matching entries.</td></tr>';
      return;
    }

    tbody.innerHTML = data.map((log) => `
      <tr>
        <td>${new Date(log.created_at).toLocaleString('en-IN')}</td>
        <td>${log.action.replace(/_/g, ' ')}</td>
        <td>${log.actor_role || '—'}</td>
        <td><code style="font-size:var(--fs-xs);">${JSON.stringify(log.details)}</code></td>
      </tr>
    `).join('');
  }

  // =======================================================================
  // REALTIME
  // =======================================================================
  function startRealtime() {
    subscribeForDate(todayStr());

    // Audit fix: a channel filtered on booking_date=eq.<today> would
    // silently go stale if an admin leaves the tab open past midnight.
    // Check every few minutes and re-subscribe against the new date.
    setInterval(() => {
      if (currentRealtimeDate !== todayStr()) {
        subscribeForDate(todayStr());
      }
    }, 5 * 60 * 1000);
  }

  let currentRealtimeDate = null;

  function subscribeForDate(dateStr) {
    window.dreamLook.booking.unsubscribe(bookingsRealtimeChannel);
    currentRealtimeDate = dateStr;

    // Admin's SELECT policy (bookings_select_admin) permits seeing every
    // row, so a Realtime subscription with no user filter delivers every
    // booking change for today — driving both the dashboard stat cards and
    // the queue table live, with no manual refresh.
    bookingsRealtimeChannel = db()
      .channel(`admin-bookings-${dateStr}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'bookings', filter: `booking_date=eq.${dateStr}` },
        debounce(async () => {
          if (loadedSections.has('dashboard')) await loadDashboard();
          if (loadedSections.has('queue')) await loadQueue();
        }, 350)
      )
      .subscribe();
  }

  function debounce(fn, wait) {
    let t;
    return (...args) => {
      clearTimeout(t);
      t = setTimeout(() => fn(...args), wait);
    };
  }
})();
