import { MongoClient } from "npm:mongodb"
import type { Db } from "npm:mongodb"

export type EngagementEntityType = "post" | "product"

export type LegacyLike = {
  entityType: EngagementEntityType
  entityId: string
  userId: string
  createdAt?: string
}

export type LegacyComment = {
  entityType: EngagementEntityType
  entityId: string
  userId: string
  text: string
  sourceId: string
  createdAt?: string
}

type EntitySummary = {
  likes: number
  comments: number
  views: number
  likedByUser: boolean
}

let databasePromise: Promise<Db> | null = null

async function engagementDb(): Promise<Db> {
  if (databasePromise) return databasePromise
  const uri = Deno.env.get("MONGO_URI")?.trim()
  if (!uri) throw new Error("MONGO_URI is not configured")

  databasePromise = (async () => {
    const client = new MongoClient(uri, {
      appName: "necxa-edge-engagement",
      family: 4,
      connectTimeoutMS: 5_000,
      serverSelectionTimeoutMS: 5_000,
      maxPoolSize: 8,
      retryReads: true,
      retryWrites: true,
    })
    await client.connect()
    const db = client.db(
      Deno.env.get("MONGO_ENGAGEMENT_DB") || "necxa_engagement",
    )
    await Promise.all([
      db.collection("engagement_likes").createIndex(
        { entityType: 1, entityId: 1, userId: 1 },
        { unique: true, name: "unique_entity_like" },
      ),
      db.collection("engagement_comments").createIndex(
        { entityType: 1, entityId: 1, createdAt: -1 },
        { name: "entity_comments_recent" },
      ),
      db.collection("engagement_comments").createIndex(
        { entityType: 1, entityId: 1, userId: 1, idempotencyKey: 1 },
        {
          unique: true,
          name: "unique_entity_comment_request",
          partialFilterExpression: { idempotencyKey: { $type: "string" } },
        },
      ),
      db.collection("engagement_comments").createIndex(
        { sourceId: 1 },
        {
          unique: true,
          name: "unique_legacy_comment_source",
          partialFilterExpression: { sourceId: { $type: "string" } },
        },
      ),
      db.collection("engagement_totals").createIndex(
        { entityType: 1, entityId: 1 },
        { unique: true, name: "unique_entity_totals" },
      ),
      db.collection("engagement_migrations").createIndex(
        { key: 1 },
        { unique: true, name: "unique_engagement_migration" },
      ),
    ])
    return db
  })().catch((error) => {
    databasePromise = null
    throw error
  })

  return databasePromise
}

async function syncTotals(
  db: Db,
  entityType: EngagementEntityType,
  entityId: string,
) {
  const [likes, comments] = await Promise.all([
    db.collection("engagement_likes").countDocuments({ entityType, entityId }),
    db.collection("engagement_comments").countDocuments({
      entityType,
      entityId,
    }),
  ])
  await db.collection("engagement_totals").updateOne(
    { entityType, entityId },
    {
      $set: {
        entityType,
        entityId,
        likes,
        comments,
        updatedAt: new Date(),
      },
      $setOnInsert: { views: 0, createdAt: new Date() },
    },
    { upsert: true },
  )
  return { likes, comments }
}

export async function toggleEntityLike(input: {
  entityType: EngagementEntityType
  entityId: string
  userId: string
}) {
  const db = await engagementDb()
  const filter = {
    entityType: input.entityType,
    entityId: input.entityId,
    userId: input.userId,
  }
  const existing = await db.collection("engagement_likes").findOne(filter, {
    projection: { _id: 1 },
  })

  let liked: boolean
  if (existing) {
    await db.collection("engagement_likes").deleteOne(filter)
    liked = false
  } else {
    const result = await db.collection("engagement_likes").updateOne(
      filter,
      { $setOnInsert: { ...filter, createdAt: new Date() } },
      { upsert: true },
    )
    liked = result.upsertedCount > 0 || result.matchedCount > 0
  }

  const totals = await syncTotals(db, input.entityType, input.entityId)
  return { liked, likes: totals.likes }
}

export async function createEntityComment(input: {
  entityType: EngagementEntityType
  entityId: string
  userId: string
  text: string
  idempotencyKey?: string
}) {
  const db = await engagementDb()
  const filter = input.idempotencyKey
    ? {
      entityType: input.entityType,
      entityId: input.entityId,
      userId: input.userId,
      idempotencyKey: input.idempotencyKey,
    }
    : null

  if (filter) {
    const existing = await db.collection("engagement_comments").findOne(filter)
    if (existing) {
      const totals = await syncTotals(db, input.entityType, input.entityId)
      return {
        id: existing._id.toString(),
        entityType: existing.entityType,
        entityId: existing.entityId,
        userId: existing.userId,
        text: existing.text,
        createdAt: existing.createdAt,
        commentsCount: totals.comments,
      }
    }
  }

  const document = {
    entityType: input.entityType,
    entityId: input.entityId,
    userId: input.userId,
    text: input.text,
    ...(input.idempotencyKey
      ? { idempotencyKey: input.idempotencyKey }
      : {}),
    createdAt: new Date(),
  }
  const result = await db.collection("engagement_comments").insertOne(document)
  const totals = await syncTotals(db, input.entityType, input.entityId)
  return {
    id: result.insertedId.toString(),
    ...document,
    commentsCount: totals.comments,
  }
}

