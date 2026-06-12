import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { redisCall, syncMessageToRedis, triggerChatNotification, normalizeMessages } from "@shared/chat-helpers.ts"




// ============================================
// NECXA-CHAT — High-Performance Neural Chat
// ============================================

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-primary-jwt",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })

const err = (message: string, status = 400) => json({ error: message }, status)

// --- Environment & Clients ---
const PRIMARY_SUPABASE_URL = Deno.env.get("PRIMARY_SUPABASE_URL") || "https://lzdtrmjcwzalckszdzpt.supabase.co"
const PRIMARY_SUPABASE_ANON_KEY = Deno.env.get("PRIMARY_SUPABASE_ANON_KEY") || "sb_publishable_lLcn4V9uIIgs3B59cHVXWg_1-PNsUfR"
const PRIMARY_SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("PRIMARY_SUPABASE_SERVICE_ROLE_KEY")

// Enforce database operations execute against the primary backend
const primaryAdminKey = PRIMARY_SUPABASE_SERVICE_ROLE_KEY || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
const primaryUrl = PRIMARY_SUPABASE_SERVICE_ROLE_KEY ? PRIMARY_SUPABASE_URL : Deno.env.get("SUPABASE_URL")!

const supabase = createClient(primaryUrl, primaryAdminKey)
const primaryClient = createClient(PRIMARY_SUPABASE_URL, PRIMARY_SUPABASE_ANON_KEY)


// ============================================
// HANDLERS
// ============================================

// ── Necxa Multilingual Linguistic Engine (TypeScript port) ──────────────────

const LANG_VOCAB: Record<string, string[]> = {
  sw: ['nyumba','shamba','bei','karibu','habari','sawa','ndiyo','hapana','pango','kodi','eneo','mji','mtaa','jengo','chumba','ardhi','ghali','mwezi','wiki','leo','kesho'],
  fr: ['bonjour','maison','loyer','propriété','quartier','cherche','location','achat','vendre','appartement','villa','terrain','bureau','mois','prix','disponible'],
  ar: ['بيت','شقة','إيجار','أرض','مكتب','سعر','متاح','موقع','مدينة','أريد','أبحث','هل','نعم','لا'],
  am: ['ቤት','ቦታ','ኪራይ','ዋጋ','ፈልጋለሁ','አካባቢ','ከተማ','ወር','አዎ','አይ'],
  so: ['guri','degaan','qiimaha','kireyn','guriga','magaalo','xaafad','haa','maya','fadlan'],
  en: ['house','home','rent','buy','sell','property','apartment','land','plot','office','price','location','area','city','estate','agent','verify','listing','deposit','landlord','tenant','available','month']
};

const ARABIC_RE = /[\u0600-\u06FF]/;
const ETHIOPIC_RE = /[\u1200-\u137F]/;

function detectLang(text: string): string {
  if (!text.trim()) return 'en';
  if (ARABIC_RE.test(text)) return 'ar';
  if (ETHIOPIC_RE.test(text)) return 'am';
  const t = text.toLowerCase();
  const scores: Record<string, number> = {};
  for (const [lang, words] of Object.entries(LANG_VOCAB)) {
    scores[lang] = words.filter(w => t.includes(w)).length;
  }
  if (scores.sw > 0 && scores.sw >= scores.en) return 'sw';
  const best = Object.entries(scores).sort((a, b) => b[1] - a[1])[0];
  return (!best || best[1] === 0) ? 'en' : best[0];
}

const INTENT_PATTERNS: Record<string, RegExp> = {
  greeting: /^(hi|hello|hey|habari|jambo|bonjour|salut|مرحبا|ሰላም|salaam)/i,
  listing_inquiry: /list|property|house|flat|apartment|nyumba|shamba|maison|appartement|بيت|شقة|guri/i,
  price_negotiation: /price|cost|bei|ngapi|combien|loyer|سعر|qiimaha|negotiate|discount|punguza/i,
  location_search: /where|location|area|eneo|wapi|mtaa|quartier|في أين|xaafad|nairobi|kampala|dar|kigali|addis|mogadishu|mombasa|kisumu|entebbe|arusha/i,
  verification_request: /verify|verified|real|fake|confirm|thibitisha|vérifier|تحقق|scam|fraud|legit/i,
  scam_alert: /scam|fraud|fake|suspicious|shaka|méfiant|احتيال|dagaal/i,
  rental_process: /how to rent|jinsi|comment louer|كيف أستأجر|deposit|lease|contract|mkataba/i,
  investment_query: /invest|roi|return|profit|buy to let|faidisha|investir|استثمار|maalgashi/i,
  legal_help: /law|legal|rights|sheria|droits|قانون|xeer|dispute|evict|notice/i,
  agent_contact: /agent|broker|contact|reach|call|phone|namba|numéro|رقم|realtor/i,
};

