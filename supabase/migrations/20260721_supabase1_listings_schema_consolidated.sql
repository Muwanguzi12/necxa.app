-- ════════════════════════════════════════════════════════════════════════════
-- SUPABASE 1 (Primary Database) – Consolidated Shopping Schema
-- This script ensures all required columns exist for the `listings` table,
-- matching exactly what the Flutter App and Edge Functions expect.
-- It uses IF NOT EXISTS so it will not destroy your existing data!
-- Run this in: Supabase Dashboard → SQL Editor (Supabase 1)
-- ════════════════════════════════════════════════════════════════════════════

-- 1. Ensure the profiles table has necessary columns (just in case)
alter table public.profiles
  add column if not exists trust_score numeric default 0,
  add column if not exists trust_score_tier text default 'new';

-- 2. Create the base listings table if it doesn't exist at all
create table if not exists public.listings (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 3. Add all required columns safely
alter table public.listings
  -- Core Identification
  add column if not exists title text,
  add column if not exists description text,
  add column if not exists sku text,
  add column if not exists category text default 'General',
  
  -- Financials & Inventory
  add column if not exists price numeric default 0,
  add column if not exists price_ugx numeric default 0,
  add column if not exists stock_count integer default 999,
  
  -- Media & Display
  add column if not exists image_url text,
  add column if not exists media_url text,
  add column if not exists thumbnail_url text,
  add column if not exists media_type text default 'image',
  add column if not exists film_hub_content text,
  add column if not exists photos jsonb default '[]'::jsonb,
  add column if not exists tags jsonb default '[]'::jsonb,
  
  -- Relationships / Ownership
  add column if not exists user_id uuid references public.profiles(id) on delete cascade,
  add column if not exists lister_id uuid references public.profiles(id) on delete cascade,
  
  -- Moderation & AI
  add column if not exists status text default 'active',
  add column if not exists is_verified boolean default false,
  add column if not exists ai_verification jsonb,
  add column if not exists ai_score numeric,
  add column if not exists ai_description text,
  
  -- Physical Logistics (for couriers)
  add column if not exists weight_kg numeric,
  add column if not exists length_cm numeric,
  add column if not exists width_cm numeric,
  add column if not exists height_cm numeric,
  add column if not exists latitude double precision,
  add column if not exists longitude double precision;

-- 4. Apply strict SKU constraint safely
alter table public.listings drop constraint if exists listings_sku_format;
alter table public.listings
  add constraint listings_sku_format check (sku ~ '^[0-9]{4}[A-Z]{3}$') not valid;

-- 5. Apply Logistics constraint safely
alter table public.listings drop constraint if exists listings_shipping_measurements_positive;
alter table public.listings
  add constraint listings_shipping_measurements_positive check (
    (weight_kg is null or weight_kg > 0) and
    (length_cm is null or length_cm > 0) and
    (width_cm is null or width_cm > 0) and
    (height_cm is null or height_cm > 0)
  );

-- 6. Indexes for Performance (Idempotent)
create unique index if not exists listings_sku_unique_idx on public.listings (sku) where sku is not null;
create index if not exists idx_listings_user on public.listings(user_id);
create index if not exists idx_listings_lister on public.listings(lister_id);
create index if not exists idx_listings_status on public.listings(status);
create index if not exists listings_price_idx on public.listings(price_ugx);
create index if not exists idx_listings_pagination on public.listings(created_at DESC);

-- 7. Ensure RLS (Row Level Security) is active and correct
alter table public.listings enable row level security;

drop policy if exists "Anyone can view active listings" on public.listings;
create policy "Anyone can view active listings" on public.listings for select 
    using (status = 'active' OR auth.uid() = user_id OR auth.uid() = lister_id);

drop policy if exists "Users can insert own listings" on public.listings;
create policy "Users can insert own listings" on public.listings for insert 
    with check (auth.uid() = user_id OR auth.uid() = lister_id);

drop policy if exists "Users can update own listings" on public.listings;
create policy "Users can update own listings" on public.listings for update 
    using (auth.uid() = user_id OR auth.uid() = lister_id);

-- 8. Refresh Schema Cache
NOTIFY pgrst, 'reload schema';
