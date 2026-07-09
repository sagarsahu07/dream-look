-- =============================================================================
-- Dream Look — Migration 003: Multi-Barber Architecture, Configurable Shop
-- Rules, No-Show Expiry, Audit Log, Realtime (Phase 2 hardening)
--
-- Run in order:
--   1. sql/002_booking_engine.sql
--   2. sql/003a_add_enum_no_show.sql   (adds the 'no_show' enum value —
--      MUST be its own file/transaction; Postgres will not let a
--      brand-new enum value be used in the same transaction it was
--      created in, and this file uses it in an EXCLUDE constraint below)
--   3. sql/003_advanced_booking_features.sql (this file)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. shop_settings — a single-row configuration table. Every value the
--    booking engine previously hardcoded (hours, buffer, weekly off, grace
--    period, multi-booking policy) now lives here and is admin-editable.
-- -----------------------------------------------------------------------------
create table if not exists public.shop_settings (
  id                              smallint primary key default 1,
  opening_time                    time not null default '09:00',
  closing_time                    time not null default '21:00',
  buffer_minutes                  integer not null default 15 check (buffer_minutes >= 0),
  slot_step_minutes               integer not null default 15 check (slot_step_minutes > 0),
  grace_period_minutes            integer not null default 10 check (grace_period_minutes >= 0),
  allow_multiple_bookings_per_day boolean not null default false,
  -- Day-of-week off, using Postgres extract(dow): 0 = Sunday … 6 = Saturday.
  weekly_off                      integer[] not null default '{}',
  shop_timezone                   text not null default 'Asia/Kolkata',
  updated_at                      timestamptz not null default now(),
  constraint shop_settings_single_row check (id = 1)
);

comment on table public.shop_settings is 'Singleton row of admin-editable shop rules: hours, buffer, weekly off, grace period, booking policy.';

insert into public.shop_settings (id)
values (1)
on conflict (id) do nothing;

drop trigger if exists trg_shop_settings_updated_at on public.shop_settings;
create trigger trg_shop_settings_updated_at
  before update on public.shop_settings
  for each row execute function public.touch_updated_at();

alter table public.shop_settings enable row level security;

-- Everyone can read shop rules — the booking pages need opening hours even
-- before a customer logs in.
drop policy if exists "shop_settings_select_public" on public.shop_settings;
create policy "shop_settings_select_public"
  on public.shop_settings for select
  using (true);

-- Only an admin can change shop rules.
drop policy if exists "shop_settings_update_admin" on public.shop_settings;
create policy "shop_settings_update_admin"
  on public.shop_settings for update
  using (public.is_admin())
  with check (public.is_admin());

