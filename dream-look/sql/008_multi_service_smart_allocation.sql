-- =============================================================================
-- Dream Look — Migration 008: Multi-Service Bookings + Smart Slot Allocation
-- Run in Supabase → SQL Editor AFTER 007_fix_function_overloads.sql.
--
-- Two functions change PARAMETER or RETURN shape (get_available_slots,
-- create_booking go from a single service_id to a service_id ARRAY;
-- get_booking_receipt gains new return columns). CREATE OR REPLACE cannot
-- change a function's signature/return shape, and migration 007 already
-- taught us what happens if an old-signature version is left behind
-- (PostgREST can no longer tell which one to call). So this file explicitly
-- DROPs those three exact old signatures first, then creates the new ones.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. booking_services — one row per service selected in a booking.
--    bookings.service_id is kept and still set to the FIRST selected
--    service, so every existing query/report that reads
--    bookings.service_id -> services(name) keeps working unmodified for a
--    quick "primary service" label; booking_services is the source of
--    truth for the FULL list, total price, and total duration.
-- -----------------------------------------------------------------------------
create table if not exists public.booking_services (
  id            uuid primary key default gen_random_uuid(),
  booking_id    uuid not null references public.bookings(id) on delete cascade,
  service_id    uuid not null references public.services(id) on delete restrict,
  price         numeric(10, 2) not null,
  duration_mins integer not null,
  created_at    timestamptz not null default now(),

  constraint unique_service_per_booking unique (booking_id, service_id)
);

comment on table public.booking_services is 'Every service selected in a booking, with price/duration SNAPSHOT at booking time (protects history if a service''s price changes later).';

create index if not exists idx_booking_services_booking_id on public.booking_services(booking_id);

alter table public.booking_services enable row level security;

drop policy if exists "booking_services_select_own" on public.booking_services;
create policy "booking_services_select_own"
  on public.booking_services for select
  using (
    exists (
      select 1 from public.bookings b
      where b.id = booking_services.booking_id
        and (b.user_id = auth.uid() or public.is_admin())
    )
  );

-- No client INSERT/UPDATE/DELETE policy — rows are written exclusively by
-- create_booking() below (SECURITY DEFINER), same pattern as bookings itself.

-- -----------------------------------------------------------------------------
-- 2. Drop the signatures being replaced with a different shape.
-- -----------------------------------------------------------------------------
drop function if exists public.get_available_slots(uuid, date, uuid);
drop function if exists public.create_booking(uuid, date, time, text, uuid);
drop function if exists public.get_booking_receipt(uuid);

-- -----------------------------------------------------------------------------
-- 3. get_available_slots — now takes an ARRAY of service ids and sizes each
--    candidate slot by their COMBINED duration (buffer still applied once,
--    after the whole multi-service session, not once per service).
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
begin
  if p_service_ids is null or array_length(p_service_ids, 1) is null then
    raise exception 'Select at least one service.';
  end if;

  select * into v_settings from public.shop_settings where id = 1;

  select sum(duration_mins) into v_duration
  from public.services
  where id = any(p_service_ids) and is_active = true;

  if v_duration is null or v_duration <= 0 then
    raise exception 'Selected service(s) are unavailable.';
  end if;

  if (select count(*) from public.services where id = any(p_service_ids) and is_active = true) <> array_length(p_service_ids, 1) then
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

    if not exists (
      select 1
      from public.bookings b
      where b.booking_date = p_booking_date
        and b.barber_id = v_barber_id
        and b.status not in ('cancelled', 'no_show')
        and tsrange(
              (b.booking_date + b.start_time)::timestamp,
              (b.booking_date + b.end_time)::timestamp, '[)'
            )
            && tsrange(
              (p_booking_date + v_slot)::timestamp,
              (p_booking_date + v_slot_end)::timestamp, '[)'
            )
    ) then
      slot_time := v_slot;
      return next;
    end if;

    v_slot := (v_slot + (v_settings.slot_step_minutes || ' minutes')::interval)::time;
  end loop;
end;
$$;

