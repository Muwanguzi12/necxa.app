import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { verifySupportToken, type VerifiedSupportUser } from "../_shared/support-token.ts"

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

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors })
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405)

  try {
    const body = await request.json()
    let verifiedUser: VerifiedSupportUser | null = null
    if (typeof body.token === "string" && body.token) {
      try {
        verifiedUser = await verifySupportToken(body.token)
      } catch {
        return json({ error: "Invalid or expired support link" }, 401)
      }
    }

    const typedEmail = text(body.email, 320).toLowerCase()
    const email = verifiedUser?.email.toLowerCase() || typedEmail
    const name = text(body.name, 160) || email.split("@")[0]
    const subject = text(body.subject, 240)
    const message = text(body.message, 10000)
    const category = text(body.category, 40) || "general"
    const priority = ["low", "medium", "high"].includes(body.priority)
      ? body.priority
      : "medium"
    const screenshotUrl = text(body.screenshot_url, 2048) || null

    if (!/^\S+@\S+\.\S+$/.test(email)) return json({ error: "A valid email is required" }, 400)
    if (!subject || !message) return json({ error: "Subject and message are required" }, 400)

    const url = Deno.env.get("SUPABASE_URL")
    const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    if (!url || !serviceRole) return json({ error: "Support service is not configured" }, 503)
    const admin = createClient(url, serviceRole, {
      auth: { persistSession: false, autoRefreshToken: false },
    })

    const portalId = `portal-${crypto.randomUUID()}`
    const { data: ticket, error: ticketError } = await admin
      .from("support_tickets")
      .insert({
        customer_email: email,
        customer_name: name,
        necxa_user_id: verifiedUser?.user_id || null,
        verified: verifiedUser !== null,
        subject: `[${category.toUpperCase()}] ${subject}`,
        snippet: message.slice(0, 120),
        status: "open",
        priority,
        source: "portal",
        received_at: new Date().toISOString(),
        inbox: "support@necxa.uk",
        gmail_message_id: portalId,
        gmail_thread_id: portalId,
      })
      .select("id, verified")
      .single()
    if (ticketError || !ticket) throw ticketError || new Error("Ticket was not created")

    const fullMessage = screenshotUrl
      ? `${message}\n\n---\nScreenshot: ${screenshotUrl}`
      : message
    const { error: messageError } = await admin.from("ticket_messages").insert({
      ticket_id: ticket.id,
      direction: "inbound",
      sender_type: "customer",
      from_email: email,
      from_name: name,
      to_email: "support@necxa.uk",
      subject,
      body_text: fullMessage,
      received_at: new Date().toISOString(),
    })
    if (messageError) {
      await admin.from("support_tickets").delete().eq("id", ticket.id)
      throw messageError
    }

    return json({ success: true, ticket })
  } catch (error) {
    console.error("create-support-ticket error:", error)
    return json({ error: "Unable to create support ticket" }, 500)
  }
})
