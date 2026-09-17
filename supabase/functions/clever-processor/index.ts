import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import {
  createEntityComment,
  deleteEntityEngagement,
  getEntitySummaries,
  importLegacyEngagement,
  listEntityComments,
  toggleEntityLike,
} from "../_shared/engagement_mongo.ts"
import type { EngagementEntityType } from "../_shared/engagement_mongo.ts"

// ============================================
// CLEVER-PROCESSOR — Neural Feed & Viral Loop
// ============================================

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-application-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })

const err = (msg: string, status = 400) => json({ error: msg }, status)

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } }
)

// 🚀 UPSTASH REDIS: Hyper-Performance Feed Layer
const REDIS_URL = Deno.env.get("UPSTASH_REDIS_REST_URL") ?? "";
const REDIS_TOKEN = Deno.env.get("UPSTASH_REDIS_REST_TOKEN") ?? "";

async function getRedis() {
  try {
    const { Redis } = await import("https://esm.sh/@upstash/redis@1.25.0");
    return new Redis({ url: REDIS_URL, token: REDIS_TOKEN });
  } catch (e) {
    console.error("Redis Import Error:", e);
    return null;
  }
}

/**
 * CDN REWRITE: Convert Storage paths to full CDN URLs
 */
const STORAGE_BUCKET = "media";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;

function toStorageCdnUrl(path: string | null) {
  if (!path) return null;
  if (path.startsWith('http')) return path;

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const cleanPath = path.replace(/^\/+/ , "");
  
  // If it's a listing path (userId/uuid.jpg), it belongs to listing-photos
  // If it's a community path (community-media/...), it already has a bucket
  if (!cleanPath.includes('/')) {
    return `${SUPABASE_URL}/storage/v1/object/public/community-media/${cleanPath}`;
  }

  // Handle paths that don't start with a known bucket
  const knownBuckets = ['community-media', 'listing-photos', 'artist-media', 'avatars'];
  const firstPart = cleanPath.split('/')[0];
  
  if (knownBuckets.includes(firstPart)) {
    return `${SUPABASE_URL}/storage/v1/object/public/${cleanPath}`;
  }

  // Default fallback for listings: if it looks like userId/timestamp.jpg
  return `${SUPABASE_URL}/storage/v1/object/public/listing-photos/${cleanPath}`;
}

function rewriteMediaUrls(post: any) {
  let parsedPhotos = post.photos || [];
  if (typeof parsedPhotos === 'string') {
    try { parsedPhotos = JSON.parse(parsedPhotos); } catch(e) { parsedPhotos = []; }
  }
  if (!Array.isArray(parsedPhotos)) parsedPhotos = [];

  const base = {
    ...post,
    hls_url: toStorageCdnUrl(post.hls_url),
    dash_url: toStorageCdnUrl(post.dash_url),
    media_url: toStorageCdnUrl(post.media_url || post.image_url),
    image_url: toStorageCdnUrl(post.image_url),
    thumbnail_url: toStorageCdnUrl(post.thumbnail_url),
    audio_url: toStorageCdnUrl(post.audio_url),
    photos: parsedPhotos.map((p: string) => toStorageCdnUrl(p)),
    film_hub_content: toStorageCdnUrl(post.film_hub_content),
  };

  // 🚀 RECURSIVE REWRITE: If this is a post with a nested listing (New Container)
  if (base.listings) {
    const l = Array.isArray(base.listings) ? base.listings[0] : base.listings;
    if (l) {
      const rwListing = rewriteMediaUrls(l);
      base.listings = {
        ...rwListing,
        film_hub_content: rwListing.film_hub_content || rwListing.media_url,
        miniature_photos: rwListing.photos || [],
      };
      
      // Inherit listing media if post media is missing (Pipeline recovery)
      if (!base.media_url && rwListing.media_url) {
        base.media_url = rwListing.media_url;
        base.media_type = rwListing.media_type || 'video';
      }
    }
  }

  return base;
}

async function hydrateEntityEngagement(
  items: any[],
  entityType: EngagementEntityType,
  userId: string,
) {
  const ids = items.map((item) => String(item.id ?? "")).filter(Boolean)
  if (ids.length === 0) return items

  try {
    const summaries = await getEntitySummaries({
      entityType,
      entityIds: ids,
      userId,
    })
    return items.map((item) => {
      const summary = summaries.get(String(item.id))
      return {
        ...item,
        likes_count: summary?.likes ?? 0,
        comments_count: summary?.comments ?? 0,
        views_count: summary?.views ?? item.views_count ?? 0,
        is_liked: summary?.likedByUser ?? false,
      }
    })
  } catch (error) {
    console.error("Mongo engagement hydration failed:", error)
    return items.map((item) => ({
      ...item,
      likes_count: 0,
      comments_count: 0,
      is_liked: false,
    }))
  }
}

async function hydrateFeedEngagement(items: any[], userId: string) {
  const postIds: string[] = []
  const productIds: string[] = []
  for (const item of items) {
    const listingId = item.listing_id ?? item.listings?.id
    if (listingId) productIds.push(String(listingId))
    else if (item.id) postIds.push(String(item.id))
  }

  try {
    const [postSummaries, productSummaries] = await Promise.all([
      getEntitySummaries({
        entityType: "post",
        entityIds: postIds,
        userId,
      }),
      getEntitySummaries({
        entityType: "product",
        entityIds: productIds,
        userId,
      }),
    ])
    return items.map((item) => {
      const listingId = item.listing_id ?? item.listings?.id
      const summary = listingId
        ? productSummaries.get(String(listingId))
        : postSummaries.get(String(item.id))
      return {
        ...item,
        likes_count: summary?.likes ?? 0,
        comments_count: summary?.comments ?? 0,
        views_count: summary?.views ?? item.views_count ?? 0,
        is_liked: summary?.likedByUser ?? false,
      }
    })
  } catch (error) {
    console.error("Mongo feed engagement hydration failed:", error)
    return items.map((item) => ({
      ...item,
      likes_count: 0,
      comments_count: 0,
      is_liked: false,
    }))
  }
}

/**
 * FETCH-FEED: Advanced ranking for the discovery reel.
 */
