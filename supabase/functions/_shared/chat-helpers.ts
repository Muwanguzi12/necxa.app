import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.4"

const REDIS_URL = Deno.env.get("UPSTASH_REDIS_REST_URL")?.trim() || ""
const REDIS_TOKEN = Deno.env.get("UPSTASH_REDIS_REST_TOKEN")?.trim() || ""

export async function redisCall(command: string, ...args: any[]) {
  if (!REDIS_URL || !REDIS_TOKEN) return null
  try {
    const res = await fetch(REDIS_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${REDIS_TOKEN}` },
      body: JSON.stringify([command, ...args]),
    })
    return await res.json()
  } catch (e) {
    console.error("REDIS Error:", e)
    return null
  }
}

export async function syncMessageToRedis(message: any) {
  const roomId = message.room_id
  const redisMsg = JSON.stringify(toLightweight(message))

  // 1. Push to room messages
  await redisCall("LPUSH", `chat:room:${roomId}:messages`, redisMsg)
  await redisCall("LTRIM", `chat:room:${roomId}:messages`, 0, 99)
}


export async function triggerChatNotification(
  recipientId: string,
  senderId: string,
  roomId: string,
  content: string,
  context?: Record<string, unknown>,
) {
  const notification = {
    type: 'new_message',
    sender_id: senderId,
    room_id: roomId,
    content: content ? content.substring(0, 50) : "Sent a media file",
    created_at: new Date().toISOString(),
    ...(context ?? {}),
  }
  await redisCall("LPUSH", `notifications:${recipientId}`, JSON.stringify(notification))
  await redisCall("LTRIM", `notifications:${recipientId}`, 0, 49)
}

// 🚀 DATA SAVER: Profile Normalization
// Strips duplicate profile info from message list and returns a unique map
export function normalizeMessages(messages: any[]) {
  const profiles: Record<string, any> = {}
  const normalizedMessages = messages.map(msg => {
    // Extract profile if it exists (nested from Supabase select)
    if (msg.profiles) {
      const p = msg.profiles
      if (!profiles[msg.sender_id]) {
        profiles[msg.sender_id] = {
          name: p.display_name || p.full_name,
          avatar: p.photo_url || p.avatar_url,
          verified: p.is_verified
        }
      }
      // Remove the non-essential nested profile from the message itself
      const { profiles: _, ...rest } = msg
      return rest
    }
    return msg
  })

  return {
    messages: normalizedMessages,
    profiles
  }
}

// 🚀 DATA SAVER: Lightweight Message for Redis
// Truncates large metadata or content for the high-speed cache
export function toLightweight(message: any) {
  return {
    ...message,
    metadata: message.metadata ? {
      type: message.metadata.type,
      id: message.metadata.id,
      thumbnail: message.metadata.thumbnail,
      interaction_context: message.metadata.interaction_context,
      conversation_label: message.metadata.conversation_label,
      initiated_via: message.metadata.initiated_via,
      source: message.metadata.source,
      ticket_id: message.metadata.ticket_id,
      source_reply_id: message.metadata.source_reply_id,
    } : {},
    // Truncate extremely long texts for the quick-preview cache
    content: message.content && message.content.length > 500
      ? message.content.substring(0, 500) + "..."
      : message.content
  }
}
