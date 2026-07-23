import { MongoClient } from "npm:mongodb"
import type { Db } from "npm:mongodb"

type EntityType = "post" | "product"

let databasePromise: Promise<Db | null> | null = null

async function engagementDb(): Promise<Db | null> {
  const uri = Deno.env.get("MONGO_URI")?.trim()
  if (!uri) return null
  if (databasePromise) return databasePromise

  databasePromise = (async () => {
    const client = new MongoClient(uri, {
      appName: "necxa-clever-processor",
      connectTimeoutMS: 5_000,
      serverSelectionTimeoutMS: 5_000,
      maxPoolSize: 5,
      retryReads: true,
      retryWrites: true,
    })
    await client.connect()
    const db = client.db(Deno.env.get("MONGO_ENGAGEMENT_DB") || "necxa_engagement")
    await Promise.all([
      db.collection("engagement_likes").createIndex(
        { entityType: 1, entityId: 1, userId: 1 },
        { unique: true, name: "unique_entity_like" },
      ),
      db.collection("engagement_comments").createIndex(
        { sourceId: 1 },
        {
          unique: true,
          name: "unique_supabase_comment",
          partialFilterExpression: { sourceId: { $type: "string" } },
        },
      ),
      db.collection("engagement_totals").createIndex(
        { entityType: 1, entityId: 1 },
        { unique: true, name: "unique_entity_totals" },
      ),
    ])
    return db
  })().catch((error) => {
    databasePromise = null
    throw error
  })

  return databasePromise
}

export async function mirrorEntityLike(input: {
  entityType?: EntityType
  entityId: string
  userId: string
  liked: boolean
}) {
  const db = await engagementDb()
  if (!db) return false
  const entityType = input.entityType || "post"
  const filter = {
    entityType,
    entityId: input.entityId,
    userId: input.userId,
  }

  if (input.liked) {
    const result = await db.collection("engagement_likes").updateOne(
      filter,
      { $setOnInsert: { ...filter, createdAt: new Date() } },
      { upsert: true },
    )
    if (result.upsertedCount > 0) {
      await db.collection("engagement_totals").updateOne(
        { entityType, entityId: input.entityId },
        {
          $inc: { likes: 1 },
          $set: { updatedAt: new Date() },
          $setOnInsert: {
            entityType,
            entityId: input.entityId,
            comments: 0,
            views: 0,
            createdAt: new Date(),
          },
        },
        { upsert: true },
      )
    }
    return true
  }

  const removed = await db.collection("engagement_likes").deleteOne(filter)
  if (removed.deletedCount > 0) {
    await db.collection("engagement_totals").updateOne(
      { entityType, entityId: input.entityId },
      [{
        $set: {
          likes: { $max: [0, { $subtract: [{ $ifNull: ["$likes", 0] }, 1] }] },
          updatedAt: new Date(),
        },
      }],
    )
  }
  return true
}

export async function mirrorEntityComment(input: {
  entityType?: EntityType
  entityId: string
  userId: string
  text: string
  sourceId: string
  createdAt?: string
}) {
  const db = await engagementDb()
  if (!db) return false
  const entityType = input.entityType || "post"
  const document = {
    entityType,
    entityId: input.entityId,
    userId: input.userId,
    text: input.text,
    sourceId: input.sourceId,
    createdAt: input.createdAt ? new Date(input.createdAt) : new Date(),
  }
  const result = await db.collection("engagement_comments").updateOne(
    { sourceId: input.sourceId },
    { $setOnInsert: document },
    { upsert: true },
  )
  if (result.upsertedCount > 0) {
    await db.collection("engagement_totals").updateOne(
      { entityType, entityId: input.entityId },
      {
        $inc: { comments: 1 },
        $set: { updatedAt: new Date() },
        $setOnInsert: {
          entityType,
          entityId: input.entityId,
          likes: 0,
          views: 0,
          createdAt: new Date(),
        },
      },
      { upsert: true },
    )
  }
  return true
}
