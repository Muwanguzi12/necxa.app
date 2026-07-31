import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { MongoClient, ObjectId, type Db } from "npm:mongodb";
import { AccessToken } from "npm:livekit-server-sdk";
import { createClient } from "npm:@supabase/supabase-js";

// ── Environment ─────────────────────────────────────────────────────────────
const LIVEKIT_URL       = Deno.env.get("LIVEKIT_URL")        ?? "wss://necxa-live-dtb2j623.livekit.cloud";
const LIVEKIT_API_KEY   = Deno.env.get("LIVEKIT_API_KEY")    ?? "";
const LIVEKIT_API_SECRET = Deno.env.get("LIVEKIT_API_SECRET") ?? "";
const MONGO_URI         = Deno.env.get("MONGO_URI")          ?? "";
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")       ?? "";
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const LIVE_REACTIONS = new Set(["like", "love", "laugh", "wow", "fire", "applause"]);
const VIEWER_ACTIVE_WINDOW_MS = 15_000;
const HOST_ACTIVE_WINDOW_MS = 45_000;
const START_CONFIRM_WINDOW_MS = 90_000;
const MONGO_DATABASE_NAME = "necxalive";
const COMMENT_PAGE_LIMIT = 50;
const COMMENT_MAX_PAGE_LIMIT = 100;
const COMMENT_MAX_LENGTH = 2_000;
const GUEST_REQUEST_TTL_MS = 1000 * 60 * 60 * 24 * 7;

let cachedMongoClient: MongoClient | null = null;
let cachedMongoDatabase: Db | null = null;
let mongoConnectionPromise: Promise<Db> | null = null;
const supabaseAdmin =
  SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
    ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    })
    : null;

// ── CORS ─────────────────────────────────────────────────────────────────────
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// ── Helpers ───────────────────────────────────────────────────────────────────
function json(body: Record<string, unknown> | unknown[], status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function jwtSubject(req: Request): string | null {
  try {
    const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
    const encodedPayload = token?.split(".")[1];
    if (!encodedPayload) return null;
    const normalized = encodedPayload.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
    const payload = JSON.parse(atob(padded)) as { sub?: unknown };
    return typeof payload.sub === "string" && payload.sub.trim()
      ? payload.sub.trim()
      : null;
  } catch {
    return null;
  }
}

type CommentCursor = { timestamp: Date; id: ObjectId };

function encodeCommentCursor(timestamp: Date, id: ObjectId): string {
  return btoa(JSON.stringify({
    timestamp: timestamp.toISOString(),
    id: id.toHexString(),
  }));
}

function decodeCommentCursor(value?: string): CommentCursor | null {
  if (!value?.trim()) return null;
  try {
    const decoded = JSON.parse(atob(value)) as {
      timestamp?: unknown;
      id?: unknown;
    };
    if (
      typeof decoded.timestamp !== "string" ||
      typeof decoded.id !== "string" ||
      !ObjectId.isValid(decoded.id)
    ) {
      return null;
    }
    const timestamp = new Date(decoded.timestamp);
    if (Number.isNaN(timestamp.getTime())) return null;
    return { timestamp, id: new ObjectId(decoded.id) };
  } catch {
    return null;
  }
}

function serializeComment(comment: Record<string, unknown>) {
  const { _id, ...data } = comment;
  const visibleText =
    data.status === undefined || data.status === "active" ? data.text : "";
  return {
    id: (_id as ObjectId).toHexString(),
    ...data,
    text: visibleText,
  };
}

function serializeGuestRequest(request: Record<string, unknown> | null) {
  if (!request) return null;
  const { _id, ...data } = request;
  return {
    id: String(data.requestId ?? (_id as ObjectId | undefined)?.toString() ?? ""),
    ...data,
  };
}

function streamEventPayload(
  event: Record<string, unknown>,
  result: { insertedId: ObjectId; sequence: number },
) {
  return {
    id: result.insertedId.toString(),
    ...event,
    cursor: String(result.sequence),
  };
}

function normalizedViewerHandle(value: unknown): string {
  return String(value ?? "")
    .trim()
    .replace(/^@+/, "")
    .replace(/[_\s]+/g, "")
    .toLowerCase();
}

function productPhotos(value: unknown): string[] {
  let source = value;
  if (typeof source === "string") {
    try {
      source = JSON.parse(source);
    } catch {
      source = [source];
    }
  }
  if (!Array.isArray(source)) return [];
  return source
    .map((item) => {
      if (typeof item === "string") return item.trim();
      if (item && typeof item === "object") {
        const record = item as Record<string, unknown>;
        return String(
          record.url ?? record.image_url ?? record.media_url ?? "",
        ).trim();
      }
      return "";
    })
    .filter(Boolean);
}

async function ownedListingProduct(
  listingId: string,
  userId: string,
): Promise<
  | { product: Record<string, unknown> }
  | { error: string; status: number }
> {
  if (!supabaseAdmin) {
    return {
      error: "Product ownership verification is unavailable",
      status: 503,
    };
  }
  const { data, error } = await supabaseAdmin
    .from("listings")
    .select("*, profiles:user_id(full_name, avatar_url)")
    .eq("id", listingId)
    .maybeSingle();
  if (error) {
    console.error("Listing ownership lookup failed:", error.message);
    return {
      error: "Product ownership verification failed",
      status: 503,
    };
  }
  if (!data) return { error: "Product listing was not found", status: 404 };

  const listing = data as Record<string, unknown>;
  const ownerId = String(listing.user_id ?? listing.lister_id ?? "");
  if (!ownerId || ownerId !== userId) {
    return {
      error: "You can only pin products owned by your hosting account",
      status: 403,
    };
  }
  const status = String(listing.status ?? "active").toLowerCase();
  if (!["active", "verified", "published"].includes(status)) {
    return { error: "This product is not available for sale", status: 409 };
  }

  const photos = productPhotos(listing.photos);
  const thumbnail = String(
    listing.thumbnail_url ??
      listing.image_url ??
      photos[0] ??
      listing.media_url ??
      listing.film_hub_content ??
      "",
  );
  const mediaUrl = String(
    listing.media_url ??
      listing.image_url ??
      listing.film_hub_content ??
      thumbnail,
  );
  const profile = listing.profiles && typeof listing.profiles === "object"
    ? listing.profiles as Record<string, unknown>
    : {};
  const price = Number(listing.price ?? listing.price_ugx ?? 0);

  return {
    product: {
      ...listing,
      id: String(listing.id),
      user_id: ownerId,
      lister_id: String(listing.lister_id ?? ownerId),
      ownerId,
      title: String(listing.title ?? "Product"),
      description: String(listing.description ?? ""),
      price: Number.isFinite(price) ? price : 0,
      price_ugx: Number.isFinite(price) ? price : 0,
      sku: String(listing.sku ?? ""),
      stock_count:
        listing.stock_count == null ? null : Number(listing.stock_count),
      category: String(listing.category ?? "General"),
      photos,
      thumbnail_url: thumbnail,
      image_url: thumbnail,
      image: thumbnail,
      media_url: mediaUrl,
      film_hub_content: String(listing.film_hub_content ?? mediaUrl),
      lister_name: String(
        listing.lister_name ?? profile.full_name ?? "Vendor",
      ),
      lister_avatar: String(
        listing.lister_avatar ?? profile.avatar_url ?? "",
      ),
      is_verified: listing.is_verified === true,
    },
  };
}

async function mongoDatabase(): Promise<Db> {
  if (!MONGO_URI) throw new Error("MONGO_URI is not configured");
  if (cachedMongoDatabase) return cachedMongoDatabase;
  if (mongoConnectionPromise) return await mongoConnectionPromise;

  const client = new MongoClient(MONGO_URI, {
    appName: "necxa-live-studio-edge",
    connectTimeoutMS: 5_000,
    socketTimeoutMS: 8_000,
    serverSelectionTimeoutMS: 5_000,
    waitQueueTimeoutMS: 5_000,
    maxPoolSize: 8,
    minPoolSize: 0,
    maxConnecting: 2,
    maxIdleTimeMS: 60_000,
    retryReads: true,
    retryWrites: true,
  });

  const pendingConnection = (async () => {
    await client.connect();
    const database = client.db(MONGO_DATABASE_NAME);
    await database.command({ ping: 1 });
    cachedMongoClient = client;
    cachedMongoDatabase = database;
    return database;
  })();
  mongoConnectionPromise = pendingConnection;

  try {
    return await pendingConnection;
  } catch (error) {
    if (cachedMongoClient === client) cachedMongoClient = null;
    cachedMongoDatabase = null;
    try {
      await client.close();
    } catch {
      // Preserve the original connection failure.
    }
    throw error;
  } finally {
    if (mongoConnectionPromise === pendingConnection) {
      mongoConnectionPromise = null;
    }
  }
}

async function insertStreamEvent(
  db: Db,
  event: Record<string, unknown> & { channelId?: string },
) {
  const channelId = event.channelId?.trim();
  if (!channelId) throw new Error("Stream event channel is required");
  const counters = db.collection("stream_event_counters");
  const update = {
    $inc: { sequence: 1 },
    $setOnInsert: { channelId, createdAt: new Date() },
    $set: { updatedAt: new Date() },
  };
  let counter;
  try {
    counter = await counters.findOneAndUpdate(
      { channelId },
      update,
      { upsert: true, returnDocument: "after" },
    );
  } catch (error) {
    const duplicateKey =
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      (error as { code?: unknown }).code === 11000;
    if (!duplicateKey) throw error;
    counter = await counters.findOneAndUpdate(
      { channelId },
      {
        $inc: { sequence: 1 },
        $set: { updatedAt: new Date() },
      },
      { returnDocument: "after" },
    );
  }
  if (!counter) throw new Error("Stream event sequence could not be allocated");
  const sequence = Number(counter?.sequence ?? 1);
  const result = await db.collection("stream_events").insertOne({
    ...event,
    channelId,
    sequence,
  });
  return { insertedId: result.insertedId, sequence };
}

function liveHeartbeatFilter(now = new Date()) {
  const activeSince = new Date(now.getTime() - HOST_ACTIVE_WINDOW_MS);
  return {
    $or: [
      { lastHeartbeatAt: { $gte: activeSince } },
      {
        lastHeartbeatAt: { $exists: false },
        startedAt: { $gte: activeSince },
      },
    ],
  };
}

async function expireStaleStreams(db: Db): Promise<void> {
  const now = new Date();
  const activeSince = new Date(now.getTime() - HOST_ACTIVE_WINDOW_MS);
  const streams = db.collection("streams");
  const staleLiveFilter = {
    status: "live",
    $or: [
      { lastHeartbeatAt: { $lt: activeSince } },
      {
        lastHeartbeatAt: { $exists: false },
        startedAt: { $lt: activeSince },
      },
    ],
  };
  const staleChannels = await streams.distinct("channelId", staleLiveFilter);
  await Promise.all([
    streams.updateMany(
      staleLiveFilter,
      {
        $set: {
          status: "ended",
          endedAt: now,
          endedReason: "host_heartbeat_timeout",
          viewerCount: 0,
        },
      },
    ),
    streams.updateMany(
      { status: "starting", prepareExpiresAt: { $lt: now } },
      {
        $set: {
          status: "failed",
          endedAt: now,
          endedReason: "start_confirmation_timeout",
          viewerCount: 0,
        },
      },
    ),
    staleChannels.length === 0
      ? Promise.resolve()
      : db.collection("stream_viewers").updateMany(
          { channelId: { $in: staleChannels }, active: true },
          { $set: { active: false, leftAt: now } },
        ),
  ]);
}

async function liveSummary(
  db: Db,
  channelId: string,
) {
  const activeSince = new Date(Date.now() - VIEWER_ACTIVE_WINDOW_MS);
  const viewers = db.collection("stream_viewers");
  await viewers.updateMany(
    { channelId, active: true, lastSeenAt: { $lt: activeSince } },
    { $set: { active: false, leftAt: new Date() } },
  );

  const [stream, activeViewers] = await Promise.all([
    db.collection("streams").findOne(
      { channelId, status: "live" },
      {
        projection: {
          _id: 0,
          likes: 1,
          shares: 1,
          reactionCounts: 1,
        },
      },
    ),
    viewers
      .find(
        {
          channelId,
          active: true,
          role: { $ne: "host" },
          lastSeenAt: { $gte: activeSince },
        },
        {
          projection: {
            _id: 0,
            userId: 1,
            userName: 1,
            avatar: 1,
            role: 1,
          },
        },
      )
      .sort({ lastSeenAt: -1 })
      .limit(8)
      .toArray(),
  ]);

  const viewerCount = await viewers.countDocuments({
    channelId,
    active: true,
    role: { $ne: "host" },
    lastSeenAt: { $gte: activeSince },
  });
  await db.collection("streams").updateOne(
    { channelId, status: "live" },
    {
      $set: { viewerCount, updatedAt: new Date() },
      $max: { peakViewers: viewerCount },
    },
  );

  return {
    viewerCount,
    likes: Number(stream?.likes ?? 0),
    shares: Number(stream?.shares ?? 0),
    reactionCounts: stream?.reactionCounts ?? {},
    viewers: activeViewers,
  };
}

async function buildLiveKitToken(
  roomName: string,
  identity: string,
  canPublish: boolean,
): Promise<string> {
  if (!LIVEKIT_API_KEY || !LIVEKIT_API_SECRET) {
    throw new Error("Missing LiveKit API configuration");
  }
  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: identity || `guest_${crypto.randomUUID()}`,
  });
  at.addGrant({
    roomJoin: true,
    room: roomName,
    canPublish,
    canPublishData: true,
    canSubscribe: true,
  });
  return await at.toJwt();
}

