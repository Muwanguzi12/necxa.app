import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { MongoClient } from "npm:mongodb";
import { AccessToken } from "npm:livekit-server-sdk";

// ── Environment ─────────────────────────────────────────────────────────────
const LIVEKIT_URL       = Deno.env.get("LIVEKIT_URL")        ?? "wss://necxa-live-dtb2j623.livekit.cloud";
const LIVEKIT_API_KEY   = Deno.env.get("LIVEKIT_API_KEY")    ?? "";
const LIVEKIT_API_SECRET = Deno.env.get("LIVEKIT_API_SECRET") ?? "";
const MONGO_URI         = Deno.env.get("MONGO_URI")          ?? "";

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
    canSubscribe: true,
  });
  return await at.toJwt();
}

// ── Valid actions whitelist ────────────────────────────────────────────────────
const VALID_ACTIONS = ["start", "join", "stop", "list_active"] as const;
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
      userId,
      role,
      metadata = {},
      location  = {},
    } = body as {
      action: string;
      channelId?: string;
      userId?: string;
      role?: string;
      metadata?: Record<string, unknown>;
      location?: Record<string, unknown>;
    };

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

    // ── Authentication gate for hosts ─────────────────────────────────────────
    if (action === "start") {
      if (!userId?.trim()) {
        return json({ error: "Authentication required to go live." }, 401);
      }
    }

    // ── 2. MongoDB with guaranteed connection cleanup ──────────────────────────
    let mongoSuccess = false;
    let mongoErrorMsg = "";
    let activeStreams: unknown[] = [];
    let newStreamId: string | null = null;

    if (MONGO_URI && (action === "start" || action === "stop" || action === "list_active" || action === "join")) {
      const client = new MongoClient(MONGO_URI, {
        connectTimeoutMS: 5000,
        socketTimeoutMS: 5000,
        serverSelectionTimeoutMS: 5000,
      });

      try {
        await client.connect();
        const db = client.db("necxalive");
        const streams = db.collection("streams");

        if (action === "start") {
          // ── 4. Prevent duplicate live sessions ───────────────────────────────
          const existing = await streams.findOne({ hostId: userId, status: "live" });
          if (existing) {
            return json({ error: "You already have an active stream. Please end it before starting a new one." }, 409);
          }

          // ── 5. Generate unique stream ID ──────────────────────────────────────
          newStreamId = crypto.randomUUID();

          // ── 7. Structured metadata  ───────────────────────────────────────────
          const { title = "Live Session", description = "", thumbnail = "", category = "", tags = [] } = metadata as Record<string, unknown>;

          await streams.insertOne({
            // Identity
            streamId:    newStreamId,
            channelId,
            hostId:      userId,
            status:      "live",

            // Metadata
            title,
            description,
            thumbnail,
            category,
            tags,
            location,

            // Engagement counters
            viewerCount: 0,
            peakViewers: 0,
            likes:       0,
            shares:      0,

            // Recording
            recording:    false,
            recordingId:  null,
            playbackUrl:  null,
            duration:     null,

            // Moderation
            isVerified:  true,
            isReported:  false,
            reportCount: 0,

            // Timestamps
            startedAt: new Date(),
            createdAt: new Date(),
          });

          mongoSuccess = true;

        } else if (action === "join") {
          // Increment viewerCount; keep peakViewers as the all-time high
          const updated = await streams.findOneAndUpdate(
            { channelId, status: "live" },
            { $inc: { viewerCount: 1 } },
            { returnDocument: "after" },
          );
          if (updated) {
            const newCount = (updated as Record<string, unknown>).viewerCount as number;
            await streams.updateOne(
              { channelId, status: "live" },
              { $max: { peakViewers: newCount } },
            );
          }
          mongoSuccess = true;

        } else if (action === "stop") {
          await streams.updateMany(
            { channelId, hostId: userId, status: "live" },
            { $set: { status: "ended", endedAt: new Date() } },
          );
          mongoSuccess = true;

        } else if (action === "list_active") {
          // ── 10. Index-friendly query: status + startedAt compound ─────────────
          activeStreams = await streams
            .find({ status: "live" })
            .sort({ startedAt: -1 })
            .toArray();
          mongoSuccess = true;
        }
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("MongoDB operation failed:", msg);
        mongoErrorMsg = msg;
      } finally {
        // ── 2. Always close — even on error ────────────────────────────────────
        await client.close();
      }
    } else if (!MONGO_URI) {
      mongoErrorMsg = "MONGO_URI is not configured";
    }

    // ── Route responses ───────────────────────────────────────────────────────

    if (action === "start") {
      const token = await buildLiveKitToken(channelId!, userId!, true);
      return json({
        token,
        url:          LIVEKIT_URL,
        streamId:     newStreamId,
        mongo_synced: mongoSuccess,
        mongo_error:  mongoErrorMsg || undefined,
      });
    }

    if (action === "join") {
      const canPublish = role === "publisher";
      const identity   = userId?.trim() || `guest_${crypto.randomUUID()}`;
      const token      = await buildLiveKitToken(channelId!, identity, canPublish);
      return json({
        token,
        url:          LIVEKIT_URL,
        mongo_synced: mongoSuccess,
        mongo_error:  mongoErrorMsg || undefined,
      });
    }

    if (action === "list_active") {
      return json(activeStreams);
    }

    if (action === "stop") {
      return json({
        status:       "stopped",
        mongo_synced: mongoSuccess,
        mongo_error:  mongoErrorMsg || undefined,
      });
    }

    // Unreachable after whitelist check but satisfies TypeScript
    return json({ error: "Unhandled action" }, 400);

  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : "Internal Server Error";
    return json({ error: msg }, 500);
  }
});
