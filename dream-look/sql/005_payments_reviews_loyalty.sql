-- =============================================================================
-- Dream Look — Migration 005: Payments, Reviews, Loyalty, Notifications
-- Run in Supabase → SQL Editor AFTER 004_admin_panel.sql.
-- Nothing in this file alters an existing function's booking/queue logic —
-- every change here is a new table, new column, or a NEW trigger/function
-- that runs alongside (never replacing) trg_bookings_queue_sync and the
-- booking RPCs from migrations 002-004.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Payments — extend the existing table (created in schema.sql) rather
--    than replace it. transaction_id is OUR reference number, generated
--    server-side, shown to the customer; provider_ref_id (already existed)
--    stores the payment gateway's own id once verified.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'payment_method') then
    create type payment_method as enum ('razorpay', 'cash', 'upi');
  end if;
end
$$;

alter table public.payments add column if not exists transaction_id text;
alter table public.payments add column if not exists method public.payment_method;

create unique index if not exists idx_payments_transaction_id
  on public.payments(transaction_id) where transaction_id is not null;

-- -----------------------------------------------------------------------------
-- 2. create_payment_record — the ONLY way a payment row is created.
--    Idempotent: calling it again for a booking that already has a pending
--    or failed payment reuses that row (fresh transaction_id) instead of
--    violating the existing unique_payment_per_booking constraint; calling
--    it for an already-PAID booking is rejected outright. This is the
--    "prevent duplicate payments" guarantee at the database level.
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

  select price into v_amount from public.services where id = v_booking.service_id;

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

