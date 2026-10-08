
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { MongoClient } from "npm:mongodb";
import { RtcTokenBuilder, RtcRole } from "npm:agora-access-token";

const AGORA_APP_ID = Deno.env.get("AGORA_APP_ID") ?? "";
const AGORA_APP_CERTIFICATE = Deno.env.get("AGORA_APP_CERTIFICATE") ?? "";
const MONGO_URI = Deno.env.get("MONGO_URI") ?? "";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { action, channelId, metadata, location, userId } = await req.json();

    // Resilient MongoDB Client Wrapper
    let mongoSuccess = false;
    let mongoErrorMsg = "";
    let activeStreams: any[] = [];

    try {
      const client = new MongoClient(MONGO_URI, {
        connectTimeoutMS: 5000,
        socketTimeoutMS: 5000,
        serverSelectionTimeoutMS: 5000,
      });
      await client.connect();
      const db = client.db("necxalive"); // Corrected to db() from database()
      const streams = db.collection("streams");

      if (action === 'start') {
        await streams.insertOne({
          channelId,
          hostId: userId,
          status: 'live',
          metadata,
          location,
          startedAt: new Date(),
        });
      } else if (action === 'list_active') {
        activeStreams = await streams.find({ status: 'live' }).toArray();
      }
      
      await client.close();
      mongoSuccess = true;
    } catch (e: any) {
      console.error("⚠️ Resilient MongoDB Operation Failed:", e.message || e);
      mongoErrorMsg = e.message || String(e);
    }

    if (action === 'start') {
      // 1. Verify Identity
      const supabase = createClient(
        Deno.env.get('SUPABASE_URL') ?? '',
        Deno.env.get('SUPABASE_ANON_KEY') ?? ''
      )
      const { data: profile } = await supabase
        .from('profiles')
        .select('verified')
        .eq('id', userId)
        .single()

      if (!profile?.verified) {
        return new Response(JSON.stringify({ error: 'Identity verification required to go live.' }), { 
          status: 403, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        })
      }

      if (!AGORA_APP_ID || !AGORA_APP_CERTIFICATE) {
        return new Response(JSON.stringify({ error: 'Missing Agora App Configuration' }), { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        })
      }

      // Generate actual Agora RTC Token (Valid for 24 hours)
      const expirationTimeInSeconds = 3600 * 24;
      const currentTimestamp = Math.floor(Date.now() / 1000);
      const privilegeExpiredTs = currentTimestamp + expirationTimeInSeconds;

      // Use UID 0 for publisher (Agora will auto-assign a UID on the client side if 0 is passed)
      const uid = 0; 

      const token = RtcTokenBuilder.buildTokenWithUid(
        AGORA_APP_ID,
        AGORA_APP_CERTIFICATE,
        channelId,
        uid,
        RtcRole.PUBLISHER,
        privilegeExpiredTs
      );

      return new Response(JSON.stringify({ 
        token, 
        appId: AGORA_APP_ID,
        mongo_synced: mongoSuccess,
        mongo_error: mongoErrorMsg
      }), { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      })
    }

    if (action === 'list_active') {
      return new Response(JSON.stringify(activeStreams), { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      })
    }

    return new Response(JSON.stringify({ status: 'ok', mongo_synced: mongoSuccess }), { 
      headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
    })
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message || 'Internal Server Error' }), { 
      status: 500, 
      headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
    })
  }
})
