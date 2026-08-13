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
    'The document is too blurred or incomplete. Hold it steady, fill the frame, and retake it in brighter light.',
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
    'Biometric verification is temporarily unavailable. Please try again later.',
  biometric_provider_unavailable:
    'Biometric verification is temporarily unavailable. Please try again later.',
  identity_reference_required:
    'The National ID reference image is missing. Restart the identity scan.',
  presentation_attack_detected:
    'Liveness verification could not approve this capture. Please retry with your face clearly visible.',
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

    const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL') || 'https://api.necxa.uk'
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
        headers: { 'x-primary-jwt': primaryJwt },
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
      const verified = ocrResult.verified === true && ocrResult.decision === 'pass'
      const reasonCode = String(ocrResult.reasonCode || 'document_requires_review')
      const feedback = verified
        ? `National ID ${stage} scan verified. Continue to the next capture.`
        : documentFailureFeedback[reasonCode] ||
          'This document scan was not approved. Retake a clear photo with the whole card inside the frame.'

      return new Response(JSON.stringify({
        verified,
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
        sessionLink: `https://dashboard.necxa.com/audit/sessions/${aiData.sessionId}`
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

    } else if (action === 'verify-selfie' || action === 'verify-face-only') {
      const { imageBase64, idImageBase64 } = payload || {}
      if (!imageBase64) throw new Error("Missing image payloads for biometric match")
      if (action === 'verify-selfie' && !idImageBase64) throw new Error("Missing idImageBase64 payload for selfie verification")

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
        throw new Error(`AI Engine Error: ${aiError.error || aiRes.statusText || aiRes.status}`);
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
        feedback: verified
          ? (action === 'verify-face-only'
            ? 'Face-only liveness verification completed successfully.'
            : 'Liveness and National ID face matching completed successfully.')
          : biometricFailureFeedback[reasonCode] ||
            'Biometric verification was not approved. Please retry with your face clearly visible.',
        biometricLogs: biometricResult.biometricLogs,
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