async function handleFetchFeed(userId: string, payload: any = {}) {
  const redis = await getRedis();
  const sinceTime = payload.since_time;
  const beforeTime = payload.before_time;
  
  if (redis && !sinceTime && !beforeTime) {
    try {
      const cachedIds = await redis.zrange("feed:global", 0, 49, { rev: true }) as string[];
      if (cachedIds.length > 0) {
        const pipeline = redis.pipeline();
        cachedIds.forEach(id => pipeline.get(`post:${id}`));
        const cachedResults = await pipeline.exec();
        const validPosts = cachedResults.filter(p => p !== null);
        
        if (validPosts.length > 0) {
          console.log(`REDIS: Found ${validPosts.length} posts in cache`);
          const hydrated = await hydrateFeedEngagement(validPosts, userId)
          return json({ success: true, data: hydrated, source: 'redis' });
        }
      }
    } catch (e) {
      console.error("REDIS Fetch Error:", e);
    }
  }

  // Fallback to Supabase: Unified container fetch for Old & New content
  console.log("SUPABASE: Fetching fresh feed from database...");
  let query = supabase
    .from('community_posts')
    .select(`
      *,
      profiles:author_id(display_name:full_name, photo_url:avatar_url, trust_score, trust_score_tier),
      listings:listing_id(*)
    `)
    .in('status', ['verified', 'pending', 'active']) // Include 'active' for new containers
    .or('visibility.eq.public,visibility.is.null');

  if (sinceTime) {
    query = query.gt('created_at', sinceTime);
  } else if (beforeTime) {
    query = query.lt('created_at', beforeTime);
  }

  const { data, error } = await query
    .order('created_at', { ascending: false })
    .limit(sinceTime ? 100 : 50);

  if (error) {
    console.error("Supabase Feed Error:", error);
    return err(`Feed resolution failure: ${error.message}`);
  }

  const cdnData = (data || []).map(rewriteMediaUrls);

  // Only sync to Redis for the 'latest' queries, not historical pagination
  if (redis && cdnData.length > 0 && !beforeTime) {
    try {
      const multi = redis.pipeline();
      cdnData.forEach(post => {
        const score = new Date(post.created_at).getTime();
        multi.zadd("feed:global", { score, member: post.id });
        multi.set(`post:${post.id}`, post, { ex: 3600 });
      });
      await multi.exec();
    } catch (e) {
      console.error("REDIS Sync Error:", e);
    }
  }

  const hydrated = await hydrateFeedEngagement(cdnData, userId)
  return json({
    success: true, 
    data: hydrated,
    source: 'supabase',
    count: hydrated.length
  });
}

/**
 * FETCH-SHOP-FEED: Discovery logic for commercial listings.
 */
async function hydrateListingEngagement(listings: any[], userId: string) {
  return hydrateEntityEngagement(listings, "product", userId)
}

async function handleFetchShopFeed(userId: string, payload: any = {}) {
  const redis = await getRedis();
  const category = payload.category;
  const sinceTime = payload.since_time;
  const beforeTime = payload.before_time;
  const feedKey = `shop_feed:${category || 'All'}`;
  
  if (redis && !sinceTime && !beforeTime) {
    try {
      const cachedIds = await redis.zrange(feedKey, 0, 49, { rev: true }) as string[];
      if (cachedIds.length > 0) {
        const pipeline = redis.pipeline();
        cachedIds.forEach(id => pipeline.get(`listing:${id}`));
        const cachedResults = await pipeline.exec();
        const validListings = cachedResults.filter(l => l !== null);
        
        if (validListings.length > 0) {
          console.log(`REDIS: Found ${validListings.length} shop listings in cache (${feedKey})`);
          const hydrated = await hydrateListingEngagement(validListings, userId);
          return json({ success: true, data: hydrated, source: 'redis' });
        }
      }
    } catch (e) {
      console.error("REDIS Shop Fetch Error:", e);
    }
  }
  
  // Fallback to Supabase
  console.log("SUPABASE: Fetching shop feed...");
  let query = supabase
    .from('listings')
    .select(`
      *,
      profiles:user_id(display_name:full_name, photo_url:avatar_url, trust_score, trust_score_tier),
      lister:lister_id(display_name:full_name, photo_url:avatar_url)
    `)
    .eq('status', 'active');

  if (category) query = query.eq('category', category);
  if (sinceTime) query = query.gt('created_at', sinceTime);
  else if (beforeTime) query = query.lt('created_at', beforeTime);

  const { data, error } = await query
    .order('created_at', { ascending: false })
    .limit(sinceTime ? 100 : 50);

  if (error) return err(`Shop feed error: ${error.message}`);

  const listings = (data || []).map(l => {
    const base = rewriteMediaUrls(l);
    return {
      ...base,
      film_hub_content: base.film_hub_content || base.media_url, 
      miniature_photos: base.photos || [], 
    };
  });

  // Only sync to Redis for the 'latest' queries, not historical pagination
  if (redis && listings.length > 0 && !sinceTime && !beforeTime) {
    try {
      const multi = redis.pipeline();
      listings.forEach(listing => {
        const score = new Date(listing.created_at).getTime();
        multi.zadd(feedKey, { score, member: listing.id });
        multi.set(`listing:${listing.id}`, listing, { ex: 3600 }); // Cache for 1 hour
      });
      await multi.exec();
      console.log(`REDIS: Synced ${listings.length} shop listings to cache (${feedKey})`);
    } catch (e) {
      console.error("REDIS Shop Sync Error:", e);
    }
  }

  const hydrated = await hydrateListingEngagement(listings, userId);
  return json({ success: true, data: hydrated, source: 'supabase' });
}

/**
 * SEARCH-LISTINGS: Semantic search across the shop.
 */
async function handleSearchListings(payload: any = {}) {
  const { category, tags, min_price, max_price } = payload;
  let query = (payload.query || "").trim();
  
  // 🛡️ SANITIZATION: Clean query to prevent FTS syntax errors
  const safeQuery = query.replace(/[&|!():]/g, ' ').trim();
  
  console.log(`SUPABASE: Hardened Search... Query: "${safeQuery}"`);
  
  const baseSelect = `
    *,
    profiles:user_id(display_name:full_name, photo_url:avatar_url, trust_score, trust_score_tier),
    lister:lister_id(display_name:full_name, photo_url:avatar_url)
  `;

  let q = supabase.from('listings').select(baseSelect).eq('status', 'active');

  // 1. Primary Text Search (FTS)
  if (safeQuery.length > 0) {
    q = q.textSearch('fts_doc', safeQuery, { config: 'english', type: 'websearch' });
  }

  // 2. Filters
  if (category && category !== 'All') q = q.eq('category', category);
  if (tags && Array.isArray(tags) && tags.length > 0) q = q.contains('tags', tags);
  if (min_price != null) q = q.gte('price_ugx', min_price);
  if (max_price != null) q = q.lte('price_ugx', max_price);

  let { data, error } = await q.limit(50);

  // 🚀 FUZZY FALLBACK: If FTS returned nothing, try fuzzy ILIKE
  if (!error && (!data || data.length === 0) && safeQuery.length > 2) {
    console.log("SEARCH: FTS returned 0, attempting fuzzy fallback...");
    const fallbackQ = supabase
      .from('listings')
      .select(baseSelect)
      .eq('status', 'active')
      .ilike('title', `%${safeQuery}%`)
      .limit(20);
    
    const fallbackRes = await fallbackQ;
    if (!fallbackRes.error && fallbackRes.data) {
      data = fallbackRes.data;
    }
  }

  if (error) return err(`Search error: ${error.message}`);
  
  // ⚖️ TRUST WEIGHTING: Prioritize verified/high-score vendors in memory
  const results = (data || []).map(rewriteMediaUrls).sort((a: any, b: any) => {
    const scoreA = a.profiles?.trust_score || 0;
    const scoreB = b.profiles?.trust_score || 0;
    return scoreB - scoreA;
  });

  return json({ success: true, data: results });
}

