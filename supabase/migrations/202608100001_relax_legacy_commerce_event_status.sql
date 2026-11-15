-- Canonical lifecycle events write order_status. The original enum-backed
-- to_status column cannot represent newer states such as confirmed or
-- driver_assigned, so retain it for old readers but no longer require it.
alter table public.commerce_order_events
  alter column to_status drop not null;

