-- =============================================================================
-- Dream Look — Migration 002: Booking Engine & Queue Management (Phase 2)
-- Run this in Supabase → SQL Editor AFTER sql/schema.sql has already been run.
-- Additive only: does not drop or recreate any Phase 1 table.
-- Safe to re-run: every statement is guarded (IF NOT EXISTS / CREATE OR REPLACE).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Extension needed for the overlap-prevention EXCLUDE constraint
-- -----------------------------------------------------------------------------
create extension if not exists "btree_gist";

-- -----------------------------------------------------------------------------
-- 1. New columns on the existing public.bookings table
--    end_time            = start_time + service duration + 15-minute buffer.
--                          This is the "occupied window" — the next booking
--                          simply cannot start before this time.
--    queue_number         = position in that day's queue (1, 2, 3…),
--                          maintained automatically by a trigger.
--    estimated_wait_mins = snapshot, in minutes, of how long the customer
--                          was waiting from the moment they booked. The
--                          dashboard recalculates a LIVE wait time on top of
--                          this for accuracy — see booking.js.
-- -----------------------------------------------------------------------------
alter table public.bookings add column if not exists end_time time;
alter table public.bookings add column if not exists queue_number integer;
alter table public.bookings add column if not exists estimated_wait_mins integer not null default 0;

-- Backfill end_time for any pre-existing rows (none expected in Phase 1, but safe).
update public.bookings b
set end_time = (b.start_time + ((s.duration_mins + 15) || ' minutes')::interval)::time
from public.services s
where b.service_id = s.id and b.end_time is null;

alter table public.bookings alter column end_time set not null;

-- -----------------------------------------------------------------------------
-- 2. Table: shop_closed_dates
--    Lets an admin mark specific dates as closed (public holidays, etc).
--    Booking logic and the date picker both read this to hide closed days.
-- -----------------------------------------------------------------------------
create table if not exists public.shop_closed_dates (
  closed_date date primary key,
  reason      text,
  created_at  timestamptz not null default now()
);

comment on table public.shop_closed_dates is 'Dates the shop is closed. Read by booking logic and the date picker.';

alter table public.shop_closed_dates enable row level security;

drop policy if exists "shop_closed_dates_select_public" on public.shop_closed_dates;
create policy "shop_closed_dates_select_public"
  on public.shop_closed_dates for select
  using (true); -- anyone (including logged-out visitors) can see which dates are closed

drop policy if exists "shop_closed_dates_write_admin" on public.shop_closed_dates;
create policy "shop_closed_dates_write_admin"
  on public.shop_closed_dates for insert
  with check (public.is_admin());

drop policy if exists "shop_closed_dates_delete_admin" on public.shop_closed_dates;
create policy "shop_closed_dates_delete_admin"
  on public.shop_closed_dates for delete
  using (public.is_admin());

-- -----------------------------------------------------------------------------
-- 3. Overlap prevention at the database level
--    An EXCLUDE constraint is enforced on the physical table regardless of
--    Row Level Security, so this is the real, race-condition-proof guarantee
--    that no two ACTIVE (non-cancelled) bookings can occupy overlapping time
--    on the same date. RPC-level checks below exist only to fail EARLY with
--    a friendly message — this constraint is the last line of defence.
-- -----------------------------------------------------------------------------
alter table public.bookings drop constraint if exists no_overlapping_bookings;
alter table public.bookings
  add constraint no_overlapping_bookings
  exclude using gist (
    booking_date with =,
    tsrange((booking_date + start_time)::timestamp, (booking_date + end_time)::timestamp, '[)') with &&
  )
  where (status <> 'cancelled');

-- The old exact-match unique constraint is now redundant (the EXCLUDE
-- constraint above is a strict superset of it) — drop it to avoid confusion.
alter table public.bookings drop constraint if exists unique_active_slot;

-- -----------------------------------------------------------------------------
-- 4. Queue recomputation
--    Recalculates queue_number for every active booking on a given date,
--    ordered by start_time. Cancelled/completed bookings get queue_number
--    cleared. SECURITY DEFINER because it must see every user's bookings for
--    that date, not just the caller's own (RLS would otherwise hide them).
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
    where booking_date = p_date and status in ('pending', 'confirmed')
  ) sub
  where b.id = sub.id and b.queue_number is distinct from sub.rn;

  update public.bookings
  set queue_number = null
  where booking_date = p_date
    and status not in ('pending', 'confirmed')
    and queue_number is not null;
end;
$$;

