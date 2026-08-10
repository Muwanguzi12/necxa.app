import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-primary-jwt, x-shield-signature',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS, PUT, DELETE',
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

const REDIS_URL = Deno.env.get('UPSTASH_REDIS_REST_URL')?.trim() || ''
const REDIS_TOKEN = Deno.env.get('UPSTASH_REDIS_REST_TOKEN')?.trim() || ''
const FACE_CACHE_TTL = Number(Deno.env.get('FACE_CACHE_TTL_SECONDS') || '1800')
const BUCKET_NAME = Deno.env.get('IDENTITY_SHARDS_BUCKET')?.trim() || 'identity-shards'
const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL')?.trim() || 'https://api.necxa.uk'
const NECXA_AI_API_KEY = Deno.env.get('NECXA_AI_API_KEY')?.trim() || ''

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')?.trim() || ''
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')?.trim() || ''
const PRIMARY_SUPABASE_URL = Deno.env.get('PRIMARY_SUPABASE_URL')?.trim() || ''
const PRIMARY_SUPABASE_ANON_KEY = Deno.env.get('PRIMARY_SUPABASE_ANON_KEY')?.trim() || ''

interface FaceCacheEntry {
  userId: string
  identityShardId: string
  sessionId: string
  idRefPath: string
  verified: boolean
  faceMatch: boolean
  score: number
  createdAt: string
  updatedAt: string
}

function buildRedisKey(sessionId: string) {
  return `necxa:facecache:${sessionId}`
}