export async function listEntityComments(input: {
  entityType: EngagementEntityType
  entityId: string
  limit?: number
}) {
  const db = await engagementDb()
  const comments = await db.collection("engagement_comments")
    .find(
      { entityType: input.entityType, entityId: input.entityId },
      { projection: { idempotencyKey: 0 } },
    )
    .sort({ createdAt: -1 })
    .limit(Math.min(Math.max(input.limit ?? 50, 1), 100))
    .toArray()
  return comments.map(({ _id, ...comment }) => ({
    id: _id.toString(),
    ...comment,
  }))
}

export async function getEntitySummaries(input: {
  entityType: EngagementEntityType
  entityIds: string[]
  userId?: string
}) {
  const ids = [...new Set(input.entityIds.filter(Boolean))]
  const summaries = new Map<string, EntitySummary>()
  if (ids.length === 0) return summaries

  const db = await engagementDb()
  const [totals, likes] = await Promise.all([
    db.collection("engagement_totals")
      .find(
        { entityType: input.entityType, entityId: { $in: ids } },
        { projection: { _id: 0, entityId: 1, likes: 1, comments: 1, views: 1 } },
      )
      .toArray(),
    input.userId
      ? db.collection("engagement_likes")
        .find(
          {
            entityType: input.entityType,
            entityId: { $in: ids },
            userId: input.userId,
          },
          { projection: { _id: 0, entityId: 1 } },
        )
        .toArray()
      : [],
  ])
  const likedIds = new Set(likes.map((like) => String(like.entityId)))
  for (const id of ids) {
    const total = totals.find((entry) => String(entry.entityId) === id)
    summaries.set(id, {
      likes: Number(total?.likes || 0),
      comments: Number(total?.comments || 0),
      views: Number(total?.views || 0),
      likedByUser: likedIds.has(id),
    })
  }
  return summaries
}

export async function deleteEntityEngagement(input: {
  entityType: EngagementEntityType
  entityId: string
}) {
  const db = await engagementDb()
  await Promise.all([
    db.collection("engagement_likes").deleteMany(input),
    db.collection("engagement_comments").deleteMany(input),
    db.collection("engagement_totals").deleteOne(input),
  ])
}

export async function importLegacyEngagement(input: {
  likes: LegacyLike[]
  comments: LegacyComment[]
}) {
  const db = await engagementDb()
  if (input.likes.length > 0) {
    await db.collection("engagement_likes").bulkWrite(
      input.likes.map((like) => ({
        updateOne: {
          filter: {
            entityType: like.entityType,
            entityId: like.entityId,
            userId: like.userId,
          },
          update: {
            $setOnInsert: {
              entityType: like.entityType,
              entityId: like.entityId,
              userId: like.userId,
              createdAt: like.createdAt
                ? new Date(like.createdAt)
                : new Date(),
            },
          },
          upsert: true,
        },
      })),
      { ordered: false },
    )
  }

  if (input.comments.length > 0) {
    await db.collection("engagement_comments").bulkWrite(
      input.comments.map((comment) => ({
        updateOne: {
          filter: { sourceId: comment.sourceId },
          update: {
            $setOnInsert: {
              entityType: comment.entityType,
              entityId: comment.entityId,
              userId: comment.userId,
              text: comment.text,
              sourceId: comment.sourceId,
              createdAt: comment.createdAt
                ? new Date(comment.createdAt)
                : new Date(),
            },
          },
          upsert: true,
        },
      })),
      { ordered: false },
    )
  }

  const affected = new Map<string, {
    entityType: EngagementEntityType
    entityId: string
  }>()
  for (const item of [...input.likes, ...input.comments]) {
    affected.set(`${item.entityType}:${item.entityId}`, {
      entityType: item.entityType,
      entityId: item.entityId,
    })
  }
  for (const entity of affected.values()) {
    await syncTotals(db, entity.entityType, entity.entityId)
  }

  await db.collection("engagement_migrations").updateOne(
    { key: "supabase-community-v1" },
    {
      $set: {
        key: "supabase-community-v1",
        likesProcessed: input.likes.length,
        commentsProcessed: input.comments.length,
        completedAt: new Date(),
      },
    },
    { upsert: true },
  )
  return {
    likesProcessed: input.likes.length,
    commentsProcessed: input.comments.length,
    entitiesRecounted: affected.size,
  }
}