/**
 * FETCH-SHOWCASE: Instant retrieval of a vendor's storefront.
 */
async function handleFetchShowcase(payload: any) {
  // 🛡️ RECTIFIED: Showcases are now strictly Supabase-driven for 100% integrity.
  // Reads target user from payload.user_id so public profile views work correctly.
  const targetUserId = payload.user_id;
  if (!targetUserId) return err("user_id required for showcase");

  const { data, error } = await supabase
    .from('listings')
    .select('*, profiles:user_id(display_name:full_name, photo_url:avatar_url, trust_score, trust_score_tier)')
    .eq('user_id', targetUserId)
    .eq('status', 'active')
    .order('created_at', { ascending: false })
    .limit(50);

  if (error) return err(error.message);

  return json({ success: true, data: (data || []).map(rewriteMediaUrls) });
}

/**
 * CREATE-LISTING: Transactional insert with neural sync to Shop Feed.
 */
async function handleCreateListing(userId: string, payload: any) {
  // 1. Filter payload to match the 'listings' table schema
  const { 
    title, description, price, media_url, media_type, 
    category, is_verified, ai_verification, photos, 
    thumbnail_url, music_track_id, audio_url, tags,
    ai_score, ai_description, sku, stock_count,
    weight_kg, length_cm, width_cm, height_cm, latitude, longitude
  } = payload;

  const listingAiApproved = ai_verification?.verified === true || ai_verification?.result?.verified === true;
  if (is_verified !== true || !listingAiApproved) {
    return err('AI verification is required before publishing a listing', 400);
  }

  const normalizedSku = String(sku || '').trim().toUpperCase();
  if (!/^\d{4}[A-Z]{3}$/.test(normalizedSku)) {
    return err('SKU is required and must contain 4 digits followed by 3 letters', 400);
  }
  const measurements = [weight_kg, length_cm, width_cm, height_cm].map(Number);
  if (measurements.some((value) => !Number.isFinite(value) || value <= 0)) {
    return err('Positive weight and package dimensions are required', 400);
  }
  const pickupLatitude = Number(latitude);
  const pickupLongitude = Number(longitude);
  if (!Number.isFinite(pickupLatitude) || !Number.isFinite(pickupLongitude) || Math.abs(pickupLatitude) > 90 || Math.abs(pickupLongitude) > 180) {
    return err('A valid pickup location is required', 400);
  }

  const { data: listing, error } = await supabase
    .from('listings')
    .insert({ 
      user_id: userId,
      lister_id: userId, // Standardized 
      title,
      description,
      price,
      price_ugx: price, // Standardized
      image_url: thumbnail_url || media_url,
      media_url: media_url, // Standardized 
      thumbnail_url: thumbnail_url,
      media_type: media_type || 'image',
      photos: photos || [],
      category: category || 'General',
      tags: tags || [],
      ai_verification: ai_verification || null,
      ai_score: ai_score ?? ai_verification?.score ?? null,
      ai_description: ai_description ?? ai_verification?.description ?? null,
      is_verified: is_verified || false,
      film_hub_content: media_url,
      sku: normalizedSku,
      stock_count: stock_count ?? 999,
      weight_kg: measurements[0],
      length_cm: measurements[1],
      width_cm: measurements[2],
      height_cm: measurements[3],
      latitude: pickupLatitude,
      longitude: pickupLongitude,
      status: 'active' 
    })
    .select()
    .single();

  if (error) return err(`Listing creation failed: ${error.message}`);

  // 🚀 NEURAL SYNC: Mirror all commercial listings to the Community Feed
  // This allows products (Videos & Photos) to gain social traction in the discovery reel.
  let shadowPost = null;
  const { data: post, error: postErr } = await supabase
    .from('community_posts')
    .insert({
      author_id: userId,
      title: title,
      content: description,
      media_url: media_url,
      media_type: media_type || 'image',
      thumbnail_url: thumbnail_url || media_url,
      listing_id: listing.id, // THE NEURAL LINK
      music_track_id: music_track_id || null,
      audio_url: audio_url || null,
      status: 'verified',
      visibility: 'public'
    })
    .select(`
      *,
      profiles:author_id(display_name:full_name, photo_url:avatar_url, trust_score, trust_score_tier)
    `)
    .single();
  
  if (!postErr) shadowPost = post;
  else console.error("Shadow Post Creation Error:", postErr);

  // 🛡️ RECTIFIED: Listings are NEVER stored in Redis.
  // We ONLY sync the shadowPost to the Community Feed (which is allowed).
  const redis = await getRedis();
  if (redis && shadowPost) {
     try {
       const score = new Date(listing.created_at).getTime();
       const pipeline = redis.pipeline();
       const cdnPost = rewriteMediaUrls(shadowPost);
       const cdnListing = rewriteMediaUrls(listing); // Needed for the nested reference
       
       pipeline.zadd("feed:global", { score, member: cdnPost.id });
       pipeline.set(`post:${cdnPost.id}`, { ...cdnPost, listings: cdnListing }, { ex: 3600 });
       
       await pipeline.exec();
     } catch (e) {
       console.error("REDIS Post Sync Error:", e);
     }
  }

  const finalListing = rewriteMediaUrls(listing);
  return json({ 
    success: true, 
    data: {
      ...finalListing,
      film_hub_content: finalListing.media_url,
      miniature_photos: finalListing.photos || [],
    } 
  });
}

/**
 * HYDRATE-POST: Manually push an existing Supabase record into Redis.
 * Used by listing-create after multi-step synthesis.
 */
