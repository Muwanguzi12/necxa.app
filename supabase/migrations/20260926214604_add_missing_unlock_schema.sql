-- Add missing 'has_used_free_unlock' column to profiles
ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS has_used_free_unlock BOOLEAN DEFAULT FALSE;

-- Add unique constraint to unlocks table for upsert operations
ALTER TABLE public.unlocks
ADD CONSTRAINT unlocks_property_buyer_key UNIQUE (property_id, buyer_id);
