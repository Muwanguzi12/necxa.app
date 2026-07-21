import { MongoClient, Db } from 'mongodb';

let client: MongoClient | null = null;
let db: Db | null = null;

export async function connectMongo(): Promise<Db> {
  if (db) return db;
  const uri = process.env.MONGO_URI || 'mongodb://localhost:27017/necxa_engagement';
  client = new MongoClient(uri, {});
  await client.connect();
  db = client.db();

  // Ensure indexes for deduplication and fast lookups
  try {
    const postLikes = db.collection('post_likes');
    await postLikes.createIndex({ postId: 1, userId: 1 }, { unique: true });

    const comments = db.collection('comments');
    // idempotencyKey index (sparse) to allow idempotent comment creation
    await comments.createIndex({ idempotencyKey: 1 }, { unique: true, sparse: true });

    const engagements = db.collection('post_engagements');
    await engagements.createIndex({ postId: 1 }, { unique: true });
  } catch (err) {
    // index creation failure should not block startup but should be logged by caller
    console.warn('index creation warning', err);
  }

  return db;
}

export async function getDb(): Promise<Db> {
  if (!db) return connectMongo();
  return db;
}

export async function closeMongo(): Promise<void> {
  if (client) {
    await client.close();
    client = null;
    db = null;
  }
}