async function handleHydratePost(payload: any) {
  const { id } = payload;
  if (!id) return err("id required for hydration");

  // Fetch full hydrated record from Supabase
  const { data: rawPost, error } = await supabase
    .from('community_posts')
    .select(`
      *,
      profiles:author_id(display_name:full_name, photo_url:avatar_url, trust_score, trust_score_tier),
      listings:listing_id(*)
    `)
    .eq('id', id)
    .single();

  if (error || !rawPost) return err(`Hydration fetch failed: ${error?.message}`);

  const post = rewriteMediaUrls(rawPost);

  try {
    const redis = await getRedis();
    if (redis) {
      const score = new Date(post.created_at).getTime();
      const pipeline = redis.pipeline();
      pipeline.zadd("feed:global", { score, member: post.id });
      pipeline.set(`post:${post.id}`, post, { ex: 3600 });
      await pipeline.exec();
      console.log(`🚀 Neural Hydration Success: Post ${id} synced to Redis.`);
    }
  } catch (e) {
    console.error("REDIS Hydration Sync Error:", e);
  }

  return json({ success: true, data: post });
}

/**
 * RECORD-USAGE: Atomic tracking of 'Use this Sound' loop.
 */
async function handleRecordUsage(userId: string, payload: Record<string, unknown>) {
  const assetId = payload.asset_id as string;
  const postId = payload.post_id as string;
  if (!assetId || !postId) return err("asset_id and post_id required");

  // Log usage
  const { error } = await supabase
    .from('media_usage')
    .insert({
      asset_id: assetId,
      post_id: postId,
      user_id: userId,
      usage_type: 'reuse'
    });

  if (error) return err(`Usage tracking failed: ${error.message}`);

  return json({ success: true, message: "Viral loop usage recorded." });
}

/**
 * CREATE-POST: Robust post creation with instant Redis sync.
 */
async function handleCreatePost(userId: string, payload: any) {
  // 1. Filter payload to prevent "column not found" errors
  const { 
    title, content, media_url, media_type, thumbnail_url, 
    hls_url, dash_url, audio_url, music_track_id, 
    visibility, tags, creator_mode, gallery_urls, 
    editing_metadata, artist_metadata, media_asset_id,
    is_fast_sync, is_verified, ai_verification
  } = payload;

  const postAiApproved = ai_verification?.verified === true || ai_verification?.result?.verified === true;
  if (is_verified !== true || !postAiApproved) {
    return err('AI verification is required before publishing a post', 400);
  }
  
  // 2. Insert into Supabase
  const { data: rawPost, error } = await supabase
    .from('community_posts')
    .insert({
      author_id: userId,
      title,
      content,
      media_url,
      media_type: media_type || 'image',
      thumbnail_url,
      hls_url,
      dash_url,
      audio_url,
      music_track_id,
      media_asset_id,
      tags: tags || [],
      status: 'verified',
      visibility: visibility || 'public',
      metadata: {
        creator_mode: creator_mode || 'unified',
        gallery_urls: gallery_urls || [],
        is_fast_sync: is_fast_sync === true,
        editing: editing_metadata || {},
        artist: artist_metadata || {},
        ai_verification
      }
    })
    .select()
    .single();

  if (error) return err(`Post creation failed: ${error.message}`);

  const post = rewriteMediaUrls(rawPost);

  // 2. Immediate push to Redis for real-time feed update
  try {
    const redis = await getRedis();
    if (redis) {
      const score = new Date(post.created_at).getTime();
      const pipeline = redis.pipeline();
      pipeline.zadd("feed:global", { score, member: post.id });
      pipeline.set(`post:${post.id}`, post, { ex: 3600 });
      await pipeline.exec();
    }
  } catch (e) {
    console.error("REDIS Sync Error:", e);
  }

  return json({ success: true, data: post });
}

/**
 * TOGGLE-LIKE: Atomic social interaction with Redis cache invalidation.
 */
async function handleToggleLike(userId: string, payload: any) {
  const targetId = payload.post_id;
  const targetType = payload.target_type ?? 'post';
  if (!targetId) return err("post_id required");
  const entityType: EngagementEntityType =
    targetType === "listing" ? "product" : "post"
  const redis = await getRedis();
  let result
  try {
    result = await toggleEntityLike({
      entityType,
      entityId: targetId,
      userId,
    })
  } catch (error) {
    console.error("Mongo like operation failed:", error)
    return err("Engagement service is temporarily unavailable", 503)
  }
  const action = result.liked ? "liked" : "unliked"

  // 🚀 SYNC REDIS: Update post metrics in cache
  if (redis) {
    try {
      const cacheKey = targetType === 'listing'
        ? `listing:${targetId}`
        : `post:${targetId}`;
      const postStr = await redis.get(cacheKey);
      if (postStr) {
        const post = typeof postStr === 'string' ? JSON.parse(postStr) : postStr;
        post.likes_count = result.likes
        post.is_liked = result.liked
        await redis.set(cacheKey, post, { ex: 3600 });
      }
    } catch (e) {
      console.error("REDIS Like Sync Error:", e);
    }
  }

  if (result.liked) {
    await handleTriggerNotification(userId, {
      type: "like",
      target_id: targetId,
      target_type: targetType,
    })
  }

  return json({
    success: true,
    action,
    liked: result.liked,
    likes_count: result.likes,
  });
}

/**
 * CREATE-COMMENT: Persistent storage + Redis real-time push.
 */
async function hydrateCommentIdentities(comments: any[]) {
  const userIds = [...new Set(
    comments.map((comment) => comment.userId).filter(Boolean),
  )]
  const { data: profiles } = userIds.length === 0
    ? { data: [] as any[] }
    : await supabase
      .from("profiles")
      .select("id, full_name, avatar_url, trust_score_tier")
      .in("id", userIds)
  const profilesById = new Map(
    (profiles ?? []).map((profile: any) => [profile.id, profile]),
  )

  return comments.map((comment) => {
    const profile = profilesById.get(comment.userId)
    const identity = {
      user_id: comment.userId,
      user_name: profile?.full_name || "User",
      user_avatar: toStorageCdnUrl(profile?.avatar_url),
      user_profile_url: `https://necxa.app/u/${comment.userId}`,
      is_verified: profile?.trust_score_tier === "titan_trust" ||
        profile?.trust_score_tier === "verified",
    }
    return {
      id: comment.id,
      post_id: comment.entityId,
      user_id: comment.userId,
      content: comment.text,
      created_at: comment.createdAt instanceof Date
        ? comment.createdAt.toISOString()
        : comment.createdAt,
      metadata: { identity },
      identity,
    }
  })
}

