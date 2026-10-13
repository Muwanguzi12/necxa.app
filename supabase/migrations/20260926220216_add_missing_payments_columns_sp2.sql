-- Add missing columns to SP2 public.payments table expected by finance-engine
ALTER TABLE public.payments
ADD COLUMN IF NOT EXISTS purpose TEXT,
ADD COLUMN IF NOT EXISTS amount NUMERIC,
ADD COLUMN IF NOT EXISTS currency TEXT DEFAULT 'UGX';
