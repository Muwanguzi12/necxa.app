import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { decode } from "https://deno.land/std@0.168.0/encoding/base64.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const NECXA_AI_URL = Deno.env.get("NECXA_AI_URL") || "https://necxa-ai-engine.knestars.workers.dev"
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

async function verifyVehicle(bytes: Uint8Array, jwt: string, countryCode: string) {
  const form = new FormData()
  form.append("vehicle", new Blob([bytes], { type: "image/jpeg" }), "vehicle.jpg")
  form.append("countryCode", countryCode)
  const response = await fetch(`${NECXA_AI_URL}/api/verify/vehicle`, {
    method: "POST",
    headers: { "x-primary-jwt": jwt },
    body: form,
  })
  const data = await response.json().catch(() => ({}))
  if (!response.ok || data?.success !== true) {
    console.error("Transport vehicle router failed", response.status, data?.error)
    throw new Error(typeof data?.error === "string" ? data.error : "Vehicle verification is temporarily unavailable.")
  }
  return data.vehicleResult ?? {}
}

async function verifyPermit(permit: Uint8Array, jwt: string, countryCode: string) {
  const form = new FormData()
  form.append("idFront", new Blob([permit], { type: "image/jpeg" }), "driving_permit.jpg")
  form.append("countryCode", countryCode)
  form.append("documentType", "driving_permit")

  const response = await fetch(`${NECXA_AI_URL}/api/verify/id`, {
    method: "POST",
    headers: { "x-primary-jwt": jwt },
    body: form,
  })
  const data = await response.json().catch(() => ({}))
  if (!response.ok || data?.success !== true) {
    console.error("Transport permit AI failed", response.status, data?.error)
    const reason = typeof data?.error === "string" && data.error.trim()
      ? data.error.trim()
      : `verification service returned ${response.status}`
    throw new Error(`Driving permit verification failed: ${reason}`)
  }
  return data.ocrResult ?? {}
}

async function verifyBiometric(selfie: Uint8Array, permit: Uint8Array, jwt: string) {
  const form = new FormData()
  form.append("selfie", new Blob([selfie], { type: "image/jpeg" }), "selfie.jpg")
  form.append("idReference", new Blob([permit], { type: "image/jpeg" }), "driving_permit.jpg")

  const response = await fetch(`${NECXA_AI_URL}/api/verify/biometric`, {
    method: "POST",
    headers: { "x-primary-jwt": jwt },
    body: form,
  })
  const data = await response.json().catch(() => ({}))
  if (!response.ok || data?.success !== true) {
    console.error("Transport biometric AI failed", response.status, data?.error)
    const reason = typeof data?.error === "string" && data.error.trim()
      ? data.error.trim()
      : `verification service returned ${response.status}`
    throw new Error(`Selfie verification failed: ${reason}`)
  }
  return data.biometricResult ?? {}
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
