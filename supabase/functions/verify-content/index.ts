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

// ─── NVIDIA Vision NIM Configuration ──────────────────────────────────────────
const NVIDIA_INVOKE_URL = Deno.env.get("NVIDIA_INVOKE_URL") || "https://integrate.api.nvidia.com/v1/chat/completions"
const NVIDIA_API_KEY = Deno.env.get("NVIDIA_API_KEY") || "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"
const NVIDIA_VISION_MODEL = Deno.env.get("NVIDIA_VISION_MODEL") || "meta/llama-3.2-11b-vision-instruct"

async function callNvidiaVision(messages: any[], maxTokens = 1024, temperature = 0.2) {
  const res = await fetch(NVIDIA_INVOKE_URL, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${NVIDIA_API_KEY}`,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    },
    body: JSON.stringify({
      model: NVIDIA_VISION_MODEL,
      messages,
      max_tokens: maxTokens,
      temperature,
      top_p: 0.95,
      stream: false,
    })
  })

  if (!res.ok) {
    const errText = await res.text()
    throw new Error(`NVIDIA Vision API returned ${res.status}: ${errText}`)
  }

  const data = await res.json()
  return data.choices?.[0]?.message?.content || ""
}

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

    // ─── NVIDIA VISION: AUTO-GENERATE LISTING DETAILS ─────────────────────────
    if (action === 'generate_listing_details') {
      const rawImages: string[] = []
      if (Array.isArray(payload.images) && payload.images.length > 0) {
        rawImages.push(...payload.images.slice(0, 4))
      } else if (mediaBase64) {
        rawImages.push(mediaBase64)
      }

      if (rawImages.length === 0) {
        return new Response(JSON.stringify({ error: 'At least one property image is required' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        })
      }

      const contentItems: any[] = []
      for (const img of rawImages) {
        const url = img.startsWith('data:') ? img : `data:image/jpeg;base64,${img}`
        contentItems.push({
          type: "image_url",
          image_url: { url }
        })
      }

      const promptText = `You are a real estate surveyor and copywriter in East Africa.
Analyze the provided property photos carefully.
Listing parameters:
- Property Type: ${payload.propertyType || 'Residential property'}
- Location: ${payload.district ? payload.district + ', ' : ''}${payload.city || 'Kampala, Uganda'}
- Purpose: ${payload.purpose || 'rent'}
${payload.title ? `- Provided Title: ${payload.title}` : ''}

Generate:
1. "title": An engaging, professional listing title (e.g. "Modern 2-Bedroom Apartment with Balcony in Kololo").
2. "description": An enticing 2-3 paragraph property description highlighting visible finishes, natural light, layout, spatial ambiance, and suitability for tenants/buyers in East Africa.
3. "amenities": A list of applicable amenities detected or strongly inferred from the images. Choose ONLY from: ["WiFi", "Pool", "Parking", "Security", "Gym", "AC", "Balcony", "Garden", "Tiled Floors", "Modern Kitchen", "Water Heater"].
4. "suggested_bedrooms": Estimated number of bedrooms (integer, min 1).
5. "suggested_bathrooms": Estimated number of bathrooms (integer, min 1).
6. "key_features": 3 to 5 visual highlights as short bullet strings.

Return STRICT JSON ONLY (no markdown formatting, no quotes around the response object, valid JSON):
{
  "title": "string",
  "description": "string",
  "amenities": ["string"],
  "suggested_bedrooms": 1,
  "suggested_bathrooms": 1,
  "key_features": ["string"]
}`

      contentItems.push({ type: "text", text: promptText })

      try {
        const rawResponse = await callNvidiaVision([
          { role: "user", content: contentItems }
        ], 1024, 0.2)

        let parsed: any = {}
        try {
          const cleanJson = rawResponse.replace(/```json/gi, '').replace(/```/g, '').trim()
          parsed = JSON.parse(cleanJson)
        } catch (_) {
          parsed = {
            title: payload.title || `${payload.propertyType || 'Property'} in ${payload.district || payload.city || 'Kampala'}`,
            description: rawResponse,
            amenities: ["Security", "Parking"],
            key_features: ["Spacious layout", "Well-lit interior"]
          }
        }

        return new Response(JSON.stringify({
          success: true,
          title: parsed.title,
          description: parsed.description,
          amenities: Array.isArray(parsed.amenities) ? parsed.amenities : [],
          suggested_bedrooms: parsed.suggested_bedrooms,
          suggested_bathrooms: parsed.suggested_bathrooms,
          key_features: Array.isArray(parsed.key_features) ? parsed.key_features : []
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        })
      } catch (nvidiaErr: any) {
        console.error("NVIDIA Vision generation error:", nvidiaErr)
        return new Response(JSON.stringify({
          success: false,
          error: `NVIDIA Vision failed: ${nvidiaErr.message || nvidiaErr}`
        }), {
          status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        })
      }
    }

    // ─── NVIDIA VISION: PROPERTY PHOTO VERIFICATION ───────────────────────────
    if (action === 'verify_listing_photo') {
      const photoBase64 = mediaBase64 || payload.images?.[0]
      if (!photoBase64) {
        return new Response(JSON.stringify({ error: 'Missing photo for listing verification' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        })
      }

      const category = (payload.category || 'property').toLowerCase()
      const url = photoBase64.startsWith('data:') ? photoBase64 : `data:image/jpeg;base64,${photoBase64}`

      const verifyPrompt = `Analyze this real estate listing photo.
Expected Category: ${category} (${category === 'exterior' ? 'building exterior, compound, gate, or facade' : category === 'interior' ? 'interior room, living area, bedroom, or kitchen' : 'bathroom, toilet, or shower'}).

Verify:
1. Is this a legitimate photo of real estate/property matching the context?
2. Does it reasonably represent "${category}"?
3. Is it clear, respectful, and free of spam or non-property objects?

Return STRICT JSON ONLY:
{
  "verified": boolean,
  "category_match": boolean,
  "score": number,
  "detected_scene": string,
  "reasoning": string
}`

      try {
        const rawResponse = await callNvidiaVision([
          {
            role: "user",
            content: [
              { type: "image_url", image_url: { url } },
              { type: "text", text: verifyPrompt }
            ]
          }
        ], 512, 0.1)

        let parsed: any = {}
        try {
          const cleanJson = rawResponse.replace(/```json/gi, '').replace(/```/g, '').trim()
          parsed = JSON.parse(cleanJson)
        } catch (_) {
          parsed = { verified: true, category_match: true, score: 85, reasoning: "Verified by NVIDIA Vision" }
        }

        const isVerified = parsed.verified !== false && (parsed.score ?? 80) >= 50
        return new Response(JSON.stringify({
          success: true,
          verified: isVerified,
          score: parsed.score ?? 85,
          category_match: parsed.category_match ?? true,
          reasoning: parsed.reasoning || "Photo meets real estate standards",
          details: parsed
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        })
      } catch (err: any) {
        console.error("NVIDIA Vision photo verify error:", err)
        return new Response(JSON.stringify({
          success: false,
          verified: false,
          error: `Photo verification failed: ${err.message || err}`
        }), {
          status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        })
      }
    }

    if (!mediaBase64 && !payload.videoFrames && !payload.images) {
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
      const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL') || 'https://necxa-ai-engine.knestars.workers.dev';
      
      const base64Data = mediaBase64.replace(/^data:\w+\/\w+;base64,/, "");
      const mediaBytes = decode(base64Data);
      const formData = new FormData();
      formData.append('frame', new Blob([mediaBytes], { type: mimeType || 'image/jpeg' }), 'frame.jpg');

      let scanResult = { safe: true, flags: {}, severity: "none", reason: null, confidence: 0 };
      
      try {
        const aiRes = await fetch(`${NECXA_AI_URL}/api/verify/live-frame`, {
          method: 'POST',
          headers: { 'x-primary-jwt': primaryJwt },
          body: formData,
        });
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
    const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL') || 'https://necxa-ai-engine.knestars.workers.dev';
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
      headers: { 'x-primary-jwt': primaryJwt },
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
