-- ==============================================================================
-- GOOBOX SUPABASE CORE MIGRATION & FIXES (2026-10-19)
-- Project: anregykcgolpgxecfxej (https://anregykcgolpgxecfxej.supabase.co)
-- Target: Goobox Support, Moderation Reviews, Media Storage & Necxa Bridge Sync
-- ==============================================================================

BEGIN;

-- ------------------------------------------------------------------------------
-- 1. EXPAND SOURCE CHECK CONSTRAINT ON support_tickets
-- ------------------------------------------------------------------------------
-- Previously, only ('portal', 'gmail', 'manual') were permitted.
-- This caused all in-app reports ('report'), user inquiries ('in_app', 'necxa'),
-- and automated moderation events ('api', 'mobile') to fail with code 23514.
ALTER TABLE public.support_tickets DROP CONSTRAINT IF EXISTS support_tickets_source_check;
ALTER TABLE public.support_tickets ADD CONSTRAINT support_tickets_source_check
  CHECK (source IN ('portal', 'gmail', 'manual', 'report', 'in_app', 'necxa', 'api', 'mobile'));

COMMENT ON CONSTRAINT support_tickets_source_check ON public.support_tickets IS
  'Permits standard portal/gmail tickets alongside Necxa app in-app support requests, moderation reports, and mobile submissions.';

-- ------------------------------------------------------------------------------
-- 2. ENSURE necxa_user_id AND verified COLUMNS
-- ------------------------------------------------------------------------------
ALTER TABLE public.support_tickets
  ADD COLUMN IF NOT EXISTS necxa_user_id UUID,
  ADD COLUMN IF NOT EXISTS customer_name TEXT,
  ADD COLUMN IF NOT EXISTS customer_email TEXT,
  ADD COLUMN IF NOT EXISTS customer_phone TEXT,
  ADD COLUMN IF NOT EXISTS verified BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- ------------------------------------------------------------------------------
-- 3. ENSURE necxa_filters CATALOGUE TABLE & SEED DATA
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.necxa_filters (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name        TEXT NOT NULL,
  category            TEXT NOT NULL CHECK (category IN ('beauty','super_face','symmetry','glow','color','creative')),
  description         TEXT,
  asset_version       TEXT NOT NULL DEFAULT '1.0.0',
  asset_path          TEXT,
  thumbnail_path      TEXT,
  asset_size_bytes    BIGINT,
  asset_sha256        TEXT,
  engine_min_version  TEXT NOT NULL DEFAULT '1.0.0',
  is_enabled          BOOLEAN NOT NULL DEFAULT true,
  effect_params       JSONB,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.set_necxa_filter_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS necxa_filters_updated_at ON public.necxa_filters;
CREATE TRIGGER necxa_filters_updated_at
  BEFORE UPDATE ON public.necxa_filters
  FOR EACH ROW EXECUTE PROCEDURE public.set_necxa_filter_updated_at();

ALTER TABLE public.necxa_filters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read enabled filters" ON public.necxa_filters;
CREATE POLICY "Public read enabled filters"
  ON public.necxa_filters FOR SELECT
  USING (is_enabled = true);

-- Seed default smart filters if empty
INSERT INTO public.necxa_filters (display_name, category, description, is_enabled, effect_params)
SELECT * FROM (VALUES
  ('Natural', 'beauty',   'Subtle skin smoothing, warm tones',             true, '{"brightness":0.05,"contrast":1.05,"saturation":1.1,"hue":0.0}'::jsonb),
  ('Cinema',  'color',    'Orange and teal cinematic grade',               true, '{"brightness":-0.05,"contrast":1.15,"saturation":0.9,"hue":0.08,"colorMatrixPreset":"cinema"}'::jsonb),
  ('Neon',    'creative', 'Purple tint high saturation',                   true, '{"brightness":0.0,"contrast":1.1,"saturation":1.6,"hue":-0.15,"colorMatrixPreset":"neon"}'::jsonb),
  ('Noir',    'color',    'Black and white desaturation',                  true, '{"brightness":0.0,"contrast":1.2,"saturation":0.0,"hue":0.0,"colorMatrixPreset":"grayscale"}'::jsonb),
  ('Vivid',   'color',    'Boosted vibrance and clarity',                  true, '{"brightness":0.05,"contrast":1.1,"saturation":1.5,"hue":0.0}'::jsonb),
  ('Glow',    'glow',     'Soft warm highlight bloom',                     true, '{"brightness":0.12,"contrast":0.95,"saturation":1.2,"hue":0.02}'::jsonb),
  ('Golden',  'beauty',   'Warm golden hour skin tone',                    true, '{"brightness":0.08,"contrast":1.05,"saturation":1.15,"hue":0.06}'::jsonb),
  ('Arctic',  'color',    'Cool blue desaturated winter feel',             true, '{"brightness":0.0,"contrast":1.1,"saturation":0.85,"hue":-0.08}'::jsonb),
  ('Moody',   'creative', 'Deep shadows high contrast cinematic',          true, '{"brightness":-0.1,"contrast":1.3,"saturation":0.8,"hue":0.0}'::jsonb),
  ('Dream',   'glow',     'Soft pastel slightly overexposed',              true, '{"brightness":0.15,"contrast":0.9,"saturation":1.1,"hue":0.03}'::jsonb)
) AS v(display_name, category, description, is_enabled, effect_params)
WHERE NOT EXISTS (SELECT 1 FROM public.necxa_filters LIMIT 1);

-- ------------------------------------------------------------------------------
-- 4. ENSURE gift_notifications TABLE
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.gift_notifications (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id     UUID NOT NULL,
  recipient_id  UUID NOT NULL,
  gift_type     TEXT NOT NULL,
  ncx_value     NUMERIC DEFAULT 0,
  message       TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  read_at       TIMESTAMPTZ
);

ALTER TABLE public.gift_notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow select gift_notifications" ON public.gift_notifications;
CREATE POLICY "Allow select gift_notifications"
  ON public.gift_notifications FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Allow insert gift_notifications" ON public.gift_notifications;
CREATE POLICY "Allow insert gift_notifications"
  ON public.gift_notifications FOR INSERT
  WITH CHECK (true);

-- ------------------------------------------------------------------------------
-- 5. STORAGE BUCKETS & RLS POLICIES
-- ------------------------------------------------------------------------------
-- Ensure public buckets exist for Experience try-ons, filters, ticket attachments, and gifts.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('user-tryons', 'user-tryons', true, 52428800, ARRAY['image/jpeg', 'image/png', 'image/webp']),
  ('necxa-filters', 'necxa-filters', true, 104857600, NULL),
  ('ticket-attachments', 'ticket-attachments', true, 52428800, NULL),
  ('gift-icons', 'gift-icons', true, 10485760, ARRAY['image/png', 'image/webp', 'image/svg+xml'])
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = COALESCE(EXCLUDED.file_size_limit, storage.buckets.file_size_limit),
  allowed_mime_types = COALESCE(EXCLUDED.allowed_mime_types, storage.buckets.allowed_mime_types);

-- Policies for user-tryons
DROP POLICY IF EXISTS "Public user-tryons select" ON storage.objects;
CREATE POLICY "Public user-tryons select" ON storage.objects
  FOR SELECT USING (bucket_id = 'user-tryons');

DROP POLICY IF EXISTS "Public user-tryons upload" ON storage.objects;
CREATE POLICY "Public user-tryons upload" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'user-tryons');

DROP POLICY IF EXISTS "Public user-tryons update" ON storage.objects;
CREATE POLICY "Public user-tryons update" ON storage.objects
  FOR UPDATE USING (bucket_id = 'user-tryons') WITH CHECK (bucket_id = 'user-tryons');

DROP POLICY IF EXISTS "Public user-tryons delete" ON storage.objects;
CREATE POLICY "Public user-tryons delete" ON storage.objects
  FOR DELETE USING (bucket_id = 'user-tryons');

-- Policies for necxa-filters
DROP POLICY IF EXISTS "Public necxa-filters select" ON storage.objects;
CREATE POLICY "Public necxa-filters select" ON storage.objects
  FOR SELECT USING (bucket_id = 'necxa-filters');

-- Policies for ticket-attachments
DROP POLICY IF EXISTS "Public ticket-attachments select" ON storage.objects;
CREATE POLICY "Public ticket-attachments select" ON storage.objects
  FOR SELECT USING (bucket_id = 'ticket-attachments');

DROP POLICY IF EXISTS "Public ticket-attachments upload" ON storage.objects;
CREATE POLICY "Public ticket-attachments upload" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'ticket-attachments');