-- -----------------------------------------------------------------------------
-- 2. barbers — starts with exactly one row, but every booking is scoped to a
--    barber_id from day one, so adding a second barber later is a data
--    change (insert a row, seed their schedule), never a schema change.
-- -----------------------------------------------------------------------------
create table if not exists public.barbers (
  id          uuid primary key default gen_random_uuid(),
  full_name   text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

comment on table public.barbers is 'Staff who can be booked. Seeded with one row; add more rows to support multiple barbers — no schema change required.';

alter table public.barbers enable row level security;

drop policy if exists "barbers_select_public" on public.barbers;
create policy "barbers_select_public"
  on public.barbers for select
  using (is_active = true or public.is_admin());

drop policy if exists "barbers_write_admin" on public.barbers;
create policy "barbers_write_admin"
  on public.barbers for insert
  with check (public.is_admin());

drop policy if exists "barbers_update_admin" on public.barbers;
create policy "barbers_update_admin"
  on public.barbers for update
  using (public.is_admin())
  with check (public.is_admin());

insert into public.barbers (full_name)
select 'Dream Look Barber'
where not exists (select 1 from public.barbers);

-- -----------------------------------------------------------------------------
-- 3. bookings.barber_id — every booking belongs to exactly one barber.
--    Backfilled to the seeded barber, then locked to NOT NULL.
-- -----------------------------------------------------------------------------
alter table public.bookings add column if not exists barber_id uuid references public.barbers(id);

update public.bookings
set barber_id = (select id from public.barbers order by created_at asc limit 1)
where barber_id is null;

alter table public.bookings alter column barber_id set not null;

-- Overlap prevention is now scoped PER BARBER, not per shop — two different
-- barbers CAN hold overlapping appointments; the same barber cannot.
alter table public.bookings drop constraint if exists no_overlapping_bookings;
alter table public.bookings
  add constraint no_overlapping_bookings
  exclude using gist (
    barber_id with =,
    booking_date with =,
    tsrange((booking_date + start_time)::timestamp, (booking_date + end_time)::timestamp, '[)') with &&
  )
  where (status not in ('cancelled', 'no_show'));

-- -----------------------------------------------------------------------------
-- 4. Performance index
--    get_available_slots and the overlap check both filter by
--    (booking_date, barber_id, status) first — this index means that lookup
--    stays fast (index range scan on a handful of rows) no matter how many
--    total bookings accumulate in the table over time.
-- -----------------------------------------------------------------------------
create index if not exists idx_bookings_date_barber_status
  on public.bookings (booking_date, barber_id, status);

-- -----------------------------------------------------------------------------
-- 5. audit_logs — an append-only record of booking lifecycle events.
--    Written exclusively by SECURITY DEFINER functions (they run as the
--    table owner, which bypasses RLS for the insert); no role is ever
--    granted a direct INSERT policy, so the log cannot be forged or edited
--    from the client.
-- -----------------------------------------------------------------------------
create table if not exists public.audit_logs (
  id          uuid primary key default gen_random_uuid(),
  action      text not null,
  booking_id  uuid references public.bookings(id) on delete set null,
  actor_id    uuid,
  actor_role  text,
  details     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

comment on table public.audit_logs is 'Append-only audit trail for booking lifecycle events. Written only by SECURITY DEFINER functions.';

create index if not exists idx_audit_logs_booking_id on public.audit_logs(booking_id);
create index if not exists idx_audit_logs_created_at on public.audit_logs(created_at desc);

alter table public.audit_logs enable row level security;

drop policy if exists "audit_logs_select_admin" on public.audit_logs;
create policy "audit_logs_select_admin"
  on public.audit_logs for select
  using (public.is_admin());

-- No insert/update/delete policy is granted to any client role on purpose.

create or replace function public.log_audit(p_action text, p_booking_id uuid, p_details jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.audit_logs (action, booking_id, actor_id, actor_role, details)
  values (
    p_action,
    p_booking_id,
    auth.uid(),
    coalesce((select role::text from public.users where id = auth.uid()), 'system'),
    p_details
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. slot_pings — a tiny, non-sensitive "something changed" signal table.
--    RLS on public.bookings correctly hides other customers' booking rows,
--    which means a customer's Realtime subscription to bookings will NEVER
--    see someone else's new booking — by design. To still support "Live
--    Slot Refresh", every booking write pings this table for its date +
--    barber (no personal data, just a timestamp), and book-slot.html
--    subscribes to THIS table instead, then re-calls the safe
--    get_available_slots() RPC to get a fresh, correctly-scoped list.
-- -----------------------------------------------------------------------------
create table if not exists public.slot_pings (
  booking_date  date not null,
  barber_id     uuid not null references public.barbers(id) on delete cascade,
  pinged_at     timestamptz not null default now(),
  primary key (booking_date, barber_id)
);

comment on table public.slot_pings is 'Non-sensitive "availability changed" signal for realtime slot refresh. No personal data.';

alter table public.slot_pings enable row level security;

drop policy if exists "slot_pings_select_public" on public.slot_pings;
create policy "slot_pings_select_public"
  on public.slot_pings for select
  using (true);

-- No client write policy — only the trigger below (SECURITY DEFINER, bypasses RLS) writes here.

create or replace function public.ping_slot_availability(p_date date, p_barber_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.slot_pings (booking_date, barber_id, pinged_at)
  values (p_date, p_barber_id, now())
  on conflict (booking_date, barber_id) do update set pinged_at = excluded.pinged_at;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Queue sync trigger — extended to also ping slot availability, and to
--    keep working correctly now that barber_id and no_show both exist.
--    Still guarded by pg_trigger_depth() to prevent recursive re-firing
--    from recompute_queue_for_date's own UPDATE.
-- -----------------------------------------------------------------------------
create or replace function public.trg_bookings_queue_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;

  if TG_OP = 'DELETE' then
    perform public.recompute_queue_for_date(old.booking_date);
    perform public.ping_slot_availability(old.booking_date, old.barber_id);
    return old;
  elsif TG_OP = 'UPDATE' then
    perform public.recompute_queue_for_date(new.booking_date);
    perform public.ping_slot_availability(new.booking_date, new.barber_id);
    if new.booking_date <> old.booking_date or new.barber_id <> old.barber_id then
      perform public.recompute_queue_for_date(old.booking_date);
      perform public.ping_slot_availability(old.booking_date, old.barber_id);
    end if;
    return new;
  else
    perform public.recompute_queue_for_date(new.booking_date);
    perform public.ping_slot_availability(new.booking_date, new.barber_id);
    return new;
  end if;
end;
$$;
-- (Trigger itself was already created in 002_booking_engine.sql and does not
-- need to be recreated — CREATE OR REPLACE FUNCTION above is enough since
-- the trigger just points at this function by name.)

-- -----------------------------------------------------------------------------
-- 8. get_available_slots — rewritten to read shop_settings dynamically
--    (hours, buffer, step, weekly off) instead of hardcoded values, and to
--    resolve/accept a barber. Still SECURITY DEFINER (must see every
--    booking that date to compute true availability); still returns only
--    bare time values, never personal data.
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
    return; -- weekly off day
  end if;

  if exists (select 1 from public.shop_closed_dates where closed_date = p_booking_date) then
    return; -- holiday
  end if;

  -- Resolve which barber this check is for: caller-specified, or (for now,
  -- with a single barber) the sole active barber. With multiple barbers and
  -- no explicit choice, fall back to the least-booked active barber that
  -- day — simple load balancing that needs no schema change to extend.
  if p_barber_id is not null then
    v_barber_id := p_barber_id;
  else
    select b.id into v_barber_id
    from public.barbers b
    where b.is_active = true
    order by (
      select count(*) from public.bookings bk
      where bk.barber_id = b.id and bk.booking_date = p_booking_date and bk.status in ('pending', 'confirmed')
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
        and b.status in ('pending', 'confirmed')
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

-- -----------------------------------------------------------------------------
-- 9. create_booking — rewritten to use shop_settings, resolve/validate a
--    barber, enforce the configurable per-day booking limit, and write an
--    audit log entry.
-- -----------------------------------------------------------------------------
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
      and status in ('pending', 'confirmed')
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
      where bk.barber_id = b.id and bk.booking_date = p_booking_date and bk.status in ('pending', 'confirmed')
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
      and b.status in ('pending', 'confirmed')
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

-- -----------------------------------------------------------------------------
-- 10. cancel_booking — unchanged behaviour, now also writes an audit entry.
-- -----------------------------------------------------------------------------
create or replace function public.cancel_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_booking public.bookings;
begin
  if v_user_id is null then
    raise exception 'You must be logged in to cancel a booking.';
  end if;

  update public.bookings
  set status = 'cancelled', queue_number = null, estimated_wait_mins = 0
  where id = p_booking_id
    and user_id = v_user_id
    and status in ('pending', 'confirmed')
  returning * into v_booking;

  if v_booking.id is null then
    raise exception 'Booking not found, or it can no longer be cancelled.';
  end if;

  perform public.log_audit('booking_cancelled', v_booking.id, jsonb_build_object('booking_date', v_booking.booking_date));

  return v_booking;
end;
$$;

-- -----------------------------------------------------------------------------
-- 11. reschedule_booking — rewritten to use shop_settings, re-validate the
--     barber's schedule, respect the per-day booking limit, and audit-log.
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
      and status in ('pending', 'confirmed')
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
      and b.status in ('pending', 'confirmed')
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
-- 12. complete_booking / mark_no_show — admin-only booking finalization.
--     Both feed the SAME trg_bookings_queue_sync trigger used everywhere
--     else, so marking one booking complete/no-show automatically
--     recomputes queue_number for every other booking that day — that
--     update reaches affected customers live via their Realtime
--     subscription (see assets/js/booking.js -> subscribeToMyBookings).
-- -----------------------------------------------------------------------------
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
  where id = p_booking_id and status in ('pending', 'confirmed')
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
  where id = p_booking_id and status in ('pending', 'confirmed')
  returning * into v_booking;

  if v_booking.id is null then
    raise exception 'Booking not found, or it is already finalized.';
  end if;

  perform public.log_audit('booking_no_show', v_booking.id, jsonb_build_object('booking_date', v_booking.booking_date));

  return v_booking;
end;
$$;

-- -----------------------------------------------------------------------------
-- 13. expire_no_shows — system maintenance job. NOT granted to any client
--     role: it is meant to run unattended (pg_cron below) or be triggered
--     manually by a project owner from the SQL editor
--     (select public.expire_no_shows();), never from the app.
-- -----------------------------------------------------------------------------
create or replace function public.expire_no_shows()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_grace int;
  v_count int;
begin
  select grace_period_minutes into v_grace from public.shop_settings where id = 1;

  with expired as (
    update public.bookings
    set status = 'no_show', queue_number = null
    where status = 'confirmed'
      and (booking_date + start_time + (v_grace || ' minutes')::interval)::timestamp < now()
    returning id, booking_date
  )
  select count(*) into v_count from expired;

  if v_count > 0 then
    perform public.log_audit('booking_auto_expired_no_show', null, jsonb_build_object('count', v_count));
  end if;

  return v_count;
end;
$$;

revoke all on function public.expire_no_shows() from public;
revoke all on function public.expire_no_shows() from authenticated;

-- Best-effort scheduling: only runs if the pg_cron extension is already
-- enabled on this project (Database → Extensions → pg_cron). If it isn't,
-- this block does nothing and expire_no_shows() can still be called
-- manually or from an external scheduler hitting a Supabase Edge Function.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('dream-look-expire-no-shows')
      where exists (select 1 from cron.job where jobname = 'dream-look-expire-no-shows');
    perform cron.schedule('dream-look-expire-no-shows', '*/5 * * * *', 'select public.expire_no_shows();');
  end if;
exception
  when others then
    -- pg_cron present but schedule failed for a project-specific reason —
    -- don't fail the whole migration over an optional convenience feature.
    null;
end;
$$;

-- -----------------------------------------------------------------------------
-- 14. Execute grants for the new/changed RPCs
-- -----------------------------------------------------------------------------
revoke all on function public.get_available_slots(uuid, date, uuid) from public;
grant execute on function public.get_available_slots(uuid, date, uuid) to authenticated;

revoke all on function public.create_booking(uuid, date, time, text, uuid) from public;
grant execute on function public.create_booking(uuid, date, time, text, uuid) to authenticated;

revoke all on function public.complete_booking(uuid) from public;
grant execute on function public.complete_booking(uuid) to authenticated; -- function itself checks is_admin()

revoke all on function public.mark_no_show(uuid) from public;
grant execute on function public.mark_no_show(uuid) to authenticated; -- function itself checks is_admin()

-- The old 4-argument get_available_slots/create_booking signatures from
-- migration 002 are superseded by the 3/5-argument versions above (default
-- parameters keep existing callers working unchanged).

-- -----------------------------------------------------------------------------
-- 15. Realtime — enable postgres_changes broadcasts for the tables the
--     frontend subscribes to. bookings is RLS-scoped per user automatically;
--     slot_pings is public and carries no personal data.
-- -----------------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.bookings;
  exception when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.slot_pings;
  exception when duplicate_object then null;
  end;
end;
$$;

-- =============================================================================
-- End of Migration 003.
-- =============================================================================
