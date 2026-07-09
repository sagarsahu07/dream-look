-- =============================================================================
-- Dream Look — Migration 006: Production Audit Fixes
-- Run in Supabase → SQL Editor AFTER 005_payments_reviews_loyalty.sql.
--
-- Everything in this file is either a NEW object or a CREATE OR REPLACE of
-- a function that keeps its exact existing signature — nothing here changes
-- the booking/queue algorithm's slot, buffer, or overlap logic.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- BUG FIX 1 — Admin "Cancel" was a raw table UPDATE (bookings_update_admin
-- RLS policy), which worked but bypassed the audit log every other admin
-- action goes through. Give it a proper RPC so cancellations are logged
-- like everything else.
-- -----------------------------------------------------------------------------
create or replace function public.admin_cancel_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can cancel a booking.';
  end if;

  update public.bookings
  set status = 'cancelled', queue_number = null, estimated_wait_mins = 0
  where id = p_booking_id and status in ('pending', 'confirmed', 'arrived', 'in_service')
  returning * into v_booking;

  if v_booking.id is null then
    raise exception 'Booking not found, or it can no longer be cancelled.';
  end if;

  perform public.log_audit('booking_cancelled', v_booking.id, jsonb_build_object('booking_date', v_booking.booking_date, 'by', 'admin'));

  return v_booking;
end;
$$;

revoke all on function public.admin_cancel_booking(uuid) from public;
grant execute on function public.admin_cancel_booking(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- BUG FIX 2 — "Revenue" was computed as (completed bookings × service
-- price), which silently assumes every completed booking was actually paid
-- for. Now that migration 005 tracks real payments, revenue must come from
-- payments.amount where status = 'paid' — a completed-but-unpaid booking no
-- longer inflates the number, and a paid-but-not-yet-completed booking
-- (pre-paid online) is correctly counted.
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
    (select coalesce(sum(p.amount), 0) from public.payments p join public.bookings b on b.id = p.booking_id
       where b.booking_date = p_date and p.status = 'paid'),
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
    coalesce((select sum(p.amount) from public.payments p join public.bookings b on b.id = p.booking_id
       where b.booking_date = d::date and p.status = 'paid'), 0)
  from generate_series(p_start, p_end, interval '1 day') as d
  order by report_date asc;
end;
$$;

-- Popular-services revenue had the same assumption — align it too.
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
    coalesce((
      select sum(p.amount) from public.payments p
      where p.status = 'paid'
        and p.booking_id in (
          select b2.id from public.bookings b2
          where b2.service_id = s.id and b2.booking_date between p_start and p_end
        )
    ), 0)
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
-- PERFORMANCE — indexes the audit surfaced as missing for queries already
-- in production use.
-- -----------------------------------------------------------------------------

-- dashboard.js filters reviews by user_id (one query per dashboard load).
create index if not exists idx_reviews_user_id on public.reviews(user_id);

-- send_due_reminders() scans exactly this shape every 5 minutes via
-- pg_cron; a partial index keeps it cheap even as booking history grows,
-- since only rows still awaiting a reminder are ever indexed.
create index if not exists idx_bookings_reminder_pending
  on public.bookings (booking_date, start_time)
  where reminder_sent_at is null and status in ('confirmed', 'arrived');

-- payments are frequently filtered by status (dashboard/report joins above).
create index if not exists idx_payments_status on public.payments(status);

-- =============================================================================
-- End of Migration 006.
-- =============================================================================
