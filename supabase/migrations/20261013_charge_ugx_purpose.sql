-- Migration: Add charge_ugx_purpose RPC for Fiat Wallet property unlocks and debits
-- Applied against SP2 (Finance Supabase)

CREATE OR REPLACE FUNCTION public.charge_ugx_purpose(
  p_user_id        UUID,
  p_amount_ugx     NUMERIC,
  p_purpose        TEXT,
  p_reference      TEXT,
  p_idempotency_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_wallet     public.wallets%ROWTYPE;
  v_balance    NUMERIC;
BEGIN
  -- 1. Idempotency check: if this operation was already processed, return success immediately
  IF EXISTS (
    SELECT 1 FROM public.immutable_financial_ledger
    WHERE metadata->>'idempotency_key' = p_idempotency_key
  ) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true);
  END IF;

  -- 2. Lock wallet row for update
  SELECT * INTO v_wallet FROM public.wallets
  WHERE user_id = p_user_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Wallet not found for this user.');
  END IF;

  v_balance := COALESCE(v_wallet.ugx_balance, 0);
  IF v_balance < p_amount_ugx THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', FORMAT('Insufficient UGX balance. Your wallet has UGX %s, but UGX %s is required.', v_balance, p_amount_ugx)
    );
  END IF;

  -- 3. Deduct from ugx_balance
  UPDATE public.wallets
  SET ugx_balance = ugx_balance - p_amount_ugx,
      updated_at  = NOW()
  WHERE user_id = p_user_id;

  -- 4. Record in immutable ledger
  INSERT INTO public.immutable_financial_ledger
    (user_id, entry_type, amount, currency, direction, balance_after, metadata)
  VALUES (
    p_user_id,
    p_purpose || '_debit',
    p_amount_ugx,
    'UGX',
    'debit',
    v_balance - p_amount_ugx,
    jsonb_build_object(
      'purpose',         p_purpose,
      'reference',       p_reference,
      'idempotency_key', p_idempotency_key
    )
  );

  RETURN jsonb_build_object(
    'success',            true,
    'ugx_charged',        p_amount_ugx,
    'fiat_balance_after', v_balance - p_amount_ugx
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.charge_ugx_purpose(UUID, NUMERIC, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.charge_ugx_purpose(UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;
