-- =============================================================================
-- Dream Look — Database Schema (Phase 1)
-- Run this entire file once in Supabase → SQL Editor → New Query → Run.
-- Safe to re-run: destructive statements are guarded with IF EXISTS/IF NOT EXISTS.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Extensions
-- -----------------------------------------------------------------------------
create extension if not exists "pgcrypto"; -- gen_random_uuid()

-- -----------------------------------------------------------------------------
-- 1. Enum types
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type user_role as enum ('customer', 'admin');
  end if;

  if not exists (select 1 from pg_type where typname = 'booking_status') then
    create type booking_status as enum ('pending', 'confirmed', 'completed', 'cancelled');
  end if;

  if not exists (select 1 from pg_type where typname = 'payment_status') then
    create type payment_status as enum ('pending', 'paid', 'failed', 'refunded');
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- 2. Table: users
-- One row per person, mirroring auth.users, plus profile fields the app needs.
-- id is the SAME uuid as auth.users.id (1:1), so RLS can compare auth.uid().
-- -----------------------------------------------------------------------------
create table if not exists public.users (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null,
  email       text not null,
  phone       text,
  role        user_role not null default 'customer',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.users is 'Extended profile data for every authenticated person, 1:1 with auth.users.';

-- -----------------------------------------------------------------------------
-- 3. Table: services
-- The catalogue of bookable services and their price/duration.
-- -----------------------------------------------------------------------------
create table if not exists public.services (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  description   text,
  price         numeric(10, 2) not null check (price >= 0),
  duration_mins integer not null check (duration_mins > 0),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.services is 'Catalogue of services customers can book (haircut, beard grooming, etc).';

-- -----------------------------------------------------------------------------
-- 4. Table: bookings
-- One row per appointment. booking_date + start_time define the slot.
-- -----------------------------------------------------------------------------
create table if not exists public.bookings (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users(id) on delete cascade,
  service_id    uuid not null references public.services(id) on delete restrict,
  booking_date  date not null,
  start_time    time not null,
  status        booking_status not null default 'pending',
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- Prevents two active bookings from occupying the exact same slot.
  constraint unique_active_slot unique (booking_date, start_time)
);

comment on table public.bookings is 'Customer appointments. Booking-creation logic is implemented in a later phase.';

-- -----------------------------------------------------------------------------
-- 5. Table: payments
-- One row per payment attempt/result, linked 1:1 to a booking.
-- -----------------------------------------------------------------------------
create table if not exists public.payments (
  id                uuid primary key default gen_random_uuid(),
  booking_id        uuid not null references public.bookings(id) on delete cascade,
  user_id           uuid not null references public.users(id) on delete cascade,
  amount            numeric(10, 2) not null check (amount >= 0),
  status            payment_status not null default 'pending',
  provider          text,
  provider_ref_id   text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint unique_payment_per_booking unique (booking_id)
);

comment on table public.payments is 'Payment records for bookings. Payment integration is implemented in a later phase.';

-- -----------------------------------------------------------------------------
-- 6. Table: admin_profiles
-- Extra metadata for staff accounts (role = 'admin' in public.users).
-- Kept separate from public.users so admin-only fields never leak into the
-- customer profile shape, and so this table can be locked down harder.
-- -----------------------------------------------------------------------------
create table if not exists public.admin_profiles (
  user_id      uuid primary key references public.users(id) on delete cascade,
  designation  text not null default 'Staff',
  permissions  jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);

comment on table public.admin_profiles is 'Extended metadata for staff/admin accounts, 1:1 with public.users where role = admin.';

-- -----------------------------------------------------------------------------
-- 7. updated_at auto-touch trigger (reused by every table that has the column)
-- -----------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_users_updated_at on public.users;
create trigger trg_users_updated_at
  before update on public.users
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_services_updated_at on public.services;
create trigger trg_services_updated_at
  before update on public.services
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_bookings_updated_at on public.bookings;
create trigger trg_bookings_updated_at
  before update on public.bookings
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_payments_updated_at on public.payments;
create trigger trg_payments_updated_at
  before update on public.payments
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 8. Auto-create a public.users row whenever someone signs up via Supabase Auth
-- Reads full_name / phone out of the options.data passed to auth.signUp().
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, full_name, email, phone, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    new.email,
    new.raw_user_meta_data ->> 'phone',
    'customer'
  );
  return new;
end;
$$;

drop trigger if exists trg_on_auth_user_created on auth.users;
create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- 9. Indexes
-- -----------------------------------------------------------------------------
create index if not exists idx_bookings_user_id     on public.bookings(user_id);
create index if not exists idx_bookings_service_id   on public.bookings(service_id);
create index if not exists idx_bookings_date         on public.bookings(booking_date);
create index if not exists idx_payments_user_id      on public.payments(user_id);
create index if not exists idx_payments_booking_id   on public.payments(booking_id);
create index if not exists idx_services_is_active    on public.services(is_active);

-- =============================================================================
-- 10. Row Level Security
-- RLS is enabled on every table. With RLS on and NO matching policy, a query
-- returns zero rows / a write is rejected — so every access path a real user
-- needs must have an explicit policy below. The service_role key (server-side
-- only, never used in this frontend) bypasses RLS entirely for admin tooling.
-- =============================================================================

alter table public.users           enable row level security;
alter table public.services        enable row level security;
alter table public.bookings        enable row level security;
alter table public.payments        enable row level security;
alter table public.admin_profiles  enable row level security;

-- Helper: is the currently-authenticated user an admin?
-- SECURITY DEFINER + fixed search_path so it can read public.users safely
-- from inside RLS policies without those policies re-triggering it.
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.users
    where id = auth.uid() and role = 'admin'
  );
