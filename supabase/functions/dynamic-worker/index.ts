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
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })

  try {
    if (req.method !== "POST") return err("Method not allowed. Use POST.", 405)

    // Auth
    let userId: string | null = null
    const authHeader = req.headers.get("Authorization")
    if (authHeader && authHeader.startsWith("Bearer ")) {
      const jwt = authHeader.replace("Bearer ", "")
      try {
        const { data: { user } } = await supabase.auth.getUser(jwt)
        if (user) userId = user.id
      } catch (_) {}
    }
    // Fallback for testing/debugging if x-user-id header is provided
    if (!userId) userId = req.headers.get("x-user-id")
    
    if (!userId) return err("Unauthorized: Please provide Authorization or x-user-id", 401)

    const body = await req.json()
    const { to_user_id, message_type = "text", content, media_url, metadata } = body

    if (!to_user_id) return err("Missing to_user_id", 400)
    if (!content && !media_url) return err("Message must have content or media", 400)

    // Get or Create Room between the sender and the recipient
    const { data: roomId, error: roomError } = await supabase.rpc('get_or_create_direct_room', {
      p_user_a: userId,
      p_user_b: to_user_id
    })

    if (roomError || !roomId) {
      console.error("Room creation error:", roomError)
      return err("Failed to initialize chat room", 500)
    }

    // Insert the direct message
    const { data: message, error: insertError } = await supabase
      .from("direct_messages")
      .insert({
        room_id: roomId,
        sender_id: userId,
        message_type,
        content,
        media_url,
        metadata: metadata || {}
      })
      .select()
      .single()

    if (insertError) {
      console.error("Message insert error:", insertError)
      return err("Failed to send message", 500)
    }

    // 🚀 Neural Sync: High-Performance Redis Delivery
    try {
      const { redisCall, syncMessageToRedis, triggerChatNotification } = await import("../_shared/chat-helpers.ts")
      
      // 1. Store in Room List for instant retrieval
      await syncMessageToRedis(message)
      
      // 2. Trigger instant notification
      await triggerChatNotification(to_user_id, userId, roomId, content)
      
      // 3. Update room activity for both users
      const timestamp = Date.now()
      await redisCall("ZADD", `chat:user:${userId}:rooms`, timestamp, roomId)
      await redisCall("ZADD", `chat:user:${to_user_id}:rooms`, timestamp, roomId)
      
    } catch (redisErr) {
      console.error("REDIS Sync Error (Non-Fatal):", redisErr)
    }

    return json({
      success: true,
      message
    })


  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error)
    console.error("Direct Message error:", msg)
    return err(`Server error: ${msg}`, 500)
  }
})
