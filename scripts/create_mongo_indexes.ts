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
    // Compound: duplicate session prevention — used by start action
    [{ hostId: 1, status: 1 },     { name: "idx_hostId_status"                       }],
    // TTL: auto-delete ended streams after 90 days
    [{ endedAt: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 90, sparse: true, name: "idx_ttl_endedAt" }],
  ]);

  // ── viewers ──────────────────────────────────────────────────────────────────
  console.log("\n📁  viewers");
  await ensureIndexes(db, "viewers", [
    [{ streamId: 1 }, { name: "idx_viewers_streamId"                             }],
    [{ userId:   1 }, { name: "idx_viewers_userId"                               }],
    // Compound: unique viewer per stream
    [{ streamId: 1, userId: 1 }, { unique: true, name: "idx_viewers_stream_user" }],
    // TTL: remove viewer records 7 days after they left
    [{ leftAt: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 7, sparse: true, name: "idx_viewers_ttl" }],
  ]);

  // ── chat_messages ────────────────────────────────────────────────────────────
  console.log("\n📁  chat_messages");
  await ensureIndexes(db, "chat_messages", [
    [{ streamId:  1  }, { name: "idx_chat_streamId"                              }],
    [{ createdAt: -1 }, { name: "idx_chat_createdAt_desc"                        }],
    // Compound: paginating chat for a specific stream
    [{ streamId: 1, createdAt: -1 }, { name: "idx_chat_stream_time"              }],
    // TTL: auto-delete chat after 30 days
    [{ createdAt: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 30, name: "idx_chat_ttl" }],
  ]);

  // ── reactions ────────────────────────────────────────────────────────────────
  console.log("\n📁  reactions");
  await ensureIndexes(db, "reactions", [
    [{ streamId:  1  }, { name: "idx_reactions_streamId"                         }],
    [{ createdAt: -1 }, { name: "idx_reactions_createdAt"                        }],
    // TTL: auto-delete reactions after 7 days
    [{ createdAt: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 7, name: "idx_reactions_ttl" }],
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
  await ensureIndexes(db, "notifications", [
    [{ userId:     1  }, { name: "idx_notif_userId"                              }],
    [{ read:       1  }, { name: "idx_notif_read"                                }],
    [{ createdAt: -1  }, { name: "idx_notif_createdAt"                           }],
    // Compound: unread notifications per user (most common query)
    [{ userId: 1, read: 1, createdAt: -1 }, { name: "idx_notif_user_unread_time" }],
    // TTL: auto-delete read notifications after 60 days
    [{ createdAt: 1 }, { expireAfterSeconds: 60 * 60 * 24 * 60, name: "idx_notif_ttl" }],
  ]);

  console.log("\n🎉  All indexes applied successfully.");
} catch (e) {
  console.error("❌  Fatal error:", e instanceof Error ? e.message : e);
  Deno.exit(1);
} finally {
  await client.close();
  console.log("🔌  MongoDB connection closed.");
}