-- Policies for gift-icons
DROP POLICY IF EXISTS "Public gift-icons select" ON storage.objects;
CREATE POLICY "Public gift-icons select" ON storage.objects
  FOR SELECT USING (bucket_id = 'gift-icons');

-- ------------------------------------------------------------------------------
-- 6. RLS POLICIES FOR SUPPORT TABLES
-- ------------------------------------------------------------------------------
-- support_tickets RLS
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role full access on support_tickets" ON public.support_tickets;
CREATE POLICY "Service role full access on support_tickets"
  ON public.support_tickets FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS "Allow select support_tickets" ON public.support_tickets;
CREATE POLICY "Allow select support_tickets"
  ON public.support_tickets FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Allow insert support_tickets" ON public.support_tickets;
CREATE POLICY "Allow insert support_tickets"
  ON public.support_tickets FOR INSERT
  WITH CHECK (true);

DROP POLICY IF EXISTS "Allow update support_tickets" ON public.support_tickets;
CREATE POLICY "Allow update support_tickets"
  ON public.support_tickets FOR UPDATE
  USING (true)
  WITH CHECK (true);

-- ticket_messages RLS
ALTER TABLE public.ticket_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role full access on ticket_messages" ON public.ticket_messages;
CREATE POLICY "Service role full access on ticket_messages"
  ON public.ticket_messages FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS "Allow select ticket_messages" ON public.ticket_messages;
