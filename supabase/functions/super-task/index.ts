import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-user-id",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS, PUT, DELETE",
}

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
})

const err = (message: string, status = 400) => json({ error: message }, status)

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } }
)

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })

  try {
    // Only allow POST
    if (req.method !== "POST") return err("Method not allowed. Use POST.", 405)

    // Auth validation
    let userId: string | null = null
    const authHeader = req.headers.get("Authorization")
    
    if (authHeader && authHeader.startsWith("Bearer ")) {
      const jwt = authHeader.replace("Bearer ", "")
      try {
        const { data: { user } } = await supabase.auth.getUser(jwt)
        if (user) userId = user.id
      } catch (_) {}
    }
    
    if (!userId) userId = req.headers.get("x-user-id")
    if (!userId) return err("Unauthorized: Please provide Authorization", 401)

    // Parse Body
    const body = await req.json()
    const { room_id, limit = 50, offset = 0 } = body

    if (!room_id) return err("Missing room_id", 400)

    // First ensure the user is part of the room (either user_a or user_b for direct_rooms)
    // NOTE: This logic assumes direct_rooms schema, can be expanded to chat_rooms if needed.
    const { data: roomCheck, error: checkError } = await supabase
      .from("direct_rooms")
      .select("id")
      .eq("id", room_id)
      .or(`user_a.eq.${userId},user_b.eq.${userId}`)
      .single()

    if (checkError || !roomCheck) {
       // fallback check for regular chat_rooms from property module if direct_rooms fails
      const { data: chatRoomCheck } = await supabase
        .from("chat_rooms")
        .select("id")
        .eq("id", room_id)
        .or(`agent_id.eq.${userId},client_id.eq.${userId}`)
        .maybeSingle()
        
       if (!chatRoomCheck) {
          console.error("Room access error:", checkError)
          return err("Room not found or unauthorized", 403)
       }
    }

    // 🚀 Neural Sync: Check Redis first for sub-millisecond latency
    try {
      const { redisCall } = await import("../_shared/chat-helpers.ts")
      const redisRes = await redisCall("LRANGE", `chat:room:${room_id}:messages`, 0, limit - 1)
      
      if (redisRes && redisRes.result && redisRes.result.length > 0) {
        const cachedMessages = redisRes.result.map((m: string) => JSON.parse(m))
        return json({
          success: true,
          data: cachedMessages,
          source: 'cache'
        })
      }
    } catch (redisErr) {
      console.error("REDIS Fetch Error (Non-Fatal):", redisErr)
    }

    // Fallback to Supabase Postgres
    const { data: messages, error: fetchError } = await supabase
      .from("direct_messages")
      .select(`
        id, room_id, sender_id, message_type, content, media_url, is_read, created_at, metadata,
        profiles:sender_id ( id, full_name, display_name, photo_url, is_verified )
      `)
      .eq("room_id", room_id)
      .order("created_at", { ascending: false })
      .range(offset, offset + limit - 1)

    if (fetchError) {
      console.error("Fetch error:", fetchError)
      return err("Failed to fetch messages", 500)
    }

    // Background Hydration: If we found messages in DB but not in Redis, push them to Redis
    if (messages && messages.length > 0 && offset === 0) {
      try {
        const { redisCall } = await import("../_shared/chat-helpers.ts")
        for (const msg of [...messages].reverse()) {
          await redisCall("RPUSH", `chat:room:${room_id}:messages`, JSON.stringify(msg))
        }
        await redisCall("LTRIM", `chat:room:${room_id}:messages`, 0, 99)
      } catch (_) {}
    }

    return json({
      success: true,
      data: messages,
      source: 'db'
    })

  } catch (error: unknown) {

    const msg = error instanceof Error ? error.message : String(error)
    console.error("get-room-messages error:", msg)
    return err(`Server error: ${msg}`, 500)
  }
})