// ── Valid actions whitelist ────────────────────────────────────────────────────
const VALID_ACTIONS = [
  "start",
  "confirm_start",
  "abort_start",
  "join",
  "confirm_join",
  "stop",
  "leave",
  "list_active",
  "pin_product",
  "unpin_product",
  "fetch_stream_state",
  "cohost_request",
  "cohost_cancel",
  "cohost_decision",
  "cohost_invite",
  "cohost_invite_response",
  "cohost_leave",
  "send_comment",
  "fetch_comments",
  "edit_comment",
  "delete_comment",
  "report_comment",
  "moderate_comment",
  "send_reaction",
  "record_share",
  "poll_event",
] as const;
type Action = typeof VALID_ACTIONS[number];

// ── Main handler ──────────────────────────────────────────────────────────────
serve(async (req) => {
  // CORS pre-flight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const {
      action,
      channelId,
      streamId,
      userId: requestedUserId,
      role,
      metadata = {},
      location  = {},
      product,
      guestId,
      userName,
      text,
      reactionType,
      protocolVersion,
      commentId,
      clientRequestId,
      before,
      after,
      limit,
      moderationAction,
      reason,
      eventCursor,
    } = body as {
      action: string;
      channelId?: string;
      streamId?: string;
      userId?: string;
      role?: string;
      metadata?: Record<string, unknown>;
      location?: Record<string, unknown>;
      product?: Record<string, unknown>;
      guestId?: string;
      userName?: string;
      text?: string;
      reactionType?: string;
      protocolVersion?: number;
      commentId?: string;
      clientRequestId?: string;
      before?: string;
      after?: string;
      limit?: number;
      moderationAction?: string;
      reason?: string;
      eventCursor?: string;
    };
    const usesConfirmedLifecycle = Number(protocolVersion) >= 2;

    const userId = jwtSubject(req);
    if (!userId) {
      return json({ error: "A valid signed-in session is required" }, 401);
    }
    if (requestedUserId?.trim() && requestedUserId.trim() !== userId) {
      return json({ error: "The requested user does not match the session" }, 403);
    }

    // ── 3. Validate action ────────────────────────────────────────────────────
    if (!VALID_ACTIONS.includes(action as Action)) {
      return json({ error: `Invalid action. Must be one of: ${VALID_ACTIONS.join(", ")}` }, 400);
    }

    // ── 1. Validate required fields per action ────────────────────────────────
    if (action !== "list_active" && !channelId?.trim()) {
      return json({ error: "channelId is required" }, 400);
    }
    if (action === "start" && !userId?.trim()) {
      return json({ error: "userId is required to start a stream" }, 400);
    }
    if (
      [
        "pin_product",
        "unpin_product",
        "cohost_request",
        "send_comment",
        "edit_comment",
        "delete_comment",
        "report_comment",
        "moderate_comment",
      ].includes(action) &&
      !userId?.trim()
    ) {
      return json({ error: "Authentication is required for this action" }, 401);
    }
    if (action === "cohost_decision" && !guestId?.trim()) {
      return json({ error: "guestId is required for a co-host decision" }, 400);
    }
    if (
      action === "cohost_invite" &&
      !guestId?.trim() &&
      !userName?.trim()
    ) {
      return json({ error: "Enter an online viewer name to invite" }, 400);
    }
    if (action === "pin_product" && (!product || !product.id)) {
      return json({ error: "A product with an id is required" }, 400);
    }
    if (
      eventCursor &&
      (!Number.isSafeInteger(Number(eventCursor)) || Number(eventCursor) < 0)
    ) {
      return json({ error: "Invalid event cursor" }, 400);
    }
    if (action === "send_reaction" && !LIVE_REACTIONS.has(reactionType ?? "")) {
      return json({ error: "Unsupported live reaction" }, 400);
    }
    if (
      ["edit_comment", "delete_comment", "report_comment", "moderate_comment"]
        .includes(action) &&
      (!commentId || !ObjectId.isValid(commentId))
    ) {
      return json({ error: "A valid commentId is required" }, 400);
    }
    if (
      action === "moderate_comment" &&
      !["hide", "restore"].includes(moderationAction ?? "")
    ) {
      return json({ error: "Unsupported moderation action" }, 400);
    }

    // ── Authentication gate for hosts ─────────────────────────────────────────
    if (action === "start") {
      if (!userId?.trim()) {
        return json({ error: "Authentication required to go live." }, 401);
      }
    }

    // One bounded MongoDB pool is reused for the lifetime of this warm isolate.
    let mongoSuccess = false;
    let mongoErrorMsg = "";
    let activeStreams: unknown[] = [];
    let newStreamId: string | null = null;
    let actionResult: unknown = null;

    if (MONGO_URI) {
      try {
        const db = await mongoDatabase();
        const streams = db.collection("streams");

        if (action === "start") {
          await expireStaleStreams(db);
          const preparedAt = new Date();
          const requestedHostName =
            String(metadata.hostName ?? metadata.name ?? "Necxa Creator")
              .trim() || "Necxa Creator";
          const requestedAvatar = String(metadata.avatar ?? "").trim();
          let existing = await streams.findOne({
            hostId: userId,
            status: { $in: ["starting", "live"] },
          });
          if (existing && existing.channelId !== channelId) {
            return json(
              { error: "You already have an active stream. End it before starting another." },
              409,
            );
          }

          if (!existing) {
            newStreamId = crypto.randomUUID();
            const {
              title = "Live Session",
              description = "",
              thumbnail = "",
              category = "",
              tags = [],
            } = metadata as Record<string, unknown>;

            await Promise.all([
              db.collection("stream_metadata").deleteOne({ channelId }),
              db.collection("stream_events").deleteMany({ channelId }),
              db.collection("stream_event_counters").deleteOne({ channelId }),
              db.collection("stream_viewers").deleteMany({ channelId }),
              db.collection("stream_guest_requests").deleteMany({ channelId }),
            ]);
            await streams.insertOne({
              streamId: newStreamId,
              channelId,
              hostId: userId,
              status: "starting",
              title,
              description,
              thumbnail,
              category,
              tags,
              hostName: requestedHostName,
              avatar: requestedAvatar,
              metadata: {
                hostName: requestedHostName,
                avatar: requestedAvatar,
              },
              location,
              viewerCount: 0,
              peakViewers: 0,
              likes: 0,
              shares: 0,
              reactionCounts: {},
              recording: false,
              recordingId: null,
              playbackUrl: null,
              duration: null,
              isVerified: true,
              isReported: false,
              reportCount: 0,
              preparedAt,
              prepareExpiresAt: new Date(
                preparedAt.getTime() + START_CONFIRM_WINDOW_MS,
              ),
              startedAt: null,
              createdAt: preparedAt,
            });
          } else {
            newStreamId = existing.streamId?.toString() ?? null;
            await streams.updateOne(
              { _id: existing._id },
              {
                $set: {
                  hostName: requestedHostName,
                  avatar: requestedAvatar,
                  "metadata.hostName": requestedHostName,
                  "metadata.avatar": requestedAvatar,
                  updatedAt: preparedAt,
                },
              },
            );
            existing = {
              ...existing,
              hostName: requestedHostName,
              avatar: requestedAvatar,
            };
          }

          // Keep already-installed clients working while protocol v2 rolls out.
          // Protocol v2 confirms only after the LiveKit connection succeeds.
          if (!usesConfirmedLifecycle) {
            await streams.updateOne(
              { channelId, hostId: userId, status: "starting" },
              {
                $set: {
                  status: "live",
                  startedAt: preparedAt,
                  lastHeartbeatAt: preparedAt,
                  updatedAt: preparedAt,
                },
                $unset: { prepareExpiresAt: "" },
              },
            );
            await streams.updateOne(
              { channelId, hostId: userId, status: "live" },
              {
                $set: {
                  lastHeartbeatAt: preparedAt,
                  updatedAt: preparedAt,
                },
              },
            );
            const legacyStream = await streams.findOne({
              channelId,
              hostId: userId,
              status: "live",
            });
            await db.collection("stream_viewers").updateOne(
              { channelId, userId },
              {
                $set: {
                  channelId,
                  userId,
                  userName:
                    legacyStream?.hostName ?? metadata.name ?? "Necxa Creator",
                  avatar: legacyStream?.avatar ?? metadata.avatar ?? "",
                  role: "host",
                  active: true,
                  lastSeenAt: preparedAt,
                },
                $setOnInsert: { joinedAt: preparedAt },
                $unset: { leftAt: "" },
              },
              { upsert: true },
            );
          }
          mongoSuccess = true;

        } else if (action === "confirm_start") {
          const confirmedAt = new Date();
          const prepared = await streams.findOne({
            channelId,
            hostId: userId,
            status: { $in: ["starting", "live"] },
            ...(streamId?.trim() ? { streamId: streamId.trim() } : {}),
          });
          if (
            !prepared ||
            (prepared.status === "starting" &&
              (!(prepared.prepareExpiresAt instanceof Date) ||
                prepared.prepareExpiresAt < confirmedAt))
          ) {
            return json(
              { error: "Live start confirmation expired. Please start again." },
              409,
            );
          }
          if (prepared.status === "starting") {
            await streams.updateOne(
              { _id: prepared._id, status: "starting" },
              {
                $set: {
                  status: "live",
                  startedAt: confirmedAt,
                  lastHeartbeatAt: confirmedAt,
                  updatedAt: confirmedAt,
                },
                $unset: { prepareExpiresAt: "" },
              },
            );
          } else {
            await streams.updateOne(
              { _id: prepared._id, status: "live" },
              {
                $set: {
                  lastHeartbeatAt: confirmedAt,
                  updatedAt: confirmedAt,
                },
              },
            );
          }
          await db.collection("stream_viewers").updateOne(
            { channelId, userId },
            {
              $set: {
                channelId,
                userId,
                userName: prepared.hostName ?? metadata.name ?? "Necxa Creator",
                avatar: prepared.avatar ?? metadata.avatar ?? "",
                role: "host",
                active: true,
                lastSeenAt: confirmedAt,
              },
              $setOnInsert: { joinedAt: confirmedAt },
              $unset: { leftAt: "" },
            },
            { upsert: true },
          );
          newStreamId = prepared.streamId?.toString() ?? null;
          actionResult = {
            streamId: newStreamId,
            status: "live",
            summary: await liveSummary(db, channelId!),
          };
          mongoSuccess = true;

        } else if (action === "abort_start") {
          const abortedAt = new Date();
          const hasAttemptId = Boolean(streamId?.trim());
          const prepared = await streams.findOne({
            channelId,
            hostId: userId,
            status: hasAttemptId ? { $in: ["starting", "live"] } : "starting",
            ...(hasAttemptId ? { streamId: streamId!.trim() } : {}),
          });
          let aborted = false;
          if (prepared) {
            const wasLive = prepared.status === "live";
            const result = await streams.updateOne(
              { _id: prepared._id, status: prepared.status },
              {
                $set: {
                  status: wasLive ? "ended" : "failed",
                  endedAt: abortedAt,
                  endedReason: wasLive
                    ? "start_confirmation_aborted"
                    : "livekit_connection_failed",
                  viewerCount: 0,
                  updatedAt: abortedAt,
                },
                $unset: { prepareExpiresAt: "" },
              },
            );
            aborted = result.modifiedCount > 0;
            if (aborted && wasLive) {
              await db.collection("stream_viewers").updateMany(
                { channelId, active: true },
                { $set: { active: false, leftAt: abortedAt } },
              );
            }
          }
          actionResult = { aborted };
          mongoSuccess = true;

        } else if (action === "join") {
          const liveStream = await streams.findOne({
            channelId,
            status: "live",
            ...liveHeartbeatFilter(),
          });
          if (!liveStream) {
            return json(
              { error: "This live stream has ended or is unavailable" },
              404,
            );
          }
          if (role === "publisher" && liveStream.hostId !== userId) {
            const approvedRequest = await db.collection("stream_guest_requests")
              .findOne({
                channelId,
                guestId: userId,
                status: { $in: ["accepted", "active"] },
              });
            if (!approvedRequest) {
              return json(
                { error: "The host must approve this co-host connection first" },
                403,
              );
            }
          }
          if (!usesConfirmedLifecycle) {
            const joinedAt = new Date();
            await db.collection("stream_viewers").updateOne(
              { channelId, userId },
              {
                $set: {
                  channelId,
                  userId,
                  userName: metadata.name ?? "Viewer",
                  avatar: metadata.avatar ?? "",
                  role: role === "publisher" ? "cohost" : "viewer",
                  active: true,
                  lastSeenAt: joinedAt,
                },
                $setOnInsert: { joinedAt },
                $unset: { leftAt: "" },
              },
              { upsert: true },
            );
          }
          actionResult = {
            ready: true,
            summary: usesConfirmedLifecycle
              ? null
              : await liveSummary(db, channelId!),
          };
          mongoSuccess = true;

        } else if (action === "confirm_join") {
          const joinedAt = new Date();
          const liveStream = await streams.findOne({
            channelId,
            status: "live",
            ...liveHeartbeatFilter(joinedAt),
          });
          if (!liveStream) {
            return json({ error: "This live stream has ended" }, 410);
          }
          if (role === "publisher" && liveStream.hostId !== userId) {
            const approvedRequest = await db.collection("stream_guest_requests")
              .findOneAndUpdate(
                {
                  channelId,
                  guestId: userId,
                  status: { $in: ["accepted", "active"] },
                },
                {
                  $set: {
                    status: "active",
                    connectedAt: joinedAt,
                    updatedAt: joinedAt,
                    expiresAt: new Date(joinedAt.getTime() + GUEST_REQUEST_TTL_MS),
                  },
                },
                { returnDocument: "after" },
              );
            if (!approvedRequest) {
              return json(
                { error: "The host approval for this co-host has expired" },
                403,
              );
            }
          }
          await db.collection("stream_viewers").updateOne(
            { channelId, userId },
            {
              $set: {
                channelId,
                userId,
                userName: metadata.name ?? "Viewer",
                avatar: metadata.avatar ?? "",
                role: role === "publisher" ? "cohost" : "viewer",
                active: true,
                lastSeenAt: joinedAt,
              },
              $setOnInsert: { joinedAt },
              $unset: { leftAt: "" },
            },
            { upsert: true },
          );
          actionResult = await liveSummary(db, channelId!);
          mongoSuccess = true;

        } else if (action === "leave") {
          await db.collection("stream_viewers").updateOne(
            { channelId, userId },
            { $set: { active: false, leftAt: new Date(), lastSeenAt: new Date() } },
          );
          actionResult = await liveSummary(db, channelId!);
          mongoSuccess = true;

        } else if (action === "stop") {
          const stoppedAt = new Date();
          const [stopped] = await Promise.all([
            streams.updateMany(
              {
                channelId,
                hostId: userId,
                status: { $in: ["starting", "live"] },
              },
              {
                $set: {
                  status: "ended",
                  endedAt: stoppedAt,
                  endedReason: "host_stopped",
                  viewerCount: 0,
                },
                $unset: { prepareExpiresAt: "" },
              },
            ),
            db.collection("stream_viewers").updateMany(
              { channelId, active: true },
              { $set: { active: false, leftAt: stoppedAt } },
            ),
            db.collection("stream_guest_requests").updateMany(
              {
                channelId,
                status: { $in: ["pending", "invited", "accepted", "active"] },
              },
              {
                $set: {
                  status: "ended",
                  updatedAt: stoppedAt,
                  expiresAt: new Date(stoppedAt.getTime() + GUEST_REQUEST_TTL_MS),
                },
              },
            ),
          ]);
          actionResult = { stopped: stopped.modifiedCount > 0 };
          mongoSuccess = true;

        } else if (action === "list_active") {
          await expireStaleStreams(db);
          const liveStreams = await streams
            .find({ status: "live" })
            .sort({ startedAt: -1 })
            .toArray();
          activeStreams = liveStreams.map((stream) => {
            const storedMetadata =
              stream.metadata && typeof stream.metadata === "object"
                ? stream.metadata as Record<string, unknown>
                : {};
            const hostName = String(
              stream.hostName ?? storedMetadata.hostName ?? "Necxa Creator",
            );
            const avatar = String(
              stream.avatar ?? storedMetadata.avatar ?? "",
            );
            return {
              ...stream,
              hostName,
              avatar,
              metadata: { ...storedMetadata, hostName, avatar },
            };
          });
          mongoSuccess = true;
        } else if (action === "pin_product") {
          const ownedStream = await streams.findOne({
            channelId,
            hostId: userId,
            status: "live",
          });
          if (!ownedStream) {
            return json({ error: "Only the live host can pin products" }, 403);
          }
          const listingResult = await ownedListingProduct(
            String(product?.id ?? ""),
            userId!,
          );
          if ("error" in listingResult) {
            return json(
              { error: listingResult.error },
              listingResult.status,
            );
          }
          const pinnedAt = new Date();
          const canonicalProduct = {
            ...listingResult.product,
            pinnedAt,
            pinnedBy: userId,
          };
          await db.collection("stream_metadata").updateOne(
            { channelId },
            {
              $set: {
                channelId,
                pinnedProduct: canonicalProduct,
                updatedAt: pinnedAt,
              },
            },
            { upsert: true },
          );
          const eventResult = await insertStreamEvent(db, {
            channelId,
            userId,
            type: "product_pinned",
            data: { product: canonicalProduct },
            timestamp: pinnedAt,
          });
          actionResult = {
            pinned: true,
            eventId: eventResult.insertedId.toString(),
            product: canonicalProduct,
          };
          mongoSuccess = true;
        } else if (action === "unpin_product") {
          const ownedStream = await streams.findOne({
            channelId,
            hostId: userId,
            status: "live",
          });
          if (!ownedStream) {
            return json({ error: "Only the live host can unpin products" }, 403);
          }
          const unpinnedAt = new Date();
          const previousState = await db.collection("stream_metadata")
            .findOneAndUpdate(
              { channelId },
              {
                $set: {
                  channelId,
                  pinnedProduct: null,
                  updatedAt: unpinnedAt,
                },
              },
              { upsert: true, returnDocument: "before" },
            );
          const previousProduct = previousState?.pinnedProduct ?? null;
          const eventResult = await insertStreamEvent(db, {
            channelId,
            userId,
            type: "product_unpinned",
            data: {
              productId:
                previousProduct && typeof previousProduct === "object"
                  ? (previousProduct as Record<string, unknown>).id ?? null
                  : null,
            },
            timestamp: unpinnedAt,
          });
          actionResult = {
            pinned: false,
            eventId: eventResult.insertedId.toString(),
            product: null,
          };
          mongoSuccess = true;
        } else if (action === "fetch_stream_state") {
          const liveStream = await streams.findOne(
            { channelId, status: "live" },
            { projection: { _id: 0, hostId: 1 } },
          );
          if (!liveStream) {
            return json({ error: "This live stream has ended" }, 410);
          }
          const isHost = liveStream.hostId === userId;
          const [streamState, summary, eventCounter, guestRequestState] = await Promise.all([
            db.collection("stream_metadata").findOne(
              { channelId },
              { projection: { _id: 0, pinnedProduct: 1, updatedAt: 1 } },
            ),
            liveSummary(db, channelId!),
            db.collection("stream_event_counters").findOne({ channelId }),
            isHost
              ? db.collection("stream_guest_requests")
                .find({
                  channelId,
                  status: { $in: ["pending", "invited", "accepted", "active"] },
                })
                .sort({ updatedAt: -1 })
                .limit(100)
                .toArray()
              : db.collection("stream_guest_requests").findOne({
                channelId,
                guestId: userId,
                status: { $in: ["pending", "invited", "accepted", "active"] },
              }),
          ]);
          actionResult = {
            pinnedProduct: streamState?.pinnedProduct ?? null,
            updatedAt: streamState?.updatedAt ?? null,
            eventCursor: String(eventCounter?.sequence ?? 0),
            summary,
            guestRequests: isHost && Array.isArray(guestRequestState)
              ? guestRequestState.map((request) => serializeGuestRequest(request))
              : [],
            guestRequest: !isHost && !Array.isArray(guestRequestState)
              ? serializeGuestRequest(guestRequestState)
              : null,
          };
          mongoSuccess = true;
        } else if (action === "cohost_request") {
          const liveStream = await streams.findOne({
            channelId,
            status: "live",
            ...liveHeartbeatFilter(),
          });
          if (!liveStream) {
            return json({ error: "This live stream has ended" }, 410);
          }
          if (liveStream.hostId === userId) {
            return json({ error: "The host is already broadcasting" }, 409);
          }
          const activeViewer = await db.collection("stream_viewers").findOne({
            channelId,
            userId,
            active: true,
          });
          if (!activeViewer) {
            return json({ error: "Join the live before requesting co-host access" }, 409);
          }
          const requests = db.collection("stream_guest_requests");
          const existing = await requests.findOne({ channelId, guestId: userId });
          if (existing?.status === "invited") {
            return json(
              { error: "The host has already invited you to co-host" },
              409,
            );
          }
          if (["pending", "accepted", "active"].includes(String(existing?.status ?? ""))) {
            return json({
              success: true,
              data: {
                request: serializeGuestRequest(existing),
                event: null,
              },
            });
          }
          const requestedAt = new Date();
          const requestId = crypto.randomUUID();
          const request = await requests.findOneAndUpdate(
            { channelId, guestId: userId },
            {
              $set: {
                requestId,
                channelId,
                hostId: liveStream.hostId,
                guestId: userId,
                guestName: String(metadata.name ?? activeViewer.userName ?? "Viewer"),
                avatar: String(metadata.avatar ?? activeViewer.avatar ?? ""),
                direction: "viewer_request",
                status: "pending",
                requestedAt,
                updatedAt: requestedAt,
                expiresAt: new Date(requestedAt.getTime() + GUEST_REQUEST_TTL_MS),
              },
              $setOnInsert: { createdAt: requestedAt },
              $unset: {
                respondedAt: "",
                cancelledAt: "",
                connectedAt: "",
                leftAt: "",
              },
            },
            { upsert: true, returnDocument: "after" },
          );
          const requestEvent = {
            channelId,
            userId,
            type: "cohost_request",
            data: {
              requestId,
              name: request?.guestName ?? "Viewer",
              avatar: request?.avatar ?? "",
              status: "pending",
            },
            timestamp: requestedAt,
          };
          const eventResult = await insertStreamEvent(db, requestEvent);
          actionResult = {
            request: serializeGuestRequest(request),
            event: streamEventPayload(requestEvent, eventResult),
          };
          mongoSuccess = true;
        } else if (action === "cohost_cancel") {
          const cancelledAt = new Date();
          const request = await db.collection("stream_guest_requests")
            .findOneAndUpdate(
              { channelId, guestId: userId, status: "pending" },
              {
                $set: {
                  status: "cancelled",
                  cancelledAt,
                  updatedAt: cancelledAt,
                  expiresAt: new Date(cancelledAt.getTime() + GUEST_REQUEST_TTL_MS),
                },
              },
              { returnDocument: "after" },
            );
          if (!request) {
            return json({ error: "There is no pending co-host request to cancel" }, 409);
          }
          const cancelEvent = {
            channelId,
            userId,
            type: "cohost_cancelled",
            data: { requestId: request.requestId, status: "cancelled" },
            timestamp: cancelledAt,
          };
          const eventResult = await insertStreamEvent(db, cancelEvent);
          actionResult = {
            request: serializeGuestRequest(request),
            event: streamEventPayload(cancelEvent, eventResult),
          };
          mongoSuccess = true;
        } else if (action === "cohost_decision") {
          const liveStream = await streams.findOne({
            channelId,
            hostId: userId,
            status: "live",
          });
          if (!liveStream) {
            return json({ error: "Only the live host can decide guest requests" }, 403);
          }
          const accepted = metadata.accepted === true;
          const respondedAt = new Date();
          const request = await db.collection("stream_guest_requests")
            .findOneAndUpdate(
              {
                channelId,
                guestId,
                hostId: userId,
                status: "pending",
              },
              {
                $set: {
                  status: accepted ? "accepted" : "declined",
                  respondedAt,
                  updatedAt: respondedAt,
                  expiresAt: new Date(respondedAt.getTime() + GUEST_REQUEST_TTL_MS),
                },
              },
              { returnDocument: "after" },
            );
          if (!request) {
            return json(
              { error: "This co-host request is no longer pending" },
              409,
            );
          }
          const decisionEvent = {
            channelId,
            userId: guestId,
            type: "cohost_decision",
            data: {
              requestId: request.requestId,
              accepted,
              hostId: request.hostId,
              status: request.status,
            },
            timestamp: respondedAt,
          };
          const eventResult = await insertStreamEvent(db, decisionEvent);
          actionResult = {
            request: serializeGuestRequest(request),
            event: streamEventPayload(decisionEvent, eventResult),
          };
          mongoSuccess = true;
        } else if (action === "cohost_invite") {
          const liveStream = await streams.findOne({
            channelId,
            hostId: userId,
            status: "live",
          });
          if (!liveStream) {
            return json({ error: "Only the live host can invite a guest" }, 403);
          }
          const activeSince = new Date(Date.now() - VIEWER_ACTIVE_WINDOW_MS);
          const onlineViewers = await db.collection("stream_viewers")
            .find({
              channelId,
              active: true,
              userId: { $ne: userId },
              lastSeenAt: { $gte: activeSince },
            })
            .limit(100)
            .toArray();
          let invitedViewer = guestId?.trim()
            ? onlineViewers.find((viewer) => viewer.userId === guestId.trim())
            : null;
          if (!invitedViewer) {
            const handle = normalizedViewerHandle(userName);
            const exactMatches = onlineViewers.filter((viewer) =>
              normalizedViewerHandle(viewer.userName) === handle
            );
            const partialMatches = exactMatches.length > 0
              ? exactMatches
              : onlineViewers.filter((viewer) =>
                normalizedViewerHandle(viewer.userName).includes(handle)
              );
            if (partialMatches.length > 1) {
              return json(
                { error: "More than one online viewer matches that name. Enter the full username." },
                409,
              );
            }
            invitedViewer = partialMatches[0];
          }
          if (!invitedViewer) {
            return json({ error: "That viewer is not currently online in this live" }, 404);
          }
          const requests = db.collection("stream_guest_requests");
          const existing = await requests.findOne({
            channelId,
            guestId: invitedViewer.userId,
          });
          if (existing?.status === "pending") {
            return json(
              { error: "That viewer already has a pending co-host request" },
              409,
            );
          }
          if (["invited", "accepted", "active"].includes(String(existing?.status ?? ""))) {
            return json({
              success: true,
              data: {
                request: serializeGuestRequest(existing),
                event: null,
              },
            });
          }
          const invitedAt = new Date();
          const requestId = crypto.randomUUID();
          const request = await requests.findOneAndUpdate(
            { channelId, guestId: invitedViewer.userId },
            {
              $set: {
                requestId,
                channelId,
                hostId: userId,
                guestId: invitedViewer.userId,
                guestName: String(invitedViewer.userName ?? "Viewer"),
                avatar: String(invitedViewer.avatar ?? ""),
                direction: "host_invite",
                status: "invited",
                invitedAt,
                updatedAt: invitedAt,
                expiresAt: new Date(invitedAt.getTime() + GUEST_REQUEST_TTL_MS),
              },
              $setOnInsert: { createdAt: invitedAt },
              $unset: {
                respondedAt: "",
                cancelledAt: "",
                connectedAt: "",
                leftAt: "",
              },
            },
            { upsert: true, returnDocument: "after" },
          );
          const inviteEvent = {
            channelId,
            userId: invitedViewer.userId,
            type: "cohost_invite",
            data: {
              requestId,
              hostId: userId,
              status: "invited",
            },
            timestamp: invitedAt,
          };
          const eventResult = await insertStreamEvent(db, inviteEvent);
          actionResult = {
            request: serializeGuestRequest(request),
            event: streamEventPayload(inviteEvent, eventResult),
          };
          mongoSuccess = true;
        } else if (action === "cohost_invite_response") {
          const accepted = metadata.accepted === true;
          const respondedAt = new Date();
          const request = await db.collection("stream_guest_requests")
            .findOneAndUpdate(
              { channelId, guestId: userId, status: "invited" },
              {
                $set: {
                  status: accepted ? "accepted" : "declined",
                  respondedAt,
                  updatedAt: respondedAt,
                  expiresAt: new Date(respondedAt.getTime() + GUEST_REQUEST_TTL_MS),
                },
              },
              { returnDocument: "after" },
            );
          if (!request) {
            return json({ error: "This co-host invitation is no longer active" }, 409);
          }
          const responseEvent = {
            channelId,
            userId,
            type: "cohost_invite_decision",
            data: {
              requestId: request.requestId,
              accepted,
              hostId: request.hostId,
              status: request.status,
            },
            timestamp: respondedAt,
          };
          const eventResult = await insertStreamEvent(db, responseEvent);
          actionResult = {
            request: serializeGuestRequest(request),
            event: streamEventPayload(responseEvent, eventResult),
          };
          mongoSuccess = true;
        } else if (action === "cohost_leave") {
          const leftAt = new Date();
          const request = await db.collection("stream_guest_requests")
            .findOneAndUpdate(
              {
                channelId,
                guestId: userId,
                status: { $in: ["accepted", "active"] },
              },
              {
                $set: {
                  status: "left",
                  leftAt,
                  updatedAt: leftAt,
                  expiresAt: new Date(leftAt.getTime() + GUEST_REQUEST_TTL_MS),
                },
              },
              { returnDocument: "after" },
            );
          if (!request) {
            return json({ error: "You are not an active co-host" }, 409);
          }
          await db.collection("stream_viewers").updateOne(
            { channelId, userId },
            { $set: { role: "viewer", lastSeenAt: leftAt } },
          );
          const leaveEvent = {
            channelId,
            userId,
            type: "cohost_left",
            data: { requestId: request.requestId, status: "left" },
            timestamp: leftAt,
          };
          const eventResult = await insertStreamEvent(db, leaveEvent);
          actionResult = {
            request: serializeGuestRequest(request),
            event: streamEventPayload(leaveEvent, eventResult),
          };
          mongoSuccess = true;
        } else if (action === "send_comment") {
          const cleanText = text?.trim() ?? "";
          if (!cleanText) {
            return json({ error: "Comment text is required" }, 400);
          }
          const liveStream = await streams.findOne({
            channelId,
            status: "live",
            ...liveHeartbeatFilter(),
          });
          if (!liveStream) {
            return json({ error: "This live stream has ended" }, 410);
          }
          const requestId = clientRequestId?.trim() ||
            `legacy_${crypto.randomUUID()}`;
          const now = new Date();
          let comment;
          try {
            comment = await db.collection("stream_chat").findOneAndUpdate(
              { channelId, userId, clientRequestId: requestId },
              {
                $setOnInsert: {
                  channelId,
                  // Retained while older app builds still query channelName.
                  channelName: channelId,
                  userId,
                  userName: userName?.trim() || "User",
                  avatar: metadata.avatar ?? "",
                  text: cleanText.slice(0, COMMENT_MAX_LENGTH),
                  status: "active",
                  clientRequestId: requestId,
                  timestamp: now,
                  createdAt: now,
                  updatedAt: now,
                  editedAt: null,
                  deletedAt: null,
                },
              },
              { upsert: true, returnDocument: "after" },
            );
          } catch (error) {
            const duplicateKey =
              typeof error === "object" &&
              error !== null &&
              "code" in error &&
              (error as { code?: unknown }).code === 11000;
            if (!duplicateKey) throw error;
            comment = await db.collection("stream_chat").findOne({
              channelId,
              userId,
              clientRequestId: requestId,
            });
          }
          if (!comment) {
            throw new Error("Comment could not be persisted");
          }
          actionResult = serializeComment(
            comment as unknown as Record<string, unknown>,
          );
          mongoSuccess = true;
        } else if (action === "fetch_comments") {
          const pageLimit = Math.min(
            Math.max(Number(limit) || COMMENT_PAGE_LIMIT, 1),
            COMMENT_MAX_PAGE_LIMIT,
          );
          const beforeCursor = decodeCommentCursor(before);
          const afterCursor = decodeCommentCursor(after);
          if ((before && !beforeCursor) || (after && !afterCursor)) {
            return json({ error: "Invalid comment cursor" }, 400);
          }
          if (beforeCursor && afterCursor) {
            return json(
              { error: "Use either before or after, not both" },
              400,
            );
          }

          const channelFilter = {
            $or: [{ channelId }, { channelName: channelId }],
          };
          const cursorFilter = afterCursor
            ? {
              $or: [
                { updatedAt: { $gt: afterCursor.timestamp } },
                {
                  updatedAt: afterCursor.timestamp,
                  _id: { $gt: afterCursor.id },
                },
              ],
            }
            : beforeCursor
            ? {
              $or: [
                { timestamp: { $lt: beforeCursor.timestamp } },
                {
                  timestamp: beforeCursor.timestamp,
                  _id: { $lt: beforeCursor.id },
                },
              ],
            }
            : null;
          const query = {
            $and: [
              channelFilter,
              ...(cursorFilter ? [cursorFilter] : []),
              ...(afterCursor
                ? []
                : [{
                  $or: [
                    { status: "active" },
                    { status: { $exists: false } },
                  ],
                }]),
            ],
          };
          const sort = afterCursor
            ? { updatedAt: 1 as const, _id: 1 as const }
            : { timestamp: -1 as const, _id: -1 as const };
          let initialSyncCursor: string | null = null;
          if (!afterCursor) {
            const latestChange = await db.collection("stream_chat")
              .find(
                {
                  ...channelFilter,
                  updatedAt: { $type: "date" },
                },
                { projection: { _id: 1, updatedAt: 1 } },
              )
              .sort({ updatedAt: -1, _id: -1 })
              .limit(1)
              .next();
            if (latestChange?.updatedAt instanceof Date) {
              initialSyncCursor = encodeCommentCursor(
                latestChange.updatedAt,
                latestChange._id,
              );
            }
          }
          const rows = await db.collection("stream_chat")
            .find(query)
            .sort(sort)
            .limit(pageLimit + 1)
            .toArray();
          const hasMore = rows.length > pageLimit;
          const comments = rows.slice(0, pageLimit);
          const last = comments.at(-1);
          const lastTimestamp = last
            ? (afterCursor
              ? (last.updatedAt ?? last.timestamp)
              : last.timestamp)
            : null;
          const cursor = last && lastTimestamp instanceof Date
            ? encodeCommentCursor(lastTimestamp, last._id)
            : null;
          actionResult = {
            comments: comments.map((comment) =>
              serializeComment(comment as Record<string, unknown>)
            ),
            hasMore,
            nextCursor: afterCursor ? null : cursor,
            syncCursor: afterCursor ? cursor : initialSyncCursor,
          };
          mongoSuccess = true;
        } else if (action === "edit_comment") {
          const cleanText = text?.trim() ?? "";
          if (!cleanText) {
            return json({ error: "Comment text is required" }, 400);
          }
          const editedAt = new Date();
          const edited = await db.collection("stream_chat").findOneAndUpdate(
            {
              $and: [
                {
                  _id: new ObjectId(commentId),
                  userId,
                },
                { $or: [{ channelId }, { channelName: channelId }] },
                {
                  $or: [
                    { status: "active" },
                    { status: { $exists: false } },
                  ],
                },
              ],
            },
            {
              $set: {
                channelId,
                status: "active",
                text: cleanText.slice(0, COMMENT_MAX_LENGTH),
                editedAt,
                updatedAt: editedAt,
              },
            },
            { returnDocument: "after" },
          );
          if (!edited) {
            return json(
              { error: "Comment was not found or cannot be edited" },
              404,
            );
          }
          actionResult = serializeComment(
            edited as unknown as Record<string, unknown>,
          );
          mongoSuccess = true;
        } else if (action === "delete_comment") {
          const targetId = new ObjectId(commentId);
          const existingComment = await db.collection("stream_chat").findOne({
            _id: targetId,
            $or: [{ channelId }, { channelName: channelId }],
          });
          if (!existingComment) {
            return json({ error: "Comment was not found" }, 404);
          }
          const stream = await streams.findOne(
            { channelId },
            { projection: { hostId: 1 } },
          );
          if (
            existingComment.userId !== userId &&
            stream?.hostId !== userId
          ) {
            return json({ error: "You cannot delete this comment" }, 403);
          }
          const deletedAt = new Date();
          const deleted = await db.collection("stream_chat").findOneAndUpdate(
            {
              _id: targetId,
              $or: [{ channelId }, { channelName: channelId }],
            },
            {
              $set: {
                channelId,
                status: "deleted",
                text: "",
                deletedAt,
                updatedAt: deletedAt,
                deletedBy: userId,
              },
            },
            { returnDocument: "after" },
          );
          actionResult = serializeComment(
            deleted as unknown as Record<string, unknown>,
          );
          mongoSuccess = true;
        } else if (action === "report_comment") {
          const targetId = new ObjectId(commentId);
          const existingComment = await db.collection("stream_chat").findOne({
            _id: targetId,
            $or: [{ channelId }, { channelName: channelId }],
          });
          if (
            !existingComment ||
            (existingComment.status !== undefined &&
              existingComment.status !== "active")
          ) {
            return json({ error: "Comment is unavailable" }, 404);
          }
          if (existingComment.userId === userId) {
            return json({ error: "You cannot report your own comment" }, 400);
          }
          const reportedAt = new Date();
          await db.collection("stream_comment_reports").updateOne(
            { channelId, commentId: targetId, reporterId: userId },
            {
              $setOnInsert: {
                channelId,
                commentId: targetId,
                commentAuthorId: existingComment.userId,
                reporterId: userId,
                reason: reason?.trim().slice(0, 500) || "inappropriate",
                status: "pending",
                createdAt: reportedAt,
              },
            },
            { upsert: true },
          );
          const reportCount = await db.collection("stream_comment_reports")
            .countDocuments({ channelId, commentId: targetId });
          if (reportCount >= 3) {
            await db.collection("stream_chat").updateOne(
              {
                _id: targetId,
                $or: [{ channelId }, { channelName: channelId }],
                $and: [
                  {
                    $or: [
                      { status: "active" },
                      { status: { $exists: false } },
                    ],
                  },
                ],
              },
              {
                $set: {
                  channelId,
                  status: "hidden",
                  moderationReason: "community_reports",
                  moderatedAt: reportedAt,
                  updatedAt: reportedAt,
                },
              },
            );
          }
          actionResult = { reported: true, reportCount };
          mongoSuccess = true;
        } else if (action === "moderate_comment") {
          const stream = await streams.findOne(
            { channelId },
            { projection: { hostId: 1 } },
          );
          if (!stream || stream.hostId !== userId) {
            return json(
              { error: "Only the stream host can moderate comments" },
              403,
            );
          }
          const moderatedAt = new Date();
          const nextStatus = moderationAction === "hide" ? "hidden" : "active";
          const moderated = await db.collection("stream_chat").findOneAndUpdate(
            {
              _id: new ObjectId(commentId),
              status: { $ne: "deleted" },
              $or: [{ channelId }, { channelName: channelId }],
            },
            {
              $set: {
                channelId,
                status: nextStatus,
                moderationReason: reason?.trim().slice(0, 500) || "host_action",
                moderatedAt,
                moderatedBy: userId,
                updatedAt: moderatedAt,
              },
            },
            { returnDocument: "after" },
          );
          if (!moderated) {
            return json({ error: "Comment was not found" }, 404);
          }
          await db.collection("stream_comment_moderation").insertOne({
            channelName: channelId,
            channelId,
            commentId: new ObjectId(commentId),
            moderatorId: userId,
            action: moderationAction,
            reason: reason?.trim().slice(0, 500) || "host_action",
            createdAt: moderatedAt,
          });
          actionResult = serializeComment(
            moderated as unknown as Record<string, unknown>,
          );
          mongoSuccess = true;
        } else if (action === "send_reaction") {
          const liveStream = await streams.findOne({ channelId, status: "live" });
          if (!liveStream) {
            return json({ error: "This live stream has ended" }, 410);
          }
          const reactedAt = new Date();
          const reaction = {
            channelId,
            userId,
            userName: userName?.trim() || "Viewer",
            avatar: metadata.avatar ?? "",
            type: reactionType,
            timestamp: reactedAt,
          };
          const reactionResult = await db.collection("stream_reactions").insertOne(reaction);
          const increments: Record<string, number> = {
            [`reactionCounts.${reactionType}`]: 1,
          };
          if (reactionType === "like") increments.likes = 1;
          await streams.updateOne(
            { channelId, status: "live" },
            { $inc: increments, $set: { updatedAt: reactedAt } },
          );
          await insertStreamEvent(db, {
            ...reaction,
            type: "live_reaction",
            data: { reactionType, userName: reaction.userName, avatar: reaction.avatar },
          });
          actionResult = {
            id: reactionResult.insertedId.toString(),
            reactionType,
            summary: await liveSummary(db, channelId!),
          };
          mongoSuccess = true;
        } else if (action === "record_share") {
          const liveStream = await streams.findOne({ channelId, status: "live" });
          if (!liveStream) {
            return json({ error: "This live stream has ended" }, 410);
          }
          await streams.updateOne(
            { channelId, status: "live" },
            { $inc: { shares: 1 }, $set: { updatedAt: new Date() } },
          );
          actionResult = { summary: await liveSummary(db, channelId!) };
          mongoSuccess = true;
        } else if (action === "poll_event") {
          const polledAt = new Date();
          const liveStream = await streams.findOne({ channelId, status: "live" });
          if (!liveStream) {
            return json({ error: "This live stream has ended" }, 410);
          }
          const isHostHeartbeat = liveStream.hostId === userId;
          if (isHostHeartbeat) {
            const hostPresence = await db.collection("stream_viewers").findOne({
              channelId,
              userId,
              active: true,
            });
            const lastHostSignal =
              liveStream.lastHeartbeatAt ??
              hostPresence?.lastSeenAt ??
              liveStream.startedAt;
            const activeSince = new Date(
              polledAt.getTime() - HOST_ACTIVE_WINDOW_MS,
            );
            if (!(lastHostSignal instanceof Date) || lastHostSignal < activeSince) {
              await streams.updateOne(
                { _id: liveStream._id, status: "live" },
                {
                  $set: {
                    status: "ended",
                    endedAt: polledAt,
                    endedReason: "host_heartbeat_timeout",
                    viewerCount: 0,
                  },
                },
              );
              return json({ error: "This live stream has ended" }, 410);
            }
            await streams.updateOne(
              { _id: liveStream._id, status: "live" },
              {
                $set: {
                  lastHeartbeatAt: polledAt,
                  updatedAt: polledAt,
                },
              },
            );
          } else {
            const lastHostSignal = liveStream.lastHeartbeatAt ?? liveStream.startedAt;
            const activeSince = new Date(
              polledAt.getTime() - HOST_ACTIVE_WINDOW_MS,
            );
            if (!(lastHostSignal instanceof Date) || lastHostSignal < activeSince) {
              return json({ error: "This live stream has ended" }, 410);
            }
          }
          await db.collection("stream_viewers").updateOne(
            { channelId, userId },
            {
              $set: {
                active: true,
                lastSeenAt: polledAt,
                userName: metadata.name ?? "Viewer",
                avatar: metadata.avatar ?? "",
                role: role === "publisher" ? "cohost" : (role === "host" ? "host" : "viewer"),
              },
              $setOnInsert: { joinedAt: polledAt, channelId, userId },
              $unset: { leftAt: "" },
            },
            { upsert: true },
          );
          const parsedEventCursor = Number(eventCursor ?? 0);
          const [events, streamState, summary, eventCounter] = await Promise.all([
            usesConfirmedLifecycle && eventCursor != null
              ? db.collection("stream_events")
                .find({ channelId, sequence: { $gt: parsedEventCursor } })
                .sort({ sequence: 1 })
                .limit(50)
                .toArray()
              : usesConfirmedLifecycle
              ? Promise.resolve([])
              : db.collection("stream_events")
                .find({ channelId })
                .sort({ timestamp: -1, _id: -1 })
                .limit(1)
                .toArray(),
            db.collection("stream_metadata").findOne(
              { channelId },
              { projection: { _id: 0, pinnedProduct: 1 } },
            ),
            liveSummary(db, channelId!),
            db.collection("stream_event_counters").findOne({ channelId }),
          ]);
          const pinnedProduct = streamState?.pinnedProduct ?? null;
          if (usesConfirmedLifecycle) {
            let nextEventCursor = eventCursor ??
              String(eventCounter?.sequence ?? 0);
            if (events.length > 0) {
              const lastEvent = events.at(-1)!;
              nextEventCursor = String(lastEvent.sequence ?? nextEventCursor);
            }
            actionResult = {
              events: events.map((event) => {
                const { _id, ...eventData } = event;
                return {
                  id: _id.toString(),
                  ...eventData,
                  cursor: String(event.sequence ?? nextEventCursor),
                };
              }),
              eventCursor: nextEventCursor,
              pinnedProduct,
              summary,
            };
          } else if (events.length > 0) {
            const { _id, ...eventData } = events[0];
            actionResult = {
              id: _id.toString(),
              ...eventData,
              pinnedProduct,
              summary,
            };
          } else {
            actionResult = { pinnedProduct, summary };
          }
          mongoSuccess = true;
        }
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("MongoDB operation failed:", msg);
        mongoErrorMsg = msg;
      }
    } else if (!MONGO_URI) {
      mongoErrorMsg = "MONGO_URI is not configured";
    }

    // ── Route responses ───────────────────────────────────────────────────────

    if (action === "start") {
      if (!mongoSuccess) {
        return json(
          { error: "Live session preparation is temporarily unavailable" },
          503,
        );
      }
      const token = await buildLiveKitToken(channelId!, userId!, true);
      return json({
        token,
        url:          LIVEKIT_URL,
        streamId:     newStreamId,
        status:       usesConfirmedLifecycle ? "prepared" : "live",
      });
    }

    if (action === "join") {
      if (!mongoSuccess) {
        return json(
          { error: "Live session validation is temporarily unavailable" },
          503,
        );
      }
      const canPublish = role === "publisher";
      const identity   = userId?.trim() || `guest_${crypto.randomUUID()}`;
      const token      = await buildLiveKitToken(channelId!, identity, canPublish);
      return json({
        token,
        url:          LIVEKIT_URL,
        status:       "ready",
      });
    }

    if (action === "list_active") {
      if (!mongoSuccess) {
        return json({ error: "Live discovery is temporarily unavailable" }, 503);
      }
      return json(activeStreams);
    }

    if (action === "stop") {
      if (!mongoSuccess) {
        return json({ error: "Live stop could not be confirmed" }, 503);
      }
      return json({ status: "stopped", data: actionResult });
    }

    if (
      [
        "pin_product",
        "unpin_product",
        "confirm_start",
        "abort_start",
        "confirm_join",
        "leave",
        "fetch_stream_state",
        "cohost_request",
        "cohost_cancel",
        "cohost_decision",
        "cohost_invite",
        "cohost_invite_response",
        "cohost_leave",
        "send_comment",
        "fetch_comments",
        "edit_comment",
        "delete_comment",
        "report_comment",
        "moderate_comment",
        "send_reaction",
        "record_share",
        "poll_event",
      ].includes(action)
    ) {
      if (!mongoSuccess) {
        return json(
          { error: "Live engagement service is temporarily unavailable" },
          503,
        );
      }
      return json({ success: true, data: actionResult });
    }

    // Unreachable after whitelist check but satisfies TypeScript
    return json({ error: "Unhandled action" }, 400);

  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : "Internal Server Error";
    return json({ error: msg }, 500);
  }
});
