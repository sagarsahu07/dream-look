-- =============================================================================
-- Dream Look — Migration 007: Critical Fix — Duplicate Function Overloads
-- Run in Supabase → SQL Editor AFTER 006_production_audit_fixes.sql.
--
-- ROOT CAUSE
-- `create or replace function` only replaces a function with the EXACT
-- SAME parameter list. When migration 003 added a trailing `p_barber_id`
-- parameter to `get_available_slots` (and similarly for `create_booking`),
-- it did not replace the original 002 version — it created a SECOND,
-- separate function with the same name and a different arity. Both
-- versions have coexisted in the database ever since.
--
-- IMPACT
-- Every call from the frontend (book-slot.js, dashboard.js reschedule
-- panel, admin-dashboard.js walk-in flow) invokes these functions with a
-- subset of arguments (omitting the newer p_barber_id / had omitted the
-- newer p_barber_id parameter). PostgREST cannot tell which of the two
-- same-named functions to use — a call like
-- `rpc('get_available_slots', { p_service_id, p_booking_date })` matches
-- BOTH the old 2-argument function and the new 3-argument function (whose
-- third parameter defaults to null), which PostgREST reports as
-- "Could not choose the best candidate function" (PGRST203) and refuses
-- to run at all. In practice this meant slot availability and booking
-- creation — the core of the entire product — were broken.
--
-- FIX
-- Explicitly drop the obsolete, superseded signatures. Only the current,
-- correct (shop_settings-aware, multi-barber-aware) versions remain.
-- =============================================================================

drop function if exists public.get_available_slots(uuid, date);
drop function if exists public.create_booking(uuid, date, time, text);

-- Sanity check (run manually, not part of the migration): after this file
-- runs, each of the following should return exactly ONE row.
--   select proname, pronargs from pg_proc where proname = 'get_available_slots';
--   select proname, pronargs from pg_proc where proname = 'create_booking';

-- =============================================================================
-- End of Migration 007.
-- =============================================================================
