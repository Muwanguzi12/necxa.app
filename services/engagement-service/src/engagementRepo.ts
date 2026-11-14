import type { Db } from 'mongodb';

export type EngagementEntityType = 'post' | 'product';

function entityFilter(entityType: EngagementEntityType, entityId: string) {
  return { entityType, entityId };
}

function isDuplicateKey(error: unknown): boolean {
  const value = error as { code?: number; message?: string };
  return value?.code === 11000 || value?.message?.includes('duplicate key') === true;
}

export async function likeEntity(
  db: Db,
  entityType: EngagementEntityType,
  entityId: string,
  userId: string,
) {
  try {
    await db.collection('engagement_likes').insertOne({
      entityType,
      entityId,
      userId,
      createdAt: new Date(),
    });
    await db.collection('engagement_totals').updateOne(
      entityFilter(entityType, entityId),
      {
        $inc: { likes: 1 },
        $setOnInsert: {
          entityType,
          entityId,
          comments: 0,
          views: 0,
          createdAt: new Date(),
        },
        $set: { updatedAt: new Date() },
      },
      { upsert: true },
    );
    return { liked: true, alreadyLiked: false };
  } catch (error) {
    if (!isDuplicateKey(error)) throw error;
    return { liked: true, alreadyLiked: true };
  }
}

export async function unlikeEntity(
  db: Db,
  entityType: EngagementEntityType,
  entityId: string,
  userId: string,
) {
  const removed = await db.collection('engagement_likes').deleteOne({
    entityType,
    entityId,
    userId,
  });
  if (removed.deletedCount > 0) {
    await db.collection('engagement_totals').updateOne(
      entityFilter(entityType, entityId),
      [
        {
          $set: {
            likes: {
              $max: [0, { $subtract: [{ $ifNull: ['$likes', 0] }, 1] }],
            },
            updatedAt: new Date(),
          },
        },
      ],
    );
  }
  return { liked: false, changed: removed.deletedCount > 0 };
}

export async function addEntityComment(
  db: Db,
  entityType: EngagementEntityType,
  entityId: string,
  userId: string,
  text: string,
  idempotencyKey?: string,
) {
  const comments = db.collection('engagement_comments');
  const document = {
    entityType,
    entityId,
    userId,
    text,
    ...(idempotencyKey ? { idempotencyKey } : {}),
    createdAt: new Date(),
  };

  try {
    const result = await comments.insertOne(document);
    await db.collection('engagement_totals').updateOne(
      entityFilter(entityType, entityId),
      {
        $inc: { comments: 1 },
        $setOnInsert: {
          entityType,
          entityId,
          likes: 0,
          views: 0,
          createdAt: new Date(),
        },
        $set: { updatedAt: new Date() },
      },
      { upsert: true },
    );
    return { id: result.insertedId.toString(), ...document };
  } catch (error) {
    if (!isDuplicateKey(error) || !idempotencyKey) throw error;
    const existing = await comments.findOne({
      entityType,
      entityId,
      userId,
      idempotencyKey,
    });
    if (!existing) throw error;
    return {
      id: existing._id.toString(),
      entityType,
      entityId,
      userId,
      text: existing.text,
      idempotencyKey,
      createdAt: existing.createdAt,
    };
  }
}

export async function getEntityEngagement(
  db: Db,
  entityType: EngagementEntityType,
  entityId: string,
  userId?: string,
) {
  const [totals, liked] = await Promise.all([
    db.collection('engagement_totals').findOne(
      entityFilter(entityType, entityId),
      { projection: { _id: 0, likes: 1, comments: 1, views: 1 } },
    ),
    userId
      ? db.collection('engagement_likes').findOne(
          { entityType, entityId, userId },
          { projection: { _id: 1 } },
        )
      : null,
  ]);
  return {
    likes: Number(totals?.likes || 0),
    comments: Number(totals?.comments || 0),
    views: Number(totals?.views || 0),
    likedByUser: Boolean(liked),
  };
}

export async function listEntityComments(
  db: Db,
  entityType: EngagementEntityType,
  entityId: string,
  limit: number,
) {
  const comments = await db
    .collection('engagement_comments')
    .find(
      entityFilter(entityType, entityId),
      { projection: { idempotencyKey: 0 } },
    )
    .sort({ createdAt: -1 })
    .limit(limit)
    .toArray();
  return comments.map(({ _id, ...comment }) => ({
    id: _id.toString(),
    ...comment,
  }));
}
