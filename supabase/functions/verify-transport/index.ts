import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { decode } from "https://deno.land/std@0.168.0/encoding/base64.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const MAX_IMAGE_BYTES = 5 * 1024 * 1024
const NVIDIA_API_URL = 'https://integrate.api.nvidia.com/v1/chat/completions'
const NVIDIA_VISION_MODEL = 'meta/llama-3.2-11b-vision-instruct'

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-primary-jwt",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}

function imageBytes(input: unknown, label: string): Uint8Array {
  if (typeof input !== "string" || !input.trim()) {
    throw new Error(`${label} is required.`)
  }

  const encoded = input.replace(/^data:image\/[a-zA-Z0-9.+-]+;base64,/, "").trim()
  let bytes: Uint8Array
  try {
    bytes = decode(encoded)
  } catch (_) {
    throw new Error(`${label} is not a valid image.`)
  }

  if (bytes.length === 0 || bytes.length > MAX_IMAGE_BYTES) {
    throw new Error(`${label} must be smaller than 5 MB.`)
  }
  return bytes
}

function normalizePlate(value: unknown): string {
  if (typeof value !== "string") return ""
  return value.toUpperCase().replace(/[^A-Z0-9]/g, "")
}

function normalizeCountryCode(value: unknown): string {
  const code = typeof value === "string" ? value.trim().toUpperCase() : ""
  return /^[A-Z]{2}$/.test(code) ? code : "ZZ"
}

function normalizeVehicleType(value: unknown): "bike" | "van" | "truck" | null {
  const type = typeof value === "string" ? value.trim().toLowerCase() : ""
  if (type === "bike" || type === "motorcycle" || type === "boda") return "bike"
  if (type === "van" || type === "car") return "van"
  if (type === "truck" || type === "lorry") return "truck"
  return null
}

function verificationMessage(reasonCode: string): string {
  const messages: Record<string, string> = {
    biometric_provider_not_configured: "Your application was saved for manual biometric review.",
    biometric_provider_unavailable: "The biometric service is temporarily unavailable, so your application was saved for review.",
    biometric_requires_review: "Your selfie needs a closer biometric review.",
    liveness_below_threshold: "The live selfie was unclear. Retake it in good lighting or wait for review.",
    face_similarity_below_threshold: "The selfie and permit photo need a closer review.",
    presentation_attack_detected: "The live selfie did not pass the anti-spoofing check.",
    country_profile_not_configured: "This country's format is not yet enabled for automatic approval. Your application was saved for review.",
    country_profile_not_approved: "This country's automatic checks are still being calibrated. Your application was saved for review.",
    document_type_not_configured_for_country: "This permit format needs a closer review.",
    issuing_country_unknown: "The permit's issuing country could not be confirmed.",
    document_unreadable: "The permit image was unclear. Retake a sharp photo with all edges visible.",
    possible_document_tampering: "The permit requires an authenticity review.",
    document_expired: "The driving permit appears to be expired.",
    vehicle_or_plate_unreadable: "The vehicle or registration plate was unclear. Retake a sharp photo.",
    plate_format_requires_review: "The registration plate needs a closer country-format review.",
  }
  return messages[reasonCode] ?? "Your application needs a closer verification review."
}

async function callNvidiaVision(messages: any[], maxTokens = 512, temperature = 0.1) {
  const apiKey = Deno.env.get("NVIDIA_API_KEY")
  if (!apiKey) throw new Error("NVIDIA_API_KEY is not configured")

  const res = await fetch(NVIDIA_API_URL, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    },
    body: JSON.stringify({
      model: NVIDIA_VISION_MODEL,
      messages,
      max_tokens: maxTokens,
      temperature,
    })
  })

  if (!res.ok) {
    const errText = await res.text().catch(() => res.statusText)
    throw new Error(`NVIDIA Vision API error ${res.status}: ${errText}`)
  }

  const data = await res.json()
  const rawText: string = data?.choices?.[0]?.message?.content ?? ''
  
  const jsonMatch = rawText.match(/\{[\s\S]*\}/)
  if (!jsonMatch) {
    console.error("NVIDIA non-JSON response:", rawText)
    throw new Error(`NVIDIA Vision returned non-JSON response`)
  }
  
  try {
    return JSON.parse(jsonMatch[0])
  } catch (e) {
    console.error("Failed to parse NVIDIA JSON:", jsonMatch[0])
    throw new Error(`NVIDIA Vision JSON parse error`)
  }
}

