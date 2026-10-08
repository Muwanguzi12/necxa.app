import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { decode } from "https://deno.land/std@0.168.0/encoding/base64.ts"

// CORS headers for the Flutter app
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-primary-jwt',
}

const documentFailureFeedback: Record<string, string> = {
  document_unreadable:
    'The model could not read the required fields from this capture. Keep the whole card inside the frame, avoid glare, and retake it once.',
  document_expired: 'This identity document appears to be expired.',
  possible_document_tampering:
    'This document could not be approved automatically and requires review.',
  issuing_country_unknown:
    'The issuing country could not be confirmed. Retake the full document in clear light.',
  document_type_not_configured_for_country:
    'This document type is not enabled for automatic verification in its issuing country.',
  country_profile_not_approved:
    'This document requires manual review and cannot be approved automatically yet.',
  country_profile_not_configured:
    'Automatic verification is not configured for this document country yet.',
}

const biometricFailureFeedback: Record<string, string> = {
  biometric_provider_not_configured:
    'Face-match service is not configured yet. Your approved ID captures remain on this step; do not retake them. Try face verification later.',
  biometric_provider_unavailable:
    'Face-match service is temporarily offline. Keep this screen open and retry only the selfie later; do not retake the ID images.',
  identity_reference_required:
    'The National ID reference image is missing. Restart the identity scan.',
  presentation_attack_detected:
    'Liveness verification could not approve this capture. Please retry with your face clearly visible in natural light. Avoid screens, reflections, and masks.',
  liveness_below_threshold:
    'Liveness could not be confirmed. Face the camera directly in brighter light and retry.',
  face_similarity_below_threshold:
    'Your selfie could not be matched to the National ID photo. Please retry in better light.',
}

function percentage(value: unknown): number {
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return 0
  return parsed <= 1 ? parsed * 100 : parsed
}

// ─────────────────────────────────────────────────────────────────────────────
// NVIDIA Vision NIM helper
// ─────────────────────────────────────────────────────────────────────────────

const NVIDIA_API_URL = 'https://integrate.api.nvidia.com/v1/chat/completions'
const NVIDIA_VISION_MODEL = 'meta/llama-3.2-11b-vision-instruct'

