import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

// ============================================
// SMOOTH-ACTION — Unified Necxa API Router
// ============================================

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-user-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })

const err = (message: string, status = 400) => json({ error: message }, status)

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } }
)

// ============================================
// AUTH HELPER
// ============================================
async function resolveUser(req: Request): Promise<string | null> {
  const authHeader = req.headers.get("Authorization")
  if (authHeader?.startsWith("Bearer ")) {
    try {
      const { data: { user } } = await supabase.auth.getUser(authHeader.replace("Bearer ", ""))
      if (user) return user.id
    } catch (_) {}
  }
  return req.headers.get("x-user-id")
}

// ============================================
// HANDLERS
// ============================================

// ── PROFILE ──
async function handleProfile(userId: string, action: string, _payload: Record<string, unknown>) {
  if (action === "get") {
    const { data, error } = await supabase
      .from("profiles")
      .select("*")
      .eq("id", userId)
      .single()
    if (error) return err(`Profile error: ${error.message}`)
    return json({ success: true, data })
  }
  return err("Unknown profile action")
}

// ── PROPERTY ──
async function handleProperty(userId: string | null, action: string, payload: Record<string, unknown>) {
  if (action === "list") {
    const limit = (payload.limit as number) || 50
    const filter = (payload.filter as string) || "all"
    let query = supabase
      .from("properties")
      .select("*")
      .eq("is_active", true)
      .eq("is_honeypot", false)
      .or("is_sold.is.null,is_sold.eq.false")
      .order("created_at", { ascending: false })
      .limit(limit)

    if (filter !== "all") {
      query = query.or(`property_type.eq.${filter},listing_type.eq.${filter}`)
    }

    const { data, error } = await query
    if (error) return err(`Properties error: ${error.message}`)

    // Check unlocks for current user
    let unlockedPropertyIds = new Set<string>()
    if (userId) {
      const { data: userUnlocks } = await supabase
        .from("unlocks")
        .select("property_id")
        .eq("buyer_id", userId)
        .eq("status", "completed")
      unlockedPropertyIds = new Set((userUnlocks || []).map((u: any) => u.property_id))
    }

    const secureList = (data || []).map((prop: any) => {
      const isOwner = Boolean(userId && prop.lister_id === userId)
      const isUnlocked = isOwner || unlockedPropertyIds.has(prop.id)

      return {
        ...prop,
        is_unlocked_by_current_user: isUnlocked,
        // Privacy protection before unlock: user sees pictures & district, but cannot access exact location or contacts
        address: isUnlocked ? prop.address : `Near ${prop.district || prop.city || 'Property Area'}`,
        gps_latitude: isUnlocked ? prop.gps_latitude : null,
        gps_longitude: isUnlocked ? prop.gps_longitude : null,
        latitude: isUnlocked ? prop.latitude : 0.0,
        longitude: isUnlocked ? prop.longitude : 0.0,
        umeme_meter_number: isUnlocked ? prop.umeme_meter_number : null,
        nwsc_customer_number: isUnlocked ? prop.nwsc_customer_number : null,
        land_title_block: isUnlocked ? prop.land_title_block : null,
        land_title_plot: isUnlocked ? prop.land_title_plot : null,
      }
    })

    return json({ success: true, data: secureList })
  }

  if (action === "get") {
    const propertyId = payload.property_id as string
    if (!propertyId) return err("property_id required")
    const { data, error } = await supabase
      .from("properties")
      .select("*")
      .eq("id", propertyId)
      .single()
    if (error) return err(`Property error: ${error.message}`)

    // Track view
    await supabase.from("properties").update({ views_count: (data.views_count || 0) + 1 }).eq("id", propertyId)

    // Check unlock
    let isUnlocked = false
    if (userId) {
      if (data.lister_id === userId) {
        isUnlocked = true
      } else {
        const { data: userUnlock } = await supabase
          .from("unlocks")
          .select("id")
          .eq("property_id", propertyId)
          .eq("buyer_id", userId)
          .eq("status", "completed")
          .maybeSingle()
        if (userUnlock) isUnlocked = true
      }
    }

    let agentPhone = null
    let agentWhatsapp = null
    let agentGoogleMeet = null

    if (isUnlocked && (data.agent_id || data.lister_id)) {
      const targetAgentId = data.agent_id || data.lister_id
      const { data: contact } = await supabase
        .from("agent_contact_methods")
        .select("phone_number, whatsapp_number, google_meet_link")
        .eq("agent_id", targetAgentId)
        .maybeSingle()
      if (contact) {
        agentPhone = contact.phone_number
        agentWhatsapp = contact.whatsapp_number
        agentGoogleMeet = contact.google_meet_link
      }
    }

    const secureData = {
      ...data,
      is_unlocked_by_current_user: isUnlocked,
      address: isUnlocked ? data.address : `Near ${data.district || data.city || 'Property Area'}`,
      gps_latitude: isUnlocked ? data.gps_latitude : null,
      gps_longitude: isUnlocked ? data.gps_longitude : null,
      latitude: isUnlocked ? data.latitude : 0.0,
      longitude: isUnlocked ? data.longitude : 0.0,
      umeme_meter_number: isUnlocked ? data.umeme_meter_number : null,
      nwsc_customer_number: isUnlocked ? data.nwsc_customer_number : null,
      land_title_block: isUnlocked ? data.land_title_block : null,
      land_title_plot: isUnlocked ? data.land_title_plot : null,
      agent_phone: agentPhone,
      agent_whatsapp: agentWhatsapp,
      agent_google_meet: agentGoogleMeet,
    }

    return json({ success: true, data: secureData })
  }

  if (action === "mylistings") {
    if (!userId) return err("Unauthorized", 401)
    const { data, error } = await supabase
      .from("properties")
      .select("*")
      .eq("lister_id", userId)
      .order("created_at", { ascending: false })
    if (error) return err(`My listings error: ${error.message}`)
    return json({ success: true, data })
  }

  return err("Unknown property action. Use: list, get, mylistings")
}