// Convert Uint8Array to base64 string
function bytesToBase64(bytes: Uint8Array): string {
  // Using a robust approach for converting large typed arrays to base64 in Deno
  let binary = '';
  const len = bytes.byteLength;
  for (let i = 0; i < len; i++) {
      binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

async function verifyVehicle(bytes: Uint8Array, jwt: string, countryCode: string) {
  const base64 = bytesToBase64(bytes)
  const prompt = `You are a vehicle verification AI for courier onboarding.
Analyze this photo of a vehicle.
1. Determine if this is a valid vehicle photo (bike, van, or truck). If it is a person, a wall, or unrelated, decision = "reject" and reasonCode = "vehicle_or_plate_unreadable".
2. If it is a valid vehicle, extract the registration/license plate number.
3. Determine the type of vehicle (bike, van, truck).

Respond in STRICT JSON ONLY:
{
  "decision": "<pass|manual_review|reject>",
  "reasonCode": "<vehicle_valid|vehicle_or_plate_unreadable|plate_format_requires_review>",
  "plate": "EXTRACTED_PLATE_NUMBER_OR_EMPTY",
  "type": "<bike|van|truck>"
}`

  const result = await callNvidiaVision([
    {
      role: 'user',
      content: [
        { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${base64}` } },
        { type: 'text', text: prompt }
      ]
    }
  ])
  
  return {
    decision: result.decision,
    reasonCode: result.reasonCode,
    plate: result.plate,
    type: result.type,
    vehicleType: result.type,
  }
}

async function verifyPermit(permit: Uint8Array, jwt: string, countryCode: string) {
  const base64 = bytesToBase64(permit)
  const prompt = `You are a certified driving permit verification AI.
Analyze this image of a driving permit/license.
Is it a clear, legible, and valid driving permit?
If it's a blank space, a wall, an unrelated object, or an illegible blur, fail it with reasonCode "not_an_id" and decision "reject".
Extract the driver's full name.

Respond in STRICT JSON ONLY:
{
  "verified": <true|false>,
  "decision": "<pass|reject|manual_review>",
  "reasonCode": "<document_valid|document_unreadable|not_an_id|document_requires_review|document_expired>",
  "score": <0-100>,
  "extractedData": {
    "fullName": "extracted name or null"
  }
}`

  const result = await callNvidiaVision([
    {
      role: 'user',
      content: [
        { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${base64}` } },
        { type: 'text', text: prompt }
      ]
    }
  ])
  
  return {
    verified: result.verified,
    decision: result.decision,
    reasonCode: result.reasonCode,
    score: result.score,
    extractedData: result.extractedData,
  }
}

async function verifyBiometric(selfie: Uint8Array, permit: Uint8Array, jwt: string) {
  const selfieBase64 = bytesToBase64(selfie)
  const permitBase64 = bytesToBase64(permit)
  
  const prompt = `You are a certified liveness and facial recognition AI. Analyze these two images carefully.

LIVENESS CHECK (Image 1 - Selfie):
Determine if Image 1 shows a real, live human being physically present. Look for screen replay attacks, paper printouts, or digital manipulation.

FACE MATCHING:
Determine if the person in the live selfie (Image 1) is EXACTLY the same person pictured on the ID card (Image 2).

Respond in STRICT JSON ONLY:
{
  "is_live_person": <true|false>,
  "faces_match": <true|false>,
  "similarityScore": <0-100>,
  "decision": "<pass|manual_review|reject>",
  "reasonCode": "<biometric_valid|liveness_below_threshold|face_similarity_below_threshold|presentation_attack_detected>"
}`

  const result = await callNvidiaVision([
    {
      role: 'user',
      content: [
        { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${selfieBase64}` } },
        { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${permitBase64}` } },
        { type: 'text', text: prompt }
      ]
    }
  ])
  
  return {
    faceMatch: result.faces_match,
    similarityScore: result.similarityScore,
    decision: result.decision,
    reasonCode: result.reasonCode,
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })
  if (req.method !== "POST") return json({ verified: false, error: "Method not allowed." }, 405)

  try {
    const authHeader = req.headers.get("Authorization") ?? ""
    const jwt = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : ""
    if (!jwt) return json({ verified: false, error: "Sign in before courier verification." }, 401)

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? ""
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    const authClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    })
    const { data: { user }, error: authError } = await authClient.auth.getUser()
    if (authError || !user) {
      return json({ verified: false, error: "Your session expired. Sign in and try again." }, 401)
    }

    const body = await req.json()
    if (body?.action !== "verify_transport") {
      return json({ verified: false, error: "Unknown transport verification action." }, 400)
    }

    const payload = body?.payload ?? {}
    if (payload.aiProcessingConsent !== true) {
      return json({ verified: false, error: "Consent is required before identity images are processed." }, 400)
    }
    const countryCode = normalizeCountryCode(payload.issuingCountryCode)
    if (countryCode === "ZZ") {
      return json({
        verified: false,
        decision: "manual_review",
        error: "Select the two-letter country code that issued the driving permit.",
      }, 400)
    }
    const selfie = imageBytes(payload.driverImageBase64, "Live selfie")
    const permit = imageBytes(payload.permitImageBase64, "Driving permit")
    const vehicle = imageBytes(payload.vehicleImageBase64, "Vehicle plate photo")

    const [vehicleResult, permitResult, biometricResult] = await Promise.all([
      verifyVehicle(vehicle, jwt, countryCode),
      verifyPermit(permit, jwt, countryCode),
      verifyBiometric(selfie, permit, jwt),
    ])

    const numberPlate = normalizePlate(vehicleResult.plate)
    const vehicleType = normalizeVehicleType(vehicleResult.vehicleType ?? vehicleResult.type)
    const permitDecision = String(permitResult?.decision ?? (permitResult?.verified === true ? "pass" : "manual_review"))
    const biometricDecision = String(biometricResult?.decision ?? (biometricResult?.faceMatch === true ? "pass" : "manual_review"))
    const vehicleDecision = String(vehicleResult?.decision ?? "manual_review")
    const vehiclePassed = vehicleDecision === "pass" && numberPlate.length >= 4 && numberPlate.length <= 12 && vehicleType !== null
    const rejected = permitDecision === "reject" || biometricDecision === "reject" || vehicleDecision === "reject"
    const needsReview = !rejected && (permitDecision !== "pass" || biometricDecision !== "pass" || !vehiclePassed)
    const verified = !rejected && !needsReview
    const extractedName = permitResult?.extractedData?.fullName?.toString().trim()
    const displayName = extractedName || user.user_metadata?.full_name || user.email?.split("@")[0] || "Courier Applicant"
    const admin = createClient(supabaseUrl, serviceRoleKey)

    if (!verified) {
      const decision = rejected ? "reject" : "manual_review"
      const reasonCode = permitDecision === "reject"
        ? String(permitResult?.reasonCode ?? "document_rejected")
        : biometricDecision === "reject"
        ? String(biometricResult?.reasonCode ?? "biometric_rejected")
        : vehicleDecision === "reject"
        ? String(vehicleResult?.reasonCode ?? "vehicle_rejected")
        : permitDecision !== "pass"
        ? String(permitResult?.reasonCode ?? "document_requires_review")
        : biometricDecision !== "pass"
        ? String(biometricResult?.reasonCode ?? "biometric_requires_review")
        : String(vehicleResult?.reasonCode ?? "vehicle_requires_review")
      const reason = verificationMessage(reasonCode)
      const { error: applicationError } = await admin.from("transport_drivers").upsert({
        id: user.id,
        name: displayName,
        email: user.email ?? null,
        number_plate: numberPlate.length >= 4 ? numberPlate : null,
        vehicle_type: vehicleType,
        country_code: countryCode,
        is_verified: false,
        is_available: false,
        verification_status: decision,
        verification_reason_code: reasonCode,
        verification_submitted_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      }, { onConflict: "id" })
      if (applicationError) {
        console.error("Transport verification application save failed", applicationError.code, applicationError.message)
      }
      return json({
        verified: false,
        decision,
        error: reason,
        reason_code: reasonCode,
        country_code: countryCode,
        permit_decision: permitDecision,
        biometric_decision: biometricDecision,
        vehicle_decision: vehicleDecision,
        vehicle_passed: vehiclePassed,
        retryable: decision !== "reject",
        application_saved: applicationError === null,
      })
    }

    const { error: upsertError } = await admin.from("transport_drivers").upsert({
      id: user.id,
      name: displayName,
      email: user.email ?? null,
      number_plate: numberPlate,
      vehicle_type: vehicleType,
      is_verified: true,
      is_available: true,
      country_code: countryCode,
      verification_status: "verified",
      verification_reason_code: null,
      verification_submitted_at: new Date().toISOString(),
      verification_reviewed_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }, { onConflict: "id" })
    if (upsertError) {
      console.error("Transport driver upsert failed", upsertError.code, upsertError.message)
      throw new Error("Courier verification passed, but the courier profile could not be saved.")
    }

    return json({
      verified: true,
      number_plate: numberPlate,
      vehicle_type: vehicleType,
      permit_name: displayName,
      country_code: countryCode,
      decision: "pass",
      permit_score: Number(permitResult?.score ?? 0),
      biometric_score: Number(biometricResult?.similarityScore ?? 0),
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : "Transport verification failed."
    console.error("verify-transport failed", message)
    return json({ verified: false, error: message, retryable: true })
  }
})
