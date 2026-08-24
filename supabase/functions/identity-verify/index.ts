import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-primary-jwt, idempotency-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
})

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
const PRIMARY_SUPABASE_URL = Deno.env.get("PRIMARY_SUPABASE_URL") || "https://lzdtrmjcwzalckszdzpt.supabase.co"
const PRIMARY_SUPABASE_ANON_KEY = Deno.env.get("PRIMARY_SUPABASE_ANON_KEY") || "sb_publishable_lLcn4V9uIIgs3B59cHVXWg_1-PNsUfR"

const encoder = new TextEncoder()

async function sha256Hex(value: ArrayBuffer | string): Promise<string> {
  const bytes = typeof value === "string" ? encoder.encode(value) : value
  const digest = await crypto.subtle.digest("SHA-256", bytes)
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
}

async function fileSha256(file: File): Promise<string> {
  return sha256Hex(await file.arrayBuffer())
}

function requiredFile(formData: FormData, name: string): File {
  const value = formData.get(name)
  if (!(value instanceof File) || value.size === 0) {
    throw new Error(`Missing ${name} image.`)
  }
  if (value.size > 10 * 1024 * 1024 || !["image/jpeg", "image/png"].includes(value.type)) {
    throw new Error(`${name} must be a JPEG or PNG image no larger than 10 MB.`)
  }
  return value
}

function stageResult(job: Record<string, any>, expectedStage: string): Record<string, any> | null {
  const stages = Array.isArray(job.ai_verification_stage_results)
    ? job.ai_verification_stage_results
    : []
  return stages.find((stage: Record<string, any>) => stage.stage === expectedStage) || null
}

