import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { MongoClient } from "npm:mongodb"
import { decode } from "https://deno.land/std@0.168.0/encoding/base64.ts"

const MONGO_URI = Deno.env.get('MONGO_URI')

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-primary-jwt',
}

// ─── Live Safety Prompt ───────────────────────────────────────────────────────
// Necxa proprietary content policy scanner for live stream frame moderation.
const LIVE_SAFETY_PROMPT = `You are a content safety AI for a live streaming platform.
Analyze this video frame image for the following violations. Be strict but fair.

Categories to detect:
1. PORNOGRAPHIC - sexual content, nudity, explicit acts
2. DRUG_ABUSE - drug use, paraphernalia, substance abuse (exclude obvious medicine)
3. CHILD_SAFETY - minors in inappropriate situations, grooming behavior, CSAM
4. DANGEROUS_CONTENT - weapons being brandished, self-harm, physical violence, explosives
5. HATE_SPEECH_DISPLAY - hate symbols, racist imagery, slurs visible on screen

Return ONLY valid JSON with no markdown:
{
  "safe": boolean,
  "flags": {
    "pornographic": boolean,
    "drug_abuse": boolean,
    "child_safety": boolean,
    "dangerous_content": boolean,
    "hate_speech_display": boolean
  },
  "severity": "none" | "low" | "medium" | "high" | "critical",
  "reason": "brief explanation if not safe, null if safe",
  "confidence": number (0.0 to 1.0)
}`

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const primaryJwt = req.headers.get("x-primary-jwt")
    if (!primaryJwt) {
      return new Response(JSON.stringify({ error: "Unauthorized: missing x-primary-jwt" }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // Dynamic JWT validation against primary Supabase project
    const PRIMARY_SUPABASE_URL = Deno.env.get('PRIMARY_SUPABASE_URL') || 'https://lzdtrmjcwzalckszdzpt.supabase.co'
    const PRIMARY_SUPABASE_ANON_KEY = Deno.env.get('PRIMARY_SUPABASE_ANON_KEY') || 'sb_publishable_lLcn4V9uIIgs3B59cHVXWg_1-PNsUfR'

    const primaryClient = createClient(
      PRIMARY_SUPABASE_URL,
      PRIMARY_SUPABASE_ANON_KEY,
      { global: { headers: { Authorization: `Bearer ${primaryJwt}` } } }
    )

    const { data: { user }, error: userError } = await primaryClient.auth.getUser()
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized: invalid primary JWT" }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    const payload = await req.json()
    const { type, mediaBase64, mimeType, textContent, action, channelId } = payload

    if (!mediaBase64 && !payload.videoFrames) {
      return new Response(JSON.stringify({ error: 'No mediaBase64 or videoFrames provided' }), {
        status: 400, headers: corsHeaders
      })
    }

      // ─── LIVE SAFETY SCAN ─────────────────────────────────────────────────────
    if (action === 'live_safety_scan') {
      if (!mediaBase64) {
        return new Response(JSON.stringify({ error: 'No mediaBase64 provided for live safety scan' }), {
          status: 400, headers: corsHeaders
        })
      }
      const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL') || 'https://api.necxa.uk';
      
      const base64Data = mediaBase64.replace(/^data:\w+\/\w+;base64,/, "");
      const mediaBytes = decode(base64Data);
      const formData = new FormData();
      formData.append('frame', new Blob([mediaBytes], { type: mimeType || 'image/jpeg' }), 'frame.jpg');

      let scanResult = { safe: true, flags: {}, severity: "none", reason: null, confidence: 0 };
      
      try {
        const aiRes = await fetch(`${NECXA_AI_URL}/api/verify/live-frame`, { method: 'POST', body: formData });
        if (aiRes.ok) scanResult = await aiRes.json();
      } catch (e) {
        console.error("Cloudflare Live Safety Error:", e);
      }

      // ── Log violations to MongoDB (live layer), not Supabase ────────────────
      if (!scanResult.safe && scanResult.severity !== 'none') {
        const activeFlags = Object.entries(scanResult.flags || {})
          .filter(([_, v]) => v === true)
          .map(([k]) => k)

        let mongo: MongoClient | null = null
        try {
          mongo = new MongoClient(MONGO_URI, {
            connectTimeoutMS: 4000,
            socketTimeoutMS: 4000,
            serverSelectionTimeoutMS: 4000,
          })
          await mongo.connect()
          const db = mongo.db('necxalive')

          // stream_violations collection — mirrors the same DB as stream_chat / stream_events
          await db.collection('stream_violations').insertOne({
            streamerId: user.id,
            channelId: channelId ?? null,
            violationType: 'live_frame',
            categories: activeFlags,
            severity: scanResult.severity,
            reason: scanResult.reason,
            confidence: scanResult.confidence,
            reviewed: false,
            autoActioned: scanResult.severity === 'critical' || activeFlags.includes('child_safety'),
            timestamp: new Date(),
          })

          console.log(`🚨 MongoDB Violation Logged: [${activeFlags.join(', ')}] severity=${scanResult.severity} channel=${channelId}`)
        } catch (mongoErr: any) {
          // Non-fatal — violation detection still returns the result even if logging fails.
          console.error('⚠️ MongoDB violation log failed:', mongoErr.message)
        } finally {
          try { await mongo?.close() } catch (_) {}
        }
      }

      return new Response(JSON.stringify({
        safe: scanResult.safe,
        flags: scanResult.flags ?? {},
        severity: scanResult.severity ?? 'none',
        reason: scanResult.reason ?? null,
        confidence: scanResult.confidence ?? 0,
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    // ─── AI ENGINE CONTENT VERIFICATION ───────────────────────────────────────
    const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL') || 'https://api.necxa.uk';
    const NECXA_AI_API_KEY = Deno.env.get('NECXA_AI_API_KEY') || '';

    const formData = new FormData();
    let endpoint = '';
    
    if (type === 'video') {
      endpoint = `${NECXA_AI_URL}/api/verify/video`;
      const videoFrames = payload.videoFrames;
      if (videoFrames && Array.isArray(videoFrames)) {
        for (let i = 0; i < videoFrames.length; i++) {
          const frameBase64 = videoFrames[i].replace(/^data:\w+\/\w+;base64,/, "");
          const frameBytes = decode(frameBase64);
          formData.append(`frame${i}`, new Blob([frameBytes], { type: 'image/jpeg' }), `frame${i}.jpg`);
        }
      } else if (mediaBase64) {
        const base64Data = mediaBase64.replace(/^data:\w+\/\w+;base64,/, "");
        const mediaBytes = decode(base64Data);
        formData.append('videoFrame', new Blob([mediaBytes], { type: mimeType || 'image/jpeg' }), 'frame.jpg');
      } else {
        throw new Error("Missing video frame payloads for video verification");
      }
    } else if (type === 'music' || type === 'audio') {
      if (!mediaBase64) throw new Error("Missing audio payload");
      const base64Data = mediaBase64.replace(/^data:\w+\/\w+;base64,/, "");
      const mediaBytes = decode(base64Data);
      formData.append('audio', new Blob([mediaBytes], { type: mimeType || 'audio/mpeg' }), 'audio.mp3');
      endpoint = `${NECXA_AI_URL}/api/verify/audio`;
    } else {
      // Photo / other generic content
      if (!mediaBase64) throw new Error("Missing photo payload");
      const base64Data = mediaBase64.replace(/^data:\w+\/\w+;base64,/, "");
      const mediaBytes = decode(base64Data);
      formData.append('photo', new Blob([mediaBytes], { type: mimeType || 'image/jpeg' }), 'photo.jpg');
      endpoint = `${NECXA_AI_URL}/api/verify/photo`;
    }

    const aiRes = await fetch(endpoint, {
      method: 'POST',
      headers: { 'X-API-Key': NECXA_AI_API_KEY },
      body: formData
    });

    if (!aiRes.ok) throw new Error(`AI Engine Error: ${aiRes.statusText}`);
    const aiData = await aiRes.json();
    if (!aiData.success) throw new Error(`Content Verification Failed: ${aiData.error}`);

    const isVerified = aiData.result.verified;
    const aiScore = aiData.result.score;
    
    return new Response(JSON.stringify({
      status: isVerified ? 'success' : 'failed',
      verified: isVerified,
      feedback: `Necxa AI Engine: Moderation complete. Verified: ${isVerified}`,
      reasoning: aiData.result.reasoning || "AI analysis completed successfully.",
      score: aiScore,
      details: aiData.result
    }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
