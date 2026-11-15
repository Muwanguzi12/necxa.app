-- Create gifts schema/table for notifications
CREATE TABLE public.gift_notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id UUID NOT NULL,
    recipient_id UUID NOT NULL,
    gift_type TEXT NOT NULL,
    ncx_value INTEGER NOT NULL,
    message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    read_at TIMESTAMPTZ
);

-- Enable RLS
ALTER TABLE public.gift_notifications ENABLE ROW LEVEL SECURITY;

-- Policies for gift_notifications
CREATE POLICY "Users can read their own gift notifications"
    ON public.gift_notifications
    FOR SELECT
    USING (auth.uid() = recipient_id OR auth.uid() = sender_id);

CREATE POLICY "Users can insert gift notifications"
    ON public.gift_notifications
    FOR INSERT
    WITH CHECK (auth.uid() = sender_id);

-- Create a storage bucket for gift icons
INSERT INTO storage.buckets (id, name, public)
VALUES ('gift-icons', 'gift-icons', true)
ON CONFLICT (id) DO NOTHING;

-- Policies for storage bucket
CREATE POLICY "Public Access" 
ON storage.objects FOR SELECT 
USING ( bucket_id = 'gift-icons' );