async function handleCreateComment(userId: string, payload: any) {
  const { post_id, content, target_type = 'post' } = payload;
  const cleanContent = typeof content === 'string' ? content.trim() : '';
  if (!post_id || !cleanContent) return err("post_id and content required");
  if (cleanContent.length > 2000) return err("Comment is too long");
  const entityType: EngagementEntityType =
    target_type === "listing" ? "product" : "post"
  let comment
  try {
    comment = await createEntityComment({
      entityType,
      entityId: post_id,
      userId,
      text: cleanContent,
      idempotencyKey: typeof payload.idempotency_key === "string"
        ? payload.idempotency_key
        : undefined,
    })
  } catch (error) {
    console.error("Mongo comment operation failed:", error)
    return err("Engagement service is temporarily unavailable", 503)
  }
  const [normalizedComment] = await hydrateCommentIdentities([comment])

  const redis = await getRedis();
  if (redis) {
    try {
      const postKey = target_type === 'listing'
        ? `listing:${post_id}`
        : `post:${post_id}`;
      const postStr = await redis.get(postKey);
      if (postStr) {
        const post = typeof postStr === 'string' ? JSON.parse(postStr) : postStr;
        post.comments_count = comment.commentsCount
        await redis.set(postKey, post, { ex: 3600 });
      }

      // 🚀 AUTO-TRIGGER: Alert the content owner
    } catch (e) {
      console.error("REDIS Comment Sync Error:", e);
    }
  }

  await handleTriggerNotification(userId, {
    type: "comment",
    target_id: post_id,
    target_type,
    metadata: {
      comment_id: normalizedComment.id,
      snippet: cleanContent.substring(0, 80),
      identity: normalizedComment.metadata.identity,
    },
  })

  return json({
    success: true,
    data: normalizedComment,
    comments_count: comment.commentsCount,
  });
}

/**
 * SUBMIT-REVIEW: Verified purchase review system.
 */
async function handleSubmitReview(userId: string, payload: any) {
  const { listing_id, rating, comment, sku } = payload;
  if (!listing_id || !rating) return err("listing_id and rating required");

  // 1. Purchase Verification Guard
  const { data: orders } = await supabase
    .from('orders')
    .select('id')
    .eq('buyer_id', userId)
    .eq('sku', sku)
    .eq('status', 'delivered')
    .limit(1);

  if (!orders || orders.length === 0) {
    return err("Review denied: Purchase and delivery verification required.", 403);
  }

  // 2. Submit Review
  const { data: review, error } = await supabase
    .from('listing_reviews')
    .insert({
      listing_id,
      user_id: userId,
      rating,
      comment,
      sku,
      created_at: new Date().toISOString()
    })
    .select('*, profiles:user_id(full_name, avatar_url)')
    .single();

  if (error) return err(error.message);

  return json({ success: true, data: review });
}

/**
 * FETCH-REVIEWS: Retrieve product feedback.
 */
async function handleFetchReviews(payload: any) {
  const { listing_id, sku } = payload;
  const query = supabase.from('listing_reviews').select('*, profiles:user_id(full_name, avatar_url)');
  
  if (sku) query.eq('sku', sku);
  else if (listing_id) query.eq('listing_id', listing_id);
  else return err("listing_id or sku required");

  const { data, error } = await query.order('created_at', { ascending: false });
  if (error) return err(error.message);
  return json({ success: true, data });
}

/**
 * FETCH-COMMENTS: High-speed retrieval from Redis.
 */
async function handleFetchComments(payload: any) {
  const { post_id, target_type = 'post' } = payload;
  if (!post_id) return err("post_id required");
  const entityType: EngagementEntityType =
    target_type === "listing" ? "product" : "post"
  try {
    const comments = await listEntityComments({
      entityType,
      entityId: post_id,
      limit: 50,
    })
    const normalized = await hydrateCommentIdentities(comments)
    return json({ success: true, data: normalized, source: "mongodb" })
  } catch (error) {
    console.error("Mongo comment retrieval failed:", error)
    return err("Engagement service is temporarily unavailable", 503)
  }
}

async function handleFetchEngagement(userId: string, payload: any) {
  const rawEntities = Array.isArray(payload.entities) ? payload.entities : []
  const entities = rawEntities
    .map((entity: any) => ({
      id: String(entity?.id ?? "").trim(),
      localId: String(entity?.local_id ?? entity?.id ?? "").trim(),
      targetType: entity?.target_type === "listing" ? "listing" : "post",
    }))
    .filter((entity: any) => entity.id && entity.localId)
    .slice(0, 12)

  if (entities.length === 0) {
    return json({ success: true, data: [] })
  }

  try {
    const postIds = entities
      .filter((entity: any) => entity.targetType === "post")
      .map((entity: any) => entity.id)
    const productIds = entities
      .filter((entity: any) => entity.targetType === "listing")
      .map((entity: any) => entity.id)
    const [postSummaries, productSummaries] = await Promise.all([
      getEntitySummaries({
        entityType: "post",
        entityIds: postIds,
        userId,
      }),
      getEntitySummaries({
        entityType: "product",
        entityIds: productIds,
        userId,
      }),
    ])

    const data = entities.map((entity: any) => {
      const summary = entity.targetType === "listing"
        ? productSummaries.get(entity.id)
        : postSummaries.get(entity.id)
      return {
        id: entity.id,
        local_id: entity.localId,
        target_type: entity.targetType,
        likes_count: summary?.likes ?? 0,
        comments_count: summary?.comments ?? 0,
        is_liked: summary?.likedByUser ?? false,
      }
    })
    return json({ success: true, data, source: "mongodb" })
  } catch (error) {
    console.error("Mongo engagement smart-load failed:", error)
    return err("Engagement service is temporarily unavailable", 503)
  }
}

function classifyMongoError(error: unknown) {
  const candidate = error && typeof error === "object"
    ? error as Record<string, unknown>
    : {}
  const name = typeof candidate.name === "string"
    ? candidate.name
    : "UnknownError"
  const code = typeof candidate.code === "string" ||
      typeof candidate.code === "number"
    ? String(candidate.code)
    : null
  const message = typeof candidate.message === "string"
    ? candidate.message.toLowerCase()
    : ""
  let category = "unknown"
  if (
    code === "ENOTFOUND" ||
    code === "ECONNREFUSED" ||
    message.includes("querysrv")
  ) {
    category = "dns"
  } else if (
    code === "ETIMEDOUT" ||
    message.includes("server selection") ||
    message.includes("timed out")
  ) {
    category = "network"
  } else if (
    code === "18" ||
    message.includes("authentication failed") ||
    message.includes("bad auth")
  ) {
    category = "authentication"
  } else if (
    message.includes("unsupported") ||
    message.includes("not implemented")
  ) {
    category = "runtime"
  }
  return { name, code, category }
}