async function loadVerificationJobs(
  supabase: ReturnType<typeof createClient>,
  ids: string[],
  userId: string,
): Promise<Record<string, any>[]> {
  for (let attempt = 0; attempt < 6; attempt++) {
    const { data, error } = await supabase
      .from("ai_verification_jobs")
      .select("id,subject_user_id,workflow,decision,reason_codes,result_summary,ai_verification_stage_results(stage,provider,model,decision,confidence,metadata)")
      .in("id", ids)
      .eq("subject_user_id", userId)
      .eq("workflow", "identity")

    if (error) throw error
    if ((data?.length || 0) === ids.length) return data as Record<string, any>[]
    if (attempt < 5) await new Promise((resolve) => setTimeout(resolve, 400))
  }
  return []
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405)

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const bearer = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim()
    const primaryJwt = (req.headers.get("x-primary-jwt") || bearer).trim()
    if (!primaryJwt) return json({ error: "Unauthorized" }, 401)

    const primaryClient = createClient(PRIMARY_SUPABASE_URL, PRIMARY_SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${primaryJwt}` } },
    })
    const { data: { user }, error: authError } = await primaryClient.auth.getUser()
    if (authError || !user) return json({ error: "Unauthorized" }, 401)

    const contentType = req.headers.get("content-type") || ""
    if (contentType.includes("application/json")) {
      const body = await req.json().catch(() => ({}))
      if (body?.action !== "status" || typeof body?.identity_shard_id !== "string") {
        return json({ error: "Invalid identity status request." }, 400)
      }
      const { data: shard, error } = await supabase
        .from("identity_shards")
        .select("id,verified,rejection_reason,created_at")
        .eq("id", body.identity_shard_id)
        .eq("user_id", user.id)
        .maybeSingle()
      if (error) throw error
      return json({
        identity_shard_id: shard?.id ?? null,
        verified: shard?.verified === true,
        rejection_reason: shard?.rejection_reason ?? null,
      }, shard ? 200 : 404)
    }

    const formData = await req.formData()
    const idFront = requiredFile(formData, "id_front")
    const idBack = requiredFile(formData, "id_back")
    const idHolding = requiredFile(formData, "id_holding")
    const facePhoto = requiredFile(formData, "face_photo")
    const docType = String(formData.get("doc_type") || "National ID")
    const docNumberInput = String(formData.get("doc_number") || "").trim()
    const idempotencyKey = String(req.headers.get("Idempotency-Key") || "").trim()
    if (idempotencyKey.length < 12 || idempotencyKey.length > 180) {
      return json({ error: "A valid identity idempotency key is required." }, 400)
    }

    const receiptIds = {
      front: String(formData.get("front_verification_id") || "").trim(),
      back: String(formData.get("back_verification_id") || "").trim(),
      holding: String(formData.get("holding_verification_id") || "").trim(),
      biometric: String(formData.get("biometric_verification_id") || "").trim(),
    }
    if (Object.values(receiptIds).some((value) => !/^[0-9a-f-]{36}$/i.test(value))) {
      return json({
        error: "One or more verification receipts are missing. Restart the identity capture once.",
        reasonCode: "verification_receipt_missing",
      }, 409)
    }

    const [frontHash, backHash, holdingHash, faceHash] = await Promise.all([
      fileSha256(idFront), fileSha256(idBack), fileSha256(idHolding), fileSha256(facePhoto),
    ])
    const jobs = await loadVerificationJobs(supabase, Object.values(receiptIds), user.id)
    if (jobs.length !== 4) {
      return json({
        error: "Verification results are still syncing. Tap Verify once more; do not retake the ID photos.",
        reasonCode: "verification_receipts_syncing",
        retryable: true,
      }, 409)
    }

    const jobsById = new Map(jobs.map((job) => [String(job.id), job]))
    const documentChecks = [
      { key: "front", hash: frontHash, stage: "front_document_assessment" },
      { key: "back", hash: backHash, stage: "back_document_assessment" },
      { key: "holding", hash: holdingHash, stage: "holding_document_assessment" },
    ] as const

    for (const check of documentChecks) {
      const job = jobsById.get(receiptIds[check.key])
      const summary = job?.result_summary || {}
      if (
        job?.decision !== "pass" ||
        summary.capture_stage !== check.key ||
        summary.media_sha256 !== check.hash ||
        !stageResult(job, check.stage) ||
        stageResult(job, check.stage)?.decision !== "pass"
      ) {
        return json({
          verified: false,
          error: `The ${check.key} capture does not match an approved Llama Vision result.`,
          reasonCode: "document_receipt_mismatch",
        }, 422)
      }
    }

    const biometricJob = jobsById.get(receiptIds.biometric)
    const biometricSummary = biometricJob?.result_summary || {}
    const biometricStage = stageResult(biometricJob || {}, "face_match_and_liveness")
    if (
      biometricJob?.decision !== "pass" ||
      biometricSummary.selfie_sha256 !== faceHash ||
      biometricSummary.reference_sha256 !== frontHash ||
      !biometricStage ||
      biometricStage.decision !== "pass"
    ) {
      return json({
        verified: false,
        error: "The biometric receipt does not contain a passed face-match and liveness decision.",
        reasonCode: "biometric_receipt_not_approved",
      }, 422)
    }

    const similarity = Number(biometricStage.metadata?.similarity_score || 0)
    const similarityNormalized = similarity > 1 ? similarity / 100 : similarity
    const similarityPercent = Math.max(0, Math.min(100, similarityNormalized * 100))
    const fraudRisk = similarityNormalized >= 0.88 ? "low" : similarityNormalized >= 0.72 ? "medium" : "high"

    const { error: profileError } = await supabase.from("profiles").upsert({
      id: user.id,
      email: user.email ?? null,
      updated_at: new Date().toISOString(),
    }, { onConflict: "id" })
    if (profileError) throw profileError

    const storagePrefix = (await sha256Hex(idempotencyKey)).slice(0, 32)
    const store = async (file: File, name: string) => {
      const path = `${user.id}/${storagePrefix}/${name}`
      const { error } = await supabase.storage.from("identity-shards").upload(path, file, {
        upsert: true,
        contentType: file.type,
      })
      if (error) throw error
      return path
    }
    const [frontPath, backPath, holdingPath, facePath] = await Promise.all([
      store(idFront, "id_front.jpg"),
      store(idBack, "id_back.jpg"),
      store(idHolding, "id_holding.jpg"),
      store(facePhoto, "face_photo.jpg"),
    ])

    const aiMetadata = {
      policy_version: "identity-receipts-v1",
      document_provider: "workers_ai",
      document_model: stageResult(jobsById.get(receiptIds.front) || {}, "front_document_assessment")?.model,
      verification_receipts: receiptIds,
      document_hashes: { front: frontHash, back: backHash, holding: holdingHash },
      biometric_provider: biometricStage.provider,
      biometric_result: biometricStage.metadata,
    }
    const row = {
      user_id: user.id,
      idempotency_key: idempotencyKey,
      doc_type: docType,
      doc_number: docNumberInput || null,
      id_front_url: frontPath,
      id_back_url: backPath,
      id_holding_url: holdingPath,
      face_scan_url: facePath,
      verified: true,
      verification_confidence: similarityPercent,
      extracted_name: null,
      extracted_nin: docNumberInput || null,
      fraud_risk: fraudRisk,
      rejection_reason: null,
      ai_metadata: aiMetadata,
    }
    const { data: shard, error: dbError } = await supabase
      .from("identity_shards")
      .upsert(row, { onConflict: "user_id,idempotency_key" })
      .select("id,verified")
      .single()
    if (dbError) throw dbError

    return json({
      identity_shard_id: shard.id,
      verified: shard.verified === true,
      message: "Identity verified from signed document and biometric receipts.",
      document_results: Object.fromEntries(documentChecks.map((check) => {
        const job = jobsById.get(receiptIds[check.key]) || {}
        const stage = stageResult(job, check.stage)
        return [check.key, {
          verified: job.decision === "pass" && stage?.decision === "pass",
          provider: stage?.provider,
          model: stage?.model,
          confidence: stage?.confidence,
          reasonCodes: job.reason_codes || [],
        }]
      })),
      biometric_result: {
        verified: true,
        provider: biometricStage.provider,
        similarityScore: similarityNormalized,
        livenessScore: biometricStage.metadata?.liveness_score,
      },
    })
  } catch (error) {
    console.error("Identity verification error:", error)
    return json({ error: error instanceof Error ? error.message : "Identity verification failed." }, 500)
  }
})
