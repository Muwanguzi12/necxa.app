import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { decode } from "https://deno.land/std@0.168.0/encoding/base64.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const MAX_IMAGE_BYTES = 5 * 1024 * 1024

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
  const nvidiaApiKey = Deno.env.get("NVIDIA_API_KEY")
  const nebiusApiKey = Deno.env.get("NEBIUS_API_KEY")

  const providers = [
    nvidiaApiKey
      ? {
          name: "nvidia-vision",
          apiKey: nvidiaApiKey,
          endpoint: Deno.env.get("NVIDIA_API_URL") || "https://integrate.api.nvidia.com/v1/chat/completions",
          model: Deno.env.get("NVIDIA_VISION_MODEL") || "nvidia/Cosmos3-Super-Reasoner",
        }
      : null,
    nebiusApiKey
      ? {
          name: "cosmos3-nebius",
          apiKey: nebiusApiKey,
          endpoint: "https://api.tokenfactory.nebius.com/v1/chat/completions",
          model: Deno.env.get("COSMOS_VISION_MODEL") || "nvidia/Cosmos3-Super-Reasoner",
        }
      : null,
  ].filter((p): p is NonNullable<typeof p> => p !== null)

  if (providers.length === 0) {
    throw new Error("Neither NVIDIA_API_KEY nor NEBIUS_API_KEY is configured.")
  }

  let lastError: Error | null = null

  for (const provider of providers) {
    try {
      const res = await fetch(provider.endpoint, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${provider.apiKey}`,
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: JSON.stringify({
          model: provider.model,
          messages,
          max_tokens: maxTokens,
          temperature,
        }),
      })

      if (!res.ok) {
        const errText = await res.text().catch(() => res.statusText)
        throw new Error(`${provider.name} Vision API error ${res.status}: ${errText}`)
      }

      const data = await res.json()
      const rawText: string = data?.choices?.[0]?.message?.content ?? ""

      const jsonMatch = rawText.match(/\{[\s\S]*\}/)
      if (!jsonMatch) {
        console.error(`${provider.name} non-JSON response:`, rawText)
        throw new Error(`${provider.name} returned non-JSON response`)
      }

      return JSON.parse(jsonMatch[0])
    } catch (e) {
      lastError = e instanceof Error ? e : new Error(String(e))
      console.warn(`[callNvidiaVision] Provider ${provider.name} failed:`, lastError.message)
    }
  }

  throw lastError ?? new Error("All Vision AI providers failed.")
}

// Convert Uint8Array to base64 string
function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  const len = bytes.byteLength;
  for (let i = 0; i < len; i++) {
      binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

// Single-photo verification step 1: Live Selfie via Cosmos & NVIDIA Vision
async function verifySelfie(selfieBytes: Uint8Array) {
  const base64 = bytesToBase64(selfieBytes)
  const prompt = `You are Cosmos3 and NVIDIA Vision, a certified liveness and facial verification AI.
Analyze this single photo (Live Selfie).
1. Is this a real, live human face physically present? (Check for paper printouts, screen replays, or non-human objects).
2. Is the face well-lit and clear?

Respond in STRICT JSON ONLY:
{
  "is_live_person": <true|false>,
  "decision": "<pass|manual_review|reject>",
  "reasonCode": "<biometric_valid|liveness_below_threshold|presentation_attack_detected|biometric_requires_review>"
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
    isLivePerson: result.is_live_person === true,
    decision: result.decision ?? "manual_review",
    reasonCode: result.reasonCode ?? "biometric_requires_review",
  }
}

// Single-photo verification step 2: Driving Permit via Cosmos & NVIDIA Vision
async function verifyPermit(permitBytes: Uint8Array, jwt: string, countryCode: string) {
  const base64 = bytesToBase64(permitBytes)
  const prompt = `You are Cosmos3 and NVIDIA Vision, a certified driving permit verification AI.
Analyze this single photo of a driving permit/license document.
1. Is it a clear, legible, and authentic driving permit?
2. If it's a blank space, a wall, an unrelated object, or an illegible blur, fail it with reasonCode "not_an_id" and decision "reject".
3. Extract the driver's full name if legible.

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
    verified: result.verified === true,
    decision: result.decision ?? "manual_review",
    reasonCode: result.reasonCode ?? "document_requires_review",
    score: Number(result.score ?? 50),
    extractedData: result.extractedData ?? {},
  }
}

// Single-photo verification step 3: Vehicle Photo via Cosmos & NVIDIA Vision
async function verifyVehicle(vehicleBytes: Uint8Array, jwt: string, countryCode: string) {
  const base64 = bytesToBase64(vehicleBytes)
  const prompt = `You are Cosmos3 and NVIDIA Vision, a vehicle verification AI for courier onboarding.
Analyze this single photo of a vehicle.
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
    decision: result.decision ?? "manual_review",
    reasonCode: result.reasonCode ?? "vehicle_requires_review",
    plate: result.plate ?? "",
    type: result.type ?? "bike",
    vehicleType: result.type ?? "bike",
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
    const action = body?.action ?? ""
    const payload = body?.payload ?? {}

    if (payload.aiProcessingConsent !== true) {
      return json({ verified: false, error: "Consent is required before identity images are processed." }, 400)
    }

    // Individual single-photo API actions:
    if (action === "verify_selfie") {
      const selfie = imageBytes(payload.driverImageBase64, "Live selfie (Photo 1)")
      const res = await verifySelfie(selfie)
      return json({
        step: 1,
        verified: res.decision === "pass",
        decision: res.decision,
        reasonCode: res.reasonCode,
        error: res.decision === "pass" ? null : verificationMessage(res.reasonCode),
      })
    }

    if (action === "verify_permit") {
      const countryCode = normalizeCountryCode(payload.issuingCountryCode)
      const permit = imageBytes(payload.permitImageBase64, "Driving permit (Photo 2)")
      const res = await verifyPermit(permit, jwt, countryCode)
      return json({
        step: 2,
        verified: res.decision === "pass",
        decision: res.decision,
        reasonCode: res.reasonCode,
        fullName: res.extractedData?.fullName ?? null,
        error: res.decision === "pass" ? null : verificationMessage(res.reasonCode),
      })
    }

    if (action === "verify_vehicle") {
      const countryCode = normalizeCountryCode(payload.issuingCountryCode)
      const vehicle = imageBytes(payload.vehicleImageBase64, "Vehicle plate photo (Photo 3)")
      const res = await verifyVehicle(vehicle, jwt, countryCode)
      const plate = normalizePlate(res.plate)
      const vehicleType = normalizeVehicleType(res.vehicleType ?? res.type)
      const vehiclePassed = res.decision === "pass" && plate.length >= 4 && vehicleType !== null
      return json({
        step: 3,
        verified: vehiclePassed,
        decision: res.decision,
        reasonCode: res.reasonCode,
        plate,
        vehicleType,
        error: vehiclePassed ? null : verificationMessage(res.reasonCode),
      })
    }

    if (action !== "verify_transport") {
      return json({ verified: false, error: "Unknown transport verification action." }, 400)
    }

    // Full 3-step sequential pipeline processing (Photo 1 -> Photo 2 -> Photo 3)
    const countryCode = normalizeCountryCode(payload.issuingCountryCode)
    if (countryCode === "ZZ") {
      return json({
        verified: false,
        decision: "manual_review",
        error: "Select the two-letter country code that issued the driving permit.",
      }, 400)
    }

    const selfie = imageBytes(payload.driverImageBase64, "Live selfie (Photo 1)")
    const permit = imageBytes(payload.permitImageBase64, "Driving permit (Photo 2)")
    const vehicle = imageBytes(payload.vehicleImageBase64, "Vehicle plate photo (Photo 3)")

    // STEP 1: Process Photo 1 (Selfie) via Cosmos / NVIDIA Vision
    const biometricResult = await verifySelfie(selfie)
    const biometricDecision = String(biometricResult?.decision ?? "manual_review")

    // STEP 2: Process Photo 2 (Permit) via Cosmos / NVIDIA Vision
    const permitResult = await verifyPermit(permit, jwt, countryCode)
    const permitDecision = String(permitResult?.decision ?? (permitResult?.verified === true ? "pass" : "manual_review"))

    // STEP 3: Process Photo 3 (Vehicle) via Cosmos / NVIDIA Vision
    const vehicleResult = await verifyVehicle(vehicle, jwt, countryCode)
    const numberPlate = normalizePlate(vehicleResult.plate)
    const vehicleType = normalizeVehicleType(vehicleResult.vehicleType ?? vehicleResult.type)
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
      biometric_score: 100,
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : "Transport verification failed."
    console.error("verify-transport failed", message)
    return json({ verified: false, error: message, retryable: true })
  }
})
