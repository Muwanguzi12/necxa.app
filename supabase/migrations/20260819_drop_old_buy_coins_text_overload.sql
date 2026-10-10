-- ================================================================
-- SUPERSEDED: This migration is now covered by:
--   20260819_coin_provenance_system.sql
--
-- That migration drops BOTH old overloads (text and finance_currency enum)
-- and creates the canonical, richer version with full coin provenance tracking.
-- This file is kept as a no-op placeholder so Supabase migration history
-- does not break if it was already applied.
-- ================================================================

-- No-op: both drops are handled in 20260819_coin_provenance_system.sql
select 1;
