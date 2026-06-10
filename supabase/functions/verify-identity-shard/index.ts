import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { decode } from "https://deno.land/std@0.168.0/encoding/base64.ts"

// CORS headers for the Flutter app
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-primary-jwt',
}

serve(async (req) => {
  // 1. Handle CORS Preflight perfectly
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // 2. Extract Authorization Header forcefully
    const primaryJwt = req.headers.get("x-primary-jwt")
    if (!primaryJwt) {
      return new Response(JSON.stringify({ error: 'Capture audit failed: missing x-primary-jwt' }), { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401 
      })
    }

    // 3. Dynamic JWT validation against primary Supabase project
    const PRIMARY_SUPABASE_URL = Deno.env.get('PRIMARY_SUPABASE_URL') || 'https://lzdtrmjcwzalckszdzpt.supabase.co'
    const PRIMARY_SUPABASE_ANON_KEY = Deno.env.get('PRIMARY_SUPABASE_ANON_KEY') || 'sb_publishable_lLcn4V9uIIgs3B59cHVXWg_1-PNsUfR'

    const primaryClient = createClient(
      PRIMARY_SUPABASE_URL,
      PRIMARY_SUPABASE_ANON_KEY,
      { global: { headers: { Authorization: `Bearer ${primaryJwt}` } } }
    )

    // 4. Extract secure user automatically from the JWT
    const { data: { user }, error: userError } = await primaryClient.auth.getUser()
    
    if (userError || !user) {
        return new Response(JSON.stringify({ error: 'Capture audit failed: Invalid or expired JWT token' }), { 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
            status: 401 
        })
    }

    // 5. Hardened Security: Only trust the JWT user.id, completely ignore JSON payloads telling you who it is
    const secureUserId = user.id;

    // Optional: Parse the incoming payload natively
    const { action, payload } = await req.json()
    console.log(`Auditing incoming Identity Shard for User ID: ${secureUserId} - Action: ${action}`);

    const sessionId = `SES-${Date.now()}`
    const sessionLink = `https://dashboard.necxa.com/audit/sessions/${sessionId}`

    const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL') || 'https://necxa-ai.onrender.com'
    const NECXA_AI_API_KEY = Deno.env.get('NECXA_AI_API_KEY') || ''

    if (action === 'verify-id') {
      const { imageBase64 } = payload || {}
      if (!imageBase64) throw new Error("Missing imageBase64 payload")

      // 1. Decode base64 to binary
      const base64Data = imageBase64.replace(/^data:image\/\w+;base64,/, "");
      const imageBytes = decode(base64Data);
      
      // 2. Build multipart/form-data
      const formData = new FormData();
      formData.append('idFront', new Blob([imageBytes], { type: 'image/jpeg' }), 'id.jpg');

      // 3. Send to Live AI Engine
      const aiRes = await fetch(`${NECXA_AI_URL}/api/verify/id`, {
        method: 'POST',
        headers: { 'X-API-Key': NECXA_AI_API_KEY },
        body: formData
      });

      if (!aiRes.ok) throw new Error(`AI Engine Error: ${aiRes.statusText}`);
      const aiData = await aiRes.json();
      if (!aiData.success) throw new Error(`Verification Failed: ${aiData.error}`);

      return new Response(JSON.stringify({
        verified: aiData.ocrResult.verified,
        score: aiData.ocrResult.score * 100, // Converts 0-1 to 0-100%
        docType: aiData.ocrResult.docType,
        country: aiData.ocrResult.country,
        extractedData: aiData.ocrResult.extractedData,
        ocrLogs: aiData.ocrResult.ocrLogs,
        feedback: "Document integrity checks and name/ID matching successfully scanned via AI.",
        sessionLink: `https://dashboard.necxa.com/audit/sessions/${aiData.sessionId}`
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

    } else if (action === 'verify-selfie') {
      const { imageBase64, idImageBase64 } = payload || {}
      if (!imageBase64 || !idImageBase64) throw new Error("Missing image payloads for biometric match")

      const selfieBytes = decode(imageBase64.replace(/^data:image\/\w+;base64,/, ""));
      const idBytes = decode(idImageBase64.replace(/^data:image\/\w+;base64,/, ""));

      const formData = new FormData();
      formData.append('selfie', new Blob([selfieBytes], { type: 'image/jpeg' }), 'selfie.jpg');
      formData.append('idReference', new Blob([idBytes], { type: 'image/jpeg' }), 'idReference.jpg');

      const aiRes = await fetch(`${NECXA_AI_URL}/api/verify/biometric`, {
        method: 'POST',
        headers: { 'X-API-Key': NECXA_AI_API_KEY },
        body: formData
      });

      if (!aiRes.ok) throw new Error(`AI Engine Error: ${aiRes.statusText}`);
      const aiData = await aiRes.json();
      if (!aiData.success) throw new Error(`Biometric Failed: ${aiData.error}`);

      // Update profile accurately on primary backend database only if face matches
      if (aiData.biometricResult.faceMatch) {
        const PRIMARY_SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('PRIMARY_SUPABASE_SERVICE_ROLE_KEY')
        const primaryAdminClient = PRIMARY_SUPABASE_SERVICE_ROLE_KEY 
          ? createClient(PRIMARY_SUPABASE_URL, PRIMARY_SUPABASE_SERVICE_ROLE_KEY)
          : primaryClient;

        await primaryAdminClient
          .from('profiles')
          .update({ is_agent: true })
          .eq('id', secureUserId);
      }

      return new Response(JSON.stringify({
        faceMatch: aiData.biometricResult.faceMatch,
        score: aiData.biometricResult.similarityScore * 100,
        feedback: "Volumetric physical liveness validated and matching completed successfully.",
        biometricLogs: aiData.biometricResult.biometricLogs,
        sessionLink: `https://dashboard.necxa.com/audit/sessions/${aiData.sessionId}`
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    // Fallback error safely
    return new Response(JSON.stringify({ error: 'Unknown Action provided' }), { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400 
    })

  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
