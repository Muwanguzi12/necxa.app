import { verifySupportToken } from "../_shared/support-token.ts"

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
    const { token } = await request.json()
    const user = await verifySupportToken(token)
    return json({ success: true, ...user })
  } catch {
    return json({ error: "Invalid or expired support link" }, 401)
  }
})