const EA_CITIES = ['nairobi','kampala','dar es salaam','dar','kigali','addis ababa','addis','mogadishu','mombasa','kisumu','entebbe','arusha','zanzibar','jinja','eldoret','nakuru','westlands','kilimani','ntinda','najjera','bugolobi','kimihurura'];

function extractLocs(text: string): string[] {
  const t = text.toLowerCase();
  return EA_CITIES.filter(c => t.includes(c)).map(c => c.charAt(0).toUpperCase() + c.slice(1));
}

function classifyIntent(text: string): string {
  const t = text.toLowerCase();
  for (const [intent, re] of Object.entries(INTENT_PATTERNS)) {
    if (re.test(t)) return intent;
  }
  return 'fallback';
}

type Handler = (locs: string[]) => string;
const RESPONSES: Record<string, Record<string, Handler>> = {
  en: {
    greeting: (l) => `Necxa here! Your East African real estate intelligence. Ask me about properties, prices, or verified listings${l.length ? ` in ${l.join(', ')}` : ''}. What are you looking for?`,
    listing_inquiry: (l) => `Active verified listings${l.length ? ` in ${l.join(', ')}` : ' across East Africa'}: bedsitters from KES 8,000, studios from KES 15,000, 2–3BR from KES 25,000/month. What's your preferred type and budget?`,
    price_negotiation: (l) => `Prices${l.length ? ` in ${l[0]}` : ''}: bedsitters KES 8,000–18,000, 1BR KES 15,000–35,000, 2BR KES 25,000–65,000/month. Many landlords accept 10–15% below asking for 3+ months upfront. Want me to filter by your range?`,
    location_search: (l) => l.length ? `${l.join(' & ')} has a strong rental market. I can pull verified listings with photos, agent contacts and scam scores. What's your budget and property type?` : `Tell me which city — Nairobi, Kampala, Dar es Salaam, Kigali, or Addis Ababa? I'll pull up verified listings instantly.`,
    verification_request: () => `Necxa Shield verifies any listing in seconds. Share the listing ID, phone number, or agent name — I'll cross-check our verified registry and flag known scam patterns. What listing are you checking?`,
    scam_alert: () => `⚠️ Scam alert! Red flags: payment before viewing, no written lease, price far below market, agent with no verifiable ID. Send me listing details and I'll run a full Shield scan immediately.`,
    rental_process: () => `Renting in East Africa typically requires: 1–3 months deposit + 1st month upfront, signed tenancy agreement, ID copy, sometimes a guarantor letter. Want a checklist or help with a specific step?`,
    investment_query: () => `Buy-to-let yields: Nairobi (Westlands, Kilimani) 6–9%, Kampala (Ntinda) 8–12%, Dar es Salaam 7–10%, Kigali 9–13%. Land appreciation in peri-urban areas runs 15–25% YoY. Which city are you considering?`,
    legal_help: () => `Tenancy laws differ: Kenya (Rent Restriction Act), Uganda (Landlord & Tenant Act 2022), Tanzania (Land Act), Rwanda (Ministerial Order). Key rights: written agreement, 30-day eviction notice, receipt for all payments. Which country?`,
    agent_contact: () => `I can connect you with Necxa-verified agents — they've passed ID verification and hold active listing licenses. Which city or property type? I'll shortlist top-rated agents with <30 min response times.`,
    fallback: () => `I specialize in East African real estate — listings, price analysis, agent verification, legal help, and community discussions across Kenya, Uganda, Tanzania, Rwanda, and Ethiopia. What can I help you find?`
  },
  sw: {
    greeting: (l) => `Habari! Mimi ni Necxa, msaidizi wako wa mali isiyohamishika Afrika Mashariki${l.length ? `, hasa ${l.join(', ')}` : ''}. Unataka nini?`,
    listing_inquiry: (l) => `Tuna listings zilizothibitishwa${l.length ? ` ${l.join(', ')}` : ''}! Bedsitter inaanzia KES 8,000, studio KES 15,000, nyumba 2–3BR KES 25,000–65,000/mwezi. Aina gani na bajeti yako?`,
    price_negotiation: (l) => `Bei${l.length ? ` ${l[0]}` : ''}: bedsitter KES 8,000–18,000, 1BR KES 15,000–35,000, 2BR KES 25,000–65,000/mwezi. Wamiliki wengi wanakubali punguzo la 10–15% ukilipa miezi 3+ mapema. Niambie bajeti yako.`,
    location_search: (l) => l.length ? `${l.join(' na ')} ni eneo zuri. Nina listings zilizothibitishwa na picha na nambari za mawakala. Bajeti yako ni ngapi?` : `Niambie mji — Nairobi, Kampala, Dar es Salaam, au Kigali? Nitakutafutia haraka!`,
    verification_request: () => `Necxa Shield inathibitisha listing yoyote haraka. Nipe nambari ya listing au wakala — nitaichunguza kwenye rejista yetu na kutambua ulaghai. Ni listing gani?`,
    scam_alert: () => `⚠️ Tahadhari! Dalili za ulaghai: malipo kabla ya kuona nyumba, hakuna mkataba, bei chini sana. Tuma maelezo ya listing nikusaidie kukagua haraka.`,
    rental_process: () => `Kukodi Afrika Mashariki unahitaji: deposit ya miezi 1–3, mkataba wa kukodi, nakala ya kitambulisho. Unahitaji msaada gani?`,
    investment_query: () => `Faida: Nairobi 6–9%, Kampala 8–12%, Dar es Salaam 7–10%, Kigali 9–13%. Ardhi pembezoni ya mji inapanda 15–25%/mwaka. Unafikiri kuwekeza wapi?`,
    legal_help: () => `Sheria: Kenya (Rent Restriction Act), Uganda (Landlord & Tenant Act 2022), Tanzania (Land Act). Haki zako: mkataba wa maandishi, notisi miezi 1, risiti ya malipo. Nchi gani?`,
    agent_contact: () => `Ninaweza kukuunganisha na mawakala wa Necxa walioidhinishwa. Unataka mji gani au aina gani ya mali?`,
    fallback: () => `Ninabobea katika mali isiyohamishika Afrika Mashariki — listings, bei, uthibitishaji wa mawakala, msaada wa kisheria. Ninawezaje kukusaidia?`
  },
  fr: {
    greeting: (l) => `Bonjour! Je suis Necxa, votre assistant immobilier pour l'Afrique de l'Est${l.length ? `, spécialement ${l[0]}` : ''}. Que recherchez-vous?`,
    listing_inquiry: (l) => `Annonces vérifiées${l.length ? ` à ${l.join(', ')}` : ' en Afrique de l\'Est'}: studios dès 15,000 KES, appartements 2–3 ch dès 25,000 KES/mois. Quel type et budget?`,
    location_search: (l) => l.length ? `${l[0]} a un marché locatif dynamique. Annonces vérifiées avec photos et contacts. Quel est votre budget?` : `Dites-moi la ville — Nairobi, Kampala, Dar es Salaam ou Kigali?`,
    verification_request: () => `Necxa Shield vérifie toute annonce en secondes. Partagez l'ID ou le numéro de l'agent — je détecterai les arnaques. Quelle annonce?`,
    scam_alert: () => `⚠️ Alerte arnaque! Paiement avant visite, pas de contrat, prix sous le marché — envoyez les détails pour un scan Shield complet.`,
    rental_process: () => `Pour louer: caution 1–3 mois + premier loyer, bail signé, copie d'identité. Quelle étape vous pose problème?`,
    investment_query: () => `Rendements: Nairobi 6–9%, Kampala 8–12%, Dar es Salaam 7–10%, Kigali 9–13%. Quelle ville envisagez-vous?`,
    legal_help: () => `Lois: Kenya (Rent Restriction Act), Uganda (Landlord & Tenant Act 2022), Rwanda (Ordonnance Ministérielle). Quel pays?`,
    agent_contact: () => `Agents certifiés Necxa disponibles. Quelle ville ou type de bien?`,
    fallback: () => `Je me spécialise dans l'immobilier d'Afrique de l'Est — annonces, prix, vérification d'agents, aide juridique. Comment puis-je vous aider?`
  },
  ar: {
    greeting: () => `مرحباً! أنا نيكسا، مساعدك العقاري لأفريقيا الشرقية. كيف يمكنني مساعدتك؟`,
    listing_inquiry: (l) => `لدينا قوائم موثقة${l.length ? ` في ${l[0]}` : ' في شرق أفريقيا'}! شقق من 15,000 شلن كينياً. ما نوع العقار وميزانيتك؟`,
    location_search: (l) => l.length ? `${l[0]} لديها سوق إيجار نشط. ما ميزانيتك؟` : `أخبرني بالمدينة — نيروبي، كمبالا، دار السلام، أو كيغالي؟`,
    verification_request: () => `Necxa Shield يتحقق من أي قائمة في ثوانٍ. أرسل معرف القائمة أو رقم الوكيل. ما القائمة؟`,
    scam_alert: () => `⚠️ تنبيه احتيال! الدفع قبل المعاينة، لا عقد، سعر منخفض جداً — أرسل التفاصيل لفحص Shield.`,
    fallback: () => `أتخصص في عقارات شرق أفريقيا — القوائم، الأسعار، التحقق من الوكلاء، المساعدة القانونية. كيف يمكنني مساعدتك؟`
  },
  am: {
    greeting: () => `ሰላም! እኔ ነቅሳ ነኝ፣ ለምስራቅ አፍሪካ ሪል እስቴት ረዳትዎ። ምን ፈልጎ ነው?`,
    listing_inquiry: () => `ተረጋግጠዋ ዝርዝሮች አሉን! ቤቶች ከ8,000 ኬኤስ ጀምሮ። ምን አይነት ቤት እና በጀቶ ምን ያህል?`,
    location_search: (l) => l.length ? `${l[0]} ጥሩ ገበያ አለው። ተረጋግጦ ዝርዝሮችን ልሰጥዎ? በጀቶ?` : `የትኛውን ከተማ? አዲስ አበባ፣ ናይሮቢ፣ ካምፓላ?`,
    fallback: () => `በምስራቅ አፍሪካ ሪል እስቴት ልረዳዎ — ዝርዝሮች፣ ዋጋ፣ ወኪሎች ማረጋገጥ። ምን ፈልጎ ነው?`
  },
  so: {
    greeting: () => `Salaam! Waxaan ahay Necxa, kaaliyahaaga guryaha Afrika Bari. Maxaa raadineysaa?`,
    listing_inquiry: (l) => `Liisas xaqiijiyey${l.length ? ` ${l[0]}` : ''}! Guryo laga bilaabi karo 8,000 KES/bishii. Nooca iyo miisaaniyadaadu?`,
    location_search: (l) => l.length ? `${l[0]} suuq guri wanaagsan leh. Miisaaniyadaadu?` : `Magaaladee? Nairobi, Kampala, Dar es Salaam, mise Kigali?`,
    fallback: () => `Waxaan ku takhasustay guryaha Afrika Bari — liisaska, qiimaha, xaqiijinta wakiillada. Sidee kaa caawin karaa?`
  }
};

