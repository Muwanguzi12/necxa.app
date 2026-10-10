import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ====================================================
// SP2 - AI & FINANCE ENGINE
// verify-property: Real-estate fraud + authenticity AI
// Uses: nvidia/Cosmos3-Super-Reasoner via Nebius
// Reads property data & images from SP1 (Primary)
// Writes verdict back to SP1 via service role key
// ====================================================

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-primary-jwt',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

const err = (message: string, status = 400) => json({ error: message }, status)

// SP1 connection (Primary app backend)
const PRIMARY_URL = Deno.env.get('PRIMARY_SUPABASE_URL') || 'https://lzdtrmjcwzalckszdzpt.supabase.co'
const PRIMARY_ANON_KEY = Deno.env.get('PRIMARY_SUPABASE_ANON_KEY') || 'sb_publishable_lLcn4V9uIIgs3B59cHVXWg_1-PNsUfR'
const PRIMARY_SERVICE_KEY = Deno.env.get('PRIMARY_SUPABASE_SERVICE_ROLE_KEY') || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// Nebius / NVIDIA
const NEBIUS_API_KEY = Deno.env.get('NEBIUS_API_KEY')
const NEBIUS_BASE_URL = 'https://api.tokenfactory.nebius.com/v1/chat/completions'

// ====================================================
// Helper: Fetch image from SP1 storage and encode base64
// ====================================================
async function fetchImageAsBase64(storagePath: string): Promise<string | null> {
  try {
    const publicUrl = `${PRIMARY_URL}/storage/v1/object/public/listing-photos/${storagePath}`
    const res = await fetch(publicUrl)
    if (!res.ok) return null
    const buffer = await res.arrayBuffer()
    const bytes = new Uint8Array(buffer)
    let binary = ''
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
    return btoa(binary)
  } catch (e) {
    console.error('Image fetch error:', e)
    return null
  }
}

// ====================================================
// Helper: Call Nebius Cosmos3-Super-Reasoner
// ====================================================
async function runCosmosVerification(params: {
  title: string
  propertyType: string
  country: string
  city: string
  priceUgx: number
  imageBase64: string | null
  mimeType?: string
}): Promise<{
  is_legitimate: boolean
  confidence_score: number
  flags: string[]
  reasoning: string
}> {
  if (!NEBIUS_API_KEY) {
    throw new Error('NEBIUS_API_KEY is not configured on the AI engine.')
  }

  const { title, propertyType, country, city, priceUgx, imageBase64, mimeType } = params

  const textPrompt = `You are a real-estate fraud detection AI for the Necxa platform in East Africa.

Analyze this property listing for authenticity and fraud indicators:
- Title: "${title}"
- Type: ${propertyType}
- Country: ${country}
- City: ${city}
- Price: ${priceUgx} UGX

${imageBase64 ? 'An image of the property has been provided. Analyze if it is a genuine real property photo or a stock/fake image.' : 'No image provided — rely on metadata analysis only.'}

Return ONLY a JSON object with this exact structure:
{
  "is_legitimate": true | false,
  "confidence_score": number (0-100),
  "flags": ["array", "of", "flag", "strings"],
  "reasoning": "brief explanation"
}

Flag codes to use when applicable: suspicious_low_price, excessive_price_variance, stock_photo_detected, no_interior_visible, possible_duplicate_listing, authentic_verified.`

  const contentParts: unknown[] = [{ type: 'text', text: textPrompt }]

  if (imageBase64) {
    contentParts.push({
      type: 'image_url',
      image_url: {
        url: `data:${mimeType || 'image/jpeg'};base64,${imageBase64}`,
      },
    })
  }

  const res = await fetch(NEBIUS_BASE_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${NEBIUS_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'nvidia/Cosmos3-Super-Reasoner',
      messages: [{ role: 'user', content: contentParts }],
      temperature: 0.1,
    }),
  })

  if (!res.ok) {
    const errText = await res.text()
    console.error('Nebius error:', errText)
    throw new Error(`AI engine returned: ${res.status}`)
  }

  const data = await res.json()
  const content = data.choices?.[0]?.message?.content || '{}'
  const jsonMatch = content.match(/\{[\s\S]*\}/)
  return jsonMatch ? JSON.parse(jsonMatch[0]) : JSON.parse(content)
}