// ── UNLOCK ──
async function handleUnlock(userId: string, payload: Record<string, unknown>) {
  const propertyId = payload.property_id as string
  if (!propertyId) return err("property_id required")

  // Get property
  const { data: property, error: propErr } = await supabase
    .from("properties")
    .select("*")
    .eq("id", propertyId)
    .single()
  if (propErr || !property) return err("Property not found", 404)

  // Check already unlocked
  const { data: existing } = await supabase
    .from("unlocks")
    .select("id")
    .eq("property_id", propertyId)
    .eq("buyer_id", userId)
    .single()
  if (existing) return json({ success: true, already_unlocked: true, unlock_id: existing.id })

  const unlockAmount = Math.floor(property.price * 0.1)

  // Check free trial
  const { data: profile } = await supabase
    .from("profiles")
    .select("has_used_free_unlock")
    .eq("id", userId)
    .single()
    
  if (profile?.has_used_free_unlock) {
    return json({ success: false, requires_payment: true, unlock_cost: unlockAmount })
  }

  // Use Free Trial: Create unlock record
  const { data: unlock, error: unlockErr } = await supabase
    .from("unlocks")
    .insert({
      property_id: propertyId,
      buyer_id: userId,
      seller_id: property.lister_id,
      agent_id: property.agent_id,
      unlock_amount: 0,
      unlock_cost: unlockAmount,
      status: "completed",
      address_revealed_at: new Date().toISOString(),
      contact_revealed_at: new Date().toISOString(),
    })
    .select()
    .single()
  if (unlockErr) return err(`Unlock error: ${unlockErr.message}`)

  // Mark trial as used
  await supabase.from("profiles").update({ has_used_free_unlock: true }).eq("id", userId)

  // Increment unlocks count
  await supabase
    .from("properties")
    .update({ unlocks_count: (property.unlocks_count || 0) + 1 })
    .eq("id", propertyId)

  return json({
    success: true,
    unlock_id: unlock.id,
    unlock_amount: unlockAmount,
    address: property.address,
    agent_id: property.agent_id,
    lister_id: property.lister_id,
    message: "Property unlocked! Contact details revealed.",
  })
}