$$;

-- ---------------------------------------------------------------------------
-- Policies: public.users
-- ---------------------------------------------------------------------------

-- A person can read their own profile row.
-- Needed for: dashboard.js, profile.js, auth.js (getCurrentUserProfile).
drop policy if exists "users_select_own" on public.users;
create policy "users_select_own"
  on public.users for select
  using (auth.uid() = id);

-- Admins can read every profile row (needed for an eventual admin panel).
drop policy if exists "users_select_admin" on public.users;
create policy "users_select_admin"
  on public.users for select
  using (public.is_admin());

-- A person can update their own profile (name, phone) but the policy alone
-- doesn't stop them changing their own `role` — that is blocked by the
-- trigger below, which is the correct place to enforce it.
drop policy if exists "users_update_own" on public.users;
create policy "users_update_own"
  on public.users for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Row creation is handled exclusively by the handle_new_user trigger
-- (SECURITY DEFINER), so no INSERT policy is granted to regular clients —
-- the frontend should never insert into public.users directly.

-- Prevents a customer from promoting themselves to admin via a profile update.
create or replace function public.prevent_role_self_escalation()
returns trigger
language plpgsql
as $$
begin
  if new.role <> old.role and not public.is_admin() then
    raise exception 'Only an admin can change a user role.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_prevent_role_escalation on public.users;
create trigger trg_prevent_role_escalation
  before update on public.users
  for each row execute function public.prevent_role_self_escalation();

-- ---------------------------------------------------------------------------
-- Policies: public.services
-- ---------------------------------------------------------------------------

-- Everyone (including logged-out visitors) can view active services —
-- the price list on the home page must work without authentication.
drop policy if exists "services_select_public" on public.services;
create policy "services_select_public"
  on public.services for select
  using (is_active = true or public.is_admin());

-- Only admins can create, edit, or deactivate services.
drop policy if exists "services_insert_admin" on public.services;
create policy "services_insert_admin"
  on public.services for insert
  with check (public.is_admin());

drop policy if exists "services_update_admin" on public.services;
create policy "services_update_admin"
  on public.services for update
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "services_delete_admin" on public.services;
create policy "services_delete_admin"
  on public.services for delete
  using (public.is_admin());

-- ---------------------------------------------------------------------------
-- Policies: public.bookings
-- ---------------------------------------------------------------------------

-- A customer can see only their own bookings.
drop policy if exists "bookings_select_own" on public.bookings;
create policy "bookings_select_own"
  on public.bookings for select
  using (auth.uid() = user_id);

-- Admins can see every booking (needed to run the shop).
drop policy if exists "bookings_select_admin" on public.bookings;
create policy "bookings_select_admin"
  on public.bookings for select
  using (public.is_admin());

