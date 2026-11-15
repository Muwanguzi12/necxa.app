-- ============================================================
-- SP2 (Finance Engine DB) – Complete Payment Schema
-- Tables used by finance-engine for the property unlock flow
-- and the full wallet/NCX coin system.
-- Run in: Supabase Dashboard > ayvescksetiuekoyfqar > SQL Editor
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Auto-update helper ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END; $$;

-- ══════════════════════════════════════════════════════════════
-- 1. PROFILES (mirror of SP1 – lightweight copy for joins)
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.profiles (
  id            UUID        PRIMARY KEY,          -- same UUID as SP1 auth.users
  full_name     TEXT,
  first_name    TEXT,
  last_name     TEXT,
  email         TEXT,
  phone         TEXT,
  avatar_url    TEXT,
  username      TEXT,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ══════════════════════════════════════════════════════════════
-- 2. WALLETS  (NCX Coin + UGX balances per user)
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.wallets (
  id               UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id          UUID        NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE CASCADE,
  ncx_balance      NUMERIC     NOT NULL DEFAULT 0 CHECK (ncx_balance >= 0),
  ugx_balance      NUMERIC     NOT NULL DEFAULT 0 CHECK (ugx_balance >= 0),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS wallets_updated_at ON public.wallets;
CREATE TRIGGER wallets_updated_at
  BEFORE UPDATE ON public.wallets
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ══════════════════════════════════════════════════════════════
-- 3. IMMUTABLE FINANCIAL LEDGER (append-only audit trail)
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.immutable_financial_ledger (
  id             UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id        UUID        NOT NULL REFERENCES public.profiles(id),
  entry_type     TEXT        NOT NULL,       -- 'ncx_debit', 'ncx_credit', 'ugx_debit', etc.
  amount         NUMERIC     NOT NULL,
  currency       TEXT        NOT NULL,       -- 'NCX' or 'UGX'
  direction      TEXT        NOT NULL,       -- 'debit' | 'credit'
  balance_after  NUMERIC     NOT NULL,
  metadata       JSONB       DEFAULT '{}',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- No UPDATE trigger – ledger rows are immutable
CREATE INDEX IF NOT EXISTS idx_ledger_user ON public.immutable_financial_ledger (user_id, created_at DESC);

-- ══════════════════════════════════════════════════════════════
-- 4. PAYMENTS  (all fiat + NCX transactions — the unlock bridge)
-- ══════════════════════════════════════════════════════════════
-- This is the KEY table. When "Authorize Payment" is pressed:
--   • Pesapal / MTN / Airtel path → creates a 'pending' row here
--   • property_unlock_status polls this to know when to write to SP1
--   • NCX path skips Pesapal but still gets a 'completed' row for audit
CREATE TABLE IF NOT EXISTS public.payments (
  id                  UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id             UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,

  -- Idempotency key = what Flutter sends as paymentId for polling
  idempotency_key     TEXT        NOT NULL UNIQUE,

  -- Payment provider
  provider            TEXT        NOT NULL,      -- 'pesapal' | 'ncx_internal' | 'wallet_balance' | 'mtn'
  provider_reference  TEXT,                      -- Pesapal orderTrackingId

  -- What this payment is for
  purpose             TEXT        NOT NULL,      -- 'property_unlock' | 'coin_purchase' | 'shop_purchase' | 'escrow_deposit'

  -- Amount in UGX (or NCX coins for ncx_internal)
  amount              NUMERIC     NOT NULL,
  currency            TEXT        NOT NULL DEFAULT 'UGX',   -- 'UGX' | 'NCX'

  -- Status lifecycle
  status              TEXT        NOT NULL DEFAULT 'pending', -- 'pending' | 'completed' | 'failed'
  settled_at          TIMESTAMPTZ,

  -- Raw request payload (e.g., { "listingId": "...", "method": "card" })
  request             JSONB       DEFAULT '{}',
  -- Raw response from Pesapal / internal
  response            JSONB       DEFAULT '{}',

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS payments_updated_at ON public.payments;
CREATE TRIGGER payments_updated_at
  BEFORE UPDATE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_payments_user      ON public.payments (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_payments_purpose   ON public.payments (purpose, status);
CREATE INDEX IF NOT EXISTS idx_payments_provider  ON public.payments (provider_reference) WHERE provider_reference IS NOT NULL;

-- ══════════════════════════════════════════════════════════════
-- 5. COIN PACKS  (NCX purchase bundles shown in app)
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.coin_packs (
  id           UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  name         TEXT        NOT NULL,
  ncx_amount   INT         NOT NULL,             -- coins the user gets
  fiat_price   NUMERIC     NOT NULL,             -- price in UGX
  fiat         NUMERIC     GENERATED ALWAYS AS (fiat_price) STORED,
  ncx          INT         GENERATED ALWAYS AS (ncx_amount) STORED,
  is_active    BOOLEAN     NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed with default packs if empty
INSERT INTO public.coin_packs (name, ncx_amount, fiat_price)
SELECT * FROM (VALUES
  ('Starter',    50,   5000),
  ('Standard',  230,  20000),
  ('Pro',       600,  50000),
  ('Elite',    1400, 100000)
) AS v(name, ncx_amount, fiat_price)
WHERE NOT EXISTS (SELECT 1 FROM public.coin_packs LIMIT 1);

-- ══════════════════════════════════════════════════════════════
-- 6. FINANCE FEATURE UNLOCKS  (used by unlock_feature action)
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.finance_feature_unlocks (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  feature_id  TEXT        NOT NULL,
  unlocked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, feature_id)
);

-- ══════════════════════════════════════════════════════════════
-- 7. WITHDRAWALS  (MTN MoMo cashouts)
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.withdrawals (
  id                  UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id             UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  method              TEXT        NOT NULL DEFAULT 'mtn',   -- 'mtn' | 'airtel'
  amount_ncx          NUMERIC     NOT NULL,
  amount_ugx          NUMERIC     NOT NULL,
  workflow_status     TEXT        NOT NULL DEFAULT 'pending', -- 'pending' | 'processing' | 'completed' | 'failed'
  status              TEXT        NOT NULL DEFAULT 'pending', -- legacy alias kept for compatibility
  provider_reference  TEXT,
  metadata            JSONB       DEFAULT '{}',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS withdrawals_updated_at ON public.withdrawals;
CREATE TRIGGER withdrawals_updated_at
  BEFORE UPDATE ON public.withdrawals
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ══════════════════════════════════════════════════════════════
-- 8. WITHDRAWAL OTPS  (OTP verification before cashout)
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.withdrawal_otps (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  code_hash   TEXT        NOT NULL,
  expires_at  TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '10 minutes'),
  used        BOOLEAN     NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id)
);

-- ══════════════════════════════════════════════════════════════
-- 9. FINANCE CONFIG  (key-value config, e.g. platform fee %)
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.finance_config (
  key         TEXT        PRIMARY KEY,
  value       TEXT        NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.finance_config (key, value)
VALUES ('gift_platform_fee_basis_points', '1000')  -- 10%
ON CONFLICT (key) DO NOTHING;

-- ══════════════════════════════════════════════════════════════
-- 10. charge_ncx_purpose RPC  (called for NCX coin unlocks)
-- ══════════════════════════════════════════════════════════════
-- Deducts NCX coins from the wallet, writes a ledger entry.
-- Called by finance-engine for: property_unlock, feature_unlock, distribution_charge.
CREATE OR REPLACE FUNCTION public.charge_ncx_purpose(
  p_user_id        UUID,
  p_amount_ncx     INT,
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
  -- Idempotency check
  IF EXISTS (
    SELECT 1 FROM public.immutable_financial_ledger
    WHERE metadata->>'idempotency_key' = p_idempotency_key
  ) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true);
  END IF;

  -- Lock wallet row
  SELECT * INTO v_wallet FROM public.wallets
  WHERE user_id = p_user_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Wallet not found');
  END IF;

  v_balance := v_wallet.ncx_balance;
  IF v_balance < p_amount_ncx THEN
    RETURN jsonb_build_object('success', false, 'message',
      FORMAT('Insufficient NCX balance. Have %s, need %s', v_balance, p_amount_ncx));
  END IF;

  -- Deduct
  UPDATE public.wallets
  SET ncx_balance = ncx_balance - p_amount_ncx,
      updated_at  = NOW()
  WHERE user_id = p_user_id;

  -- Write ledger
  INSERT INTO public.immutable_financial_ledger
    (user_id, entry_type, amount, currency, direction, balance_after, metadata)
  VALUES (
    p_user_id,
    p_purpose || '_debit',
    p_amount_ncx,
    'NCX',
    'debit',
    v_balance - p_amount_ncx,
    jsonb_build_object(
      'purpose',         p_purpose,
      'reference',       p_reference,
      'idempotency_key', p_idempotency_key
    )
  );

  RETURN jsonb_build_object(
    'success',             true,
    'ncx_charged',         p_amount_ncx,
    'coin_balance_after',  v_balance - p_amount_ncx
  );
END;
$$;

-- ══════════════════════════════════════════════════════════════
-- 11. ROW LEVEL SECURITY
-- ══════════════════════════════════════════════════════════════
ALTER TABLE public.wallets                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.immutable_financial_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawals              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coin_packs              ENABLE ROW LEVEL SECURITY;

-- Wallets: user sees only their own
DROP POLICY IF EXISTS "wallet_owner" ON public.wallets;
CREATE POLICY "wallet_owner" ON public.wallets
  FOR ALL USING (auth.uid() = user_id);

-- Payments: user sees only their own
DROP POLICY IF EXISTS "payment_owner" ON public.payments;
CREATE POLICY "payment_owner" ON public.payments
  FOR ALL USING (auth.uid() = user_id);

-- Ledger: read-only for owner
DROP POLICY IF EXISTS "ledger_owner_read" ON public.immutable_financial_ledger;
CREATE POLICY "ledger_owner_read" ON public.immutable_financial_ledger
  FOR SELECT USING (auth.uid() = user_id);

-- Coin packs: everyone can read active packs
DROP POLICY IF EXISTS "coin_packs_public_read" ON public.coin_packs;
CREATE POLICY "coin_packs_public_read" ON public.coin_packs
  FOR SELECT USING (is_active = true);

-- Withdrawals: owner only
DROP POLICY IF EXISTS "withdrawal_owner" ON public.withdrawals;
CREATE POLICY "withdrawal_owner" ON public.withdrawals
  FOR ALL USING (auth.uid() = user_id);

-- Service role bypasses RLS for all finance operations
GRANT ALL ON public.payments                  TO service_role;
GRANT ALL ON public.wallets                   TO service_role;
GRANT ALL ON public.immutable_financial_ledger TO service_role;
GRANT ALL ON public.withdrawals               TO service_role;
GRANT ALL ON public.profiles                  TO service_role;
GRANT EXECUTE ON FUNCTION public.charge_ncx_purpose(UUID, INT, TEXT, TEXT, TEXT) TO service_role;