revoke all on function public.get_available_slots(uuid[], date, uuid) from public;
grant execute on function public.get_available_slots(uuid[], date, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. is_barber_slot_free — small helper used by both the direct check and
--    the smart-reassignment search loop below, so the overlap logic exists
--    in exactly one place.
-- -----------------------------------------------------------------------------
create or replace function public.is_barber_slot_free(
  p_barber_id uuid,
  p_booking_date date,
  p_start_time time,
  p_end_time time,
  p_exclude_booking_id uuid default null
)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select not exists (
    select 1
    from public.bookings b
    where b.booking_date = p_booking_date
      and b.barber_id = p_barber_id
      and b.status not in ('cancelled', 'no_show')
      and (p_exclude_booking_id is null or b.id <> p_exclude_booking_id)
      and tsrange(
            (b.booking_date + b.start_time)::timestamp,
            (b.booking_date + b.end_time)::timestamp, '[)'
          )
          && tsrange(
            (p_booking_date + p_start_time)::timestamp,
            (p_booking_date + p_end_time)::timestamp, '[)'
          )
  );
$$;

-- -----------------------------------------------------------------------------
-- 5. create_booking — Smart Queue & Slot Allocation.
--    Accepts one or more services. Tries the requested barber/time first;
--    if that exact combination is unavailable (or is taken out from under
--    it by a genuine concurrent race — caught via the EXCLUDE constraint,
--    not just a pre-check), it automatically searches every active barber
--    at the requested time, then the same barbers at progressively later
--    time steps, until it finds and successfully claims an open slot.
--    The EXCLUDE constraint (not this search) is what actually guarantees
--    no two concurrent callers can ever both win the same slot — the
--    search only picks a CANDIDATE; the retry loop is what makes it safe
--    under real concurrency.
-- -----------------------------------------------------------------------------
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
begin
  if v_user_id is null then
    raise exception 'You must be logged in to book an appointment.';
  end if;

  if p_service_ids is null or array_length(p_service_ids, 1) is null then
    raise exception 'Select at least one service.';
  end if;

  if p_booking_date is null or p_start_time is null then
    raise exception 'Date and time are required.';
  end if;

  select * into v_settings from public.shop_settings where id = 1;

  -- Past-date/time protection — compared against the server clock, so a
  -- tampered client can never bypass it (frontend disabling is a courtesy,
  -- this is the actual guarantee).
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

  if (select count(*) from public.services where id = any(p_service_ids) and is_active = true) <> array_length(p_service_ids, 1) then
    raise exception 'One or more selected services are unavailable.';
  end if;

  select sum(duration_mins) into v_duration
  from public.services
  where id = any(p_service_ids) and is_active = true;

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

  -- ---- Smart allocation search --------------------------------------------
  v_candidate_time := p_start_time;

  <<time_search>>
  while v_candidate_time + (v_duration || ' minutes')::interval <= v_settings.closing_time loop
    v_end_time := (v_candidate_time + ((v_duration + v_settings.buffer_minutes) || ' minutes')::interval)::time;

    -- Skip past times if we've searched forward into "today" edge cases.
    if not (p_booking_date = current_date and (p_booking_date + v_candidate_time)::timestamp <= now()) then

      if p_barber_id is not null then
        -- A specific barber was requested — only ever consider that barber.
        if public.is_barber_slot_free(p_barber_id, p_booking_date, v_candidate_time, v_end_time) then
          v_candidate_barber := p_barber_id;
          v_found := true;
          exit time_search;
        end if;
      else
        -- No specific barber requested — try every active barber at this
        -- time, least-busy first, before advancing to the next time step.
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

  -- ---- Claim the slot, with a bounded retry against real concurrency -----
  -- is_barber_slot_free() above is only a CANDIDATE check — another request
  -- could still commit an overlapping booking between that check and this
  -- INSERT. The EXCLUDE constraint on public.bookings is the actual
  -- guarantee: it will reject the INSERT (exclusion_violation) if that
  -- happens, and we simply search again from just past the failed time.
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
        v_user_id, p_service_ids[1], v_candidate_barber, p_booking_date, v_candidate_time, v_end_time,
        'confirmed', nullif(trim(coalesce(p_notes, '')), ''), v_wait_mins
      )
      returning * into v_booking;

      exit retry; -- success
    exception
      when exclusion_violation or unique_violation then
        -- Someone else just took this exact barber+time. Advance one slot
        -- step and search again (still respecting a requested barber, if any).
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

  -- Snapshot every selected service's price/duration for this booking.
  insert into public.booking_services (booking_id, service_id, price, duration_mins)
  select v_booking.id, s.id, s.price, s.duration_mins
  from public.services s
  where s.id = any(p_service_ids);

  select * into v_booking from public.bookings where id = v_booking.id;

  perform public.log_audit('booking_created', v_booking.id, jsonb_build_object(
    'booking_date', v_booking.booking_date,
    'start_time', v_booking.start_time,
    'barber_id', v_booking.barber_id,
    'requested_time', p_start_time,
    'was_reassigned', (v_booking.start_time <> p_start_time or v_booking.barber_id <> coalesce(p_barber_id, v_booking.barber_id)),
    'service_count', array_length(p_service_ids, 1)
  ));

  return v_booking;