async function callNvidiaVisionBiometric(
  selfieBase64: string,
  idBase64: string | null,
  mode: 'face-only' | 'biometric'
): Promise<{
  is_live_person: boolean
  liveness_score: number
  anti_spoof_flags: string[]
  faces_match: boolean
  similarity_score: number
  reasoning: string
  raw_text?: string
}> {
  const NVIDIA_API_KEY = Deno.env.get('NVIDIA_API_KEY')
  if (!NVIDIA_API_KEY) throw new Error('NVIDIA_API_KEY not configured')

  // Strip data-URI prefix if present
  const selfieData = selfieBase64.replace(/^data:image\/\w+;base64,/, '')
  const selfieUrl = `data:image/jpeg;base64,${selfieData}`

  const contentParts: unknown[] = [
    {
      type: 'image_url',
      image_url: { url: selfieUrl },
    },
  ]

  let promptText: string

  if (mode === 'face-only' || !idBase64) {
    promptText = `You are a certified liveness and anti-spoofing AI system. Analyze this image carefully.

LIVENESS CHECK:
Determine if Image 1 shows a real, live human being physically present in front of the camera.
Look for:
- Screen replay attack: pixel grid patterns, moiré artifacts, screen glare, bezel borders, screen refresh banding
- Paper/printout attack: flat 2D surface, paper edges, paper sheen, uniform lighting with no depth
- 3D printed mask: unnatural skin texture, rigid surface, mask seams
- Deepfake/digital manipulation: unnatural skin grain, edge blurring, inconsistent lighting

Respond in STRICT JSON ONLY (no markdown, no explanation outside JSON):
{
  "is_live_person": <true|false>,
  "liveness_score": <0-100>,
  "anti_spoof_flags": ["<flag1>", "<flag2>"],
  "faces_match": true,
  "similarity_score": 100,
  "reasoning": "<one sentence summary>"
}`
  } else {
    const idData = idBase64.replace(/^data:image\/\w+;base64,/, '')
    const idUrl = `data:image/jpeg;base64,${idData}`
    contentParts.push({ type: 'image_url', image_url: { url: idUrl } })

    promptText = `You are a certified biometric identity verification AI system. You have two images:
- Image 1: A live selfie captured from the phone's front camera
- Image 2: A physical government-issued National ID card

TASK 1 — LIVENESS / ANTI-SPOOFING (evaluate Image 1 only):
Determine if Image 1 shows a real, live human being physically present in front of the camera.
Reject if you detect any of these presentation attacks:
- Screen replay attack: pixel grid, moiré patterns, screen glare, bezel borders
- Paper printout attack: flat 2D plane, paper edges, paper texture, unnaturally uniform lighting
- 3D mask: rigid skin texture, mask edges, synthetic appearance
- Deepfake / digital composite: blur halos at face edges, inconsistent skin grain, mismatched lighting angle

TASK 2 — 1:1 BIOMETRIC FACE MATCH (compare Image 1 face vs. portrait on Image 2):
Compare the facial structure of the person in the selfie (Image 1) against the portrait photo printed on the ID card (Image 2).
Evaluate:
- Eye shape, inter-pupillary distance, eyebrow arch
- Nose bridge width, nostril shape
- Lip shape and width
- Jawline and chin contour
- Overall facial proportions and bone structure
Score similarity from 0 to 100. A score >= 75 indicates the same individual.
A score below 60 should result in faces_match: false.

IMPORTANT: Do not query any government or external database. This is a purely visual 1:1 comparison.

Respond in STRICT JSON ONLY (no markdown, no explanation outside JSON):
{
  "is_live_person": <true|false>,
  "liveness_score": <0-100>,
  "anti_spoof_flags": ["<spoof type if any, else empty array>"],
  "faces_match": <true|false>,
  "similarity_score": <0-100>,
  "reasoning": "<one sentence summary of your determination>"
}`
  }

  contentParts.push({ type: 'text', text: promptText })

  const nvidiaRes = await fetch(NVIDIA_API_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${NVIDIA_API_KEY}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({
      model: NVIDIA_VISION_MODEL,
      messages: [{ role: 'user', content: contentParts }],
      max_tokens: 512,
      temperature: 0.1,
    }),
  })

  if (!nvidiaRes.ok) {
    const errText = await nvidiaRes.text().catch(() => nvidiaRes.statusText)
    throw new Error(`NVIDIA Vision API error ${nvidiaRes.status}: ${errText}`)
  }

  const nvidiaData = await nvidiaRes.json()
  const rawText: string =
    nvidiaData?.choices?.[0]?.message?.content ?? ''

  // Extract JSON from the model's response (strip any accidental markdown fences)
  const jsonMatch = rawText.match(/\{[\s\S]*\}/)
  if (!jsonMatch) {
    throw new Error(`NVIDIA Vision returned non-JSON response: ${rawText.slice(0, 200)}`)
  }

  const parsed = JSON.parse(jsonMatch[0])
  return {
    is_live_person: Boolean(parsed.is_live_person),
    liveness_score: Number(parsed.liveness_score ?? 0),
    anti_spoof_flags: Array.isArray(parsed.anti_spoof_flags) ? parsed.anti_spoof_flags : [],
    faces_match: Boolean(parsed.faces_match),
    similarity_score: Number(parsed.similarity_score ?? 0),
    reasoning: String(parsed.reasoning ?? ''),
    raw_text: rawText,
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main handler
// ─────────────────────────────────────────────────────────────────────────────

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

    const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL') || 'https://necxa-ai-engine.knestars.workers.dev'

    // ─────────────────────────────────────────────────────────────────────────
    // ID document capture actions
    // ─────────────────────────────────────────────────────────────────────────
    if (action === 'verify-id' || action === 'verify-id-front' || action === 'verify-id-back' || action === 'verify-id-holding') {
      const { imageBase64 } = payload || {}
      if (!imageBase64) throw new Error("Missing imageBase64 payload")

      const stage = action === 'verify-id' ? 'front' : action.replace('verify-id-', '')
      const base64Data = imageBase64.replace(/^data:image\/\w+;base64,/, "");
      const imageBytes = decode(base64Data);
      
      const formData = new FormData();
      formData.append('idFront', new Blob([imageBytes], { type: 'image/jpeg' }), `${stage}.jpg`);
      formData.append('countryCode', payload?.countryCode || 'UG');
      formData.append('documentType', payload?.documentType || 'national_id');
      formData.append('captureStage', stage);

      const aiRes = await fetch(`${NECXA_AI_URL}/api/verify/id`, {
        method: 'POST',
        headers: {
          'x-primary-jwt': primaryJwt,
          'Idempotency-Key': `${secureUserId}:${stage}:${crypto.randomUUID()}`,
        },
        body: formData
      });

      if (!aiRes.ok) {
        const aiError = await aiRes.json().catch(() => ({}));
        const providerUnavailable = aiRes.status === 503 ||
          aiError.code === 'document_provider_unavailable';
        return new Response(JSON.stringify({
          verified: false,
          decision: 'deferred',
          reasonCode: providerUnavailable
            ? 'document_provider_unavailable'
            : 'document_analysis_failed',
          retryable: providerUnavailable,
          feedback: providerUnavailable
            ? 'Document verification is temporarily unavailable. Your photo was not rejected; please retry shortly.'
            : 'The document could not be analyzed. Please retake it with the whole card inside the frame.'
        }), {
          status: providerUnavailable ? 503 : 422,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        });
      }
      const aiData = await aiRes.json();
      if (!aiData.success) throw new Error(`Verification Failed: ${aiData.error}`);

      const ocrResult = aiData.ocrResult || {}
      const reasonCode = String(ocrResult.reasonCode || 'document_requires_review')
      const automaticallyVerified = ocrResult.verified === true && ocrResult.decision === 'pass'
      const feedback = automaticallyVerified
        ? `National ID ${stage} scan verified by ${ocrResult.model || 'the vision model'}. Continue to the next capture.`
        : documentFailureFeedback[reasonCode] ||
          'This document scan could not be accepted.'

      return new Response(JSON.stringify({
        verified: automaticallyVerified,
        automaticallyVerified,
        decision: ocrResult.decision || 'manual_review',
        reasonCode,
        requiresManualReview: ocrResult.decision === 'manual_review',
        score: percentage(ocrResult.score),
        qualityScore: percentage(ocrResult.qualityScore),
        docType: ocrResult.docType,
        country: ocrResult.country,
        extractedData: ocrResult.extractedData,
        warnings: ocrResult.warnings,
        ocrLogs: ocrResult.ocrLogs,
        stage,
        feedback,
        verificationSessionId: aiData.sessionId,
        sessionLink: `https://dashboard.necxa.com/audit/sessions/${aiData.sessionId}`
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

    // ─────────────────────────────────────────────────────────────────────────
    // Biometric / selfie actions — NVIDIA Vision primary, Worker fallback
    // ─────────────────────────────────────────────────────────────────────────
    } else if (action === 'verify-selfie' || action === 'verify-face-only') {
      const { imageBase64, idImageBase64 } = payload || {}
      if (!imageBase64) throw new Error("Missing image payloads for biometric match")
      if (action === 'verify-selfie' && !idImageBase64) throw new Error("Missing idImageBase64 payload for selfie verification")

      const mode: 'face-only' | 'biometric' = action === 'verify-face-only' ? 'face-only' : 'biometric'

      // ── Attempt NVIDIA Vision first ──────────────────────────────────────
      let nvidiaResult: Awaited<ReturnType<typeof callNvidiaVisionBiometric>> | null = null
      let nvidiaError: string | null = null

      try {
        nvidiaResult = await callNvidiaVisionBiometric(imageBase64, idImageBase64 ?? null, mode)
        console.log(`[NVIDIA Vision] liveness=${nvidiaResult.liveness_score} similarity=${nvidiaResult.similarity_score} live=${nvidiaResult.is_live_person} match=${nvidiaResult.faces_match}`)
      } catch (err: any) {
        nvidiaError = err.message
        console.warn(`[NVIDIA Vision] Failed (${nvidiaError}), falling back to Cloudflare Worker`)
      }

      // ── Build biometric result from NVIDIA Vision ─────────────────────────
      if (nvidiaResult) {
        const LIVENESS_THRESHOLD = 60
        const SIMILARITY_THRESHOLD = 75

        const livenessPassed =
          nvidiaResult.is_live_person &&
          nvidiaResult.liveness_score >= LIVENESS_THRESHOLD &&
          (nvidiaResult.anti_spoof_flags.length === 0 ||
            (nvidiaResult.anti_spoof_flags.length === 1 && nvidiaResult.anti_spoof_flags[0] === ''))

        const faceMatch =
          mode === 'face-only'
            ? true
            : nvidiaResult.faces_match && nvidiaResult.similarity_score >= SIMILARITY_THRESHOLD

        const verified = livenessPassed && faceMatch

        let reasonCode: string
        if (!livenessPassed && nvidiaResult.anti_spoof_flags.length > 0) {
          reasonCode = 'presentation_attack_detected'
        } else if (!livenessPassed) {
          reasonCode = 'liveness_below_threshold'
        } else if (!faceMatch) {
          reasonCode = 'face_similarity_below_threshold'
        } else {
          reasonCode = 'biometric_passed'
        }

        // Mark profile as verified agent if selfie fully passes
        if (action === 'verify-selfie' && verified) {
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
          verified,
          faceMatch,
          livenessPassed,
          decision: verified ? 'pass' : 'fail',
          reasonCode,
          requiresManualReview: false,
          score: nvidiaResult.similarity_score,
          livenessScore: nvidiaResult.liveness_score,
          antiSpoofFlags: nvidiaResult.anti_spoof_flags,
          engine: 'nvidia-vision',
          feedback: verified
            ? (action === 'verify-face-only'
              ? 'Liveness verification completed successfully by NVIDIA Vision AI.'
              : 'Liveness and National ID face matching completed successfully by NVIDIA Vision AI.')
            : biometricFailureFeedback[reasonCode] ||
              'Biometric verification was not approved. Please retry with your face clearly visible.',
          reasoning: nvidiaResult.reasoning,
          verificationSessionId: sessionId,
          sessionLink,
        }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
      }

      // ── Fallback: Cloudflare Worker ───────────────────────────────────────
      console.log('[Biometric] Using Cloudflare Worker fallback')
      const selfieBytes = decode(imageBase64.replace(/^data:image\/\w+;base64,/, ""));
      const formData = new FormData();
      formData.append('selfie', new Blob([selfieBytes], { type: 'image/jpeg' }), 'selfie.jpg');

      if (idImageBase64) {
        const idBytes = decode(idImageBase64.replace(/^data:image\/\w+;base64,/, ""));
        formData.append('idReference', new Blob([idBytes], { type: 'image/jpeg' }), 'idReference.jpg');
      }

      const endpoint = action === 'verify-face-only' ? '/api/verify/face-only' : '/api/verify/biometric';
      const aiRes = await fetch(`${NECXA_AI_URL}${endpoint}`, {
        method: 'POST',
        headers: { 'x-primary-jwt': primaryJwt },
        body: formData
      });

      if (!aiRes.ok) {
        const aiError = await aiRes.json().catch(() => ({}));
        // Both NVIDIA and Worker failed — return graceful deferred response
        return new Response(JSON.stringify({
          verified: false,
          faceMatch: false,
          livenessPassed: false,
          decision: 'deferred',
          reasonCode: 'biometric_provider_unavailable',
          retryable: true,
          engine: 'none',
          feedback: biometricFailureFeedback['biometric_provider_unavailable'],
          verificationSessionId: sessionId,
          sessionLink,
        }), {
          status: 503,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        })
      }
      const aiData = await aiRes.json();
      if (!aiData.success) throw new Error(`Biometric Failed: ${aiData.error}`);

      const biometricResult = aiData.biometricResult || {}
      const verified = biometricResult.verified === true &&
        biometricResult.faceMatch === true &&
        biometricResult.livenessPassed === true
      const reasonCode = String(biometricResult.reasonCode || 'biometric_requires_review')

      if (action === 'verify-selfie' && verified) {
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
        verified,
        faceMatch: verified,
        livenessPassed: biometricResult.livenessPassed === true,
        decision: biometricResult.decision || 'manual_review',
        reasonCode,
        requiresManualReview: biometricResult.decision === 'manual_review',
        score: percentage(biometricResult.similarityScore),
        livenessScore: percentage(biometricResult.livenessScore),
        engine: 'cloudflare-worker',
        feedback: verified
          ? (action === 'verify-face-only'
            ? 'Face-only liveness verification completed successfully.'
            : 'Liveness and National ID face matching completed successfully.')
          : biometricFailureFeedback[reasonCode] ||
            'Biometric verification was not approved. Please retry with your face clearly visible.',
        biometricLogs: biometricResult.biometricLogs,
        verificationSessionId: aiData.sessionId,
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