function buildReply(message: string): string {
  const lang = detectLang(message);
  const intent = classifyIntent(message);
  const locs = extractLocs(message);
  const langMap = RESPONSES[lang] || RESPONSES['en'];
  const handler = langMap[intent] || langMap['fallback'];
  return handler(locs);
}

// --- 🤖 1. AI Assistant ---
async function handleAI(_userId: string, payload: any) {
  const message = payload.message || (payload.messages && payload.messages[0]?.content)
  if (!message) return err("Missing message for AI")

  const NECXA_AI_URL = Deno.env.get('NECXA_AI_URL') || 'https://api.necxa.uk'

  // Try Cloudflare Workers AI (Llama 3.1 — real multilingual AI)
  try {
    const aiRes = await fetch(`${NECXA_AI_URL}/api/assistant/chat/sync`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message }),
    })
    if (aiRes.ok) {
      const aiData = await aiRes.json()
      if (aiData.response) {
        return json({ success: true, reply: aiData.response, content: aiData.response, engine: 'Necxa AI — Cloudflare Workers' })
      }
    }
  } catch (e) {
    console.error("Cloudflare AI fallback:", e)
  }

  // Fallback: local linguistic engine
  const reply = buildReply(message)
  return json({ success: true, reply, content: reply, engine: 'Necxa Linguistic Engine (fallback)' })
}



