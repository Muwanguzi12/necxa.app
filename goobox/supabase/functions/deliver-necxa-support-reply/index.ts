import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const cors = {
  "Access-Control-Allow-Origin": "https://goobox.necxa.uk",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status,
  headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
})

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors })
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405)

  try {
    const authorization = request.headers.get("Authorization")
    const url = Deno.env.get("SUPABASE_URL")
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")
    const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    if (!authorization || !url || !anonKey || !serviceRole) return json({ error: "Unauthorized" }, 401)

    const userClient = createClient(url, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { data: { user }, error: userError } = await userClient.auth.getUser()
    if (userError || !user) return json({ error: "Unauthorized" }, 401)

    const admin = createClient(url, serviceRole, {
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { data: agent } = await admin
      .from("profiles")
      .select("role")
      .eq("id", user.id)
      .single()
    if (!agent || !["owner", "admin", "agent"].includes(agent.role)) {
      return json({ error: "Support-agent access required" }, 403)
    }

    const { ticket_id: ticketId, body } = await request.json()
    if (typeof ticketId !== "string" || typeof body !== "string" || !body.trim()) {
      return json({ error: "ticket_id and body are required" }, 400)
    }
    if (body.length > 5000) return json({ error: "Reply is too long" }, 400)

    const { data: ticket, error: ticketError } = await admin
      .from("support_tickets")
      .select("id, necxa_user_id, verified")
      .eq("id", ticketId)
      .single()
    if (ticketError || !ticket) return json({ error: "Ticket not found" }, 404)
    if (!ticket.verified || !ticket.necxa_user_id) {
      return json({ success: true, delivered: false, reason: "email_only" })
    }

    const chatUrl = Deno.env.get("NECXA_CHAT_URL") ||
      "https://ayvescksetiuekoyfqar.supabase.co/functions/v1/necxa-chat"
    const chatAnonKey = Deno.env.get("NECXA_CHAT_ANON_KEY") || ""
    const sharedSecret = Deno.env.get("GOOBOX_SHARED_SECRET") || ""
    if (!chatAnonKey || sharedSecret.length < 32) {
      return json({ error: "Necxa chat bridge is not configured" }, 503)
    }

    const chatResponse = await fetch(chatUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: chatAnonKey,
        Authorization: `Bearer ${chatAnonKey}`,
        "x-goobox-secret": sharedSecret,
      },
      body: JSON.stringify({
        action: "SEND_MESSAGE",
        payload: {
          to_user_id: ticket.necxa_user_id,
          content: body.trim(),
          ticket_id: ticket.id,
        },
      }),
    })
    const result = await chatResponse.json().catch(() => ({}))
    if (!chatResponse.ok) {
      console.error("necxa-chat bridge error:", chatResponse.status, result)
      return json({ error: "Necxa in-app delivery failed" }, 502)
    }
    return json({ success: true, delivered: true, room_id: result?.data?.room_id })
  } catch (error) {
    console.error("deliver-necxa-support-reply error:", error)
    return json({ error: "Necxa in-app delivery failed" }, 500)
  }
})
