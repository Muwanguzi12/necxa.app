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

const text = (value: unknown, max: number) =>
  typeof value === "string" ? value.trim().slice(0, max) : ""

export async function handleNecxaSupportReply(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors })
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405)

  try {
    const authorization = request.headers.get("Authorization")
    const url = Deno.env.get("SUPABASE_URL")
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")
    const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    if (!authorization || !url || !anonKey || !serviceRole) {
      return json({ error: "Unauthorized" }, 401)
    }

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

    const requestBody = await request.json()
    const ticketId = text(requestBody.ticket_id, 128)
    const replyBody = text(requestBody.body, 5000)
    if (!ticketId || !replyBody) {
      return json({ error: "ticket_id and body are required" }, 400)
    }

    const { data: ticket, error: ticketError } = await admin
      .from("support_tickets")
      .select("id, necxa_user_id, verified")
      .eq("id", ticketId)
      .single()
    if (ticketError || !ticket) return json({ error: "Ticket not found" }, 404)
    if (!ticket.verified || !ticket.necxa_user_id) {
      return json({ success: true, relayed: false, delivered: false, reason: "email_only" })
    }

    let sourceReplyId = text(requestBody.source_reply_id, 512)
    if (sourceReplyId) {
      const { data: savedReply, error: replyError } = await admin
        .from("ticket_replies")
        .select("id")
        .eq("id", sourceReplyId)
        .eq("ticket_id", ticket.id)
        .maybeSingle()
      if (replyError) return json({ error: "Unable to verify the support reply" }, 503)
      if (!savedReply) {
        return json({ error: "The support reply does not belong to this ticket" }, 409)
      }
    } else {
      const { data: latestReply, error: replyError } = await admin
        .from("ticket_replies")
        .select("id")
        .eq("ticket_id", ticket.id)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle()
      if (replyError) return json({ error: "Unable to identify the support reply" }, 503)
      sourceReplyId = latestReply?.id ? String(latestReply.id) : ""
    }
    if (!sourceReplyId) {
      return json({ error: "The support reply must be saved before it can be relayed" }, 409)
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
          content: replyBody,
          ticket_id: ticket.id,
          source_reply_id: sourceReplyId,
        },
      }),
    })
    const result = await chatResponse.json().catch(() => ({}))
    if (!chatResponse.ok) {
      console.error("necxa-chat bridge error:", chatResponse.status, result?.error || "unknown")
      return json({ error: "Necxa in-app delivery failed" }, 502)
    }

    return json({
      success: true,
      relayed: true,
      delivered: true,
      room_id: result?.data?.room_id,
      message_id: result?.data?.id,
      deduplicated: result?.deduplicated === true,
    })
  } catch (error) {
    console.error("relay-necxa-reply error:", error instanceof Error ? error.message : "unknown")
    return json({ error: "Necxa in-app delivery failed" }, 500)
  }
}