// ── ESCROW ──
async function handleEscrow(userId: string, payload: Record<string, unknown>) {
  const propertyId = payload.property_id as string
  if (!propertyId) return err("property_id required")

  const { data: property, error: propErr } = await supabase
    .from("properties")
    .select("*")
    .eq("id", propertyId)
    .single()
  if (propErr || !property) return err("Property not found", 404)

  const depositAmount = Math.floor(property.price * 0.1)
  const expiresAt = new Date(Date.now() + 1000 * 60 * 60 * 24 * 7) // 7 days

  const { data: escrow, error: escrowErr } = await supabase
    .from("escrow_reservations")
    .insert({
      property_id: propertyId,
      buyer_id: userId,
      seller_id: property.lister_id,
      agent_id: property.agent_id,
      property_value: property.price,
      deposit_amount: depositAmount,
      status: "pending",
      reservation_expires_at: expiresAt.toISOString(),
    })
    .select()
    .single()
  if (escrowErr) return err(`Escrow error: ${escrowErr.message}`)

  await supabase
    .from("properties")
    .update({ reservations_count: (property.reservations_count || 0) + 1 })
    .eq("id", propertyId)

  const qrPayload = JSON.stringify({
    escrow_id: escrow.id,
    amount: depositAmount,
    property: property.title,
    expires: expiresAt.toISOString(),
  })

  return json({
    success: true,
    escrow_id: escrow.id,
    deposit_amount: depositAmount,
    property_value: property.price,
    expires_at: expiresAt.toISOString(),
    qr_code: `https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${encodeURIComponent(qrPayload)}`,
    message: "Escrow reservation created. Pay the deposit to confirm.",
  })
}

// ── WALLET ──
async function handleWallet(userId: string, action: string, _payload: Record<string, unknown>) {
  if (action === "balance") {
    // Count unlocks made by user (coins spent)
    const { count: unlockCount } = await supabase
      .from("unlocks")
      .select("*", { count: "exact", head: true })
      .eq("buyer_id", userId)

    // Count escrows
    const { count: escrowCount } = await supabase
      .from("escrow_reservations")
      .select("*", { count: "exact", head: true })
      .eq("buyer_id", userId)

    // Count listings (earnings proxy)
    const { count: listingCount } = await supabase
      .from("properties")
      .select("*", { count: "exact", head: true })
      .eq("lister_id", userId)

    return json({
      success: true,
      data: {
        fiat_balance: 0,
        ncx_balance: 0,
        escrow_balance: 0,
        unlocks_count: unlockCount || 0,
        escrows_count: escrowCount || 0,
        listings_count: listingCount || 0,
        currency: "UGX",
      },
    })
  }
  return err("Unknown wallet action. Use: balance")
}