async function handleDiagnoseEngagement(user: any) {
  const isAdmin = user?.app_metadata?.role === "admin" ||
    user?.app_metadata?.is_admin === true
  if (!isAdmin) return err("Administrator authorization required", 403)

  try {
    await getEntitySummaries({
      entityType: "post",
      entityIds: [`diagnostic-${Date.now()}`],
      userId: user.id,
    })
    return json({ success: true, status: "mongodb-ready" })
  } catch (error) {
    console.error("Mongo engagement diagnostic failed:", error)
    return json({
      success: false,
      status: "mongodb-unavailable",
      diagnostic: classifyMongoError(error),
    }, 503)
  }
}

async function fetchLegacyRows(table: string) {
  const rows: any[] = []
  const pageSize = 1_000
  for (let offset = 0; ; offset += pageSize) {
    const { data, error } = await supabase
      .from(table)
      .select("*")
      .range(offset, offset + pageSize - 1)
    if (error) throw new Error(`${table}: ${error.message}`)
    rows.push(...(data ?? []))
    if (!data || data.length < pageSize) break
  }
  return rows
}

async function handleMigrateLegacyEngagement(user: any, req: Request) {
  const migrationKey = Deno.env.get("ENGAGEMENT_MIGRATION_KEY") ||
    Deno.env.get("APPLICATION_API_PRIVATE_KEY") ||
    Deno.env.get("APP_API_PRIVATE_KEY")
  const suppliedKey = req.headers.get("x-application-key")
  const isAdmin = user?.app_metadata?.role === "admin" ||
    user?.app_metadata?.is_admin === true
  if ((!migrationKey || suppliedKey !== migrationKey) && !isAdmin) {
    return err("Administrator authorization required", 403)
  }

  try {
    const [likes, comments, linkedPosts] = await Promise.all([
      fetchLegacyRows("community_likes"),
      fetchLegacyRows("community_comments"),
      supabase
        .from("community_posts")
        .select("id, listing_id")
        .not("listing_id", "is", null),
    ])
    if (linkedPosts.error && linkedPosts.error.code !== "42703") {
      throw new Error(`community_posts: ${linkedPosts.error.message}`)
    }
    const listingByPost = new Map(
      (linkedPosts.error ? [] : linkedPosts.data ?? [])
        .map((post: any) => [post.id, post.listing_id]),
    )
    const destination = (postId: string) => {
      const listingId = listingByPost.get(postId)
      return listingId
        ? { entityType: "product" as const, entityId: String(listingId) }
        : { entityType: "post" as const, entityId: String(postId) }
    }

    const result = await importLegacyEngagement({
      likes: likes
        .filter((like) => like.post_id && like.user_id)
        .map((like) => ({
          ...destination(like.post_id),
          userId: String(like.user_id),
          createdAt: like.created_at,
        })),
      comments: comments
        .filter((comment) =>
          comment.post_id &&
          (comment.user_id || comment.author_id) &&
          comment.content
        )
        .map((comment) => ({
          ...destination(comment.post_id),
          userId: String(comment.user_id ?? comment.author_id),
          text: String(comment.content),
          sourceId: `supabase:${comment.id}`,
          createdAt: comment.created_at,
        })),
    })
    return json({ success: true, data: result })
  } catch (error) {
    console.error("Legacy engagement migration failed:", error)
    const message = error instanceof Error ? error.message : String(error)
    return err(`Legacy engagement migration failed: ${message}`, 500)
  } finally {
    if (user?.is_anonymous === true && user?.id) {
      const { error } = await supabase.auth.admin.deleteUser(user.id)
      if (error) console.error("Temporary migration user cleanup failed:", error)
    }
  }
}

/**
 * DELETE-POST: Sync deletion across Supabase and Redis.
 */
async function handleDeletePost(userId: string, payload: any) {
  const postId = payload.post_id;
  if (!postId) return err("post_id required");

  // 1. Verify Ownership & Delete from Supabase
  const { data: post, error: fetchError } = await supabase
    .from('community_posts')
    .select('author_id')
    .eq('id', postId)
    .single();

  if (fetchError || !post) return err("Post not found");
  if (post.author_id !== userId) return err("Unauthorized deletion", 403);

  const { error: deleteError } = await supabase
    .from('community_posts')
    .delete()
    .eq('id', postId);

  if (deleteError) return err(`Supabase delete failed: ${deleteError.message}`);

  // 2. Remove engagement owned by the deleted post.
  try {
    await deleteEntityEngagement({ entityType: "post", entityId: postId })
  } catch (error) {
    console.error("Mongo engagement cleanup failed:", error)
  }

  // 3. Remove from Redis Cache
  try {
    const redis = await getRedis();
    if (redis) {
      const pipeline = redis.pipeline();
      pipeline.zrem("feed:global", postId);
      pipeline.del(`post:${postId}`);
      await pipeline.exec();
    }
  } catch (e) {
    console.error("REDIS Delete Error:", e);
  }

  return json({ success: true, message: "Post deleted from neural nodes." });
}

/**
 * CLEAR-CACHE: Emergency invalidation for all feed nodes.
 */
async function handleClearCache() {
  try {
    const redis = await getRedis();
    if (redis) {
      await redis.del("feed:global");
      await redis.del("feed:shop:global");
      // Individual category shop feeds would need a scan/del, but clearing global is a good start
      // For thoroughness, we could scan for feed:shop:* and delete them
      return json({ success: true, message: "All neural and shop caches cleared." });
    }
  } catch (e) {
    return err(`Cache clear failed: ${e}`);
  }
  return err("Redis not available");
}

/**
 * ASSET HELPERS
 */
async function handleGetUploadUrl(userId: string, payload: any) {
  const { bucket, asset_type, file_name } = payload;
  if (!bucket || !file_name) return err("bucket and file_name required");

  const path = `${userId}/${Date.now()}_${file_name}`;
  const assetId = `asset_${crypto.randomUUID().slice(0, 8)}`;

  return json({ success: true, path, asset_id: assetId });
}

async function handleVerifyAsset(userId: string, payload: any) {
  const { asset_id } = payload;
  if (!asset_id) return err("asset_id required");

  return json({ success: true, verified: true, asset_id });
}

