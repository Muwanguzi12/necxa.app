/**
 * necxa-live — MongoDB Index Setup
 * Run once to create all production indexes across every NECXA Live collection.
 *
 * Usage:
 *   $env:MONGO_URI = "mongodb+srv://knestars_db_user:<password>@necxa-cluster..."
 *   deno run --allow-net --allow-env scripts/create_mongo_indexes.ts
 */

import { MongoClient } from "npm:mongodb";

const MONGO_URI = Deno.env.get("MONGO_URI");
if (!MONGO_URI) {
  console.error("❌  MONGO_URI environment variable is not set.");
  Deno.exit(1);
}

const client = new MongoClient(MONGO_URI);

async function ensureIndexes(
  db: ReturnType<MongoClient["db"]>,
  collectionName: string,
  indexes: Parameters<ReturnType<ReturnType<MongoClient["db"]>["collection"]>["createIndex"]>[],
) {
  const col = db.collection(collectionName);
  for (const [keySpec, opts] of indexes) {
    try {
      await col.createIndex(keySpec, opts ?? {});
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // "IndexAlreadyExists" is safe to ignore
      if (!msg.includes("already exists") && !msg.includes("IndexOptionsConflict")) {
        console.warn(`  ⚠️  [${collectionName}] ${msg}`);
      }
    }
  }
  const list = await col.listIndexes().toArray();
  console.log(`  ✅  ${collectionName}: ${list.length} indexes`);
}

