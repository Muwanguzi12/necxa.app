import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4"

const cors = {
  "Access-Control-Allow-Origin": "https://goobox.necxa.uk",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status,
  headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
})

const supportEmail = (Deno.env.get("SUPPORT_EMAIL") || "support@necxa.uk").toLowerCase()
const gmailAccount = (Deno.env.get("GMAIL_ACCOUNT") || "knestars@gmail.com").toLowerCase()

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors })
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405)

  try {
    const url = Deno.env.get("SUPABASE_URL")
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")
    const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    const authorization = request.headers.get("Authorization") || ""
    if (!url || !anonKey || !serviceRole) {
      return json({ error: "Gmail connection service is not configured" }, 503)
    }
    if (!authorization.toLowerCase().startsWith("bearer ")) {
      return json({ error: "Authentication required" }, 401)
    }

    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { data: { user }, error: userError } = await caller.auth.getUser()
    if (userError || !user) return json({ error: "Invalid session" }, 401)

    const admin = createClient(url, serviceRole, {
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { data: agent, error: agentError } = await admin
      .from("profiles")
      .select("role, is_active")
      .eq("id", user.id)
      .maybeSingle()
    if (agentError) throw agentError
    if (!agent?.is_active || !["agent", "admin", "owner"].includes(agent.role)) {
      return json({ error: "An active support agent account is required" }, 403)
    }

    const body = await request.json().catch(() => ({}))
    if (body.action === "status") {
      const { data: inbox, error: inboxError } = await admin
        .from("inboxes")
        .select("gmail_refresh_token, active")
        .eq("email_address", supportEmail)
        .maybeSingle()
      if (inboxError) throw inboxError
      return json({
        connected: Boolean(inbox?.active && inbox.gmail_refresh_token),
        supportEmail,
        gmailAccount,
      })
    }

    const refreshToken = typeof body.refreshToken === "string" ? body.refreshToken.trim() : ""
    const accessToken = typeof body.accessToken === "string" ? body.accessToken.trim() : ""
    if (refreshToken.length < 20 || accessToken.length < 20) {
      return json({ error: "Google did not provide durable Gmail authorization. Re-authorize with Google consent." }, 400)
    }

    const profileResponse = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/profile", {
      headers: { Authorization: `Bearer ${accessToken}` },
    })
    const gmailProfile = await profileResponse.json().catch(() => ({}))
    if (!profileResponse.ok) {
      console.error("Gmail profile verification failed", profileResponse.status)
      return json({ error: "Google Gmail authorization could not be verified" }, 400)
    }
    const authorizedEmail = String(gmailProfile.emailAddress || "").toLowerCase()
    if (authorizedEmail !== gmailAccount) {
      return json({ error: `Authorize the ${gmailAccount} Google account, not ${authorizedEmail || "another account"}` }, 403)
    }

    const { error: inboxError } = await admin.from("inboxes").upsert({
      name: "Necxa Support",
      email_address: supportEmail,
      gmail_refresh_token: refreshToken,
      gmail_access_token: accessToken,
      gmail_token_updated: new Date().toISOString(),
      active: true,
    }, { onConflict: "email_address" })
    if (inboxError) throw inboxError

    return json({ connected: true, supportEmail, gmailAccount })
  } catch (error) {
    console.error("connect-gmail-inbox error:", error instanceof Error ? error.message : error)
    return json({ error: "Unable to save Gmail authorization" }, 500)
  }
})
