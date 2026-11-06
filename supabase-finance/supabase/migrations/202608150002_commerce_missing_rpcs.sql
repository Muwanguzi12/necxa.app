-- Commerce RPCs already exist on the remote DB with correct signatures.
-- This migration is a no-op placeholder to unblock the migration chain.
-- Existing remote signatures confirmed:
--   reserve_commerce_inventory(p_listing_id uuid, p_customer_id uuid, p_quantity integer, p_idempotency_key text) returns commerce_inventory_reservations
--   transition_commerce_order(p_order_id uuid, p_actor_id uuid, p_actor_role text, p_action text, p_driver_id uuid, p_metadata jsonb) returns jsonb
--
-- No changes needed: functions were already deployed correctly to the remote DB.
select 1;