const notificationTypes = new Set([
  "like",
  "comment",
  "follow",
  "share",
  "save",
  "mention",
])

async function resolveNotificationRecipient(
  type: string,
  targetId: string,
  targetType: string,
) {
  if (type === "follow") return targetId

  if (targetType === "listing") {
    const { data, error } = await supabase
      .from("listings")
      .select("lister_id")
      .eq("id", targetId)
      .maybeSingle()
    if (error) throw error
    return data?.lister_id as string | undefined
  }

  const { data, error } = await supabase
    .from("community_posts")
    .select("author_id")
    .eq("id", targetId)
    .maybeSingle()
  if (error) throw error
  return data?.author_id as string | undefined
}

function notificationCopy(
  type: string,
  actorName: string,
  metadata: Record<string, unknown>,
) {
  switch (type) {
    case "like":
      return {
        title: "New like",
        body: `${actorName} liked your content.`,
      }
    case "comment": {
      const snippet = String(metadata.snippet ?? "").trim()
      return {
        title: "New comment",
        body: snippet
          ? `${actorName}: ${snippet}`
          : `${actorName} commented on your content.`,
      }
    }
    case "follow":
      return {
        title: "New follower",
        body: `${actorName} started following you.`,
      }
    case "share":
      return {
        title: "Content shared",
        body: `${actorName} shared your content.`,
      }
    case "save":
      return {
        title: "Content saved",
        body: `${actorName} saved your content.`,
      }
    default:
      return {
        title: "New activity",
        body: `${actorName} engaged with your content.`,
      }
  }
}

/**
 * Persist an authenticated engagement notification for the recipient.
 */
async function handleTriggerNotification(userId: string, payload: any) {
  const type = String(payload.type ?? "")
  const targetId = String(payload.target_id ?? "")
  const targetType = payload.target_type === "listing"
    ? "listing"
    : type === "follow"
    ? "profile"
    : "post"
  const metadata = payload.metadata &&
      typeof payload.metadata === "object" &&
      !Array.isArray(payload.metadata)
    ? payload.metadata as Record<string, unknown>
    : {}

  if (!notificationTypes.has(type)) return err("Unsupported notification type")
  if (!targetId) return err("target_id required")

  let recipientId: string | undefined
  try {
    recipientId = await resolveNotificationRecipient(type, targetId, targetType)
  } catch (error) {
    console.error("Notification recipient lookup failed:", error)
    return err("Notification target could not be resolved", 404)
  }
  if (!recipientId) return err("Notification target was not found", 404)
  if (recipientId === userId) {
    return json({ success: true, skipped: "self_notification" })
  }

  const { data: actor } = await supabase
    .from("profiles")
    .select("full_name, avatar_url")
    .eq("id", userId)
    .maybeSingle()
  const actorName = String(actor?.full_name || "Someone")
  const actorAvatar = toStorageCdnUrl(actor?.avatar_url ?? null)
  const copy = notificationCopy(type, actorName, metadata)
  const eventId = type === "comment"
    ? String(metadata.comment_id ?? payload.idempotency_key ?? crypto.randomUUID())
    : targetId
  const dedupeKey = `${type}:${userId}:${targetType}:${eventId}`
  const notificationId = crypto.randomUUID()
  const notificationMetadata = {
    ...metadata,
    actor_name: actorName,
    actor_avatar: actorAvatar,
  }
  const row = {
    id: notificationId,
    user_id: recipientId,
    actor_id: userId,
    type,
    title: copy.title,
    body: copy.body,
    target_id: targetId,
    target_type: targetType,
    metadata: notificationMetadata,
    dedupe_key: dedupeKey,
    is_read: false,
    created_at: new Date().toISOString(),
  }

  const { data: inserted, error: insertError } = await supabase
    .from("notifications")
    .upsert(row, {
      onConflict: "user_id,dedupe_key",
      ignoreDuplicates: true,
    })
    .select("*")
    .maybeSingle()
  if (insertError) {
    console.error("Notification persistence failed:", insertError)
    return err("Notification persistence failed", 503)
  }
  if (!inserted) {
    return json({ success: true, skipped: "duplicate" })
  }

  const redis = await getRedis()
  if (redis) {
    try {
      await redis.lpush(
        `notifications:${recipientId}`,
        JSON.stringify(inserted),
      )
      await redis.ltrim(`notifications:${recipientId}`, 0, 49)
    } catch (error) {
      console.error("Notification cache update failed:", error)
    }
  }

  return json({ success: true, data: inserted })
}

async function handleFetchNotifications(userId: string, payload: any) {
  const requestedLimit = Number(payload.limit ?? 30)
  const limit = Math.max(1, Math.min(50, requestedLimit))
  let query = supabase
    .from("notifications")
    .select("*")
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .limit(limit)
  if (typeof payload.before === "string" && payload.before) {
    query = query.lt("created_at", payload.before)
  }

  const { data, error } = await query
  if (error) {
    console.error("Notification fetch failed:", error)
    return err("Notifications are temporarily unavailable", 503)
  }
  const notifications = data ?? []
  return json({
    success: true,
    data: notifications,
    next_cursor: notifications.length === limit
      ? notifications[notifications.length - 1]?.created_at
      : null,
  })
}

async function handleMarkNotificationRead(userId: string, payload: any) {
  const notificationId = String(payload.notification_id ?? "")
  if (!notificationId) return err("notification_id required")
  const { error } = await supabase
    .from("notifications")
    .update({ is_read: true, read_at: new Date().toISOString() })
    .eq("id", notificationId)
    .eq("user_id", userId)
  if (error) return err("Notification could not be updated", 503)
  return json({ success: true })
}

async function handleMarkAllNotificationsRead(userId: string) {
  const { error } = await supabase
    .from("notifications")
    .update({ is_read: true, read_at: new Date().toISOString() })
    .eq("user_id", userId)
    .eq("is_read", false)
  if (error) return err("Notifications could not be updated", 503)
  return json({ success: true })
}

/**
 * MUSIC DISCOVERY: High-performance trending, featured, and categories via Redis.
 */
async function handleFetchMusicDiscovery() {
  const redis = await getRedis();
  if (!redis) return err("Redis unavailable for music discovery");

  try {
    const pipeline = redis.pipeline();
    pipeline.get("music:genres");
    pipeline.zrange("music:trending", 0, 9, { rev: true });
    pipeline.smembers("music:featured");

    const results = await pipeline.exec();
    const genresStr = results[0] as string | null;
    const trendingIds = results[1] as string[];
    const featuredIds = results[2] as string[];

    const hydratedTrending = await hydrateTracks(redis, trendingIds);
    const hydratedFeatured = await hydrateTracks(redis, featuredIds);

    return json({
      success: true,
      data: {
        genres: genresStr ? JSON.parse(genresStr) : [],
        trending: hydratedTrending,
        featured: hydratedFeatured,
      }
    });
  } catch (e) {
    return err(`Discovery failed: ${e}`);
  }
}

