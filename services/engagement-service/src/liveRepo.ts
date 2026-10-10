import type { Db } from 'mongodb';

export async function joinLive(db: Db, streamId: string, userId: string) {
  const now = new Date();
  const result = await db.collection('live_members').updateOne(
    { streamId, userId },
    {
      $set: { lastSeenAt: now },
      $setOnInsert: { streamId, userId, joinedAt: now },
    },
    { upsert: true },
  );
  return { joined: true, changed: result.upsertedCount > 0 };
}

export async function leaveLive(db: Db, streamId: string, userId: string) {
  const result = await db.collection('live_members').deleteOne({ streamId, userId });
  return { left: true, changed: result.deletedCount > 0 };
}

export async function addLiveComment(
  db: Db,
  streamId: string,
  userId: string,
  text: string,
) {
  const createdAt = new Date();
  const result = await db.collection('live_comments').insertOne({
    streamId,
    userId,
    text,
    createdAt,
  });
  return {
    id: result.insertedId.toString(),
    streamId,
    userId,
    text,
    createdAt,
  };
}

export async function addLiveReaction(
  db: Db,
  streamId: string,
  userId: string,
  type: string,
) {
  await db.collection('live_reactions').updateOne(
    { streamId, type },
    {
      $inc: { count: 1 },
      $set: { updatedAt: new Date(), lastUserId: userId },
      $setOnInsert: { streamId, type, createdAt: new Date() },
    },
    { upsert: true },
  );
  return { streamId, type, accepted: true };
}

export async function getLiveSummary(db: Db, streamId: string) {
  const [viewers, reactions] = await Promise.all([
    db.collection('live_members').countDocuments({ streamId }),
    db
      .collection('live_reactions')
      .find({ streamId }, { projection: { _id: 0, type: 1, count: 1 } })
      .toArray(),
  ]);
  return {
    viewers,
    reactions: Object.fromEntries(
      reactions.map((reaction) => [reaction.type, Number(reaction.count || 0)]),
    ),
  };
}