revoke all on function public.create_payment_record(uuid, public.payment_method) from public;
grant execute on function public.create_payment_record(uuid, public.payment_method) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. mark_payment_paid / mark_payment_failed — the trust boundary for
--    payments. These are deliberately NOT granted to `authenticated` at
--    all: only the service_role key (used exclusively by the
--    verify-razorpay-payment Edge Function, after it has independently
--    verified the gateway's cryptographic signature) can call them. A
--    customer's browser can never mark its own payment as paid — this is
--    the "never mark Paid until verified" guarantee.
-- -----------------------------------------------------------------------------
create or replace function public.mark_payment_paid(
  p_payment_id uuid,
  p_provider text,
  p_provider_ref_id text
)
returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
begin
  update public.payments
  set status = 'paid', provider = p_provider, provider_ref_id = p_provider_ref_id
  where id = p_payment_id and status = 'pending'
  returning * into v_payment;

  if v_payment.id is null then
    raise exception 'Payment not found, or it is not awaiting verification.';
  end if;

  perform public.log_audit('payment_paid', v_payment.booking_id, jsonb_build_object(
    'provider', p_provider, 'provider_ref_id', p_provider_ref_id, 'amount', v_payment.amount
  ));

  return v_payment;
end;
$$;

create or replace function public.mark_payment_failed(p_payment_id uuid, p_reason text default null)
returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
begin
  update public.payments
  set status = 'failed'
  where id = p_payment_id and status = 'pending'
  returning * into v_payment;

  if v_payment.id is null then
    raise exception 'Payment not found, or it is not awaiting verification.';
  end if;

  perform public.log_audit('payment_failed', v_payment.booking_id, jsonb_build_object('reason', p_reason));

  return v_payment;
end;
$$;

revoke all on function public.mark_payment_paid(uuid, text, text) from public, authenticated, anon;
revoke all on function public.mark_payment_failed(uuid, text) from public, authenticated, anon;
grant execute on function public.mark_payment_paid(uuid, text, text) to service_role;
grant execute on function public.mark_payment_failed(uuid, text) to service_role;

-- Refunds are a deliberate admin decision (cash refunded at the counter, or
-- a gateway refund initiated separately) — admin-callable like every other
-- staff action, self-checked, audit-logged.
create or replace function public.mark_payment_refunded(p_payment_id uuid)
returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can issue a refund.';
  end if;

  update public.payments
  set status = 'refunded'
  where id = p_payment_id and status = 'paid'
  returning * into v_payment;

  if v_payment.id is null then
    raise exception 'Payment not found, or it was never marked paid.';
  end if;

  perform public.log_audit('payment_refunded', v_payment.booking_id, jsonb_build_object('amount', v_payment.amount));

  return v_payment;
end;
$$;

revoke all on function public.mark_payment_refunded(uuid) from public;
grant execute on function public.mark_payment_refunded(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. get_booking_receipt — a single, ownership-checked read for the Booking
--    Success / Receipt pages, so the frontend doesn't need three separate
--    RLS-scoped joins to assemble one receipt.
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
  service_price         numeric,
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
    s.name,
    s.price,
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
-- 5. Reviews — one review per booking, only for a completed booking the
--    reviewer actually owns. All writes go through RPCs (submit / reply);
--    no direct INSERT/UPDATE policy is granted, so a review's admin_reply
--    can never be forged by a customer, and a rating can never be forged
--    by anyone but the customer who was actually served.
-- -----------------------------------------------------------------------------
create table if not exists public.reviews (
  id              uuid primary key default gen_random_uuid(),
  booking_id      uuid not null unique references public.bookings(id) on delete cascade,
  user_id         uuid references public.users(id) on delete cascade,
  rating          smallint not null check (rating between 1 and 5),
  comment         text,
  admin_reply     text,
  admin_reply_at  timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

comment on table public.reviews is 'One review per completed booking. Writes only via submit_review() / admin_reply_review().';

drop trigger if exists trg_reviews_updated_at on public.reviews;
create trigger trg_reviews_updated_at
  before update on public.reviews
  for each row execute function public.touch_updated_at();

alter table public.reviews enable row level security;

-- Public, read-only — reviews double as testimonials on the site.
drop policy if exists "reviews_select_public" on public.reviews;
create policy "reviews_select_public"
  on public.reviews for select
  using (true);

-- No INSERT/UPDATE/DELETE policy for any client role — see RPCs below.

create or replace function public.submit_review(p_booking_id uuid, p_rating smallint, p_comment text default null)
returns public.reviews
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_booking public.bookings;
  v_review  public.reviews;
begin
  if v_user_id is null then
    raise exception 'You must be logged in to leave a review.';
  end if;

  if p_rating < 1 or p_rating > 5 then
    raise exception 'Rating must be between 1 and 5.';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id;

  if v_booking.id is null or v_booking.user_id is distinct from v_user_id then
    raise exception 'Booking not found.';
  end if;

  if v_booking.status <> 'completed' then
    raise exception 'You can only review a completed appointment.';
  end if;

  insert into public.reviews (booking_id, user_id, rating, comment)
  values (p_booking_id, v_user_id, p_rating, nullif(trim(coalesce(p_comment, '')), ''))
  on conflict (booking_id) do update
    set rating = excluded.rating, comment = excluded.comment
  returning * into v_review;

  return v_review;
end;
$$;

create or replace function public.admin_reply_review(p_review_id uuid, p_reply text)
returns public.reviews
language plpgsql
security definer
set search_path = public
as $$
declare
  v_review public.reviews;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can reply to a review.';
  end if;

  update public.reviews
  set admin_reply = nullif(trim(coalesce(p_reply, '')), ''), admin_reply_at = now()
  where id = p_review_id
  returning * into v_review;

  if v_review.id is null then
    raise exception 'Review not found.';
  end if;

  return v_review;
end;
$$;

revoke all on function public.submit_review(uuid, smallint, text) from public;
grant execute on function public.submit_review(uuid, smallint, text) to authenticated;

revoke all on function public.admin_reply_review(uuid, text) from public;
grant execute on function public.admin_reply_review(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Loyalty — future-ready reward points, visit count, membership tier.
--    Delivered as a BRAND NEW trigger that runs alongside (never replacing)
--    trg_bookings_queue_sync — the booking/queue algorithm itself is
--    untouched. Skipped for walk-ins (no account to credit).
-- -----------------------------------------------------------------------------
alter table public.users add column if not exists loyalty_points integer not null default 0;
alter table public.users add column if not exists visit_count integer not null default 0;
alter table public.users add column if not exists membership_tier text not null default 'standard';

create or replace function public.award_loyalty_on_completion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_visit_count int;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' and new.user_id is not null then
    update public.users
    set visit_count = visit_count + 1,
        loyalty_points = loyalty_points + 10
    where id = new.user_id
    returning visit_count into v_new_visit_count;

    update public.users
    set membership_tier = case
      when v_new_visit_count >= 20 then 'platinum'
      when v_new_visit_count >= 10 then 'gold'
      when v_new_visit_count >= 5  then 'silver'
      else 'standard'
    end
    where id = new.user_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_award_loyalty on public.bookings;
create trigger trg_award_loyalty
  after update on public.bookings
  for each row execute function public.award_loyalty_on_completion();

-- -----------------------------------------------------------------------------
-- 7. Notification dispatch — fire-and-forget. A failure here NEVER blocks
--    the booking/payment transaction that triggered it (wrapped in its own
--    exception handler), and it silently no-ops until an admin configures
--    notification_settings AND enables the pg_net extension — both
--    optional, both safe to leave unset.
-- -----------------------------------------------------------------------------
create table if not exists public.notification_settings (
  id                    smallint primary key default 1,
  edge_function_base_url text,
  internal_secret        text,
  constraint notification_settings_single_row check (id = 1)
);

comment on table public.notification_settings is 'Base URL + shared secret for the send-booking-email Edge Function. Empty = notifications disabled.';

insert into public.notification_settings (id) values (1) on conflict (id) do nothing;

alter table public.notification_settings enable row level security;

drop policy if exists "notification_settings_admin_only" on public.notification_settings;
create policy "notification_settings_admin_only"
  on public.notification_settings for select
  using (public.is_admin());

drop policy if exists "notification_settings_update_admin" on public.notification_settings;
create policy "notification_settings_update_admin"
  on public.notification_settings for update
  using (public.is_admin())
  with check (public.is_admin());

create or replace function public.notify_event(p_type text, p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg public.notification_settings;
begin
  select * into v_cfg from public.notification_settings where id = 1;

  if v_cfg.edge_function_base_url is null or v_cfg.edge_function_base_url = '' then
    return;
  end if;

  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    return;
  end if;

  begin
    perform net.http_post(
      url := v_cfg.edge_function_base_url || '/send-booking-email',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', coalesce(v_cfg.internal_secret, '')),
      body := jsonb_build_object('type', p_type, 'booking_id', p_booking_id)
    );
  exception when others then
    -- Never let a notification failure break the caller's transaction.
    null;
  end;
end;
$$;

create or replace function public.trg_bookings_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;

  if TG_OP = 'INSERT' then
    perform public.notify_event('booking_created', new.id);
  elsif TG_OP = 'UPDATE' then
    if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
      perform public.notify_event('booking_cancelled', new.id);
    elsif (new.booking_date <> old.booking_date or new.start_time <> old.start_time)
          and new.status not in ('cancelled', 'no_show', 'completed') then
      perform public.notify_event('booking_rescheduled', new.id);
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_bookings_notify on public.bookings;
create trigger trg_bookings_notify
  after insert or update on public.bookings
  for each row execute function public.trg_bookings_notify();

-- -----------------------------------------------------------------------------
-- 8. Appointment reminders — best-effort scheduled job (pg_cron), fires a
--    'booking_reminder' notification once per booking, 50-70 minutes ahead
--    of the appointment. Self-guarding: safe to run even if pg_cron/pg_net
--    are not enabled on this project.
-- -----------------------------------------------------------------------------
alter table public.bookings add column if not exists reminder_sent_at timestamptz;

create or replace function public.send_due_reminders()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking record;
  v_count int := 0;
begin
  for v_booking in
    select id from public.bookings
    where status in ('confirmed', 'arrived')
      and reminder_sent_at is null
      and (booking_date + start_time)::timestamp between now() + interval '50 minutes' and now() + interval '70 minutes'
  loop
    perform public.notify_event('booking_reminder', v_booking.id);
    update public.bookings set reminder_sent_at = now() where id = v_booking.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.send_due_reminders() from public, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('dream-look-send-reminders')
      where exists (select 1 from cron.job where jobname = 'dream-look-send-reminders');
    perform cron.schedule('dream-look-send-reminders', '*/5 * * * *', 'select public.send_due_reminders();');
  end if;
exception
  when others then null;
end;
$$;

-- =============================================================================
-- End of Migration 005.
-- =============================================================================