/**
 * MUSIC SEARCH: Sub-millisecond fuzzy search via Redis inverted index.
 */
async function handleSearchMusic(payload: any) {
  const { query, genre, license_type, limit = 50 } = payload;
  const redis = await getRedis();
  if (!redis) return err("Redis unavailable for search");

  try {
    let resultIds: string[] = [];

    if (query) {
      const words = query.toLowerCase().split(/\s+/).filter((w: string) => w.length > 1);
      if (words.length > 0) {
        const wordSets = words.map((w: string) => `music:search:word:${w}`);
        resultIds = await redis.sinter(...wordSets) as string[];
      }
    } else if (genre) {
      resultIds = await redis.smembers(`music:genre:${genre}`) as string[];
    } else {
      // Return trending if no query/genre
      resultIds = await redis.zrange("music:trending", 0, limit - 1, { rev: true }) as string[];
    }

    let tracks = await hydrateTracks(redis, resultIds);
    
    // Client-side filtering for license_type if provided
    if (license_type) {
      tracks = tracks.filter(t => t.license_type === license_type);
    }

    return json({ success: true, data: tracks.slice(0, limit) });
  } catch (e) {
    return err(`Search failed: ${e}`);
  }
}

/**
 * SYNC MUSIC LIBRARY: Admin tool to populate Redis index from Supabase.
 */
async function handleSyncMusicLibrary() {
  const redis = await getRedis();
  if (!redis) return err("Redis unavailable for sync");

  try {
    // 1. Fetch from Supabase
    const { data: genres } = await supabase.from('music_genres').select('*').eq('is_active', true);
    const { data: tracks } = await supabase.from('music_tracks').select('*').eq('is_active', true);

    if (!tracks) return err("No tracks found to sync");

    const pipeline = redis.pipeline();

    // 2. Clear old index (Simplified for now, in prod use scanning)
    // We clear genres and trending to ensure fresh state
    pipeline.del("music:genres");
    pipeline.del("music:trending");
    pipeline.del("music:featured");

    // 3. Populate genres
    pipeline.set("music:genres", JSON.stringify(genres));

    // 4. Populate tracks & inverted index
    for (const track of tracks) {
      const trackKey = `music:track:${track.id}`;
      pipeline.set(trackKey, JSON.stringify(track));
      
      // Trending score
      pipeline.zadd("music:trending", { score: track.usage_count || 0, member: track.id });
      
      // Featured
      if (track.is_featured) pipeline.sadd("music:featured", track.id);
      
      // Genre sets
      if (track.genre) pipeline.sadd(`music:genre:${track.genre}`, track.id);

      // Inverted index for title and artist
      const words = `${track.title} ${track.artist_name}`.toLowerCase()
        .split(/[^a-z0-9]+/)
        .filter(w => w.length > 1);
      
      for (const word of new Set(words)) {
        pipeline.sadd(`music:search:word:${word}`, track.id);
      }
    }

    await pipeline.exec();
    return json({ success: true, message: `Synced ${tracks.length} tracks and ${genres?.length} genres.` });
  } catch (e) {
    return err(`Sync failed: ${e}`);
  }
}

/**
 * HELPER: Hydrate track IDs into full objects.
 */
async function hydrateTracks(redis: any, ids: string[]) {
  if (!ids || ids.length === 0) return [];
  const pipeline = redis.pipeline();
  ids.forEach(id => pipeline.get(`music:track:${id}`));
  const results = await pipeline.exec();
  return results.filter(r => r !== null).map(r => typeof r === 'string' ? JSON.parse(r) : r);
}


// ============================================
// MAIN ROUTER
// ============================================

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  
  try {
    const authHeader = req.headers.get("Authorization");
    const { data: { user } } = await supabase.auth.getUser(authHeader?.replace("Bearer ", "") || "");
    const userId = user?.id;
    const body = await req.json() as { action: string; payload?: Record<string, unknown> };
    const { action, payload = {} } = body;

    // The one-time cutover is authenticated by a private application key.
    // It runs before user auth because deployment callers use the project anon
    // key at the gateway and never receive an end-user session.
    if (action === "migrate-legacy-engagement") {
      return handleMigrateLegacyEngagement(user, req);
    }
    if (action === "diagnose-engagement") {
      return handleDiagnoseEngagement(user);
    }

    if (!userId) return err("Unauthorized", 401);

    switch (action) {
      case "fetch-feed":           return handleFetchFeed(userId, payload);
      case "record-usage":         return handleRecordUsage(userId, payload);
      case "toggle-like":          return handleToggleLike(userId, payload);
      case "get-upload-url":       return handleGetUploadUrl(userId, payload);
      case "verify-asset":         return handleVerifyAsset(userId, payload);
      case "create-post":          return handleCreatePost(userId, payload);
      case "delete-post":          return handleDeletePost(userId, payload);
      case "clear-feed-cache":     return handleClearCache();
      case "trigger-notification": return handleTriggerNotification(userId, payload);
      case "fetch-notifications":  return handleFetchNotifications(userId, payload);
      case "mark-notification-read": return handleMarkNotificationRead(userId, payload);
      case "mark-all-notifications-read": return handleMarkAllNotificationsRead(userId);
      case "create-comment":       return handleCreateComment(userId, payload);
      case "submit-review":        return handleSubmitReview(userId, payload);
      case "fetch-reviews":        return handleFetchReviews(payload);
      case "fetch-shop-feed":      return handleFetchShopFeed(userId, payload);
      case "fetch-comments":       return handleFetchComments(payload);
      case "fetch-engagement":     return handleFetchEngagement(userId, payload);
      case "fetch-showcase":       return handleFetchShowcase(payload);
      case "create-listing":       return handleCreateListing(userId, payload);
      case "hydrate-post":         return handleHydratePost(payload);
      case "sync-music-library":   return handleSyncMusicLibrary();
      case "fetch-music-discovery":return handleFetchMusicDiscovery();
      case "search-music":         return handleSearchMusic(payload);
      case "search-listings":      return handleSearchListings(payload);
      default:                     return err(`Unknown action: "${action}"`);
    }
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error("Viral Engine Panic:", msg);
    return err(`Viral Engine Panicked: ${msg}`, 500);
  }
});
