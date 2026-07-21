import { Db } from 'mongodb';
import { ObjectId } from 'mongodb';

export async function likePost(db: Db, postId: string, userId: string) {
  const col = db.collection('post_engagements');
  const res = await col.findOneAndUpdate(
    { postId },
    { $inc: { likes: 1 }, $setOnInsert: { postId, createdAt: new Date() } },
    { upsert: true, returnDocument: 'after' }
  );
  // Optionally record who liked (skipped for performance here)
  return res.value || { postId, likes: 1 };
}

export async function commentPost(db: Db, postId: string, userId: string, text: string) {
  const comments = db.collection('comments');
  const r = await comments.insertOne({ postId, userId, text, createdAt: new Date() });
  const col = db.collection('post_engagements');
  await col.updateOne({ postId }, { $inc: { comments: 1 }, $setOnInsert: { postId, createdAt: new Date() } }, { upsert: true });
  return { id: r.insertedId.toString(), postId, text };
}

export async function getEngagement(db: Db, postId: string) {
  const col = db.collection('post_engagements');
  const doc = await col.findOne({ postId });
  return doc || { postId, likes: 0, comments: 0, views: 0 };
}
