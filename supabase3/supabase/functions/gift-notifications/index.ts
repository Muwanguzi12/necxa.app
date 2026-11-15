import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    );

    const { recipientId, giftType, ncxValue, message } = await req.json();
    
    // Get the user who sent the gift
    const { data: { user } } = await supabaseClient.auth.getUser();
    if (!user) throw new Error('Unauthenticated');

    // Here we can trigger push notifications using Firebase Cloud Messaging (FCM) or other push services
    // For now, we will log it to the database for notification retrieval
    const { data, error } = await supabaseClient.from('gift_notifications').insert([
      {
        sender_id: user.id,
        recipient_id: recipientId,
        gift_type: giftType,
        ncx_value: ncxValue,
        message: message
      }
    ]).select().single();

    if (error) throw error;

    return new Response(
      JSON.stringify({ success: true, data }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
    );
  }
});
