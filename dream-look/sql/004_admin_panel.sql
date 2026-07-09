-- =============================================================================
-- Dream Look — Migration 004: Admin Panel Backend (Phase 3)
--
-- Run in order:
--   1. sql/003_advanced_booking_features.sql
--   2. sql/004a_add_enum_arrived_in_service.sql  (adds 'arrived'/'in_service' —
--      MUST be its own file/transaction, same reason as 003a)
--   3. sql/004_admin_panel.sql (this file)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Walk-in customer support
--    A walk-in has no auth.users account, so bookings.user_id must become
--    nullable. walk_in_name/phone hold their details instead. The check
--    constraint guarantees every row is unambiguously either a logged-in
--    customer's booking or a walk-in's — never a row missing both.
-- -----------------------------------------------------------------------------
alter table public.bookings alter column user_id drop not null;
alter table public.bookings add column if not exists is_walk_in boolean not null default false;
alter table public.bookings add column if not exists walk_in_name text;
alter table public.bookings add column if not exists walk_in_phone text;

alter table public.bookings drop constraint if exists bookings_walkin_consistency;
alter table public.bookings
  add constraint bookings_walkin_consistency
  check (
    (is_walk_in = true  and user_id is null     and walk_in_name is not null)
    or
    (is_walk_in = false and user_id is not null and walk_in_name is null)
  );

create index if not exists idx_bookings_is_walk_in on public.bookings(is_walk_in);

-- -----------------------------------------------------------------------------
-- 2. recompute_queue_for_date — now includes the full in-shop lifecycle
--    (pending, confirmed, arrived, in_service) as "in the queue"; only
--    completed/cancelled/no_show fall out of numbering.
-- -----------------------------------------------------------------------------
create or replace function public.recompute_queue_for_date(p_date date)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.bookings b
  set queue_number = sub.rn
  from (
    select id, row_number() over (order by start_time asc, created_at asc) as rn
    from public.bookings
    where booking_date = p_date and status in ('pending', 'confirmed', 'arrived', 'in_service')
  ) sub
  where b.id = sub.id and b.queue_number is distinct from sub.rn;

  update public.bookings
  set queue_number = null
  where booking_date = p_date
    and status not in ('pending', 'confirmed', 'arrived', 'in_service')
    and queue_number is not null;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. get_available_slots / create_booking / reschedule_booking — the set of