-- A customer may create a booking for themselves only.
-- (Booking-creation UI/logic ships in a later phase; the policy is in
-- place now so the schema is ready for it.)
drop policy if exists "bookings_insert_own" on public.bookings;
create policy "bookings_insert_own"
  on public.bookings for insert
  with check (auth.uid() = user_id);

-- A customer may update only their own booking, and only while it is still
-- pending or confirmed (e.g. to cancel it) — they cannot edit a completed
-- booking's history. Admins can update any booking in any state.
drop policy if exists "bookings_update_own" on public.bookings;
create policy "bookings_update_own"
  on public.bookings for update
  using (auth.uid() = user_id and status in ('pending', 'confirmed'))
  with check (auth.uid() = user_id);

drop policy if exists "bookings_update_admin" on public.bookings;
create policy "bookings_update_admin"
  on public.bookings for update
  using (public.is_admin())
  with check (public.is_admin());

-- Nobody can hard-delete a booking from the client — cancellation is a
-- status update, not a row deletion, so history is preserved. Only admins
-- retain delete rights for genuine data-cleanup needs.
drop policy if exists "bookings_delete_admin" on public.bookings;
create policy "bookings_delete_admin"
  on public.bookings for delete
  using (public.is_admin());

-- ---------------------------------------------------------------------------
-- Policies: public.payments
-- ---------------------------------------------------------------------------

-- A customer can view only their own payment records.
drop policy if exists "payments_select_own" on public.payments;
create policy "payments_select_own"
  on public.payments for select
  using (auth.uid() = user_id);

-- Admins can view every payment (needed for reconciliation).
drop policy if exists "payments_select_admin" on public.payments;
create policy "payments_select_admin"
  on public.payments for select
  using (public.is_admin());

-- No INSERT/UPDATE policy is granted to regular clients: payment records
-- must only be written by a trusted server process (e.g. a payment-provider
-- webhook running with the service_role key) once payment logic is built,
-- so a customer can never fabricate or edit their own "paid" status.
drop policy if exists "payments_write_admin" on public.payments;
create policy "payments_write_admin"
  on public.payments for insert
  with check (public.is_admin());

drop policy if exists "payments_update_admin" on public.payments;
create policy "payments_update_admin"
  on public.payments for update
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- Policies: public.admin_profiles
-- ---------------------------------------------------------------------------

-- An admin can read their own extended profile; admins can read all of them.
drop policy if exists "admin_profiles_select_own" on public.admin_profiles;
create policy "admin_profiles_select_own"
  on public.admin_profiles for select
  using (auth.uid() = user_id or public.is_admin());

-- Only an existing admin can create or edit admin_profiles rows — this is
-- how new staff accounts get provisioned, deliberately not self-service.
drop policy if exists "admin_profiles_write_admin" on public.admin_profiles;
create policy "admin_profiles_write_admin"
  on public.admin_profiles for insert
  with check (public.is_admin());

drop policy if exists "admin_profiles_update_admin" on public.admin_profiles;
create policy "admin_profiles_update_admin"
  on public.admin_profiles for update
  using (public.is_admin())
  with check (public.is_admin());

-- =============================================================================
-- 11. Seed data — starter service catalogue (safe to re-run)
-- =============================================================================
insert into public.services (name, description, price, duration_mins, is_active)
select * from (values
  ('Classic Haircut',      'A precise, tailored cut finished with a clean edge-up.',     300.00, 30, true),
  ('Beard Grooming',       'Shape, trim and hot-towel finish for a sharp beard line.',    200.00, 20, true),
  ('Cut & Beard Combo',    'Full haircut with beard grooming — our most popular pick.',   450.00, 50, true),
  ('Hair Styling',         'Wash, blow-dry and styling for a finished, ready-to-go look.', 250.00, 25, true),
  ('Hair Colour',          'Full or partial colour using ammonia-free professional tones.', 800.00, 60, true),
  ('Kids Haircut',         'A patient, gentle cut for younger guests, aged 12 and under.', 200.00, 25, true)
) as seed(name, description, price, duration_mins, is_active)
where not exists (select 1 from public.services where public.services.name = seed.name);

-- =============================================================================
-- End of Phase 1 schema.
-- =============================================================================
