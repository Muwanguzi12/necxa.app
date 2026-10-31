const fetch = require('node-fetch');
const sql = `
CREATE TABLE IF NOT EXISTS public.gift_notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id UUID NOT NULL,
    recipient_id UUID NOT NULL,
    gift_type TEXT NOT NULL,
    ncx_value INTEGER NOT NULL,
    message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    read_at TIMESTAMPTZ
);
ALTER TABLE public.gift_notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can read their own gift notifications" ON public.gift_notifications;
CREATE POLICY "Users can read their own gift notifications" ON public.gift_notifications FOR SELECT USING (auth.uid() = recipient_id OR auth.uid() = sender_id);
DROP POLICY IF EXISTS "Users can insert gift notifications" ON public.gift_notifications;
CREATE POLICY "Users can insert gift notifications" ON public.gift_notifications FOR INSERT WITH CHECK (auth.uid() = sender_id);
INSERT INTO storage.buckets (id, name, public) VALUES ('gift-icons', 'gift-icons', true) ON CONFLICT (id) DO NOTHING;
DROP POLICY IF EXISTS "Public Access" ON storage.objects;
CREATE POLICY "Public Access" ON storage.objects FOR SELECT USING ( bucket_id = 'gift-icons' );
`;

fetch('https://api.supabase.com/v1/projects/anregykcgolpgxecfxej/query', {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({ query: sql })
})
.then(res => res.text())
.then(console.log)
.catch(console.error);
