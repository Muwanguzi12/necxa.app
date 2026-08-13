import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
// Necxa Proprietary Biometric Engine — no external AI dependencies

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-primary-jwt, x-shield-signature",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS, PUT, DELETE",
}

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
})


const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!!
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!!
// SP1 remains the authentication project. This function runs on SP2 so that
// the identity shard and private images have a single authoritative home.
const PRIMARY_SUPABASE_URL = Deno.env.get("PRIMARY_SUPABASE_URL") || "https://lzdtrmjcwzalckszdzpt.supabase.co"
const PRIMARY_SUPABASE_ANON_KEY = Deno.env.get("PRIMARY_SUPABASE_ANON_KEY") || "sb_publishable_lLcn4V9uIIgs3B59cHVXWg_1-PNsUfR"

async function fileToBase64(file: File): Promise<string> {
  const arrayBuffer = await file.arrayBuffer()
  const bytes = new Uint8Array(arrayBuffer)
  let binary = ""
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
  return btoa(binary)
}

async function verifyDocumentWithAi(
  file: File,
  label: string,
  captureStage: 'front' | 'back' | 'holding',
  countryCode: string,
  documentType: string,
  aiUrl: string,
  apiKey: string,
) {
  const aiFormData = new FormData()
  aiFormData.append('idFront', file, `${label}.jpg`)
  aiFormData.append('captureStage', captureStage)
  aiFormData.append('countryCode', countryCode)
  aiFormData.append('documentType', documentType)

  const aiRes = await fetch(`${aiUrl}/api/verify/id`, {
    method: "POST",
    headers: { 'X-API-Key': apiKey },
    body: aiFormData,
  })

  if (!aiRes.ok) {
    const errorText = await aiRes.text()
    throw new Error(`${label} document AI failed: ${errorText}`)
  }

  const aiData = await aiRes.json()
  if (!aiData.success) throw new Error(`${label} document AI failed: ${aiData.error}`)
  return aiData.ocrResult
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    
    // 1. Validate the caller against SP1. Gateway verification is disabled on
    // SP2 because it cannot validate an SP1 session JWT.
    const authHeader = req.headers.get('Authorization') || ''
    if (!authHeader.startsWith('Bearer ')) return json({ error: "Unauthorized" }, 401)
    const { data: { user }, error: authError } = await createClient(
      PRIMARY_SUPABASE_URL,
      PRIMARY_SUPABASE_ANON_KEY,
      { global: { headers: { Authorization: authHeader } } }
    ).auth.getUser()

    if (authError || !user) return json({ error: "Unauthorized" }, 401)

    // 2. Parse Multipart
    const formData = await req.formData()
    const idFront = formData.get('id_front') as File
    const idBack = formData.get('id_back') as File
    const idHolding = formData.get('id_holding') as File
    const facePhoto = formData.get('face_photo') as File
    const docType = formData.get('doc_type') as string || 'NATIONAL_ID'
    const country = formData.get('country') as string || 'Uganda'
    const docNumber = formData.get('doc_number') as string || 'UNKNOWN'

    // 3. AI Processing — Cloudflare Workers AI Biometric Engine
    const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL') || 'https://api.necxa.uk';
    const NECXA_AI_API_KEY = Deno.env.get('NECXA_AI_API_KEY') || '';
    if (!NECXA_AI_API_KEY) {
      return json({ error: "Identity AI is not configured on SP2." }, 503)
    }

    // Finance/verification SP2 keeps a minimal profile stub for its foreign
    // key. SP1 remains the user-profile authority.
    const { error: profileError } = await supabase.from('profiles').upsert({
      id: user.id,
      email: user.email ?? null,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'id' })
    if (profileError) throw profileError

    const countryCode = country.toLowerCase() === 'uganda' ? 'UG' : country
    const normalizedDocumentType = docType.toLowerCase().replace(/[\s-]+/g, '_')
    const [frontOcr, backOcr, holdingOcr] = await Promise.all([
      verifyDocumentWithAi(idFront, 'id_front', 'front', countryCode, normalizedDocumentType, NECXA_AI_URL, NECXA_AI_API_KEY),
      verifyDocumentWithAi(idBack, 'id_back', 'back', countryCode, normalizedDocumentType, NECXA_AI_URL, NECXA_AI_API_KEY),
      verifyDocumentWithAi(idHolding, 'id_holding', 'holding', countryCode, normalizedDocumentType, NECXA_AI_URL, NECXA_AI_API_KEY),
    ])

    const documentVerified = [frontOcr, backOcr, holdingOcr].every((result) => result?.verified === true)
    if (!documentVerified) {
      return json({
        verified: false,
        error: "One or more National ID scans failed document AI verification.",
        document_results: { front: frontOcr, back: backOcr, holding: holdingOcr },
      }, 422)
    }

    const aiFormData = new FormData();
    aiFormData.append('selfie', facePhoto);
    aiFormData.append('idReference', idFront);

    const aiRes = await fetch(`${NECXA_AI_URL}/api/verify/biometric`, {
      method: "POST",
      headers: { 'X-API-Key': NECXA_AI_API_KEY },
      body: aiFormData
    });

    if (!aiRes.ok) {
       console.error("AI Error:", await aiRes.text());
       return json({ error: "Cloudflare Biometric Engine offline" }, 500);
    }
    const aiData = await aiRes.json();
    
    if (!aiData.success) {
       return json({ error: "AI Processing Failed: " + aiData.error }, 500);
    }

    const similarity = aiData.biometricResult?.similarityScore || 0;
    const verified = documentVerified && (aiData.biometricResult?.faceMatch || false);
    const fraud_risk = similarity >= 88 ? "low" : similarity >= 72 ? "medium" : "high";
    const extractedData = frontOcr?.extractedData || holdingOcr?.extractedData || {};

    const aiResponse = {
      verified,
      similarity,
      document_verified: documentVerified,
      extracted_name: extractedData.fullName || "Verified User",
      extracted_nin: extractedData.docNumber || docNumber,
      fraud_risk,
      rejection_reason: verified ? null : "Document or biometric similarity below verification threshold.",
      document_results: {
        front: frontOcr,
        back: backOcr,
        holding: holdingOcr,
      },
      biometric_result: aiData.biometricResult,
    }

    // 4. Persistence (Storage)
    const store = async (file: File, path: string) => {
      const storagePath = `${user.id}/${Date.now()}_${path}`
      const upload = await supabase.storage.from('identity-shards').upload(storagePath, file)
      if (upload.error) throw upload.error
      return upload.data?.path
    }

    const [frontPath, backPath, holdingPath, facePath] = await Promise.all([
      store(idFront, 'id_front.jpg'),
      store(idBack, 'id_back.jpg'),
      store(idHolding, 'id_holding.jpg'),
      store(facePhoto, 'face_photo.jpg'),
    ])

    // 5. Persistence (Database Shard)
    const { data: shard, error: dbError } = await supabase.from('identity_shards').insert({
      user_id: user.id,
      doc_type: docType,
      doc_number: docNumber,
      id_front_url: frontPath,
      id_back_url: backPath,
      id_holding_url: holdingPath,
      face_scan_url: facePath,
      verified: aiResponse.verified,
      verification_confidence: aiResponse.similarity,
      extracted_name: aiResponse.extracted_name,
      extracted_nin: aiResponse.extracted_nin,
      fraud_risk: aiResponse.fraud_risk,
      rejection_reason: aiResponse.rejection_reason,
      ai_metadata: aiResponse
    }).select().single()

    if (dbError) throw dbError

    return json({
      identity_shard_id: shard.id,
      verified: aiResponse.verified,
      message: aiResponse.rejection_reason || "Identity Shard Synthesized"
    })

  } catch (e) {
    console.error("Verification Error:", e)
    return json({ error: e.message }, 500)
  }
})
