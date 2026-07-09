-- =============================================================================
-- Dream Look — Migration 003a: Add 'no_show' enum value
-- Run this file ON ITS OWN, as a separate SQL Editor query, AFTER
-- 002_booking_engine.sql and BEFORE 003_advanced_booking_features.sql.
--
-- Why this is its own file: PostgreSQL will not allow a newly-added enum
-- value to be referenced (e.g. in a WHERE clause, constraint, or query)
-- within the same transaction that added it. Since the Supabase SQL Editor
-- runs each submitted script as one transaction, the enum addition must be
-- committed on its own before 003_advanced_booking_features.sql (which
-- uses 'no_show' in an EXCLUDE constraint) can run.
-- =============================================================================

alter type booking_status add value if not exists 'no_show';