async function redisCall(command: string[]) {
  if (!REDIS_URL || !REDIS_TOKEN) {
    throw new Error('Upstash Redis is not configured')
  }
  const response = await fetch(REDIS_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${REDIS_TOKEN}`, 
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(command),
  })
  if (!response.ok) {
    const error = await response.text()
    throw new Error(`Upstash Redis request failed: ${response.status} ${error}`)
  }
  const payload = (await response.json()) as { result?: unknown; error?: string }
  if (payload.error) {
    throw new Error(payload.error)
  }
  return payload.result
}

async function redisGet(key: string): Promise<string | null> {
  const result = await redisCall(['GET', key])
  return result == null ? null : String(result)
}

async function redisSet(key: string, value: string): Promise<void> {
  await redisCall(['SET', key, value, 'EX', String(FACE_CACHE_TTL)])
}

async function redisDel(key: string): Promise<void> {
  await redisCall(['DEL', key])
}

function parseJson<T>(value: string): T | null {
  try {
    return JSON.parse(value) as T
  } catch (_error) {
    return null
  }
}

async function validatePrimaryJwt(request: Request) {
  const header = request.headers.get('authorization') || ''
  if (!header.startsWith('Bearer ')) {
    return { ok: false, error: json({ success: false, error: 'Missing or malformed Authorization header' }, 401) }
  }

  const primaryUrl = PRIMARY_SUPABASE_URL || SUPABASE_URL
  const primaryKey = PRIMARY_SUPABASE_ANON_KEY
  if (!primaryUrl || !primaryKey) {
    return { ok: false, error: json({ success: false, error: 'Primary Supabase authentication is not configured' }, 500) }
  }

  try {
    const userResponse = await fetch(`${primaryUrl}/auth/v1/user`, {
      headers: {
        apikey: primaryKey,
        Authorization: header,
      },
    })
    if (!userResponse.ok) {
      return { ok: false, error: json({ success: false, error: 'Invalid or expired session.' }, 401) }
    }
    const user = await userResponse.json()
    if (!user?.id) {
      return { ok: false, error: json({ success: false, error: 'Invalid session.' }, 401) }
    }
    return { ok: true, user, jwt: header.replace(/^Bearer\s+/i, '') }
  } catch (error) {
    console.error('Primary JWT validation failed:', error)
    return { ok: false, error: json({ success: false, error: 'Authentication service is temporarily unavailable.' }, 503) }
  }
}

function normalizeSessionId(value: string): string {
  return value.trim()
}

function chooseReferencePath(shard: Record<string, unknown>) {
  return (shard.id_front_url || shard.id_holding_url || shard.id_back_url || '') as string
}

async function downloadStorageFile(supabase: ReturnType<typeof createClient>, path: string): Promise<Blob> {
  const bucket = supabase.storage.from(BUCKET_NAME)
  const download = await bucket.download(path)
  if (download.error) {
    throw download.error
  }
  const data = download.data
  if (data instanceof Blob) {
    return data
  }
  if (data instanceof ArrayBuffer) {
    return new Blob([new Uint8Array(data)], { type: 'image/jpeg' })
  }
  if (data && typeof (data as Response).arrayBuffer === 'function') {
    const arrayBuffer = await (data as Response).arrayBuffer()
    return new Blob([new Uint8Array(arrayBuffer)], { type: 'image/jpeg' })
  }
  throw new Error('Unsupported storage download payload')
}

function base64ToBlob(base64: string, mimeType = 'image/jpeg'): Blob {
  const clean = base64.replace(/^data:[^;]+;base64,/, '')
  const binary = atob(clean)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  return new Blob([bytes], { type: mimeType })
}

async function fetchBiometricComparison(selfie: Blob, idReference: Blob, jwt: string) {
  const formData = new FormData()
  formData.append('selfie', selfie, 'selfie.jpg')
  formData.append('idReference', idReference, 'id_reference.jpg')

  const response = await fetch(`${NECXA_AI_URL}/api/verify/biometric`, {
    method: 'POST',
    headers: {
      'X-API-Key': NECXA_AI_API_KEY,
      'x-primary-jwt': jwt,
    },
    body: formData,
  })

  if (!response.ok) {
    const bodyText = await response.text()
    throw new Error(`Cloudflare biometric compare failed: ${response.status} ${bodyText}`)
  }

  const payload = await response.json()
  return payload
}

async function handleCacheCreate(request: Request, user: { id: string }) {
  const body = request.headers.get('content-type')?.includes('application/json')
    ? await request.json()
    : null
  if (!body) {
    return json({ success: false, error: 'JSON body required' }, 400)
  }

  const sessionIdRaw = body.sessionId || body.session_id
  const identityShardId = body.identityShardId || body.identity_shard_id
  if (!sessionIdRaw || !identityShardId) {
    return json({ success: false, error: 'sessionId and identityShardId are required' }, 400)
  }

  const sessionId = normalizeSessionId(String(sessionIdRaw))
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
  const { data: shard, error: shardError } = await supabase
    .from('identity_shards')
    .select('id, user_id, id_front_url, id_holding_url, id_back_url')
    .eq('id', identityShardId)
    .single()

  if (shardError || !shard) {
    return json({ success: false, error: 'Identity shard not found' }, 404)
  }
  if (shard.user_id !== user.id) {
    return json({ success: false, error: 'Unauthorized identity shard access' }, 403)
  }

  const idRefPath = chooseReferencePath(shard)
  if (!idRefPath) {
    return json({ success: false, error: 'Identity shard is missing a reference image' }, 400)
  }

  const cacheEntry: FaceCacheEntry = {
    userId: user.id,
    identityShardId: identityShardId,
    sessionId,
    idRefPath,
    verified: body.verified === true,
    faceMatch: body.faceMatch === true,
    score: Number(body.score ?? 0),
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  }

  await redisSet(buildRedisKey(sessionId), JSON.stringify(cacheEntry))
  return json({ success: true, cache: cacheEntry })
}

async function handleCacheGet(request: Request, user: { id: string }) {
  const url = new URL(request.url)
  const sessionId = url.searchParams.get('sessionId')?.trim()
  if (!sessionId) {
    return json({ success: false, error: 'sessionId query parameter is required' }, 400)
  }

  const raw = await redisGet(buildRedisKey(sessionId))
  if (!raw) {
    return json({ success: false, error: 'cache not found' }, 404)
  }
  const cache = parseJson<FaceCacheEntry>(raw)
  if (!cache || cache.userId !== user.id) {
    return json({ success: false, error: 'cache not found or unauthorized' }, 404)
  }
  return json({ success: true, cache })
}

async function handleCacheDelete(request: Request, user: { id: string }) {
  const url = new URL(request.url)
  const sessionId = url.searchParams.get('sessionId')?.trim()
  if (!sessionId) {
    return json({ success: false, error: 'sessionId query parameter is required' }, 400)
  }

  const raw = await redisGet(buildRedisKey(sessionId))
  if (!raw) {
    return json({ success: false, error: 'cache not found' }, 404)
  }
  const cache = parseJson<FaceCacheEntry>(raw)
  if (!cache || cache.userId !== user.id) {
    return json({ success: false, error: 'cache not found or unauthorized' }, 404)
  }

  await redisDel(buildRedisKey(sessionId))
  return json({ success: true, deleted: true })
}

async function handleCompare(request: Request, user: { id: string }, authToken: string) {
  const url = new URL(request.url)
  const sessionId = url.searchParams.get('sessionId')?.trim()
  if (!sessionId) {
    return json({ success: false, error: 'sessionId query parameter is required' }, 400)
  }

  const raw = await redisGet(buildRedisKey(sessionId))
  if (!raw) {
    return json({ success: false, error: 'no cache exists for this session' }, 404)
  }
  const cache = parseJson<FaceCacheEntry>(raw)
  if (!cache || cache.userId !== user.id) {
    return json({ success: false, error: 'cache not found or unauthorized' }, 404)
  }

  const contentType = request.headers.get('content-type') || ''
  let selfieBlob: Blob | null = null
  if (contentType.includes('multipart/form-data')) {
    const formData = await request.formData()
    const selfie = formData.get('selfie')
    if (!selfie || !(selfie instanceof Blob)) {
      return json({ success: false, error: 'selfie file is required' }, 400)
    }
    selfieBlob = selfie
  } else {
    const body = await request.json().catch(() => null)
    const selfieBase64 = body?.selfieBase64
    if (!selfieBase64 || typeof selfieBase64 !== 'string') {
      return json({ success: false, error: 'selfieBase64 is required' }, 400)
    }
    selfieBlob = base64ToBlob(selfieBase64)
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
  const idReferenceBlob = await downloadStorageFile(supabase, cache.idRefPath)
  const result = await fetchBiometricComparison(selfieBlob, idReferenceBlob, authToken)

  const updatedCache = {
    ...cache,
    updatedAt: new Date().toISOString(),
    score: Number(result?.biometricResult?.similarityScore ?? cache.score),
    faceMatch: Boolean(result?.biometricResult?.faceMatch ?? cache.faceMatch),
  }
  await redisSet(buildRedisKey(sessionId), JSON.stringify(updatedCache))

  return json({ success: true, cache: updatedCache, biometricResult: result?.biometricResult ?? null })
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders })
  }

  const auth = await validatePrimaryJwt(request)
  if (!auth.ok) {
    return auth.error
  }
  const user = auth.user as { id: string }
  const authToken = auth.jwt

  const url = new URL(request.url)
  const pathname = url.pathname.replace(/\/+$/, '')

  try {
    if (request.method === 'POST' && pathname.endsWith('/cache')) {
      return await handleCacheCreate(request, user)
    }
    if (request.method === 'GET' && pathname.endsWith('/cache')) {
      return await handleCacheGet(request, user)
    }
    if (request.method === 'DELETE' && pathname.endsWith('/cache')) {
      return await handleCacheDelete(request, user)
    }
    if (request.method === 'POST' && pathname.endsWith('/compare')) {
      return await handleCompare(request, user, authToken)
    }

    return json({ success: false, error: 'Not found' }, 404)
  } catch (error) {
    console.error('Face session cache error:', error)
    return json({ success: false, error: error instanceof Error ? error.message : 'Unknown error' }, 500)
  }
})


