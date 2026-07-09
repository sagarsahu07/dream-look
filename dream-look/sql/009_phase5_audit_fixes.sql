-- =============================================================================
-- Dream Look — Migration 009: Phase 5 Audit Fixes
-- Run in Supabase → SQL Editor AFTER 008_multi_service_smart_allocation.sql.
-- All three fixes below are CREATE OR REPLACE against the EXACT signatures
-- already in place — no new overloads, no signature drift.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- BUG FIX 1 — is_barber_slot_free() was created in migration 008 without an
-- explicit REVOKE/GRANT. PostgreSQL grants EXECUTE on new functions to
-- PUBLIC by default, which is inconsistent with every other function in
-- this project (all explicitly locked down). The function only returns a
-- boolean (no row data), so the practical exposure was low, but it's
-- tightened here to match the project's least-privilege pattern.
-- -----------------------------------------------------------------------------
revoke all on function public.is_barber_slot_free(uuid, date, time, time, uuid) from public;
grant execute on function public.is_barber_slot_free(uuid, date, time, time, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- BUG FIX 2 — get_available_slots / create_booking rejected a service-id
-- array containing an accidental duplicate (e.g. [id1, id1]) even though
-- the duplicate was harmless — array_length() counted the duplicate,
-- but "count(*) from services where id = any(array)" naturally
-- deduplicates against the table, so the two numbers legitimately
-- disagreed and a valid request was rejected. Both functions now
-- deduplicate the input array first.
-- -----------------------------------------------------------------------------
create or replace function public.get_available_slots(
  p_service_ids uuid[],
  p_booking_date date,
  p_barber_id uuid default null
)
returns table(slot_time time)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_duration    int;
  v_settings    public.shop_settings;
  v_barber_id   uuid;
  v_slot        time;
  v_slot_end    time;
  v_ids         uuid[];
begin
  if p_service_ids is null or array_length(p_service_ids, 1) is null then
    raise exception 'Select at least one service.';
  end if;

  select array_agg(distinct x) into v_ids from unnest(p_service_ids) x;

  select * into v_settings from public.shop_settings where id = 1;

  select sum(duration_mins) into v_duration
  from public.services
  where id = any(v_ids) and is_active = true;

  if v_duration is null or v_duration <= 0 then
    raise exception 'Selected service(s) are unavailable.';
  end if;

  if (select count(*) from public.services where id = any(v_ids) and is_active = true) <> array_length(v_ids, 1) then
    raise exception 'One or more selected services are unavailable.';
  end if;

  if p_booking_date < current_date then
    return;
  end if;

  if extract(dow from p_booking_date)::int = any(v_settings.weekly_off) then
    return;
  end if;

  if exists (select 1 from public.shop_closed_dates where closed_date = p_booking_date) then
    return;
  end if;

  if p_barber_id is not null then
    v_barber_id := p_barber_id;
  else
    select b.id into v_barber_id
    from public.barbers b
    where b.is_active = true
    order by (
      select count(*) from public.bookings bk
      where bk.barber_id = b.id and bk.booking_date = p_booking_date
        and bk.status not in ('cancelled', 'no_show')
    ) asc, b.created_at asc
    limit 1;
  end if;

  if v_barber_id is null then
    raise exception 'No barber is available.';
  end if;

  v_slot := v_settings.opening_time;

  while v_slot + (v_duration || ' minutes')::interval <= v_settings.closing_time loop
    v_slot_end := (v_slot + ((v_duration + v_settings.buffer_minutes) || ' minutes')::interval)::time;

    if p_booking_date = current_date and (p_booking_date + v_slot)::timestamp <= now() then
      v_slot := (v_slot + (v_settings.slot_step_minutes || ' minutes')::interval)::time;
      continue;
    end if;

    if public.is_barber_slot_free(v_barber_id, p_booking_date, v_slot, v_slot_end) then
      slot_time := v_slot;
      return next;
    end if;

    v_slot := (v_slot + (v_settings.slot_step_minutes || ' minutes')::interval)::time;
  end loop;
end;
$$;

revoke all on function public.get_available_slots(uuid[], date, uuid) from public;
grant execute on function public.get_available_slots(uuid[], date, uuid) to authenticated;

create or replace function public.create_booking(
  p_service_ids uuid[],
  p_booking_date date,
  p_start_time time,
  p_notes text default null,
  p_barber_id uuid default null
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id       uuid := auth.uid();
  v_settings      public.shop_settings;
  v_duration      int;
  v_service_end   time;
  v_end_time      time;
  v_wait_mins     int;
  v_booking       public.bookings;
  v_candidate_barber uuid;
  v_candidate_time   time;
  v_found         boolean := false;
  v_attempts      int := 0;
  v_max_attempts  constant int := 40;
  v_service       record;
  v_ids           uuid[];
begin
  if v_user_id is null then
    raise exception 'You must be logged in to book an appointment.';
  end if;

  if p_service_ids is null or array_length(p_service_ids, 1) is null then
    raise exception 'Select at least one service.';
  end if;

  select array_agg(distinct x) into v_ids from unnest(p_service_ids) x;

  if p_booking_date is null or p_start_time is null then
    raise exception 'Date and time are required.';
  end if;

  select * into v_settings from public.shop_settings where id = 1;

  if p_booking_date < current_date then
    raise exception 'You cannot book a date in the past.';
  end if;

  if p_booking_date = current_date and (p_booking_date + p_start_time)::timestamp <= now() then
    raise exception 'You cannot book a time in the past.';
  end if;

  if extract(dow from p_booking_date)::int = any(v_settings.weekly_off) then
    raise exception 'The shop is closed on this day of the week. Please choose another date.';
  end if;

  if exists (select 1 from public.shop_closed_dates where closed_date = p_booking_date) then
    raise exception 'The shop is closed on this date. Please choose another date.';
  end if;

  if not v_settings.allow_multiple_bookings_per_day and exists (
    select 1 from public.bookings
    where user_id = v_user_id
      and booking_date = p_booking_date
      and status in ('pending', 'confirmed', 'arrived', 'in_service')
  ) then
    raise exception 'You already have an active booking on this date.';
  end if;

  if (select count(*) from public.services where id = any(v_ids) and is_active = true) <> array_length(v_ids, 1) then
    raise exception 'One or more selected services are unavailable.';
  end if;

  select sum(duration_mins) into v_duration
  from public.services
  where id = any(v_ids) and is_active = true;

  if p_start_time < v_settings.opening_time then
    raise exception 'Bookings start at %.', to_char(v_settings.opening_time, 'HH12:MI AM');
  end if;

  v_service_end := (p_start_time + (v_duration || ' minutes')::interval)::time;
  if v_service_end > v_settings.closing_time then
    raise exception 'This combination does not fit before closing time (%). Please choose fewer services or an earlier slot.',
      to_char(v_settings.closing_time, 'HH12:MI AM');
  end if;

  if p_barber_id is not null and not exists (select 1 from public.barbers where id = p_barber_id and is_active = true) then
    raise exception 'Selected barber is unavailable.';
  end if;

  v_candidate_time := p_start_time;

  <<time_search>>
  while v_candidate_time + (v_duration || ' minutes')::interval <= v_settings.closing_time loop
    v_end_time := (v_candidate_time + ((v_duration + v_settings.buffer_minutes) || ' minutes')::interval)::time;

    if not (p_booking_date = current_date and (p_booking_date + v_candidate_time)::timestamp <= now()) then

      if p_barber_id is not null then
        if public.is_barber_slot_free(p_barber_id, p_booking_date, v_candidate_time, v_end_time) then
          v_candidate_barber := p_barber_id;
          v_found := true;
          exit time_search;
        end if;
      else
        for v_service in
          select b.id
          from public.barbers b
          where b.is_active = true
          order by (
            select count(*) from public.bookings bk
            where bk.barber_id = b.id and bk.booking_date = p_booking_date
              and bk.status not in ('cancelled', 'no_show')
          ) asc, b.created_at asc
        loop
          if public.is_barber_slot_free(v_service.id, p_booking_date, v_candidate_time, v_end_time) then
            v_candidate_barber := v_service.id;
            v_found := true;
            exit time_search;
          end if;
        end loop;
      end if;
    end if;

    v_candidate_time := (v_candidate_time + (v_settings.slot_step_minutes || ' minutes')::interval)::time;
  end loop;

  if not v_found then
    raise exception 'Fully booked for the rest of today with this service combination. Please try another date.';
  end if;

  <<retry>>
  loop
    v_attempts := v_attempts + 1;
    if v_attempts > v_max_attempts then
      raise exception 'This time is extremely busy right now — please try booking again in a moment.';
    end if;

    begin
      v_wait_mins := greatest(0, floor(
        extract(epoch from ((p_booking_date + v_candidate_time)::timestamp - now())) / 60
      )::int);

      insert into public.bookings (
        user_id, service_id, barber_id, booking_date, start_time, end_time,
        status, notes, estimated_wait_mins
      )
      values (
        v_user_id, v_ids[1], v_candidate_barber, p_booking_date, v_candidate_time, v_end_time,
        'confirmed', nullif(trim(coalesce(p_notes, '')), ''), v_wait_mins
      )
      returning * into v_booking;

      exit retry;
    exception
      when exclusion_violation or unique_violation then
        v_candidate_time := (v_candidate_time + (v_settings.slot_step_minutes || ' minutes')::interval)::time;
        v_found := false;

        <<retry_search>>
        while v_candidate_time + (v_duration || ' minutes')::interval <= v_settings.closing_time loop
          v_end_time := (v_candidate_time + ((v_duration + v_settings.buffer_minutes) || ' minutes')::interval)::time;

          if p_barber_id is not null then
            if public.is_barber_slot_free(p_barber_id, p_booking_date, v_candidate_time, v_end_time) then
              v_candidate_barber := p_barber_id;
              v_found := true;
              exit retry_search;
            end if;
          else
            for v_service in
              select b.id from public.barbers b where b.is_active = true
              order by (
                select count(*) from public.bookings bk
                where bk.barber_id = b.id and bk.booking_date = p_booking_date and bk.status not in ('cancelled', 'no_show')
              ) asc, b.created_at asc
            loop
              if public.is_barber_slot_free(v_service.id, p_booking_date, v_candidate_time, v_end_time) then
                v_candidate_barber := v_service.id;
                v_found := true;
                exit retry_search;
              end if;
            end loop;
          end if;

          v_candidate_time := (v_candidate_time + (v_settings.slot_step_minutes || ' minutes')::interval)::time;
        end loop;

        if not v_found then
          raise exception 'Fully booked for the rest of today with this service combination. Please try another date.';
        end if;
    end;
  end loop;

  insert into public.booking_services (booking_id, service_id, price, duration_mins)
  select v_booking.id, s.id, s.price, s.duration_mins
  from public.services s
  where s.id = any(v_ids);

  select * into v_booking from public.bookings where id = v_booking.id;

  perform public.log_audit('booking_created', v_booking.id, jsonb_build_object(
    'booking_date', v_booking.booking_date,
    'start_time', v_booking.start_time,
    'barber_id', v_booking.barber_id,
    'requested_time', p_start_time,
    'was_reassigned', (v_booking.start_time <> p_start_time or v_booking.barber_id <> coalesce(p_barber_id, v_booking.barber_id)),
    'service_count', array_length(v_ids, 1)
  ));

  return v_booking;
end;
$$;

revoke all on function public.create_booking(uuid[], date, time, text, uuid) from public;
grant execute on function public.create_booking(uuid[], date, time, text, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- BUG FIX 3 — create_payment_record used `if v_amount = 0` to decide
-- whether to fall back to the single-service price (for bookings made
-- before booking_services existed). That fallback would incorrectly
-- fire for a LEGITIMATELY free (₹0) multi-service combination too,
-- overwriting a correct ₹0 total with an unrelated stale price. The
-- check is now based on whether any booking_services rows exist at all,
-- not on the computed amount.
-- -----------------------------------------------------------------------------
create or replace function public.create_payment_record(
  p_booking_id uuid,
  p_method public.payment_method
)
returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_booking  public.bookings;
  v_amount   numeric(10,2);
  v_has_rows boolean;
  v_txn_id   text;
  v_payment  public.payments;
begin
  if v_user_id is null then
    raise exception 'You must be logged in to pay for a booking.';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id;

  if v_booking.id is null then
    raise exception 'Booking not found.';
  end if;

  if v_booking.user_id is distinct from v_user_id and not public.is_admin() then
    raise exception 'You can only pay for your own booking.';
  end if;

  select exists(select 1 from public.booking_services where booking_id = p_booking_id) into v_has_rows;

  if v_has_rows then
    select coalesce(sum(price), 0) into v_amount from public.booking_services where booking_id = p_booking_id;
  else
    -- No booking_services rows at all (only possible for a booking that
    -- somehow predates migration 008's backfill) — fall back to the
    -- single primary service's price.
    select price into v_amount from public.services where id = v_booking.service_id;
  end if;

  v_txn_id := 'DL' || to_char(now(), 'YYYYMMDDHH24MISS') || upper(substr(md5(random()::text), 1, 6));

  select * into v_payment from public.payments where booking_id = p_booking_id;

  if v_payment.id is not null then
    if v_payment.status = 'paid' then
      raise exception 'This booking has already been paid for.';
    end if;

    update public.payments
    set method = p_method, transaction_id = v_txn_id, status = 'pending', amount = v_amount
    where id = v_payment.id
    returning * into v_payment;
  else
    insert into public.payments (booking_id, user_id, amount, status, method, transaction_id)
    values (p_booking_id, v_booking.user_id, v_amount, 'pending', p_method, v_txn_id)
    returning * into v_payment;
  end if;

  perform public.log_audit('payment_initiated', p_booking_id, jsonb_build_object(
    'method', p_method, 'transaction_id', v_txn_id, 'amount', v_amount
  ));

  return v_payment;
end;
$$;

-- =============================================================================
-- End of Migration 009.
-- =============================================================================
