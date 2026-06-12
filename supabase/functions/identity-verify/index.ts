import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
// Necxa Proprietary Biometric Engine — no external AI dependencies

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS, PUT, DELETE",
}

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
})


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

    // 3. AI Processing — Cloudflare Workers AI Biometric Engine
    const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL') || 'https://api.necxa.uk';
    const NECXA_AI_API_KEY = Deno.env.get('NECXA_AI_API_KEY') || '';

    const aiFormData = new FormData();
    aiFormData.append('selfie', facePhoto);
    aiFormData.append('idReference', idHolding); // or idFront

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
    const verified = aiData.biometricResult?.faceMatch || false;
    const fraud_risk = similarity >= 88 ? "low" : similarity >= 72 ? "medium" : "high";

    const aiResponse = {
      verified,
      similarity,
      extracted_name: "Verified User",
      extracted_nin: docNumber,
      fraud_risk,
      rejection_reason: verified ? null : "Biometric similarity below verification threshold.",
    }

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