-- Trigger wrapper. pg_trigger_depth() > 1 means this fire was CAUSED BY the
-- UPDATE inside recompute_queue_for_date itself — bail out immediately so
-- the trigger cannot recursively re-trigger itself.
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
    return old;
  elsif TG_OP = 'UPDATE' then
    perform public.recompute_queue_for_date(new.booking_date);
    if new.booking_date <> old.booking_date then
      perform public.recompute_queue_for_date(old.booking_date);
    end if;
    return new;
  else
    perform public.recompute_queue_for_date(new.booking_date);
    return new;
  end if;
end;
$$;

drop trigger if exists trg_bookings_queue_sync on public.bookings;
create trigger trg_bookings_queue_sync
  after insert or update or delete on public.bookings
  for each row execute function public.trg_bookings_queue_sync();

-- -----------------------------------------------------------------------------
-- 5. get_available_slots(service_id, date)
--    Returns ONLY open start times, at 15-minute granularity, for a given
--    service and date. Considers: shop hours (09:00–21:00), closed dates,
--    past times (if the date is today), service duration, and every existing
--    active booking's occupied window (duration + 15-minute buffer).
--    SECURITY DEFINER: must see every user's bookings for that date to know
--    what's taken, but returns nothing except bare time values — no personal
--    data of any kind is exposed to the caller.
-- -----------------------------------------------------------------------------
create or replace function public.get_available_slots(
  p_service_id uuid,
  p_booking_date date
)
returns table(slot_time time)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_duration    int;
  v_shop_open   time := time '09:00';
  v_shop_close  time := time '21:00';
  v_step_mins   int := 15;
  v_slot        time;
  v_slot_end    time;