// --- 💬 2. Send Message (Direct) ---
async function handleSendMessage(userId: string, payload: any) {
  const { id, to_user_id, room_id, content, media_url, message_type = "text", metadata = {} } = payload
  if (!to_user_id && !room_id) return err("Missing recipient or room")

  // 1. Resolve/Create Room
  let finalRoomId = room_id
  if (!finalRoomId) {
    const { data: rId, error: rErr } = await supabase.rpc('get_or_create_direct_room', {
      p_user_a: userId,
      p_user_b: to_user_id
    })
    if (rErr || !rId) return err(`Room error: ${rErr?.message}`)
    finalRoomId = rId
  }

  // 2. Persist to Postgres
  const { data: message, error: mErr } = await supabase
    .from("direct_messages")
    .insert({
      ...(id && { id }), // Only include id if provided
      room_id: finalRoomId,
      sender_id: userId,
      message_type,
      content,
      media_url,
      metadata
    })
    .select("*, profiles:sender_id(full_name, avatar_url)")
    .single()

  if (mErr) return err(`Insert failed: ${mErr.message}`)

  // 3. 🚀 Neural Sync: Push to Redis
  await syncMessageToRedis(message)

  // 4. Update Room List for both users in Redis
  const { data: roomInfo } = await supabase.from("direct_chat_rooms").select("user_a, user_b").eq("id", finalRoomId).single()
  if (roomInfo) {
    const timestamp = Date.now()
    await redisCall("ZADD", `chat:user:${roomInfo.user_a}:rooms`, timestamp, finalRoomId)
    await redisCall("ZADD", `chat:user:${roomInfo.user_b}:rooms`, timestamp, finalRoomId)
  }

  // 5. Trigger Notification in Redis
  const recipientId = to_user_id || (roomInfo?.user_a === userId ? roomInfo?.user_b : roomInfo?.user_a)
  if (recipientId) {
    await triggerChatNotification(recipientId, userId, finalRoomId, content)
  }


  return json({ success: true, data: message })
}

