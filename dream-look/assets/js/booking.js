/**
 * Dream Look — Booking Module
 * -----------------------------------------------------------------------
 * Thin wrapper around the booking-engine RPCs defined in
 * sql/002_booking_engine.sql, plus small formatting helpers shared by
 * book-slot.js and dashboard.js. Load AFTER auth.js.
 * -----------------------------------------------------------------------
 */

window.dreamLook = window.dreamLook || {};

window.dreamLook.booking = (function bookingModule() {
  function client() {
    return window.dreamLook.supabase;
  }

  /** All active services, cheapest-duration-first is not assumed — natural id order. */
  async function fetchActiveServices() {
    return client()
      .from('services')
      .select('id, name, description, price, duration_mins')
      .eq('is_active', true)
      .order('price', { ascending: true });
  }

  /** Dates the shop is closed (public holidays etc), used to disable the date picker. */
  async function fetchClosedDates() {
    return client().from('shop_closed_dates').select('closed_date, reason');
  }

  /**
   * Open start times for a COMBINATION of services on a date — already
   * excluding shop-hours edges, closed dates, past times and every
   * existing occupied window (combined duration + buffer).
   */
  async function fetchAvailableSlots(serviceIds, dateStr, barberId) {
    return client().rpc('get_available_slots', {
      p_service_ids: serviceIds,
      p_booking_date: dateStr,
      p_barber_id: barberId || null,
    });
  }

  async function createBooking({ serviceIds, date, startTime, notes, barberId }) {
    return client().rpc('create_booking', {
      p_service_ids: serviceIds,
      p_booking_date: date,
      p_start_time: startTime,
      p_notes: notes || null,
      p_barber_id: barberId || null,
    });
  }

  async function cancelBooking(bookingId) {
    return client().rpc('cancel_booking', { p_booking_id: bookingId });
  }

  async function rescheduleBooking(bookingId, newDate, newStartTime) {
    return client().rpc('reschedule_booking', {
      p_booking_id: bookingId,
      p_new_date: newDate,
      p_new_start_time: newStartTime,
    });
  }

  /** A user's own bookings, most recent date first, with every selected service. */
  async function fetchMyBookings(userId) {
    return client()
      .from('bookings')
      .select('id, booking_date, start_time, end_time, status, queue_number, estimated_wait_mins, notes, services(id, name, price, duration_mins), booking_services(price, duration_mins, services(name))')
      .eq('user_id', userId)
      .order('booking_date', { ascending: false })
      .order('start_time', { ascending: false });
  }

  /** ['Haircut','Beard'] -> "Haircut + Beard"; falls back to the primary service if booking_services is empty (pre-migration-008 rows). */
  function formatServiceList(booking) {
    if (booking.booking_services && booking.booking_services.length > 0) {
      return booking.booking_services.map((bs) => bs.services?.name).filter(Boolean).join(' + ');
    }
    return booking.services ? booking.services.name : 'Service';
  }

  /** Total price for a booking from its full service list (falls back to the primary service). */
  function totalPrice(booking) {
    if (booking.booking_services && booking.booking_services.length > 0) {
      return booking.booking_services.reduce((sum, bs) => sum + Number(bs.price), 0);
    }
    return booking.services ? Number(booking.services.price) : 0;
  }

  /** '14:30:00' -> '2:30 PM' */
  function formatTime12h(timeStr) {
    if (!timeStr) return '';
    const [h, m] = timeStr.split(':').map(Number);
    const period = h >= 12 ? 'PM' : 'AM';
    const hour12 = h % 12 === 0 ? 12 : h % 12;
    return `${hour12}:${String(m).padStart(2, '0')} ${period}`;
  }

  /** 'YYYY-MM-DD' -> '3 Jul 2026' */
  function formatDate(dateStr) {
    if (!dateStr) return '';
    return new Date(`${dateStr}T00:00:00`).toLocaleDateString('en-IN', {
      day: 'numeric',
      month: 'short',
      year: 'numeric',
    });
  }

  /**
   * Live estimated wait, recalculated against the current clock rather than
   * the stored snapshot, so it stays accurate as time passes.
   * Returns 0 once the slot has arrived/passed.
   */
  function computeLiveWaitMins(dateStr, startTimeStr) {
    const target = new Date(`${dateStr}T${startTimeStr}`);
    const diffMs = target.getTime() - Date.now();
    return Math.max(0, Math.round(diffMs / 60000));
  }

  /** Human-friendly "45 min" / "1h 15m" formatter. */
  function formatWait(mins) {
    if (mins <= 0) return 'Now';
    if (mins < 60) return `${mins} min`;
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return m === 0 ? `${h}h` : `${h}h ${m}m`;
  }

  /** Today's date as 'YYYY-MM-DD' in the browser's local timezone. */
  function todayStr() {
    const now = new Date();
    const offset = now.getTimezoneOffset();
    const local = new Date(now.getTime() - offset * 60000);
    return local.toISOString().slice(0, 10);
  }

  /**
   * Admin-configurable shop rules: hours, buffer, weekly off days, grace
   * period, multi-booking policy. Read-only for customers (RLS enforces
   * that only an admin can write to this table).
   */
  async function fetchShopSettings() {
    return client().from('shop_settings').select('*').eq('id', 1).single();
  }

  /**
   * Live Slot Refresh: RLS correctly hides other customers' booking rows,
   * so we cannot subscribe to the bookings table directly to detect their
   * activity. Instead we subscribe to the non-sensitive slot_pings table,
   * which is touched (date + barber only, no personal data) on every
   * booking write, and re-fetch availability whenever it changes.
   * Returns the channel — pass it to unsubscribe() when the date/service
   * changes or the page unloads.
   */
  function subscribeToSlotPings(dateStr, onChange) {
    return client()
      .channel(`slot-pings-${dateStr}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'slot_pings', filter: `booking_date=eq.${dateStr}` },
        onChange
      )
      .subscribe();
  }

  /**
   * Real-time Queue: subscribes to changes on the current user's OWN
   * booking rows. When an admin marks someone else's earlier booking
   * completed/no-show, the queue-sync trigger updates every remaining
   * booking's queue_number that day — including this user's row — which
   * fires this subscription (RLS scopes it to their own rows automatically).
   */
  function subscribeToMyBookings(userId, onChange) {
    return client()
      .channel(`my-bookings-${userId}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'bookings', filter: `user_id=eq.${userId}` },
        onChange
      )
      .subscribe();
  }

  function unsubscribe(channel) {
    if (channel) client().removeChannel(channel);
  }

  return {
    fetchActiveServices,
    fetchClosedDates,
    fetchAvailableSlots,
    createBooking,
    cancelBooking,
    rescheduleBooking,
    fetchMyBookings,
    formatServiceList,
    totalPrice,
    fetchShopSettings,
    subscribeToSlotPings,
    subscribeToMyBookings,
    unsubscribe,
    formatTime12h,
    formatDate,
    computeLiveWaitMins,
    formatWait,
    todayStr,
  };
})();