begin
  select duration_mins into v_duration
  from public.services
  where id = p_service_id and is_active = true;

  if v_duration is null then
    raise exception 'Selected service is unavailable.';
  end if;

  if p_booking_date < current_date then
    return;
  end if;

  if exists (select 1 from public.shop_closed_dates where closed_date = p_booking_date) then
    return;
  end if;

  v_slot := v_shop_open;

  while v_slot + (v_duration || ' minutes')::interval <= v_shop_close loop
    v_slot_end := (v_slot + ((v_duration + 15) || ' minutes')::interval)::time;

    if p_booking_date = current_date and (p_booking_date + v_slot)::timestamp <= now() then
      v_slot := (v_slot + (v_step_mins || ' minutes')::interval)::time;
      continue;
    end if;

    if not exists (
      select 1
      from public.bookings b
      where b.booking_date = p_booking_date
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

    v_slot := (v_slot + (v_step_mins || ' minutes')::interval)::time;
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. create_booking(service_id, date, start_time, notes)
--    The ONLY sanctioned way to create a booking. SECURITY DEFINER so it can
--    validate against every existing booking that day (not just the caller's
--    own, which RLS would otherwise hide) — but it manually enforces
--    "auth.uid() must be logged in" and always books FOR the caller, so a
--    customer can never create a booking in someone else's name.
-- -----------------------------------------------------------------------------
create or replace function public.create_booking(
  p_service_id uuid,
  p_booking_date date,
  p_start_time time,
  p_notes text default null
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id      uuid := auth.uid();
  v_duration     int;
  v_service_end  time;
  v_end_time     time;
  v_wait_mins    int;
  v_booking      public.bookings;
begin
  if v_user_id is null then
    raise exception 'You must be logged in to book an appointment.';
  end if;

  if p_service_id is null or p_booking_date is null or p_start_time is null then
    raise exception 'Service, date and time are all required.';
  end if;

  if p_booking_date < current_date then
    raise exception 'You cannot book a date in the past.';
  end if;

  if p_booking_date = current_date and (p_booking_date + p_start_time)::timestamp <= now() then
    raise exception 'You cannot book a time in the past.';
  end if;

  if exists (select 1 from public.shop_closed_dates where closed_date = p_booking_date) then
    raise exception 'The shop is closed on this date. Please choose another date.';
  end if;

  select duration_mins into v_duration
  from public.services
  where id = p_service_id and is_active = true;

  if v_duration is null then
    raise exception 'Selected service is unavailable.';
  end if;

  if p_start_time < time '09:00' then
    raise exception 'Bookings start at 09:00 AM.';
  end if;

  v_service_end := (p_start_time + (v_duration || ' minutes')::interval)::time;
  if v_service_end > time '21:00' then
    raise exception 'This service does not fit before closing time (09:00 PM). Please choose an earlier slot.';
  end if;

  v_end_time := (p_start_time + ((v_duration + 15) || ' minutes')::interval)::time;

  if exists (
    select 1
    from public.bookings b
    where b.booking_date = p_booking_date
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
    user_id, service_id, booking_date, start_time, end_time,
    status, notes, estimated_wait_mins
  )
  values (
    v_user_id, p_service_id, p_booking_date, p_start_time, v_end_time,
    'confirmed', nullif(trim(coalesce(p_notes, '')), ''), v_wait_mins
  )
  returning * into v_booking;

  -- Re-select so the response includes the queue_number the AFTER INSERT
  -- trigger just assigned.
  select * into v_booking from public.bookings where id = v_booking.id;

  return v_booking;
exception
  when exclusion_violation or unique_violation then
    raise exception 'This slot was just taken. Please choose another time.';
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. cancel_booking(booking_id)
--    Customers may only cancel their OWN booking, and only while it is still
--    pending or confirmed. Cancelling frees the slot and the queue-sync
--    trigger automatically shifts everyone behind it up by one.
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

  return v_booking;
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. reschedule_booking(booking_id, new_date, new_start_time)
--    Moves an existing booking to a new date/time, re-running every
--    validation create_booking runs, then re-triggers the queue sync for
--    both the old date (people behind it shift up) and the new date.
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
  v_service_id   uuid;
  v_duration     int;
  v_service_end  time;
  v_end_time     time;
  v_wait_mins    int;
  v_booking      public.bookings;
begin
  if v_user_id is null then
    raise exception 'You must be logged in to reschedule a booking.';
  end if;

  select service_id into v_service_id
  from public.bookings
  where id = p_booking_id and user_id = v_user_id and status in ('pending', 'confirmed');

  if v_service_id is null then
    raise exception 'Booking not found, or it can no longer be rescheduled.';
  end if;

  if p_new_date < current_date then
    raise exception 'You cannot reschedule to a date in the past.';
  end if;

  if p_new_date = current_date and (p_new_date + p_new_start_time)::timestamp <= now() then
    raise exception 'You cannot reschedule to a time in the past.';
  end if;

  if exists (select 1 from public.shop_closed_dates where closed_date = p_new_date) then
    raise exception 'The shop is closed on this date. Please choose another date.';
  end if;

  select duration_mins into v_duration from public.services where id = v_service_id;

  if p_new_start_time < time '09:00' then
    raise exception 'Bookings start at 09:00 AM.';
  end if;

  v_service_end := (p_new_start_time + (v_duration || ' minutes')::interval)::time;
  if v_service_end > time '21:00' then
    raise exception 'This service does not fit before closing time (09:00 PM). Please choose an earlier slot.';
  end if;

  v_end_time := (p_new_start_time + ((v_duration + 15) || ' minutes')::interval)::time;

  if exists (
    select 1
    from public.bookings b
    where b.booking_date = p_new_date
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

  return v_booking;
exception
  when exclusion_violation or unique_violation then
    raise exception 'This slot was just taken. Please choose another time.';
end;
$$;

-- -----------------------------------------------------------------------------
-- 9. Lock down direct table writes on bookings.
--    All customer-facing writes now go exclusively through the SECURITY
--    DEFINER functions above, which contain the real validation. Direct
--    client INSERT/UPDATE policies are removed so a customer can no longer
--    bypass buffer/overlap/queue logic by calling
--    supabase.from('bookings').insert(...) directly. Admin policies are
--    untouched — staff tooling can still write directly.
-- -----------------------------------------------------------------------------
drop policy if exists "bookings_insert_own" on public.bookings;
drop policy if exists "bookings_update_own" on public.bookings;

-- -----------------------------------------------------------------------------
-- 10. Execute grants
--     Booking functions require an authenticated session; anonymous
--     visitors cannot call them (book-slot.html is already a protected page).
-- -----------------------------------------------------------------------------
revoke all on function public.get_available_slots(uuid, date) from public;
grant execute on function public.get_available_slots(uuid, date) to authenticated;

revoke all on function public.create_booking(uuid, date, time, text) from public;
grant execute on function public.create_booking(uuid, date, time, text) to authenticated;

revoke all on function public.cancel_booking(uuid) from public;
grant execute on function public.cancel_booking(uuid) to authenticated;

revoke all on function public.reschedule_booking(uuid, date, time) from public;
grant execute on function public.reschedule_booking(uuid, date, time) to authenticated;

-- =============================================================================
-- End of Migration 002.
-- =============================================================================