// ── CHAT ──
async function handleChat(userId: string, action: string, payload: Record<string, unknown>) {
  if (action === "conversations") {
    const { data, error } = await supabase
      .from("chat_conversations")
      .select("*, property:properties(title, images)")
      .or(`buyer_id.eq.${userId},seller_id.eq.${userId},agent_id.eq.${userId}`)
      .order("last_message_at", { ascending: false })
    if (error) return err(`Chat error: ${error.message}`)
    return json({ success: true, data })
  }

  if (action === "messages") {
    const conversationId = payload.conversation_id as string
    if (!conversationId) return err("conversation_id required")
    const { data, error } = await supabase
      .from("in_app_chat_messages")
      .select("*")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: true })
      .limit(100)
    if (error) return err(`Messages error: ${error.message}`)
    return json({ success: true, data })
  }

  if (action === "send") {
    const { conversation_id, property_id, receiver_id, message } = payload as {
      conversation_id?: string
      property_id: string
      receiver_id: string
      message: string
    }
    if (!receiver_id || !message) return err("receiver_id and message required")

    // Find or create conversation
    let convoId = conversation_id
    if (!convoId && property_id) {
      const { data: existing } = await supabase
        .from("chat_conversations")
        .select("id")
        .eq("property_id", property_id)
        .or(`buyer_id.eq.${userId},seller_id.eq.${userId}`)
        .single()

      if (existing) {
        convoId = existing.id
      } else {
        const { data: newConvo } = await supabase
          .from("chat_conversations")
          .insert({
            property_id,
            buyer_id: userId,
            seller_id: receiver_id,
            last_message: message,
            last_message_at: new Date().toISOString(),
            last_message_sender_id: userId,
          })
          .select()
          .single()
        convoId = newConvo?.id
      }
    }

    const { data: msg, error: msgErr } = await supabase
      .from("in_app_chat_messages")
      .insert({
        conversation_id: convoId,
        property_id: property_id || null,
        sender_id: userId,
        receiver_id,
        message,
        message_type: "text",
      })
      .select()
      .single()
    if (msgErr) return err(`Send error: ${msgErr.message}`)

    // Update conversation
    if (convoId) {
      await supabase.from("chat_conversations").update({
        last_message: message,
        last_message_at: new Date().toISOString(),
        last_message_sender_id: userId,
      }).eq("id", convoId)
    }

    return json({ success: true, data: msg, conversation_id: convoId })
  }

  return err("Unknown chat action. Use: conversations, messages, send")
}

// ── UTILITY ──
async function handleUtility(userId: string, payload: Record<string, unknown>) {
  const country = (payload.country as string) || "Uganda"
  const umemeMeter = payload.umeme_meter as string | undefined
  const nwscAccount = payload.nwsc_account as string | undefined
  const kplcMeter = payload.kplc_meter as string | undefined
  const tanescoMeter = payload.tanesco_meter as string | undefined
  const landBlock = payload.land_block as string | undefined
  const landPlot = payload.land_plot as string | undefined
  const propertyId = payload.property_id as string | undefined

  const anchors: string[] = []
  const missing: string[] = []

  const isUganda = country === "Uganda" || country === "UGANDA"
  const isKenya = country === "Kenya" || country === "KENYA"
  const isTanzania = country === "Tanzania" || country === "TANZANIA"

  // Meter validation
  if (isUganda) {
    if (umemeMeter && /^\d{11}$/.test(umemeMeter.replace(/\s/g, ""))) {
      anchors.push("Umeme Yaka Meter")
    } else { missing.push("Umeme Yaka Meter Number (11 digits)") }

    if (nwscAccount && nwscAccount.replace(/\s/g, "").length >= 6) {
      anchors.push("NWSC Water Account")
    } else { missing.push("NWSC Customer Account Number") }
  }

  if (isKenya) {
    if (kplcMeter && /^\d{10,12}$/.test(kplcMeter.replace(/\s/g, ""))) {
      anchors.push("KPLC Meter")
    } else { missing.push("KPLC Meter Number") }
  }

  if (isTanzania) {
    if (tanescoMeter && /^\d{10,12}$/.test(tanescoMeter.replace(/\s/g, ""))) {
      anchors.push("TANESCO Luku Meter")
    } else { missing.push("TANESCO Meter Number") }
  }

  // Land title (block + plot)
  if (landBlock && landPlot) {
    anchors.push("Land Title (Block/Plot)")
  } else {
    missing.push("Land Title Block and Plot Number")
  }

  const required = isUganda ? 3 : 2
  const complete = anchors.length >= required

  // Save shard
  const { data: shard, error: shardErr } = await supabase
    .from("utility_shards")
    .upsert({
      profile_id: userId,
      property_id: propertyId || null,
      umeme_meter_number: umemeMeter,
      umeme_verified: isUganda && !!umemeMeter,
      nwsc_account_number: nwscAccount,
      nwsc_verified: isUganda && !!nwscAccount,
      kplc_meter_number: kplcMeter,
      kplc_verified: isKenya && !!kplcMeter,
      tanesco_meter_number: tanescoMeter,
      tanesco_verified: isTanzania && !!tanescoMeter,
      land_block: landBlock,
      land_plot: landPlot,
      land_title_verified: !!(landBlock && landPlot),
      shard_complete: complete,
      verified_at: complete ? new Date().toISOString() : null,
      updated_at: new Date().toISOString(),
    }, { onConflict: "profile_id" })
    .select()
    .single()

  if (shardErr) return err(`Utility shard error: ${shardErr.message}`)

  return json({
    success: true,
    utility_shard_id: shard.id,
    verified: complete,
    anchors,
    missing,
    message: complete
      ? "✅ Utility verification complete!"
      : `⚠️ Missing: ${missing.join(", ")}`,
  })
}

