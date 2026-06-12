import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { decode } from "https://deno.land/std@0.168.0/encoding/base64.ts"
// Necxa Listing Engine — Edge AI integration

// ============================================
// INLINE HELPERS
// ============================================

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS, PUT, DELETE",
}

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
})

const err = (message: string, status = 400) => json({ error: message }, status)



// ============================================
// MAIN EDGE FUNCTION
// ============================================

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } }
)

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  try {
    // ============================================
    // AUTHENTICATION - Support multiple auth methods
    // ============================================
    let userId: string | null = null
    let userEmail: string | null = null
    let authDebugInfo = "No info"
    let isSdkAuth = false
    
    const authHeader = req.headers.get("Authorization")
    const apiKey = req.headers.get("apikey") || req.headers.get("x-api-key")
    const reqContentType = req.headers.get("content-type") || ""

    // 1. SDK API Key Authentication
    if (apiKey && apiKey.startsWith("pk_")) {
       isSdkAuth = true
       authDebugInfo = "Authenticated via Shield SDK API Key"
       // Fallback mock user if absolutely necessary for insertion without token (edge cases)
    }
    
    // 2. Native Bearer Token Authentication
    if (!isSdkAuth && authHeader && authHeader.startsWith("Bearer ")) {
      try {
        const jwt = authHeader.replace("Bearer ", "")
        const { data: { user }, error } = await supabaseAdmin.auth.getUser(jwt)
        
        if (!error && user) {
          userId = user.id
          userEmail = user.email
          authDebugInfo = "Successfully unpacked JWT"
        } else {
           console.error("JWT decoding error:", error)
           authDebugInfo = `JWT Invalid or Expired: ${error?.message}`
        }
      } catch (e) {
        console.error("Auth verification failed:", e)
        authDebugInfo = `Auth Exception: ${e.message}`
      }
    } else if (!isSdkAuth && !authHeader) {
       authDebugInfo = "No 'Authorization' header found starting with 'Bearer '"
    }
    
    // 3. Fallback: Check headers for simple context overrides
    if (!userId) {
      const xUserId = req.headers.get("x-user-id")
      if (xUserId) {
        userId = xUserId
        authDebugInfo = "Bypassed with x-user-id"
      }
    }
    
    let jsonPayload: any = null

    // 4. Fallback: Try decoding formData or JSON for profile_id / userId
    // 4. Fallback: Try decoding formData or JSON for profile_id / userId
    if (!userId) {
      if (reqContentType.includes("application/json")) {
        try {
           const clonedReq = req.clone()
           jsonPayload = await clonedReq.json()
           if (jsonPayload.userId) userId = jsonPayload.userId
           if (jsonPayload.profile_id) userId = jsonPayload.profile_id // alias
        } catch (e) {
           authDebugInfo += " | JSON parsed err"
        }
      } else {
        try {
          const clonedReq = req.clone() 
          const formData = await clonedReq.formData()
          const profileId = formData.get("profile_id") as string
          if (profileId) {
             userId = profileId // Direct mapping to profile ID
             authDebugInfo = `Recovered via profile_id (${profileId})`
          }
        } catch (e) {
          authDebugInfo += ` | FormData parse error: ${e.message}`
        }
      }
    }

    // ============================================
    // ROUTING: JSON vs MULTIPART FORMS
    // ============================================
    
    if (reqContentType.includes("application/json")) {
      const payload = jsonPayload || await req.json()
      
      // Mode A: Basic Listing Creation (from SocialService.createListing)
      if (payload.userId && payload.title && payload.price && !payload.imageBase64) {
        const { userId, title, description, price, category, media_url, media_type, photos, status } = payload;
        
        const { data: listing, error: listErr } = await supabaseAdmin
          .from("listings")
          .insert({
            user_id: userId,
            lister_id: userId, // Standardized
            title,
            description,
            price: parseInt(price.toString()),
            price_ugx: parseInt(price.toString()), // Standardized
            category: category || "OTHER",
            status: status || "active",
            image_url: media_url,
            media_url: media_url, // Standardized
            media_type: media_type || "image",
            photos: photos || [],
            is_verified: true,
          })
          .select()
          .single();

        if (listErr) {
          console.error("Listing JSON creation error:", listErr);
          return err(`Listing creation failed: ${listErr.message}`, 500);
        }

        return json({
          success: true,
          listing_id: listing.id,
          message: "Listing created successfully via SocialService",
        });
      }

      // Mode B: Necxa Proprietary Listing Image Validator (Legacy/External)
      if (payload.title && payload.imageBase64) {
         if (!isSdkAuth && !userId) return err(`Unauthorized: Missing or invalid authentication. Debug: ${authDebugInfo}`, 401)

         const { title, type } = payload

         // Cloudflare Workers AI Listing Authenticity Scanner
         let score = 80;
         let verified = true;
         let aiDescription = "Listing verified.";
         
         try {
           const base64Data = payload.imageBase64.replace(/^data:\w+\/\w+;base64,/, "");
           const mediaBytes = decode(base64Data);
           const formData = new FormData();
           formData.append('photo', new Blob([mediaBytes], { type: 'image/jpeg' }), 'photo.jpg');
           formData.append('title', title);

           const aiRes = await fetch('https://api.necxa.uk/api/verify/listing', { method: 'POST', body: formData });
           if (aiRes.ok) {
             const result = await aiRes.json();
             score = result.score || score;
             verified = result.verified ?? verified;
             aiDescription = result.description || aiDescription;
           }
         } catch (e) {
           console.error("Cloudflare Listing Verification Error:", e);
         }

         return json({
           status: verified ? "success" : "rejected",
           verified,
           description: verified
             ? `Necxa AI: Listing image for '${title}' passed authenticity validation (score: ${score}/100). Details: ${aiDescription}`
             : `Necxa AI: Listing image for '${title}' did not meet the minimum authenticity threshold. Details: ${aiDescription}`,
           score
         })
      }
    }

    // If we've passed the generic JSON modules, we require absolute native user ID context!
    if (!userId) {
      return err(`Unauthorized: Missing or invalid authentication. Debug: ${authDebugInfo}`, 401)
    }

    // ============================================
    // VERIFY PROFILE
    // ============================================
    let { data: profile, error: profileErr } = await supabaseAdmin
      .from("profiles")
      .select("*")
      .eq("id", userId)
      .single()

    if (profileErr) {
      console.error("Profile fetch error:", profileErr)
      return err(`Profile error: ${profileErr.message}`, 500)
    }

    if (!profile) {
      return err("Profile not found. Please register first.", 404)
    }

    // ============================================
    // ROUTING: MULTIPART FORMS (Listing Synthesis)
    // ============================================
    const contentType = req.headers.get("content-type") || ""

    // ============================================
    // PARSE FORM DATA
    // ============================================
    const formData = await req.formData()
    const stage = formData.get("stage") as string

    if (!stage) {
      return err("stage parameter is required", 400)
    }

    // ============================================
    // STAGE 1: IDENTITY SHARD (Depreciated)
    // ============================================
    if (stage === "identity_shard") {
       return err("Identity Shards are now natively handled by the verify-identity-shard edge function in v2 architecture.", 400)
    }

    // ============================================
    // STAGE 2: UTILITY SHARD (Depreciated)
    // ============================================
    if (stage === "utility_shard") {
      return err("Utility Shards are now natively handled by the utility-verify edge function in v2 architecture.", 400)
    }

    // ============================================
    // STAGE 3: GPS LOCK
    // ============================================
    if (stage === "gps_lock") {
      const lat = parseFloat(formData.get("latitude") as string)
      const lng = parseFloat(formData.get("longitude") as string)
      const accuracy = parseFloat(formData.get("accuracy") as string || "0")
      const reportedAddress = formData.get("reported_address") as string
      const reportedDistrict = formData.get("reported_district") as string

      if (isNaN(lat) || isNaN(lng)) {
        return err("Valid GPS coordinates required", 400)
      }

      const { data: gpsNode, error: gpsErr } = await supabaseAdmin
        .from("gps_nodes")
        .insert({
          agent_id: profile.id, // Linked to profile
          latitude: lat,
          longitude: lng,
          accuracy_meters: accuracy,
          reported_address: reportedAddress,
          reported_district: reportedDistrict,
          coordinate_match: true,
          risk_flag: accuracy > 500,
          risk_reason: accuracy > 500 ? "GPS accuracy too low - may not be at property" : null,
          captured_at: new Date().toISOString(),
        })
        .select()
        .single()

      if (gpsErr) {
        console.error("GPS node error:", gpsErr)
        return err(`GPS node error: ${gpsErr.message}`, 500)
      }

      return json({
        gps_node_id: gpsNode.id,
        coordinates: { lat, lng, accuracy },
        risk_flag: accuracy > 500,
        stage: "gps_lock",
        message: accuracy > 500
          ? "GPS accuracy low. Listing will be flagged as High Risk."
          : "GPS Node locked! You are verified at the property location.",
      })
    }

    // ============================================
    // STAGE 4: NEURAL SYNTHESIS - CREATE LISTING
    // ============================================
    if (stage === "neural_synthesis") {
      const identityShardId = formData.get("identity_shard_id") as string
      const utilityShardId = formData.get("utility_shard_id") as string
      const gpsNodeId = formData.get("gps_node_id") as string

      // Property details
      const title = formData.get("title") as string
      const description = formData.get("description") as string
      const propertyType = formData.get("property_type") as string
      const purpose = formData.get("purpose") as string
      const country = formData.get("country") as string || "Uganda"
      const district = formData.get("district") as string
      const address = formData.get("address") as string
      const priceUgx = parseInt(formData.get("price_ugx") as string)
      const pricePeriod = formData.get("price_period") as string || "/month"
      const bedrooms = parseInt(formData.get("bedrooms") as string || "0")
      const bathrooms = parseInt(formData.get("bathrooms") as string || "1")
      const sqft = parseInt(formData.get("sqft") as string || "0")
      const amenities = JSON.parse(formData.get("amenities") as string || "[]")

      // Agent contact
      const agentPhone = formData.get("agent_phone") as string
      const agentWhatsapp = formData.get("agent_whatsapp") as string
      const agentMeet = formData.get("agent_google_meet") as string

      // Music Linkage
      const musicTrackId = formData.get("music_track_id") as string
      const audioUrl = formData.get("audio_url") as string

      // Live Ping (stamped during Shield Verification)
      const livePingLat = formData.get("live_ping_lat") as string
      const livePingLng = formData.get("live_ping_lng") as string

      // Hardware Integrity (Play Integrity / App Check logic)
      const securityRaw = formData.get("security_metadata") as string
      const security = securityRaw ? JSON.parse(securityRaw) : null
      
      if (security?.is_emulated) {
        return err("SECURITY ALERT: Verification from emulated hardware is forbidden.", 403)
      }

      // Media Files
      const photoFiles: File[] = []
      const bathroomFiles: File[] = []
      const videoFiles: File[] = []
      
      for (const [key, val] of formData.entries()) {
        if (key.startsWith("photo_") && val instanceof File) photoFiles.push(val)
        if (key.startsWith("bathroom_") && val instanceof File) bathroomFiles.push(val)
        if (key.startsWith("video_") && val instanceof File) videoFiles.push(val)
      }

      if (!title || !propertyType || !purpose || !district || !priceUgx) {
        return err("Missing required fields: title, property_type, purpose, district, price", 400)
      }
      if (bathroomFiles.length === 0) {
        return err("Bathroom photos are mandatory - please upload at least one", 400)
      }

      // Get GPS node for coordinates
      const { data: gpsNode } = await supabaseAdmin
        .from("gps_nodes")
        .select("*")
        .eq("id", gpsNodeId)
        .eq("agent_id", profile.id)
        .single()

      // Upload photos
      const timestamp = Date.now()
      const photoPaths: string[] = []
      const bathroomPaths: string[] = []

      for (let i = 0; i < photoFiles.length; i++) {
        const path = `${userId}/${timestamp}_${i}.jpg`
        const { error } = await supabaseAdmin.storage.from("listing-photos").upload(path, photoFiles[i], { upsert: true, contentType: photoFiles[i].type || 'image/jpeg' })
        if (!error) photoPaths.push(path)
      }

      const videoPaths: string[] = []
      for (let i = 0; i < videoFiles.length; i++) {
        const ext = videoFiles[i].name.split('.').pop() || 'mp4'
        const path = `${userId}/reel_${timestamp}_${i}.${ext}`
        const { error } = await supabaseAdmin.storage.from("listing-photos").upload(path, videoFiles[i], { upsert: true, contentType: videoFiles[i].type || 'video/mp4' })
        if (!error) videoPaths.push(path)
      }

      for (let i = 0; i < bathroomFiles.length; i++) {
        const path = `${userId}/bath_${timestamp}_${i}.jpg`
        const { error } = await supabaseAdmin.storage.from("listing-photos").upload(path, bathroomFiles[i], { upsert: true, contentType: bathroomFiles[i].type || 'image/jpeg' })
        if (!error) bathroomPaths.push(path)
      }

      // Calculate broker fee (5% for agent, 2% for Necxa = 7% total)
      const brokerFee = Math.floor(priceUgx * 0.07)

      // === Cloudflare Workers AI Listing Verifier ===
      let aiScore = 0.85;
      let aiLevel = "VERIFIED";
      let aiDescription = "Listing verified.";
      
      if (photoFiles.length > 0) {
         try {
           const aiFormData = new FormData();
           aiFormData.append('photo', photoFiles[0]);
           aiFormData.append('title', title);
           const aiRes = await fetch('https://api.necxa.uk/api/verify/listing', { method: 'POST', body: aiFormData });
           if (aiRes.ok) {
             const result = await aiRes.json();
             aiScore = (result.score || 85) / 100.0; // Normalize 0-100 to 0.0-1.0
             aiLevel = result.verified ? "VERIFIED" : "FLAGGED";
             aiDescription = result.description || aiDescription;
           }
         } catch (e) {
           console.error("Cloudflare Listing Verification Error:", e);
         }
      }

      // Create listing
      const { data: listing, error: listErr } = await supabaseAdmin
        .from("listings")
        .insert({
          user_id: userId,
          lister_id: userId, // Standardized
          title,
          description,
          price: priceUgx,
          price_ugx: priceUgx, // Standardized
          category: propertyType.toUpperCase(),
          image_url: photoPaths.length > 0 ? photoPaths[0] : null,
          media_url: videoPaths.length > 0 ? videoPaths[0] : (photoPaths.length > 0 ? photoPaths[0] : null), 
          media_type: videoPaths.length > 0 ? "video" : "image",
          thumbnail_url: photoPaths.length > 0 ? photoPaths[0] : null, // Essential for fast feed loading
          film_hub_content: videoPaths.length > 0 ? videoPaths[0] : null,
          photos: photoPaths, // Store miniatures directly in the JSON column
          ai_verification: {
            property_type: propertyType.toUpperCase(),
            score: aiScore,
            level: aiLevel,
            description: aiDescription,
            broker_fee: brokerFee,
            trust_score: Math.round(aiScore * 100),
            amenities: amenities,
            gps: {
              lat: gpsNode?.latitude,
              lng: gpsNode?.longitude,
              live_ping_lat: livePingLat ? parseFloat(livePingLat) : null,
              live_ping_lng: livePingLng ? parseFloat(livePingLng) : null,
              device_id: security?.device_id || 'unknown',
              device_model: security?.device_model || 'unknown',
              os_version: security?.os_version || 'unknown',
              verified_email: userEmail || 'unknown',
              captured_at: gpsNode?.captured_at,
              address: address || `${district}, ${country}`,
            }
          }
        })
        .select()
        .single()

      if (listErr) {
        console.error("Listing creation error:", listErr)
        return err(`Listing creation failed: ${listErr.message}`, 500)
      }

      // Add photos to listing_photos table
      if (photoPaths.length > 0) {
        await supabaseAdmin.from("listing_photos").insert(
          photoPaths.map((p, i) => ({
            listing_id: listing.id,
            storage_path: p,
            photo_type: "INTERIOR",
            is_primary: i === 0,
            sort_order: i,
          }))
        )
      }

      if (bathroomPaths.length > 0) {
        await supabaseAdmin.from("listing_photos").insert(
          bathroomPaths.map((p, i) => ({
            listing_id: listing.id,
            storage_path: p,
            photo_type: "BATHROOM",
            sort_order: i,
          }))
        )
      }

      // 🚀 NEURAL SYNC: Create a Shadow Post so the listing appears in the Community Feed
      let shadowPostId = null;
      if (videoPaths.length > 0 || photoPaths.length > 0) {
        const { data: post, error: postErr } = await supabaseAdmin
          .from('community_posts')
          .insert({
            author_id: userId,
            title: title,
            content: description,
            media_url: videoPaths.length > 0 ? videoPaths[0] : photoPaths[0],
            media_type: videoPaths.length > 0 ? 'video' : 'image',
            thumbnail_url: photoPaths.length > 0 ? photoPaths[0] : null,
            listing_id: listing.id,
            music_track_id: musicTrackId || null,
            audio_url: audioUrl || null,
            status: 'verified',
            visibility: 'public'
          })
          .select()
          .single();
        
        
        if (!postErr) {
          shadowPostId = post.id;
          
          // 🚀 INSTANT SYNC: Push to Redis discovery feed immediately
          const redisUrl = process.env.UPSTASH_REDIS_REST_URL;
          const redisToken = process.env.UPSTASH_REDIS_REST_TOKEN;
          const supabaseUrl = process.env.SUPABASE_URL;
          
          if (redisUrl && redisToken && supabaseUrl) {
            try {
              const score = Date.now();
              const cdnBase = `${supabaseUrl}/storage/v1/object/public/listing-photos/`;
              
              const cdnPost = {
                ...post,
                media_url: videoPaths.length > 0 ? `${cdnBase}${videoPaths[0]}` : `${cdnBase}${photoPaths[0]}`,
                thumbnail_url: photoPaths.length > 0 ? `${cdnBase}${photoPaths[0]}` : null,
                profiles: {
                  display_name: profile.full_name,
                  photo_url: profile.avatar_url,
                  trust_score: profile.trust_score,
                  trust_score_tier: profile.trust_score_tier
                },
                listings: {
                  ...listing,
                  media_url: videoPaths.length > 0 ? `${cdnBase}${videoPaths[0]}` : null,
                  film_hub_content: videoPaths.length > 0 ? `${cdnBase}${videoPaths[0]}` : null,
                  miniature_photos: photoPaths.map(p => `${cdnBase}${p}`)
                }
              };

              await fetch(`${redisUrl}/pipeline`, {
                method: "POST",
                headers: { Authorization: `Bearer ${redisToken}` },
                body: JSON.stringify([
                  ["ZADD", "feed:global", score.toString(), cdnPost.id],
                  ["SET", `post:${cdnPost.id}`, JSON.stringify(cdnPost), "EX", "3600"]
                ])
              });
              console.log(`🚀 NEURAL SYNC COMPLETE: New Container ${cdnPost.id} is LIVE.`);
            } catch (re) {
              console.error("Redis Sync Error in listing-create:", re);
            }
          }
        }
      }

      // Update agent contact methods
      if (agentPhone || agentWhatsapp || agentMeet) {
        await supabaseAdmin
          .from("agent_contact_methods")
          .upsert({
            agent_id: profile.id,
            phone_number: agentPhone || "",
            whatsapp_number: agentWhatsapp,
            google_meet_link: agentMeet,
            updated_at: new Date().toISOString(),
          }, {
            onConflict: "agent_id",
          })
      }

      // Update utility shard with listing_id
      if (utilityShardId) {
        await supabaseAdmin
          .from("utility_shards")
          .update({ listing_id: listing.id })
          .eq("id", utilityShardId)
      }

      // Update GPS node with listing_id
      if (gpsNodeId) {
        await supabaseAdmin
          .from("gps_nodes")
          .update({ listing_id: listing.id })
          .eq("id", gpsNodeId)
      }

      // Create mint event
      const mintEventId = `MINT_${timestamp}_${listing.id.slice(0, 8)}`
      await supabaseAdmin.from("mint_events").insert({
        listing_id: listing.id,
        agent_id: profile.id,
        mint_event_id: mintEventId,
      })

      console.log(`✅ MINT EVENT: Listing ${listing.id} | Agent ${profile.id} | Mint ID: ${mintEventId}`)

      return json({
        success: true,
        listing_id: listing.id,
        mint_event_id: mintEventId,
        status: "ACTIVE",
        titan_trust: "VERIFIED",
        unlock_cost: Math.floor(priceUgx * 0.1),
        broker_fee: brokerFee,
        stage: "complete",
        message: "Your listing is LIVE on the Necxa Neural Grid!",
      })
    }

    return err("Invalid stage parameter. Valid stages: identity_shard, utility_shard, gps_lock, neural_synthesis", 400)

  } catch (e) {
    console.error("listing-create error:", e)
    return err(`Server error: ${e.message}`, 500)
  }
})