CREATE POLICY "Allow select ticket_messages"
  ON public.ticket_messages FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Allow insert ticket_messages" ON public.ticket_messages;
CREATE POLICY "Allow insert ticket_messages"
  ON public.ticket_messages FOR INSERT
  WITH CHECK (true);

-- ticket_replies RLS
ALTER TABLE public.ticket_replies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role full access on ticket_replies" ON public.ticket_replies;
CREATE POLICY "Service role full access on ticket_replies"
  ON public.ticket_replies FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS "Allow select ticket_replies" ON public.ticket_replies;
CREATE POLICY "Allow select ticket_replies"
  ON public.ticket_replies FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Allow insert ticket_replies" ON public.ticket_replies;
CREATE POLICY "Allow insert ticket_replies"
  ON public.ticket_replies FOR INSERT
  WITH CHECK (true);

-- ------------------------------------------------------------------------------
-- 7. PERFORMANCE & LOOKUP INDEXES
-- ------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS support_tickets_necxa_user_idx
  ON public.support_tickets (necxa_user_id)
  WHERE necxa_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS support_tickets_status_updated_idx
  ON public.support_tickets (status, updated_at DESC);

CREATE INDEX IF NOT EXISTS support_tickets_customer_email_idx
  ON public.support_tickets (customer_email);

CREATE INDEX IF NOT EXISTS support_tickets_source_idx
  ON public.support_tickets (source);

CREATE INDEX IF NOT EXISTS ticket_messages_ticket_created_idx
  ON public.ticket_messages (ticket_id, created_at DESC);

CREATE INDEX IF NOT EXISTS ticket_replies_ticket_created_idx
  ON public.ticket_replies (ticket_id, created_at DESC);

-- ------------------------------------------------------------------------------
-- 8. AUTO-UPDATE UPDATED_AT TRIGGER ON support_tickets
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_support_ticket_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS support_tickets_set_updated_at ON public.support_tickets;
CREATE TRIGGER support_tickets_set_updated_at
  BEFORE UPDATE ON public.support_tickets
  FOR EACH ROW EXECUTE FUNCTION public.set_support_ticket_updated_at();

COMMIT;
