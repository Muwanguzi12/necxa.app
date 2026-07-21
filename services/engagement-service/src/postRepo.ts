import { Db } from 'mongodb';
import { ObjectId } from 'mongodb';

export async function likePost(db: Db, postId: string, userId: string, idempotencyKey?: string) {
  const likesCol = db.collection('post_likes');
  const engagements = db.collection('post_engagements');

  try {
    const doc: any = { postId, userId, createdAt: new Date() };
    if (idempotencyKey) doc.idempotencyKey = idempotencyKey;
    // try to insert a like document — unique index on (postId,userId) prevents duplicates
    await likesCol.insertOne(doc);
    // increment aggregate counter
    const res = await engagements.findOneAndUpdate(
      { postId },
      { $inc: { likes: 1 }, $setOnInsert: { postId, createdAt: new Date() } },
      { upsert: true, returnDocument: 'after' }
    );

    return { postId, liked: true, likes: res.value?.likes || 1 };
  } catch (err: any) {
    // duplicate like — return existing counts
    if (err && (err.code === 11000 || (err.message && err.message.includes('duplicate key')))) {
      const agg = await engagements.findOne({ postId });
      return { postId, liked: false, alreadyLiked: true, likes: agg?.likes || 0 };
    }
    throw err;
  }
}

export async function commentPost(db: Db, postId: string, userId: string, text: string, idempotencyKey?: string) {
  const comments = db.collection('comments');
  const engagements = db.collection('post_engagements');

  try {
    const doc: any = { postId, userId, text, createdAt: new Date() };
    if (idempotencyKey) doc.idempotencyKey = idempotencyKey;

    const r = await comments.insertOne(doc);
    await engagements.updateOne(
      { postId },
      { $inc: { comments: 1 }, $setOnInsert: { postId, createdAt: new Date() } },
      { upsert: true }
    );
    return { id: r.insertedId.toString(), postId, text };
  } catch (err: any) {
    // If idempotencyKey caused the duplicate, return the existing comment
    if (err && (err.code === 11000 || (err.message && err.message.includes('duplicate key')))) {
      if (!idempotencyKey) throw err;
      const existing = await comments.findOne({ idempotencyKey });
      if (existing) return { id: existing._id.toString(), postId: existing.postId, text: existing.text };
    }
    throw err;
  }
}

export async function getEngagement(db: Db, postId: string) {
  const col = db.collection('post_engagements');
  const doc = await col.findOne({ postId });
  return doc || { postId, likes: 0, comments: 0, views: 0 };
}
