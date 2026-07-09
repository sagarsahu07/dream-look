-- =============================================================================
-- Dream Look — Migration 004a: Add 'arrived' / 'in_service' enum values
-- Run this file ON ITS OWN, as a separate SQL Editor query, AFTER
-- 003a_add_enum_no_show.sql + 003_advanced_booking_features.sql, and
-- BEFORE 004_admin_panel.sql.
--
-- Same reason as 003a: PostgreSQL will not allow a newly-added enum value
-- to be used in the same transaction that added it, and the Supabase SQL
-- Editor runs each submitted script as one transaction.
-- =============================================================================

alter type booking_status add value if not exists 'arrived';
alter type booking_status add value if not exists 'in_service';
