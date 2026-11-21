-- Product Promotion Support for Vendor Inventory and Community Feed
-- Allows vendors to promote existing products using daily coin budget and duration.

ALTER TABLE public.listings
  ADD COLUMN IF NOT EXISTS is_promoted BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS promotion_daily_coins INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS promotion_duration_days INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS promotion_starts_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS promotion_ends_at TIMESTAMPTZ;

ALTER TABLE public.community_posts
  ADD COLUMN IF NOT EXISTS is_promoted BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS promotion_daily_coins INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS promotion_duration_days INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS promotion_starts_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS promotion_ends_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_listings_promoted ON public.listings(is_promoted, promotion_ends_at);
CREATE INDEX IF NOT EXISTS idx_posts_promoted ON public.community_posts(is_promoted, promotion_ends_at);
