import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const url = Deno.env.get('SUPABASE_URL')!
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const primaryUrl = Deno.env.get('PRIMARY_SUPABASE_URL') || url
const primaryAnonKey = Deno.env.get('PRIMARY_SUPABASE_ANON_KEY') || Deno.env.get('SUPABASE_ANON_KEY') || ''
const db = createClient(url, serviceKey)

async function userFor(request: Request) {
  const authorization = request.headers.get('authorization') || ''
  if (!authorization.startsWith('Bearer ')) return null
  const response = await fetch(`${primaryUrl}/auth/v1/user`, {
    headers: { apikey: primaryAnonKey, authorization },
  })
  return response.ok ? await response.json() : null
}
function randomNonce() {
  const bytes = new Uint8Array(32)
  crypto.getRandomValues(bytes)
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '')
}
function bytesFromBase64(value: string) {
  const binary = atob(value.replaceAll('-', '+').replaceAll('_', '/'))
  return new Uint8Array([...binary].map((c) => c.charCodeAt(0)))
}
async function sha256(value: string) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const user = await userFor(request)
  if (!user?.id) return json({ error: 'Authenticated SP1 JWT required' }, 401)
  const body = await request.json().catch(() => ({}))
  const keyId = String(body.keyId || '')
  if (!keyId) return json({ error: 'keyId is required' }, 400)

  if (body.action === 'register') {
    if (!body.publicKeyJwk || body.publicKeyJwk.kty !== 'EC' || body.publicKeyJwk.crv !== 'P-256') {
      return json({ error: 'A P-256 publicKeyJwk is required' }, 400)
    }
    const { error } = await db.from('liveness_device_keys').upsert({
      user_id: user.id, key_id: keyId, public_key_jwk: body.publicKeyJwk,
      attestation_certificates: Array.isArray(body.attestationCertificates) ? body.attestationCertificates : [],
    }, { onConflict: 'user_id,key_id' })
    return error ? json({ error: error.message }, 500) : json({ registered: true })
  }
  if (body.action === 'issue') {
    const { data: key } = await db.from('liveness_device_keys').select('key_id').eq('user_id', user.id).eq('key_id', keyId).maybeSingle()
    if (!key) return json({ error: 'Register the device key first' }, 400)
    const nonce = randomNonce()
    const issued = new Date()
    const expires = new Date(issued.getTime() + 2 * 60 * 1000)
    const { error } = await db.from('liveness_challenges').insert({ user_id: user.id, key_id: keyId, nonce, expires_at: expires.toISOString() })
    return error ? json({ error: error.message }, 500) : json({ nonce, issuedAt: issued.toISOString(), expiresAt: expires.toISOString() })
  }
  if (body.action === 'consume') {
    const manifest = body.manifest
    if (!manifest?.nonce || !manifest?.signature || !Array.isArray(manifest.frames)) return json({ error: 'Invalid manifest' }, 400)
    const { data: challenge } = await db.from('liveness_challenges').select('*').eq('user_id', user.id).eq('nonce', manifest.nonce).eq('key_id', keyId).is('consumed_at', null).maybeSingle()
    if (!challenge || new Date(challenge.expires_at).getTime() < Date.now()) return json({ error: 'Challenge is missing, expired, or already consumed' }, 409)
    const { data: key } = await db.from('liveness_device_keys').select('public_key_jwk').eq('user_id', user.id).eq('key_id', keyId).single()
    const canonical = JSON.stringify({ nonce: manifest.nonce, frames: manifest.frames, createdAt: manifest.createdAt })
    const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, await crypto.subtle.importKey('jwk', key.public_key_jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']), bytesFromBase64(manifest.signature), new TextEncoder().encode(canonical))
    if (!valid) return json({ error: 'Invalid manifest signature' }, 422)
    const manifestHash = await sha256(canonical)
    const { error } = await db.from('liveness_challenges').update({ consumed_at: new Date().toISOString(), manifest_hash: manifestHash }).eq('id', challenge.id)
    if (error) return json({ error: error.message }, 500)
    await db.from('liveness_device_keys').update({ last_used_at: new Date().toISOString() }).eq('user_id', user.id).eq('key_id', keyId)
    return json({ accepted: true, manifestHash })
  }
  return json({ error: 'action must be register, issue, or consume' }, 400)
})
