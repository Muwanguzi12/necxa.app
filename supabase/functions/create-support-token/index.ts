import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })

const supportTokenSecret = Deno.env.get("SUPPORT_TOKEN_SECRET") || ""
const signingKey = supportTokenSecret.length >= 32
  ? crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(supportTokenSecret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign", "verify"],
    )
  : null

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405)
  if (!signingKey) return json({ error: "Support handoff is not configured" }, 503)

  try {
    const authorization = request.headers.get("Authorization")
    if (!authorization?.startsWith("Bearer ")) {
      return json({ error: "Unauthorized" }, 401)
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")
    if (!supabaseUrl || !supabaseAnonKey) {
      return json({ error: "Authentication service is not configured" }, 503)
    }

    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { data: { user }, error } = await userClient.auth.getUser()
    if (error || !user?.email) return json({ error: "Unauthorized" }, 401)

    const key = await signingKey
    const now = Math.floor(Date.now() / 1000)
    const token = await create(
      { alg: "HS256", typ: "JWT" },
      {
        sub: user.id,
        user_id: user.id,
        email: user.email,
        purpose: "goobox_support",
        iss: "necxa",
        aud: "goobox_support",
        iat: now,
        exp: getNumericDate(10 * 60),
        jti: crypto.randomUUID(),
      },
      key,
    )

    return json({ success: true, token })
  } catch (error) {
    console.error("create-support-token error:", error)
    return json({ error: "Unable to create support handoff" }, 500)
  }
})