--    statuses that "occupy" a physical time slot now also covers arrived
--    and in_service (a customer who has checked in is still sitting in
--    that slot). Only cancelled/no_show free up the time.
-- -----------------------------------------------------------------------------
create or replace function public.get_available_slots(
  p_service_id uuid,
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
  select * into v_settings from public.shop_settings where id = 1;

  select duration_mins into v_duration
  from public.services
  where id = p_service_id and is_active = true;

  if v_duration is null then
    raise exception 'Selected service is unavailable.';
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

create or replace function public.create_booking(
  p_service_id uuid,
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
  v_user_id      uuid := auth.uid();
  v_settings     public.shop_settings;
  v_duration     int;
  v_service_end  time;
  v_end_time     time;
  v_wait_mins    int;
  v_barber_id    uuid;
  v_booking      public.bookings;
begin
  if v_user_id is null then
    raise exception 'You must be logged in to book an appointment.';
  end if;

  if p_service_id is null or p_booking_date is null or p_start_time is null then
    raise exception 'Service, date and time are all required.';
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

  select duration_mins into v_duration
  from public.services
  where id = p_service_id and is_active = true;

  if v_duration is null then
    raise exception 'Selected service is unavailable.';
  end if;

  if p_start_time < v_settings.opening_time then
    raise exception 'Bookings start at %.', to_char(v_settings.opening_time, 'HH12:MI AM');
  end if;

  v_service_end := (p_start_time + (v_duration || ' minutes')::interval)::time;
  if v_service_end > v_settings.closing_time then
    raise exception 'This service does not fit before closing time (%). Please choose an earlier slot.',
      to_char(v_settings.closing_time, 'HH12:MI AM');
  end if;

  if p_barber_id is not null then
    if not exists (select 1 from public.barbers where id = p_barber_id and is_active = true) then
      raise exception 'Selected barber is unavailable.';
    end if;
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
    raise exception 'No barber is available to take this booking.';
  end if;

  v_end_time := (p_start_time + ((v_duration + v_settings.buffer_minutes) || ' minutes')::interval)::time;

  if exists (
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
            (p_booking_date + p_start_time)::timestamp,
            (p_booking_date + v_end_time)::timestamp, '[)'
          )
  ) then
    raise exception 'This slot was just taken. Please choose another time.';
  end if;

  v_wait_mins := greatest(0, floor(
    extract(epoch from ((p_booking_date + p_start_time)::timestamp - now())) / 60
  )::int);

  insert into public.bookings (
    user_id, service_id, barber_id, booking_date, start_time, end_time,
    status, notes, estimated_wait_mins
  )
  values (
    v_user_id, p_service_id, v_barber_id, p_booking_date, p_start_time, v_end_time,
    'confirmed', nullif(trim(coalesce(p_notes, '')), ''), v_wait_mins
  )
  returning * into v_booking;

  select * into v_booking from public.bookings where id = v_booking.id;

  perform public.log_audit('booking_created', v_booking.id, jsonb_build_object(
    'booking_date', v_booking.booking_date, 'start_time', v_booking.start_time, 'barber_id', v_barber_id
  ));

  return v_booking;
exception
  when exclusion_violation or unique_violation then
    raise exception 'This slot was just taken. Please choose another time.';
end;
$$;

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
  v_service_id   uuid;
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

  select service_id, barber_id, booking_date into v_service_id, v_barber_id, v_old_date
  from public.bookings
  where id = p_booking_id and user_id = v_user_id and status in ('pending', 'confirmed');

  if v_service_id is null then
    raise exception 'Booking not found, or it can no longer be rescheduled.';
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

  select duration_mins into v_duration from public.services where id = v_service_id;

  if p_new_start_time < v_settings.opening_time then
    raise exception 'Bookings start at %.', to_char(v_settings.opening_time, 'HH12:MI AM');
  end if;

  v_service_end := (p_new_start_time + (v_duration || ' minutes')::interval)::time;
  if v_service_end > v_settings.closing_time then
    raise exception 'This service does not fit before closing time (%). Please choose an earlier slot.',
      to_char(v_settings.closing_time, 'HH12:MI AM');
  end if;

  v_end_time := (p_new_start_time + ((v_duration + v_settings.buffer_minutes) || ' minutes')::interval)::time;

  if exists (
    select 1
    from public.bookings b
    where b.booking_date = p_new_date
      and b.barber_id = v_barber_id
      and b.id <> p_booking_id
      and b.status not in ('cancelled', 'no_show')
      and tsrange(
            (b.booking_date + b.start_time)::timestamp,
            (b.booking_date + b.end_time)::timestamp, '[)'
          )
          && tsrange(
            (p_new_date + p_new_start_time)::timestamp,
            (p_new_date + v_end_time)::timestamp, '[)'
          )
  ) then
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
-- 4. Queue lifecycle actions (admin-only, all audit-logged, all feed the
--    same queue-sync trigger so every remaining booking's position updates
--    automatically and reaches customers/admins live via Realtime).
-- -----------------------------------------------------------------------------
create or replace function public.mark_arrived(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can update queue status.';
  end if;

  update public.bookings
  set status = 'arrived'
  where id = p_booking_id and status in ('pending', 'confirmed')
  returning * into v_booking;

  if v_booking.id is null then
    raise exception 'Booking not found, or it is not awaiting arrival.';
  end if;

  perform public.log_audit('booking_arrived', v_booking.id, '{}'::jsonb);
  return v_booking;
end;
$$;

create or replace function public.mark_in_service(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can update queue status.';
  end if;

  update public.bookings
  set status = 'in_service'
  where id = p_booking_id and status = 'arrived'
  returning * into v_booking;

  if v_booking.id is null then
    raise exception 'Booking not found, or the customer has not checked in yet.';
  end if;

  perform public.log_audit('booking_in_service', v_booking.id, '{}'::jsonb);
  return v_booking;
end;
$$;

create or replace function public.call_next_customer(p_barber_id uuid default null, p_date date default current_date)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_barber_id uuid;
  v_booking   public.bookings;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can call the next customer.';
  end if;

  if p_barber_id is not null then
    v_barber_id := p_barber_id;
  else
    select id into v_barber_id from public.barbers where is_active = true order by created_at asc limit 1;
  end if;

  if v_barber_id is null then
    raise exception 'No barber found. Specify a barber.';
  end if;

  if exists (
    select 1 from public.bookings
    where barber_id = v_barber_id and booking_date = p_date and status = 'in_service'
  ) then
    raise exception 'Please complete the current customer before calling the next one.';
  end if;

  update public.bookings
  set status = 'in_service'
  where id = (
    select id from public.bookings
    where barber_id = v_barber_id and booking_date = p_date and status = 'arrived'
    order by queue_number asc nulls last, start_time asc
    limit 1
  )
  returning * into v_booking;

  if v_booking.id is null then
    raise exception 'No checked-in customers are waiting.';
  end if;

  perform public.log_audit('booking_in_service', v_booking.id, jsonb_build_object('via', 'call_next_customer'));
  return v_booking;
end;
$$;

-- complete_booking / mark_no_show — widened to accept the full lifecycle.
create or replace function public.complete_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can complete a booking.';
  end if;

  update public.bookings
  set status = 'completed', queue_number = null
  where id = p_booking_id and status in ('pending', 'confirmed', 'arrived', 'in_service')
  returning * into v_booking;

  if v_booking.id is null then
    raise exception 'Booking not found, or it is already finalized.';
  end if;

  perform public.log_audit('booking_completed', v_booking.id, jsonb_build_object('booking_date', v_booking.booking_date));
  return v_booking;
end;
$$;

create or replace function public.mark_no_show(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can mark a booking as no-show.';
  end if;

  update public.bookings
  set status = 'no_show', queue_number = null
  where id = p_booking_id and status in ('pending', 'confirmed', 'arrived')
  returning * into v_booking;

  if v_booking.id is null then
    raise exception 'Booking not found, already finalized, or already in service.';
  end if;

  perform public.log_audit('booking_no_show', v_booking.id, jsonb_build_object('booking_date', v_booking.booking_date));
  return v_booking;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Walk-in customer booking
--    Finds the earliest available slot for TODAY using the exact same
--    availability engine customers use, then books it immediately as
--    'arrived' (they are physically present already).
-- -----------------------------------------------------------------------------
create or replace function public.admin_create_walk_in(
  p_service_id uuid,
  p_name text,
  p_phone text default null,
  p_barber_id uuid default null
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings    public.shop_settings;
  v_duration    int;
  v_barber_id   uuid;
  v_slot        time;
  v_end_time    time;
  v_booking     public.bookings;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can add a walk-in customer.';
  end if;

  if p_name is null or trim(p_name) = '' then
    raise exception 'Customer name is required.';
  end if;

  select * into v_settings from public.shop_settings where id = 1;

  if extract(dow from current_date)::int = any(v_settings.weekly_off)
     or exists (select 1 from public.shop_closed_dates where closed_date = current_date) then
    raise exception 'The shop is closed today.';
  end if;

  select duration_mins into v_duration from public.services where id = p_service_id and is_active = true;
  if v_duration is null then
    raise exception 'Selected service is unavailable.';
  end if;

  if p_barber_id is not null then
    if not exists (select 1 from public.barbers where id = p_barber_id and is_active = true) then
      raise exception 'Selected barber is unavailable.';
    end if;
    v_barber_id := p_barber_id;
  end if;

  select slot_time into v_slot
  from public.get_available_slots(p_service_id, current_date, v_barber_id)
  order by slot_time asc
  limit 1;

  if v_slot is null then
    raise exception 'No available slots remain today for this service.';
  end if;

  if v_barber_id is null then
    select b.id into v_barber_id
    from public.barbers b
    where b.is_active = true
    order by (
      select count(*) from public.bookings bk
      where bk.barber_id = b.id and bk.booking_date = current_date
        and bk.status not in ('cancelled', 'no_show')
    ) asc, b.created_at asc
    limit 1;
  end if;

  v_end_time := (v_slot + ((v_duration + v_settings.buffer_minutes) || ' minutes')::interval)::time;

  insert into public.bookings (
    user_id, service_id, barber_id, booking_date, start_time, end_time,
    status, is_walk_in, walk_in_name, walk_in_phone, estimated_wait_mins
  )
  values (
    null, p_service_id, v_barber_id, current_date, v_slot, v_end_time,
    'arrived', true, trim(p_name), nullif(trim(coalesce(p_phone, '')), ''), 0
  )
  returning * into v_booking;

  select * into v_booking from public.bookings where id = v_booking.id;

  perform public.log_audit('walk_in_booking_created', v_booking.id, jsonb_build_object(
    'name', trim(p_name), 'start_time', v_slot
  ));

  return v_booking;
exception
  when exclusion_violation or unique_violation then
    raise exception 'This slot was just taken. Please try again.';
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Admin dashboard + reporting RPCs
-- -----------------------------------------------------------------------------
create or replace function public.admin_dashboard_stats(p_date date default current_date)
returns table (
  today_bookings      bigint,
  current_queue_count bigint,
  walk_in_count       bigint,
  revenue_today       numeric,
  total_customers     bigint,
  completed_count     bigint,
  cancelled_count     bigint,
  no_show_count       bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only an admin can view dashboard stats.';
  end if;

  return query
  select
    (select count(*) from public.bookings where booking_date = p_date),
    (select count(*) from public.bookings where booking_date = p_date and status in ('pending','confirmed','arrived','in_service')),
    (select count(*) from public.bookings where booking_date = p_date and is_walk_in = true),
    (select coalesce(sum(s.price), 0) from public.bookings b join public.services s on s.id = b.service_id
       where b.booking_date = p_date and b.status = 'completed'),
    (select count(*) from public.users where role = 'customer'),
    (select count(*) from public.bookings where booking_date = p_date and status = 'completed'),
    (select count(*) from public.bookings where booking_date = p_date and status = 'cancelled'),
    (select count(*) from public.bookings where booking_date = p_date and status = 'no_show');
end;
$$;

create or replace function public.admin_revenue_report(p_start date, p_end date)
returns table (
  report_date      date,
  bookings_count   bigint,
  completed_count  bigint,
  cancelled_count  bigint,
  no_show_count    bigint,
  revenue          numeric
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
    d::date as report_date,
    coalesce((select count(*) from public.bookings b where b.booking_date = d::date), 0),
    coalesce((select count(*) from public.bookings b where b.booking_date = d::date and b.status = 'completed'), 0),
    coalesce((select count(*) from public.bookings b where b.booking_date = d::date and b.status = 'cancelled'), 0),
    coalesce((select count(*) from public.bookings b where b.booking_date = d::date and b.status = 'no_show'), 0),
    coalesce((select sum(s.price) from public.bookings b join public.services s on s.id = b.service_id
       where b.booking_date = d::date and b.status = 'completed'), 0)
  from generate_series(p_start, p_end, interval '1 day') as d
  order by report_date asc;
end;
$$;

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
    count(b.id),
    coalesce(sum(s.price) filter (where b.status = 'completed'), 0)
  from public.services s
  left join public.bookings b
    on b.service_id = s.id
    and b.booking_date between p_start and p_end
    and b.status not in ('cancelled')
  group by s.id, s.name
  order by count(b.id) desc, s.name asc;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Execute grants — every function above self-checks is_admin() internally,
--    so granting execute to `authenticated` is safe (a non-admin call simply
--    gets a friendly exception, same defense-in-depth pattern as elsewhere).
-- -----------------------------------------------------------------------------
revoke all on function public.get_available_slots(uuid, date, uuid) from public;
grant execute on function public.get_available_slots(uuid, date, uuid) to authenticated;

revoke all on function public.create_booking(uuid, date, time, text, uuid) from public;
grant execute on function public.create_booking(uuid, date, time, text, uuid) to authenticated;

revoke all on function public.reschedule_booking(uuid, date, time) from public;
grant execute on function public.reschedule_booking(uuid, date, time) to authenticated;

revoke all on function public.mark_arrived(uuid) from public;
grant execute on function public.mark_arrived(uuid) to authenticated;

revoke all on function public.mark_in_service(uuid) from public;
grant execute on function public.mark_in_service(uuid) to authenticated;

revoke all on function public.call_next_customer(uuid, date) from public;
grant execute on function public.call_next_customer(uuid, date) to authenticated;

revoke all on function public.admin_create_walk_in(uuid, text, text, uuid) from public;
grant execute on function public.admin_create_walk_in(uuid, text, text, uuid) to authenticated;

revoke all on function public.admin_dashboard_stats(date) from public;
grant execute on function public.admin_dashboard_stats(date) to authenticated;

revoke all on function public.admin_revenue_report(date, date) from public;
grant execute on function public.admin_revenue_report(date, date) to authenticated;

revoke all on function public.admin_popular_services(date, date) from public;
grant execute on function public.admin_popular_services(date, date) to authenticated;

-- =============================================================================
-- End of Migration 004.
-- =============================================================================