end;
$$;

revoke all on function public.create_booking(uuid[], date, time, text, uuid) from public;
grant execute on function public.create_booking(uuid[], date, time, text, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 6. reschedule_booking — same signature (no overload risk), body updated
--    to size the slot from the booking's full multi-service total duration
--    instead of a single service.
-- -----------------------------------------------------------------------------
create or replace function public.reschedule_booking(
  p_booking_id uuid,
  p_new_date date,
  p_new_start_time time
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id      uuid := auth.uid();
  v_settings     public.shop_settings;
  v_barber_id    uuid;
  v_old_date     date;
  v_duration     int;
  v_service_end  time;
  v_end_time     time;
  v_wait_mins    int;
  v_booking      public.bookings;
begin
  if v_user_id is null then
    raise exception 'You must be logged in to reschedule a booking.';
  end if;

  select barber_id, booking_date into v_barber_id, v_old_date
  from public.bookings
  where id = p_booking_id and user_id = v_user_id and status in ('pending', 'confirmed');

  if v_barber_id is null then
    raise exception 'Booking not found, or it can no longer be rescheduled.';
  end if;

  select coalesce(sum(duration_mins), 0) into v_duration
  from public.booking_services
  where booking_id = p_booking_id;

  if v_duration = 0 then
    raise exception 'Could not determine this booking''s service duration.';
  end if;

  select * into v_settings from public.shop_settings where id = 1;

  if p_new_date < current_date then
    raise exception 'You cannot reschedule to a date in the past.';
  end if;

  if p_new_date = current_date and (p_new_date + p_new_start_time)::timestamp <= now() then
    raise exception 'You cannot reschedule to a time in the past.';
  end if;

  if extract(dow from p_new_date)::int = any(v_settings.weekly_off) then
    raise exception 'The shop is closed on this day of the week. Please choose another date.';
  end if;

  if exists (select 1 from public.shop_closed_dates where closed_date = p_new_date) then
    raise exception 'The shop is closed on this date. Please choose another date.';
  end if;

  if p_new_date <> v_old_date and not v_settings.allow_multiple_bookings_per_day and exists (
    select 1 from public.bookings
    where user_id = v_user_id
      and booking_date = p_new_date
      and id <> p_booking_id
      and status in ('pending', 'confirmed', 'arrived', 'in_service')
  ) then
    raise exception 'You already have an active booking on this date.';
  end if;

  if p_new_start_time < v_settings.opening_time then
    raise exception 'Bookings start at %.', to_char(v_settings.opening_time, 'HH12:MI AM');
  end if;

  v_service_end := (p_new_start_time + (v_duration || ' minutes')::interval)::time;
  if v_service_end > v_settings.closing_time then
    raise exception 'This booking does not fit before closing time (%). Please choose an earlier slot.',
      to_char(v_settings.closing_time, 'HH12:MI AM');
  end if;

  v_end_time := (p_new_start_time + ((v_duration + v_settings.buffer_minutes) || ' minutes')::interval)::time;

  if not public.is_barber_slot_free(v_barber_id, p_new_date, p_new_start_time, v_end_time, p_booking_id) then
    raise exception 'This slot was just taken. Please choose another time.';
  end if;

  v_wait_mins := greatest(0, floor(
    extract(epoch from ((p_new_date + p_new_start_time)::timestamp - now())) / 60
  )::int);

  update public.bookings
  set booking_date = p_new_date,
      start_time = p_new_start_time,
      end_time = v_end_time,
      estimated_wait_mins = v_wait_mins
  where id = p_booking_id
  returning * into v_booking;

  perform public.log_audit('booking_rescheduled', v_booking.id, jsonb_build_object(
    'from_date', v_old_date, 'to_date', p_new_date, 'to_start_time', p_new_start_time
  ));

  return v_booking;
exception
  when exclusion_violation or unique_violation then
    raise exception 'This slot was just taken. Please choose another time.';
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. create_payment_record — amount now comes from the SUM of every
--    service on the booking (booking_services), not a single service price.
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

  select coalesce(sum(price), 0) into v_amount
  from public.booking_services
  where booking_id = p_booking_id;

  if v_amount = 0 then
    -- Fallback for any pre-migration-008 booking that never got a
    -- booking_services row backfilled.
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

-- -----------------------------------------------------------------------------
-- 8. get_booking_receipt — now returns every selected service as a JSON
--    array (services_json) plus a comma-joined label (service_name) so
--    older display code that only ever printed one string still shows
--    something sensible.
-- -----------------------------------------------------------------------------
create or replace function public.get_booking_receipt(p_booking_id uuid)
returns table (
  booking_id            uuid,
  booking_date          date,
  start_time            time,
  end_time              time,
  status                text,
  queue_number          integer,
  estimated_wait_mins   integer,
  customer_name         text,
  customer_email        text,
  service_name          text,
  services_json         jsonb,
  barber_name           text,
  payment_status        text,
  payment_method        text,
  transaction_id        text,
  amount                numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'You must be logged in to view this receipt.';
  end if;

  return query
  select
    b.id,
    b.booking_date,
    b.start_time,
    b.end_time,
    b.status::text,
    b.queue_number,
    b.estimated_wait_mins,
    coalesce(u.full_name, b.walk_in_name),
    u.email,
    coalesce(
      (select string_agg(s2.name, ', ' order by s2.name) from public.booking_services bs2 join public.services s2 on s2.id = bs2.service_id where bs2.booking_id = b.id),
      s.name
    ),
    coalesce(
      (select jsonb_agg(jsonb_build_object('name', s3.name, 'price', bs3.price, 'duration_mins', bs3.duration_mins) order by s3.name)
       from public.booking_services bs3 join public.services s3 on s3.id = bs3.service_id where bs3.booking_id = b.id),
      jsonb_build_array(jsonb_build_object('name', s.name, 'price', s.price, 'duration_mins', s.duration_mins))
    ),
    br.full_name,
    p.status::text,
    p.method::text,
    p.transaction_id,
    p.amount
  from public.bookings b
  join public.services s on s.id = b.service_id
  left join public.barbers br on br.id = b.barber_id
  left join public.users u on u.id = b.user_id
  left join public.payments p on p.booking_id = b.id
  where b.id = p_booking_id
    and (b.user_id = v_user_id or public.is_admin());
end;
$$;

revoke all on function public.get_booking_receipt(uuid) from public;
grant execute on function public.get_booking_receipt(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 9. admin_popular_services — count/revenue now sourced from
--    booking_services, so a multi-service booking correctly contributes to
--    EVERY service it included, not just the first one.
-- -----------------------------------------------------------------------------
create or replace function public.admin_popular_services(p_start date, p_end date)
returns table (
  service_id      uuid,
  service_name    text,
  bookings_count  bigint,
  revenue         numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only an admin can view reports.';
  end if;

  return query
  select
    s.id,
    s.name,
    count(bs.id),
    coalesce(sum(bs.price) filter (
      where exists (
        select 1 from public.payments p
        where p.booking_id = bs.booking_id and p.status = 'paid'
      )
    ), 0)
  from public.services s
  left join public.booking_services bs on bs.service_id = s.id
  left join public.bookings b
    on b.id = bs.booking_id
    and b.booking_date between p_start and p_end
    and b.status not in ('cancelled')
  where bs.booking_id is null or b.id is not null
  group by s.id, s.name
  order by count(bs.id) desc, s.name asc;
end;
$$;

-- -----------------------------------------------------------------------------
-- 10. Backfill booking_services for any booking created before this
--     migration, so historical receipts/reports don't show blank services.
-- -----------------------------------------------------------------------------
insert into public.booking_services (booking_id, service_id, price, duration_mins)
select b.id, b.service_id, s.price, s.duration_mins
from public.bookings b
join public.services s on s.id = b.service_id
where not exists (select 1 from public.booking_services bs where bs.booking_id = b.id);

-- =============================================================================
-- End of Migration 008.
-- =============================================================================
