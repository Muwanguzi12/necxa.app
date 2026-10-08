import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { GoogleGenerativeAI } from 'npm:@google/generative-ai'

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS, PUT, DELETE",
}

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
})

const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") 
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!!
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!!

async function fileToBase64(file: File): Promise<string> {
  const arrayBuffer = await file.arrayBuffer()
  const bytes = new Uint8Array(arrayBuffer)
  let binary = ""
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
  return btoa(binary)
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    
    // 1. Get User from Auth Header
    const authHeader = req.headers.get('Authorization')!!
    const { data: { user }, error: authError } = await createClient(
      SUPABASE_URL, 
      Deno.env.get("SUPABASE_ANON_KEY")!!, 
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

    // 3. AI Processing (Gemini 1.5 Flash)
    const genAI = new GoogleGenerativeAI(GEMINI_API_KEY!!)
    const model = genAI.getGenerativeModel({ model: 'gemini-1.5-flash' })

    const parts = [
      { text: `Perform high-security identity verification for NECXA platform (${country}).
Documents provided: ${docType}.

IMAGE SEQUENCE:
1. ID Front (Reference)
2. ID Back
3. ID Holding (Biometric Join)
The final image is the Face Photo (Selfie).

TASKS:
1. BIOMETRIC MATCH: Compare person in 'Face Photo' and 'ID Holding' with portrait on 'ID Front'. 
2. DOCUMENT AUTHENTICITY: Check ID Front for physical tampering or digital forgery.
3. DATA EXTRACTION: Extract Full Name and NIN.

Return STRICT JSON:
{
  "verified": boolean,
  "similarity": number (0-100),
  "extracted_name": "string",
  "extracted_nin": "string",
  "fraud_risk": "low" | "medium" | "high",
  "rejection_reason": "string | null"
}` },
      { inlineData: { mimeType: idFront.type, data: await fileToBase64(idFront) } },
      { inlineData: { mimeType: idBack.type, data: await fileToBase64(idBack) } },
      { inlineData: { mimeType: idHolding.type, data: await fileToBase64(idHolding) } },
      { inlineData: { mimeType: facePhoto.type, data: await fileToBase64(facePhoto) } },
    ]

    const result = await model.generateContent(parts)
    const aiResponse = JSON.parse(result.response.text().replace(/```json|```/g, "").trim())

    // 4. Persistence (Storage)
    const store = async (file: File, path: string) => {
      const { data } = await supabase.storage.from('verifications').upload(`${user.id}/${Date.now()}_${path}`, file)
      return data?.path
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

    // 6. 🚀 Update Unified Profile Status
    if (aiResponse.verified) {
      await supabase.from('profiles').update({
        face_verified: true,
        full_name: aiResponse.extracted_name,
        verified_at: new Date().toISOString()
      }).eq('id', user.id);
    }

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