// --- 📥 3. Fetch Messages (Direct) ---
async function handleFetchMessages(userId: string, payload: any) {
  const { room_id, limit = 50 } = payload
  if (!room_id) return err("Missing room_id")

  // 1. Try Redis first (High Performance)
  const redisRes = await redisCall("LRANGE", `chat:room:${room_id}:messages`, 0, limit - 1)
  if (redisRes && redisRes.result && redisRes.result.length > 0) {
    const rawMessages = redisRes.result.map((m: string) => JSON.parse(m))
    const { messages, profiles } = normalizeMessages(rawMessages)
    return json({ success: true, data: messages, profiles, source: 'cache' })
  }

  // 2. Fallback to Postgres (Reliable Source)
  const { data, error } = await supabase
    .from("direct_messages")
    .select("*, profiles:sender_id(full_name, avatar_url, is_verified)")
    .eq("room_id", room_id)
    .order("created_at", { ascending: false })
    .limit(limit)

  if (error) return err(`Fetch error: ${error.message}`)

  // Optional: Hydrate Redis cache in background
  if (data.length > 0) {
    for (const msg of [...data].reverse()) {
       await syncMessageToRedis(msg)
    }
    await redisCall("LTRIM", `chat:room:${room_id}:messages`, 0, 99)
  }

  const { messages, profiles } = normalizeMessages(data)
  return json({ success: true, data: messages, profiles, source: 'db' })
}


// --- 📂 4. Fetch Rooms (Direct) ---
async function handleFetchRooms(userId: string) {
  // We'll use a view if available, or just direct fetch
  const { data, error } = await supabase
    .from("v_my_chats_v2") // Using the secure view we created in migrations
    .select("*")
    .order("last_message_at", { ascending: false })

  if (error) {
    // Fallback to simpler view if v2 doesn't exist yet
    const { data: v1, error: e1 } = await supabase.from("v_my_chats").select("*")
    if (e1) return err(`Rooms error: ${e1.message}`)
    return json({ success: true, data: v1 })
  }

  return json({ success: true, data })
}

// ============================================
// MAIN ROUTER
// ============================================

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })

  try {
    // Auth Check using primary auth server - Strict Federated Auth Bridge
    const primaryJwt = req.headers.get("x-primary-jwt")
    if (!primaryJwt) return err("Unauthorized: missing x-primary-jwt", 401)

    const primaryUserClient = createClient(
      PRIMARY_SUPABASE_URL,
      PRIMARY_SUPABASE_ANON_KEY,
      { global: { headers: { Authorization: `Bearer ${primaryJwt}` } } }
    )

    const { data: { user }, error: userError } = await primaryUserClient.auth.getUser()
    if (userError || !user) return err("Unauthorized: invalid primary JWT", 401)

    const userId = user.id

    const body = await req.json()
    const { action, payload = {} } = body

    // Route Actions
    switch (action) {
      case "AI_ASSISTANT":
        return handleAI(userId, body) // Body passed for legacy 'messages' field
      case "SEND_MESSAGE":
        return handleSendMessage(userId, payload)
      case "FETCH_MESSAGES":
        return handleFetchMessages(userId, payload)
      case "FETCH_ROOMS":
        return handleFetchRooms(userId)
      default:
        // Default to AI if no action (for askNexca compatibility)
        if (body.message || body.messages) {
          return handleAI(userId, body)
        }
        return err(`Unknown action: ${action}`)
    }
  } catch (e) {
    console.error("Router Error:", e)
    return err(`Internal error: ${e.message}`, 500)
  }
})