// ── PUSH TOKENS ──
async function handlePushToken(userId: string, action: string, payload: Record<string, unknown>) {
  if (action === "register") {
    const { token, device_type } = payload as { token: string; device_type?: string }
    if (!token) return err("token required")

    const { error } = await supabase
      .from("user_push_tokens")
      .upsert({
        user_id: userId,
        fcm_token: token,
        device_type: device_type || "android",
        updated_at: new Date().toISOString(),
      }, { onConflict: "user_id, fcm_token" })

    if (error) return err(`Push token error: ${error.message}`)
    return json({ success: true, message: "Token registered" })
  }
  return err("Unknown push-token action")
}

// ── NOTIFICATIONS ──
async function handleNotifications(userId: string, action: string) {
  if (action === "list" || !action) {
    const { data, error } = await supabase
      .from("notifications")
      .select("*")
      .eq("user_id", userId)
      .order("created_at", { ascending: false })
      .limit(50)
    if (error) return err(`Notifications error: ${error.message}`)
    return json({ success: true, data })
  }
  return err("Unknown notifications action")
}

// ============================================
// MAIN ROUTER
// ============================================

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })
  if (req.method !== "POST") return err("POST only", 405)

  try {
    const userId = await resolveUser(req)

    const body = await req.json() as {
      name: string
      action?: string
      payload?: Record<string, unknown>
    }

    const { name, action = "get", payload = {} } = body

    // Allow public browsing for properties
    if (!userId && !(name === "property" && (action === "list" || action === "get"))) {
      return err("Unauthorized", 401)
    }

    switch (name) {
      case "profile":      return userId ? handleProfile(userId, action, payload) : err("Unauthorized", 401)
      case "property":     return handleProperty(userId, action, payload)
      case "unlock":       return userId ? handleUnlock(userId, payload) : err("Unauthorized", 401)
      case "escrow":       return userId ? handleEscrow(userId, payload) : err("Unauthorized", 401)
      case "wallet":       return userId ? handleWallet(userId, action, payload) : err("Unauthorized", 401)
      case "chat":         return userId ? handleChat(userId, action, payload) : err("Unauthorized", 401)
      case "utility":      return userId ? handleUtility(userId, payload) : err("Unauthorized", 401)
      case "notifications":return userId ? handleNotifications(userId, action) : err("Unauthorized", 401)
      case "push-token":   return userId ? handlePushToken(userId, action, payload) : err("Unauthorized", 401)
      default:             return err(`Unknown action name: "${name}". Valid: profile, property, unlock, escrow, wallet, chat, utility, notifications`)
    }
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e)
    console.error("smooth-action error:", msg)
    return err(`Server error: ${msg}`, 500)
  }
})
