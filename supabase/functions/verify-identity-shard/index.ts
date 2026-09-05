import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { decode } from "https://deno.land/std@0.168.0/encoding/base64.ts"

// CORS remains open for native Flutter clients unless an allowed origin is configured.
const allowedOrigin = Deno.env.get('IDENTITY_ALLOWED_ORIGIN')?.trim() || '*'
const corsHeaders = {
  'Access-Control-Allow-Origin': allowedOrigin,
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-primary-jwt',
}

const documentFailureFeedback: Record<string, string> = {
  document_unreadable:
    'The model could not read the required fields from this capture. Keep the whole card inside the frame, avoid glare, and retake it once.',
  not_an_id:
    'This does not appear to be a valid identity document. Please ensure you are taking a clear picture of your actual ID card.',
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
  liveness_agrees: boolean
  faces_match: boolean
  face_match_agrees: boolean
  similarity_score: number
  reasoning: string
  provider: string
  raw_text?: string
}> {
  const NVIDIA_API_KEY = Deno.env.get('NVIDIA_API_KEY')
  const NEBIUS_API_KEY = Deno.env.get('NEBIUS_API_KEY')
  const providers = [
    NEBIUS_API_KEY
      ? {
          name: 'cosmos3-face-verification',
          apiKey: NEBIUS_API_KEY,
          endpoint: 'https://api.tokenfactory.nebius.com/v1/chat/completions',
          model: 'nvidia/Cosmos3-Super-Reasoner',
        }
      : null,
    NVIDIA_API_KEY
      ? {
          name: 'nvidia-vision',
          apiKey: NVIDIA_API_KEY,
          endpoint: NVIDIA_API_URL,
          model: NVIDIA_VISION_MODEL,
        }
      : null,
  ].filter((provider): provider is NonNullable<typeof provider> => provider !== null)
  if (providers.length === 0) {
    throw new Error('Neither NVIDIA_API_KEY nor NEBIUS_API_KEY is configured')
  }

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
    promptText = `You are Cosmos3, a certified liveness and anti-spoofing AI system. Analyze this selfie carefully.

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
  "liveness_agrees": <true|false>,
  "faces_match": true,
  "face_match_agrees": true,
  "similarity_score": 100,
  "reasoning": "<one sentence summary>"
}`
  } else {
    const idData = idBase64.replace(/^data:image\/\w+;base64,/, '')
    const idUrl = `data:image/jpeg;base64,${idData}`
    contentParts.push({ type: 'image_url', image_url: { url: idUrl } })

    promptText = `You are Cosmos3, a certified biometric identity verification AI system. You have exactly two images:
- Image 1: A live selfie captured from the phone's front camera
- Image 2: A physical government-issued National ID card

TASK 1 — LIVENESS / ANTI-SPOOFING (evaluate Image 1 only):
Determine whether Image 1 shows a real, live human being physically present in front of the camera.
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
Score similarity from 0 to 100. A score >= 30 indicates the same individual.
A score below 30 must result in faces_match: false.
Set liveness_agrees to true only when Image 1 passes liveness.
Set face_match_agrees to true only when the selfie and ID portrait are the same person.
The final agreement requires both liveness_agrees and face_match_agrees.

IMPORTANT: Do not query any government or external database. This is a purely visual 1:1 comparison.

Respond in STRICT JSON ONLY (no markdown, no explanation outside JSON):
{
  "is_live_person": <true|false>,
  "liveness_score": <0-100>,
  "anti_spoof_flags": ["<spoof type if any, else empty array>"],
  "liveness_agrees": <true|false>,
  "faces_match": <true|false>,
  "face_match_agrees": <true|false>,
  "similarity_score": <0-100>,
  "reasoning": "<one sentence summary of your determination>"
}`
  }

  // Cosmos follows the same text-first multimodal message shape used by the
  // working property-verification function.
  contentParts.unshift({ type: 'text', text: promptText })

  let lastError = 'Vision providers unavailable'
  for (const provider of providers) {
    try {
      const response = await fetch(provider.endpoint, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${provider.apiKey}`,
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: JSON.stringify({
          model: provider.model,
          messages: [{ role: 'user', content: contentParts }],
          max_tokens: provider.name === 'cosmos3-face-verification' ? 1024 : 256,
          temperature: 0.1,
        }),
      })

      if (!response.ok) {
        const errorText = await response.text().catch(() => response.statusText)
        throw new Error(`${provider.name} API error ${response.status}: ${errorText}`)
      }

      const data = await response.json()
      const message = data?.choices?.[0]?.message ?? {}
      const parts = [message.content, message.reasoning_content, data?.output_text]
      const rawText = parts
        .filter((part: unknown) => part !== null && part !== undefined)
        .map((part: unknown) => {
          if (typeof part === 'string') return part
          if (Array.isArray(part)) {
            return part
              .map((item: unknown) => {
                if (typeof item === 'string') return item
                if (typeof item !== 'object' || item === null) return ''
                if ('text' in item) return String((item as { text?: unknown }).text ?? '')
                if ('content' in item) return String((item as { content?: unknown }).content ?? '')
                return ''
              })
              .join('')
          }
          return typeof part === 'object' ? JSON.stringify(part) : String(part)
        })
        .join('\n')
      const jsonMatch = rawText.match(/\{[\s\S]*\}/)
      if (!jsonMatch) {
        throw new Error(`${provider.name} returned no JSON decision`)
      }

      const parsed = JSON.parse(jsonMatch[0])
      return {
        is_live_person: Boolean(parsed.is_live_person),
        liveness_score: Number(parsed.liveness_score ?? 0),
        anti_spoof_flags: Array.isArray(parsed.anti_spoof_flags) ? parsed.anti_spoof_flags : [],
        liveness_agrees: parsed.liveness_agrees ?? Boolean(parsed.is_live_person),
        faces_match: Boolean(parsed.faces_match),
        face_match_agrees: parsed.face_match_agrees ?? Boolean(parsed.faces_match),
        similarity_score: Number(parsed.similarity_score ?? 0),
        reasoning: String(parsed.reasoning ?? ''),
        provider: provider.name,
        raw_text: rawText,
      }
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error)
      console.warn(`[${provider.name}] biometric verification failed: ${lastError}`)
    }
  }
  throw new Error(lastError)
}

async function callNvidiaVisionId(
  imageBase64: string,
  stage: string
): Promise<{
  verified: boolean
  decision: string
  reasonCode: string
  score: number
  qualityScore: number
  docType: string
  country: string
  extractedData: any
}> {
  const NVIDIA_API_KEY = Deno.env.get('NVIDIA_API_KEY')
  if (!NVIDIA_API_KEY) throw new Error('NVIDIA_API_KEY not configured')

  const imageData = imageBase64.replace(/^data:image\/\w+;base64,/, '')
  const imageUrl = `data:image/jpeg;base64,${imageData}`

  const promptText = `You are a certified identity document verification AI.
Analyze this image of an ID card or Passport (${stage} side).
Is it a clear, legible, and valid identity document?
If the user captured a blank space, a wall, an object like a chair, a face without an ID, or an illegible blur, it MUST fail with reasonCode "not_an_id".

Extract the person's full name, the document/ID number, and their date of birth if they are visible.

Respond in STRICT JSON ONLY:
{
  "verified": <true|false>,
  "decision": "<pass|fail|manual_review>",
  "reasonCode": "<document_valid|document_unreadable|not_an_id|document_requires_review>",
  "score": <0-100>,
  "qualityScore": <0-100>,
  "docType": "national_id",
  "country": "UG",
  "extractedData": {
    "fullName": "extracted name or null",
    "documentNumber": "extracted ID number or null",
    "dateOfBirth": "extracted DOB (YYYY-MM-DD) or null"
  }
}`

  const nvidiaRes = await fetch(NVIDIA_API_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${NVIDIA_API_KEY}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({
      model: NVIDIA_VISION_MODEL,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'image_url', image_url: { url: imageUrl } },
            { type: 'text', text: promptText }
          ]
        }
      ],
      max_tokens: 512,
      temperature: 0.1,
    }),
  })

  if (!nvidiaRes.ok) throw new Error(`NVIDIA Vision API error ${nvidiaRes.status}`)

  const nvidiaData = await nvidiaRes.json()
  const rawText: string = nvidiaData?.choices?.[0]?.message?.content ?? ''
  
  const jsonMatch = rawText.match(/\{[\s\S]*\}/)
  if (!jsonMatch) throw new Error(`NVIDIA Vision returned non-JSON response`)

  const parsed = JSON.parse(jsonMatch[0])
  return {
    verified: Boolean(parsed.verified),
    decision: parsed.decision ?? 'manual_review',
    reasonCode: parsed.reasonCode ?? 'document_requires_review',
    score: Number(parsed.score ?? 0),
    qualityScore: Number(parsed.qualityScore ?? 0),
    docType: parsed.docType ?? 'national_id',
    country: parsed.country ?? 'UG',
    extractedData: parsed.extractedData ?? {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Holding check — only verifies a person is physically holding an ID card.
// NO OCR, NO data extraction — minimal tokens, fast response.
// ─────────────────────────────────────────────────────────────────────────────
async function callNvidiaVisionHolding(imageBase64: string): Promise<{
  verified: boolean
  person_detected: boolean
  id_card_detected: boolean
  holding_confirmed: boolean
  score: number
  reasoning: string
}> {
  const NVIDIA_API_KEY = Deno.env.get('NVIDIA_API_KEY')
  const NEBIUS_API_KEY = Deno.env.get('NEBIUS_API_KEY')

  if (!NVIDIA_API_KEY && !NEBIUS_API_KEY) {
    throw new Error('Neither NVIDIA_API_KEY nor NEBIUS_API_KEY is configured')
  }

  const imageData = imageBase64.replace(/^data:image\/\w+;base64,/, '')
  const imageUrl = `data:image/jpeg;base64,${imageData}`

  const promptText = `You are an identity presence verification AI.
Your ONLY job is to verify that a human person is holding up an ID card (or identity document / badge / passport) in this photo.

CRITICAL RULES:
- Do NOT perform OCR, text reading, or data extraction from the ID card.
- Do NOT verify names, numbers, photos on the card, or expiration dates.
- Do NOT perform face-matching between the person and the ID card.
- The ID card may be held in hand near the chest or shoulder. It may appear relatively small in the frame.
- As long as a person is visible holding or presenting a card/document, this is a PASS.

Respond in STRICT JSON ONLY (no markdown formatting, no other text):
{
  "person_detected": <true|false>,
  "id_card_detected": <true|false>,
  "holding_confirmed": <true|false>,
  "score": <0-100 confidence>,
  "reasoning": "<one concise sentence>"
}`

  let rawText = ''

  // 1. Try NVIDIA Vision first
  if (NVIDIA_API_KEY) {
    try {
      const nvidiaRes = await fetch(NVIDIA_API_URL, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${NVIDIA_API_KEY}`,
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: JSON.stringify({
          model: NVIDIA_VISION_MODEL,
          messages: [{
            role: 'user',
            content: [
              { type: 'image_url', image_url: { url: imageUrl } },
              { type: 'text', text: promptText }
            ]
          }],
          max_tokens: 256,
          temperature: 0.1,
        }),
      })

      if (nvidiaRes.ok) {
        const data = await nvidiaRes.json()
        rawText = data?.choices?.[0]?.message?.content ?? ''
      } else {
        console.warn(`[NVIDIA Holding] status ${nvidiaRes.status}`)
      }
    } catch (e: any) {
      console.warn('[NVIDIA Holding] error:', e.message)
    }
  }

  // 2. Try Nebius fallback if NVIDIA didn't succeed
  if (!rawText && NEBIUS_API_KEY) {
    try {
      const nebiusRes = await fetch('https://api.tokenfactory.nebius.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${NEBIUS_API_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: 'meta-llama/Llama-3.2-11B-Vision-Instruct',
          messages: [{
            role: 'user',
            content: [
              { type: 'image_url', image_url: { url: imageUrl } },
              { type: 'text', text: promptText }
            ]
          }],
          max_tokens: 256,
          temperature: 0.1,
        }),
      })

      if (nebiusRes.ok) {
        const data = await nebiusRes.json()
        rawText = data?.choices?.[0]?.message?.content ?? ''
      } else {
        console.warn(`[Nebius Holding] status ${nebiusRes.status}`)
      }
    } catch (e: any) {
      console.warn('[Nebius Holding] error:', e.message)
    }
  }

  if (!rawText) {
    throw new Error('Vision AI provider unavailable for holding check')
  }

  const jsonMatch = rawText.match(/\{[\s\S]*\}/)
  if (!jsonMatch) throw new Error(`Holding check returned non-JSON: ${rawText.slice(0, 200)}`)

  const parsed = JSON.parse(jsonMatch[0])
  const holding_confirmed = Boolean(parsed.holding_confirmed)
  const person_detected = Boolean(parsed.person_detected)
  const id_card_detected = Boolean(parsed.id_card_detected)
  const score = Number(parsed.score ?? 85)

  // Pass if holding is confirmed, OR if both person and ID card are detected, OR if score >= 60 with person/ID detected
  const isVerified = holding_confirmed || (person_detected && id_card_detected) || (score >= 60 && (person_detected || id_card_detected))

  return {
    verified: isVerified,
    person_detected: person_detected || holding_confirmed,
    id_card_detected: id_card_detected || holding_confirmed,
    holding_confirmed: isVerified,
    score: score > 0 ? score : (isVerified ? 92 : 30),
    reasoning: String(parsed.reasoning ?? (isVerified ? 'Person holding ID confirmed' : 'ID or person not clearly detected in frame')),
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main handler
// ─────────────────────────────────────────────────────────────────────────────

serve(async (req) => {
  const requestId = req.headers.get('x-request-id')?.trim() || crypto.randomUUID()
  const responseHeaders = {
    ...corsHeaders,
    'Content-Type': 'application/json',
    'X-Request-Id': requestId,
  }

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
    // ─────────────────────────────────────────────────────────────────────────
    // Holding check — person physically holding an ID card (no OCR)
    // ─────────────────────────────────────────────────────────────────────────
    if (action === 'verify-id-holding') {
      const { imageBase64 } = payload || {}
      if (!imageBase64) throw new Error('Missing imageBase64 payload')

      let holdingResult: Awaited<ReturnType<typeof callNvidiaVisionHolding>> | null = null
      try {
        holdingResult = await callNvidiaVisionHolding(imageBase64)
        console.log(`[NVIDIA Holding] verified=${holdingResult.verified} person=${holdingResult.person_detected} id=${holdingResult.id_card_detected}`)
      } catch (err: any) {
        console.error('[NVIDIA Holding] Error:', err.message)
        return new Response(JSON.stringify({
          verified: false,
          decision: 'deferred',
          reasonCode: 'holding_check_unavailable',
          retryable: true,
          feedback: 'The holding verification is temporarily unavailable. Please retry shortly.',
        }), { status: 503, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
      }

      const feedback = holdingResult.verified
        ? 'Confirmed: you are physically holding your ID card. Proceed to the next step.'
        : !holdingResult.person_detected
          ? 'No person was detected. Make sure your full upper body and face are visible.'
          : !holdingResult.id_card_detected
            ? 'No ID card was detected. Hold your ID card clearly in front of the camera.'
            : 'The ID card must be clearly visible and held in your hands. Retake the photo.'

      return new Response(JSON.stringify({
        verified: holdingResult.verified,
        decision: holdingResult.verified ? 'pass' : 'fail',
        reasonCode: holdingResult.verified ? 'holding_confirmed' : 'holding_not_confirmed',
        person_detected: holdingResult.person_detected,
        id_card_detected: holdingResult.id_card_detected,
        holding_confirmed: holdingResult.holding_confirmed,
        score: holdingResult.score,
        reasoning: holdingResult.reasoning,
        feedback,
        verificationSessionId: sessionId,
        sessionLink,
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ID document front / back capture (OCR + data extraction)
    // ─────────────────────────────────────────────────────────────────────────
    if (action === 'verify-id' || action === 'verify-id-front' || action === 'verify-id-back') {
      const { imageBase64 } = payload || {}
      if (!imageBase64) throw new Error("Missing imageBase64 payload")

      const stage = action === 'verify-id' ? 'front' : action.replace('verify-id-', '')
      
      // ── Attempt NVIDIA Vision ID verification first ─────────────────────
      let nvidiaIdResult: any = null
      let nvidiaIdError: string | null = null

      try {
        nvidiaIdResult = await callNvidiaVisionId(imageBase64, stage)
        console.log(`[NVIDIA Vision ID] verified=${nvidiaIdResult.verified} decision=${nvidiaIdResult.decision}`)
      } catch (err: any) {
        nvidiaIdError = err.message
        console.warn(`[NVIDIA Vision ID] Failed (${nvidiaIdError}), falling back to Cloudflare Worker`)
      }

      if (nvidiaIdResult) {
        const automaticallyVerified = nvidiaIdResult.verified === true && nvidiaIdResult.decision === 'pass'
        const reasonCode = String(nvidiaIdResult.reasonCode || 'document_requires_review')
        const feedback = automaticallyVerified
          ? `National ID ${stage} scan verified by NVIDIA Vision AI. Continue to the next capture.`
          : documentFailureFeedback[reasonCode] || 'This document scan could not be accepted.'

        return new Response(JSON.stringify({
          verified: automaticallyVerified,
          automaticallyVerified,
          decision: nvidiaIdResult.decision || 'manual_review',
          reasonCode,
          requiresManualReview: nvidiaIdResult.decision === 'manual_review',
          score: percentage(nvidiaIdResult.score),
          qualityScore: percentage(nvidiaIdResult.qualityScore),
          docType: nvidiaIdResult.docType,
          country: nvidiaIdResult.country,
          extractedData: nvidiaIdResult.extractedData,
          stage,
          feedback,
          verificationSessionId: sessionId,
          sessionLink
        }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
      }

      console.log('[ID Capture] Using Cloudflare Worker fallback')
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

      // ── Attempt configured Vision providers before the Worker fallback ────
      let nvidiaResult: Awaited<ReturnType<typeof callNvidiaVisionBiometric>> | null = null
      let nvidiaError: string | null = null

      try {
        nvidiaResult = await callNvidiaVisionBiometric(imageBase64, idImageBase64 ?? null, mode)
        console.log(`[Vision] liveness=${nvidiaResult.liveness_score} similarity=${nvidiaResult.similarity_score} live=${nvidiaResult.is_live_person} match=${nvidiaResult.faces_match}`)
      } catch (err: any) {
        nvidiaError = err.message
        console.warn(`[Vision] Failed (${nvidiaError}), falling back to Cloudflare Worker`)
      }

      // ── Build biometric result; liveness is always required ──────────────
      if (nvidiaResult) {
        const LIVENESS_THRESHOLD = 60
        const SIMILARITY_THRESHOLD = 30

        const livenessPassed =
          nvidiaResult.is_live_person &&
          nvidiaResult.liveness_agrees &&
          nvidiaResult.liveness_score >= LIVENESS_THRESHOLD &&
          (nvidiaResult.anti_spoof_flags.length === 0 ||
            (nvidiaResult.anti_spoof_flags.length === 1 && nvidiaResult.anti_spoof_flags[0] === ''))

        const faceMatch =
          mode === 'face-only'
            ? true
            : nvidiaResult.faces_match &&
              nvidiaResult.face_match_agrees &&
              nvidiaResult.similarity_score >= SIMILARITY_THRESHOLD

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
          engine: nvidiaResult.provider,
          feedback: verified
            ? (action === 'verify-face-only'
              ? 'Liveness verification completed successfully.'
              : 'Liveness and National ID face matching completed successfully.')
            : biometricFailureFeedback[reasonCode] ||
              'Biometric verification was not approved. Please retry with your face clearly visible.',
          reasoning: nvidiaResult.reasoning,
          verificationSessionId: sessionId,
          sessionLink,
        }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
      }

      // Do not fall through to the legacy Worker: it reports misleading
      // provider-configuration errors for this face-match flow.
      return new Response(JSON.stringify({
        verified: false,
        faceMatch: false,
        livenessPassed: false,
        decision: 'deferred',
        reasonCode: 'biometric_provider_unavailable',
        retryable: true,
        engine: 'vision-provider-unavailable',
        feedback: biometricFailureFeedback['biometric_provider_unavailable'],
        requestId,
        verificationSessionId: sessionId,
        sessionLink,
      }), {
        status: 503,
        headers: responseHeaders
      })

      /* Legacy Worker fallback retained below for reference.
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
      */
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
