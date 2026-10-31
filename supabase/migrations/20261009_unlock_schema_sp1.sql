-- ============================================================
-- SP1 (Primary DB) – Unlock Details Schema
-- Covers all tables the smooth-action edge function reads/writes
-- when "Unlock Details ⚡" is tapped.
-- Run this in: Supabase Dashboard > lzdtrmjcwzalckszdzpt > SQL Editor
-- ============================================================

-- ── 1. EXTENSIONS ────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── 2. PROPERTIES TABLE ──────────────────────────────────────
-- This is the heart: smooth-action reads from here to find unlock_cost,
-- lister_id, agent_id and to check is_active/is_honeypot.
-- listing-create upserts into this table after a listing is published.

CREATE TABLE IF NOT EXISTS public.properties (
  id                   UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
  lister_id            UUID         REFERENCES auth.users(id) ON DELETE SET NULL,
  agent_id             UUID         REFERENCES auth.users(id) ON DELETE SET NULL,

  -- Core listing info
  title                TEXT         NOT NULL,
  description          TEXT         NOT NULL DEFAULT '',
  property_type        TEXT         NOT NULL DEFAULT 'apartment',  -- apartment, house, land, etc
  listing_type         TEXT         NOT NULL DEFAULT 'rent',       -- rent, sale, short_stay, lease

  -- Price (stored as UGX)
  price                NUMERIC      NOT NULL DEFAULT 0,
  price_type           TEXT         NOT NULL DEFAULT 'monthly',    -- monthly, nightly, once
  unlock_cost          NUMERIC      GENERATED ALWAYS AS (FLOOR(price * 0.10)) STORED,

  -- Physical details
  bedrooms             INT          NOT NULL DEFAULT 1,
  bathrooms            INT          NOT NULL DEFAULT 1,
  size_sqft            INT          NOT NULL DEFAULT 0,

  -- Location
  address              TEXT         NOT NULL DEFAULT '',
  city                 TEXT         NOT NULL DEFAULT 'Kampala',
  district             TEXT         NOT NULL DEFAULT 'Kampala',
  country              TEXT         NOT NULL DEFAULT 'Uganda',
  latitude             NUMERIC,
  longitude            NUMERIC,
  gps_latitude         NUMERIC,
  gps_longitude        NUMERIC,
  umeme_meter_number   TEXT,

  -- Media
  images               TEXT[]       NOT NULL DEFAULT '{}',
  bathroom_image_urls  TEXT[]       NOT NULL DEFAULT '{}',

  -- Verification & status flags
  is_verified          BOOLEAN      NOT NULL DEFAULT false,
  is_active            BOOLEAN      NOT NULL DEFAULT true,
  is_sold              BOOLEAN      NOT NULL DEFAULT false,
  is_honeypot          BOOLEAN      NOT NULL DEFAULT false,

  -- Escrow
  escrow_status        TEXT         NOT NULL DEFAULT 'available',  -- available, reserved, sold

  -- Counters (incremented by smooth-action)
  views_count          INT          NOT NULL DEFAULT 0,
  unlocks_count        INT          NOT NULL DEFAULT 0,
  reservations_count   INT          NOT NULL DEFAULT 0,

  -- Timestamps
  created_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS properties_updated_at ON public.properties;
CREATE TRIGGER properties_updated_at
  BEFORE UPDATE ON public.properties
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ── 3. PROFILES TABLE PATCH ───────────────────────────────────
-- The profiles table already exists (from Supabase Auth setup).
-- We just need to ensure the has_used_free_unlock column exists.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS has_used_free_unlock BOOLEAN NOT NULL DEFAULT false;

-- ── 4. UNLOCKS TABLE ─────────────────────────────────────────
-- smooth-action reads this to check if a user already unlocked a property.
-- smooth-action inserts here on free trial.
-- finance-engine (SP2) upserts here via PRIMARY_SUPABASE_SERVICE_ROLE_KEY after paid unlock.

CREATE TABLE IF NOT EXISTS public.unlocks (
  id                    UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
  property_id           UUID         NOT NULL REFERENCES public.properties(id) ON DELETE CASCADE,
  buyer_id              UUID         NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  seller_id             UUID         REFERENCES auth.users(id) ON DELETE SET NULL,
  agent_id              UUID         REFERENCES auth.users(id) ON DELETE SET NULL,

  -- Amount paid for the unlock (0 = free trial)
  unlock_amount         NUMERIC      NOT NULL DEFAULT 0,
  -- Full unlock cost at the time of unlock
  unlock_cost           NUMERIC      NOT NULL DEFAULT 0,

  -- Status
  status                TEXT         NOT NULL DEFAULT 'completed',  -- completed, pending, failed

  -- Timestamps when each piece of info was revealed
  address_revealed_at   TIMESTAMPTZ,
  contact_revealed_at   TIMESTAMPTZ,

  created_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  -- One unlock per buyer per property
  UNIQUE (property_id, buyer_id)
);

DROP TRIGGER IF EXISTS unlocks_updated_at ON public.unlocks;
CREATE TRIGGER unlocks_updated_at
  BEFORE UPDATE ON public.unlocks
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ── 5. ROW-LEVEL SECURITY (RLS) ──────────────────────────────

-- Properties: public read, only lister/agent can write
ALTER TABLE public.properties ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "properties_public_read" ON public.properties;
CREATE POLICY "properties_public_read"
  ON public.properties FOR SELECT
  USING (is_active = true AND is_honeypot = false);

DROP POLICY IF EXISTS "properties_lister_write" ON public.properties;
CREATE POLICY "properties_lister_write"
  ON public.properties FOR ALL
  USING (auth.uid() = lister_id OR auth.uid() = agent_id);

-- Service role bypasses RLS (finance-engine SP2 uses service key)

-- Unlocks: user can read their own unlocks, service role can write
ALTER TABLE public.unlocks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "unlocks_buyer_read" ON public.unlocks;
CREATE POLICY "unlocks_buyer_read"
  ON public.unlocks FOR SELECT
  USING (auth.uid() = buyer_id OR auth.uid() = seller_id OR auth.uid() = agent_id);

DROP POLICY IF EXISTS "unlocks_insert_own" ON public.unlocks;
CREATE POLICY "unlocks_insert_own"
  ON public.unlocks FOR INSERT
  WITH CHECK (auth.uid() = buyer_id);

-- ── 6. INDEXES ───────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_properties_active
  ON public.properties (is_active, is_honeypot, created_at DESC)
  WHERE is_active = true AND is_honeypot = false;

CREATE INDEX IF NOT EXISTS idx_properties_lister
  ON public.properties (lister_id);

CREATE INDEX IF NOT EXISTS idx_unlocks_buyer
  ON public.unlocks (buyer_id);

CREATE INDEX IF NOT EXISTS idx_unlocks_property_buyer
  ON public.unlocks (property_id, buyer_id);

-- ── 7. GRANT SERVICE ROLE ACCESS ─────────────────────────────
-- Allows finance-engine (SP2) to write unlocks via service role key
GRANT ALL ON public.unlocks   TO service_role;
GRANT ALL ON public.properties TO service_role;
