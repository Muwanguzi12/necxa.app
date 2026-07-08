
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { MongoClient } from "npm:mongodb";
import { RtcTokenBuilder, RtcRole } from "npm:agora-access-token";

const AGORA_APP_ID = Deno.env.get("AGORA_APP_ID") ?? "";
const AGORA_APP_CERTIFICATE = Deno.env.get("AGORA_APP_CERTIFICATE") ?? "";
const MONGO_URI = Deno.env.get("MONGO_URI") ?? "";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function json(body: Record<string, unknown> | unknown[], status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function buildRtcToken(channelId: string, role: RtcRole) {
  if (!AGORA_APP_ID || !AGORA_APP_CERTIFICATE) {
    throw new Error('Missing Agora App Configuration')
  }

  const expirationTimeInSeconds = 3600 * 24;
  const currentTimestamp = Math.floor(Date.now() / 1000);
  const privilegeExpiredTs = currentTimestamp + expirationTimeInSeconds;

  return RtcTokenBuilder.buildTokenWithUid(
    AGORA_APP_ID,
    AGORA_APP_CERTIFICATE,
    channelId,
    0,
    role,
    privilegeExpiredTs,
  );
}

serve(async (req) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { action, channelId, metadata, location, userId, role } = await req.json();

    // Resilient MongoDB Client Wrapper
    let mongoSuccess = false;
    let mongoErrorMsg = "";
    let activeStreams: any[] = [];

    if (action === 'stop' || action === 'list_active') {
    try {
      const client = new MongoClient(MONGO_URI, {
        connectTimeoutMS: 5000,
        socketTimeoutMS: 5000,
        serverSelectionTimeoutMS: 5000,
      });
      await client.connect();
      const db = client.db("necxalive"); // Corrected to db() from database()
      const streams = db.collection("streams");

      if (action === 'stop') {
        await streams.updateMany(
          { channelId, hostId: userId, status: 'live' },
          { $set: { status: 'ended', endedAt: new Date() } },
        );
      } else if (action === 'list_active') {
        activeStreams = await streams.find({ status: 'live' }).toArray();
      }
      
      await client.close();
      mongoSuccess = true;
    } catch (e: any) {
      console.error("⚠️ Resilient MongoDB Operation Failed:", e.message || e);
      mongoErrorMsg = e.message || String(e);
    }
    }

    if (action === 'start') {
      const userIsAuthenticated = Boolean(userId && userId.trim())
      if (!userIsAuthenticated) {
        return json({ error: 'Authentication required to go live.' }, 401)
      }

      const token = buildRtcToken(channelId, RtcRole.PUBLISHER);

      try {
        const client = new MongoClient(MONGO_URI, {
          connectTimeoutMS: 5000,
          socketTimeoutMS: 5000,
          serverSelectionTimeoutMS: 5000,
        });
        await client.connect();
        const db = client.db("necxalive");
        await db.collection("streams").insertOne({
          channelId,
          hostId: userId,
          status: 'live',
          metadata,
          location,
          startedAt: new Date(),
        });
        await client.close();
        mongoSuccess = true;
        mongoErrorMsg = "";
      } catch (e: any) {
        console.error("Live stream sync failed:", e.message || e);
        mongoSuccess = false;
        mongoErrorMsg = e.message || String(e);
      }

      return json({ 
        token, 
        appId: AGORA_APP_ID,
        mongo_synced: mongoSuccess,
        mongo_error: mongoErrorMsg
      })
    }

    if (action === 'join') {
      const rtcRole = role === 'publisher' ? RtcRole.PUBLISHER : RtcRole.SUBSCRIBER;
      const token = buildRtcToken(channelId, rtcRole);
      return json({
        token,
        appId: AGORA_APP_ID,
        mongo_synced: mongoSuccess,
        mongo_error: mongoErrorMsg
      })
    }

    if (action === 'list_active') {
      return json(activeStreams)
    }

    if (action === 'stop') {
      return json({ status: 'stopped', mongo_synced: mongoSuccess, mongo_error: mongoErrorMsg })
    }

    return json({ status: 'ok', mongo_synced: mongoSuccess })
  } catch (error: any) {
    return json({ error: error.message || 'Internal Server Error' }, 500)
  }
})