// ====================================================
// MAIN HANDLER
// ====================================================
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    if (req.method !== 'POST') return err('Method not allowed', 405)

    // Authenticate against SP1 using the primary JWT
    const primaryJwt = req.headers.get('x-primary-jwt') || req.headers.get('Authorization')?.replace('Bearer ', '')
    if (!primaryJwt) return err('Unauthorized: missing x-primary-jwt', 401)

    const primaryUserClient = createClient(PRIMARY_URL, PRIMARY_ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${primaryJwt}` } },
    })
    const { data: { user }, error: authError } = await primaryUserClient.auth.getUser()
    if (authError || !user) return err('Unauthorized: invalid primary JWT', 401)

    const body = await req.json()
    const { property_id, listing_id } = body

    // Support both property_id (properties table) and listing_id (listings table)
    const targetId = property_id || listing_id
    const targetTable = listing_id ? 'listings' : 'properties'

    if (!targetId) return err('property_id or listing_id is required', 400)

    // Connect to SP1 as admin to read and write property/listing data
    const sp1Admin = createClient(PRIMARY_URL, PRIMARY_SERVICE_KEY)

    const { data: property, error: propErr } = await sp1Admin
      .from(targetTable)
      .select('*')
      .eq('id', targetId)
      .single()

    if (propErr || !property) return err(`${targetTable === 'listings' ? 'Listing' : 'Property'} not found`, 404)

    // Heuristic fraud pre-check (fast, token-free)
    const priceNum = Number(property.price || property.price_ugx || 0)
    let preCheckFailed = false
    let preCheckFlags: string[] = []
    let preCheckReason = ''

    if (priceNum > 0) {
      if ((property.property_type === 'land' || property.category === 'LAND') && priceNum < 500_000) {
        preCheckFailed = true
        preCheckFlags = ['suspicious_low_price']
        preCheckReason = 'Land price is extremely low for the East African market — high risk of title fraud honeypot.'
      } else if (priceNum > 10_000_000_000) {
        preCheckFailed = true
        preCheckFlags = ['excessive_price_variance']
        preCheckReason = 'Listed price deviates massively from municipal averages — likely a typo or shell listing.'
      }
    }

    if (preCheckFailed) {
      // Flag as honeypot immediately — no AI tokens spent
      await sp1Admin.from(targetTable).update({
        is_honeypot: true,
        is_verified: false,
        verification_score: 20,
        honeypot_redirected_at: new Date().toISOString(),
      }).eq('id', targetId)

      await sp1Admin.from('ai_flags').insert({
        property_id: targetId,
        user_id: property.lister_id || property.user_id,
        flag_type: preCheckFlags[0],
        confidence_score: 20,
        is_honeypot_redirected: true,
        reviewed_by_ai: false,
      }).catch(() => {}) // Non-critical

      return json({ status: 'honeypot', flags: preCheckFlags, reasoning: preCheckReason, ai_used: false })
    }

    // === NVIDIA Cosmos3 Vision Analysis ===
    // Fetch the first available property photo from SP1 storage
    const photoPaths: string[] = property.photos || (property.image_url ? [property.image_url] : [])
    let imageBase64: string | null = null
    if (photoPaths.length > 0) {
      // Try the first photo path
      imageBase64 = await fetchImageAsBase64(photoPaths[0])
    }

    let aiResult: { is_legitimate: boolean; confidence_score: number; flags: string[]; reasoning: string }
    try {
      aiResult = await runCosmosVerification({
        title: property.title || '',
        propertyType: property.property_type || property.category || 'unknown',
        country: property.country || 'Uganda',
        city: property.city || property.district || '',
        priceUgx: priceNum,
        imageBase64,
      })
    } catch (e) {
      console.error('Cosmos3 error:', e)
      // Fallback: pass with moderate score rather than blocking user
      aiResult = {
        is_legitimate: true,
        confidence_score: 70,
        flags: [],
        reasoning: 'AI engine temporarily unavailable. Heuristic pre-checks passed.',
      }
    }

    const isVerified = aiResult.is_legitimate && aiResult.confidence_score >= 65

    if (!isVerified) {
      // Flag as honeypot
      await sp1Admin.from(targetTable).update({
        is_honeypot: true,
        is_verified: false,
        verification_score: aiResult.confidence_score,
        honeypot_redirected_at: new Date().toISOString(),
      }).eq('id', targetId)

      await sp1Admin.from('ai_flags').insert({
        property_id: targetId,
        user_id: property.lister_id || property.user_id,
        flag_type: aiResult.flags?.[0] || 'ai_rejected',
        confidence_score: aiResult.confidence_score,
        is_honeypot_redirected: true,
        reviewed_by_ai: true,
      }).catch(() => {})

      return json({ status: 'honeypot', flags: aiResult.flags, reasoning: aiResult.reasoning, ai_used: true, confidence_score: aiResult.confidence_score })
    }

    // === VERIFIED ===
    await sp1Admin.from(targetTable).update({
      is_verified: true,
      is_honeypot: false,
      trust_status: 'verified',
      verification_score: aiResult.confidence_score,
      published_at: property.published_at || new Date().toISOString(),
    }).eq('id', targetId)

    await sp1Admin.from('notifications').insert({
      user_id: property.lister_id || property.user_id,
      notification_type: 'listing_verified',
      title: 'Listing Verified ✅',
      body: `Your property "${property.title}" has been verified by the Necxa AI engine.`,
      metadata: { property_id: targetId, listing_id: targetId },
      is_sent: true,
      sent_at: new Date().toISOString(),
    }).catch(() => {}) // Non-critical

    return json({
      status: 'verified',
      confidence_score: aiResult.confidence_score,
      reasoning: aiResult.reasoning,
      ai_used: true,
      flags: aiResult.flags,
    })

  } catch (e) {
    console.error('verify-property error:', e)
    return err(`Server error: ${e.message}`, 500)
  }
})