try {
  await client.connect();
  console.log("✅  Connected to MongoDB — necxalive\n");
  const db = client.db("necxalive");

  // ── streams ─────────────────────────────────────────────────────────────────
  console.log("📁  streams");
  await ensureIndexes(db, "streams", [
    [{ streamId:   1 }, { unique: true, sparse: true, name: "idx_streamId_unique"    }],
    [{ hostId:     1 }, { name: "idx_hostId"                                          }],
    [{ channelId:  1 }, { name: "idx_channelId"                                       }],
    [{ status:     1 }, { name: "idx_status"                                          }],
    [{ startedAt: -1 }, { name: "idx_startedAt_desc"                                  }],
    // Compound: active stream listing — used by list_active
    [{ status: 1, startedAt: -1 }, { name: "idx_status_startedAt"                   }],
    [{ status: 1, lastHeartbeatAt: 1 }, { name: "idx_status_heartbeat"              }],
    [{ status: 1, prepareExpiresAt: 1 }, { name: "idx_status_prepare_expiry"         }],
    // Compound: duplicate session prevention — used by start action
    [{ hostId: 1, status: 1 },     { name: "idx_hostId_status"                       }],
    // TTL: auto-delete ended streams after 90 days
    [{ endedAt: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 90, sparse: true, name: "idx_ttl_endedAt" }],
  ]);

  // ── viewers ──────────────────────────────────────────────────────────────────
  console.log("\n📁  viewers");
  await ensureIndexes(db, "stream_viewers", [
    [{ channelId: 1 }, { name: "idx_viewers_channelId"                           }],
    [{ userId:   1 }, { name: "idx_viewers_userId"                               }],
    // Compound: unique viewer per stream
    [{ channelId: 1, userId: 1 }, { unique: true, name: "idx_viewers_channel_user" }],
    [{ channelId: 1, active: 1, lastSeenAt: -1 }, { name: "idx_viewers_active"    }],
    [
      { channelId: 1, active: 1, normalizedUsername: 1, lastSeenAt: -1 },
      { name: "idx_viewers_online_username" },
    ],
    // TTL: remove viewer records 7 days after they left
    [{ leftAt: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 7, sparse: true, name: "idx_viewers_ttl" }],
  ]);

  // ── chat_messages ────────────────────────────────────────────────────────────
  console.log("\n📁  chat_messages");
  await db.collection("stream_chat").updateMany(
    { channelId: { $exists: false }, channelName: { $type: "string" } },
    [
      {
        $set: {
          channelId: "$channelName",
          status: { $ifNull: ["$status", "active"] },
          createdAt: { $ifNull: ["$createdAt", "$timestamp"] },
          updatedAt: { $ifNull: ["$updatedAt", "$timestamp"] },
        },
      },
    ],
  );
  await ensureIndexes(db, "stream_chat", [
    [{ channelName: 1  }, { name: "idx_chat_channel"                              }],
    [{ channelId: 1  }, { name: "idx_chat_channel_id"                             }],
    [{ timestamp: -1 }, { name: "idx_chat_timestamp_desc"                        }],
    // Compound: paginating chat for a specific stream
    [{ channelName: 1, timestamp: -1 }, { name: "idx_chat_channel_time"           }],
    [{ channelId: 1, timestamp: -1, _id: -1 }, { name: "idx_chat_page_cursor"     }],
    [{ channelId: 1, updatedAt: 1, _id: 1 }, { name: "idx_chat_sync_cursor"       }],
    [
      { channelId: 1, userId: 1, clientRequestId: 1 },
      {
        unique: true,
        name: "idx_chat_idempotency",
        partialFilterExpression: { clientRequestId: { $type: "string" } },
      },
    ],
    // TTL: auto-delete chat after 30 days
    [{ timestamp: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 30, name: "idx_chat_ttl" }],
  ]);

  console.log("\nðŸ“  stream_comment_reports");
  await ensureIndexes(db, "stream_comment_reports", [
    [
      { channelId: 1, commentId: 1, reporterId: 1 },
      { unique: true, name: "idx_comment_report_unique" },
    ],
    [
      { channelId: 1, status: 1, createdAt: -1 },
      { name: "idx_comment_reports_moderation" },
    ],
  ]);

  console.log("\nðŸ“  stream_comment_moderation");
  await ensureIndexes(db, "stream_comment_moderation", [
    [
      { channelId: 1, commentId: 1, createdAt: -1 },
      { name: "idx_comment_moderation_history" },
    ],
  ]);

  // ── reactions ────────────────────────────────────────────────────────────────
  console.log("\n📁  reactions");
  await ensureIndexes(db, "stream_reactions", [
    [{ channelId:  1  }, { name: "idx_reactions_channel"                         }],
    [{ timestamp: -1 }, { name: "idx_reactions_timestamp"                        }],
    [{ channelId: 1, timestamp: -1 }, { name: "idx_reactions_channel_time"       }],
    // TTL: auto-delete reactions after 7 days
    [{ timestamp: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 7, name: "idx_reactions_ttl" }],
  ]);

  // ── gifts ────────────────────────────────────────────────────────────────────
  console.log("\n📁  gifts");
  await ensureIndexes(db, "gifts", [
    [{ streamId:    1  }, { name: "idx_gifts_streamId"                           }],
    [{ receiverId:  1  }, { name: "idx_gifts_receiverId"                         }],
    [{ senderId:    1  }, { name: "idx_gifts_senderId"                           }],
    [{ createdAt:  -1  }, { name: "idx_gifts_createdAt"                          }],
    // Compound: leaderboard — top gifters per stream
    [{ streamId: 1, senderId: 1 }, { name: "idx_gifts_stream_sender"             }],
  ]);

  // ── notifications ────────────────────────────────────────────────────────────
  console.log("\n📁  notifications");
  // Live commerce state and the event poll are keyed by channel.
  await ensureIndexes(db, "stream_metadata", [
    [{ channelId: 1 }, { unique: true, name: "idx_stream_metadata_channel" }],
  ]);
  await ensureIndexes(db, "stream_events", [
    [
      { channelId: 1, timestamp: -1 },
      { name: "idx_stream_events_channel_time" },
    ],
    [
      { channelId: 1, timestamp: 1, _id: 1 },
      { name: "idx_stream_events_cursor" },
    ],
    [
      { channelId: 1, sequence: 1 },
      {
        unique: true,
        name: "idx_stream_events_sequence",
        partialFilterExpression: { sequence: { $type: "number" } },
      },
    ],
    [
      { timestamp: 1 },
      {
        expireAfterSeconds: 60 * 60 * 24 * 7,
        name: "idx_stream_events_ttl",
      },
    ],
  ]);
  await ensureIndexes(db, "stream_event_counters", [
    [
      { channelId: 1 },
      { unique: true, name: "idx_stream_event_counter_channel" },
    ],
  ]);
  await ensureIndexes(db, "stream_guest_requests", [
    [
      { channelId: 1, guestId: 1 },
      { unique: true, name: "idx_guest_request_channel_guest" },
    ],
    [
      { channelId: 1, hostId: 1, status: 1, updatedAt: -1 },
      { name: "idx_guest_request_host_queue" },
    ],
    [
      { channelId: 1, guestId: 1, status: 1 },
      { name: "idx_guest_request_guest_state" },
    ],
    [
      { expiresAt: 1 },
      {
        expireAfterSeconds: 0,
        name: "idx_guest_request_ttl",
      },
    ],
  ]);

  await ensureIndexes(db, "notifications", [
    [{ userId:     1  }, { name: "idx_notif_userId"                              }],
    [{ read:       1  }, { name: "idx_notif_read"                                }],
    [{ createdAt: -1  }, { name: "idx_notif_createdAt"                           }],
    // Compound: unread notifications per user (most common query)
    [{ userId: 1, read: 1, createdAt: -1 }, { name: "idx_notif_user_unread_time" }],
    // TTL: auto-delete read notifications after 60 days
    [{ createdAt: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 60, name: "idx_notif_ttl" }],
  ]);

  // Engagement data lives separately from ephemeral live-stream data so live
  // retention policies can never remove post or product interactions.
  const engagementDb = client.db("necxa_engagement");
  console.log("\nEngagement database: necxa_engagement");
  await ensureIndexes(engagementDb, "engagement_likes", [
    [
      { entityType: 1, entityId: 1, userId: 1 },
      { unique: true, name: "unique_entity_like" },
    ],
  ]);
  await ensureIndexes(engagementDb, "engagement_comments", [
    [
      { entityType: 1, entityId: 1, createdAt: -1 },
      { name: "entity_comments_recent" },
    ],
    [
      { entityType: 1, entityId: 1, userId: 1, idempotencyKey: 1 },
      {
        unique: true,
        name: "unique_entity_comment_request",
        partialFilterExpression: { idempotencyKey: { $type: "string" } },
      },
    ],
    [
      { sourceId: 1 },
      {
        unique: true,
        name: "unique_legacy_comment_source",
        partialFilterExpression: { sourceId: { $type: "string" } },
      },
    ],
  ]);
  await ensureIndexes(engagementDb, "engagement_totals", [
    [
      { entityType: 1, entityId: 1 },
      { unique: true, name: "unique_entity_totals" },
    ],
  ]);
  await ensureIndexes(engagementDb, "engagement_migrations", [
    [
      { key: 1 },
      { unique: true, name: "unique_engagement_migration" },
    ],
  ]);

  console.log("\nAll indexes applied successfully.");
} catch (e) {
  console.error("❌  Fatal error:", e instanceof Error ? e.message : e);
  Deno.exit(1);
} finally {
  await client.close();
  console.log("🔌  MongoDB connection closed.");
}
