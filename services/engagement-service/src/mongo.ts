import { MongoClient, Db } from 'mongodb';

let client: MongoClient | null = null;
let db: Db | null = null;
let connection: Promise<Db> | null = null;

function requiredMongoUri(): string {
  const uri = process.env.MONGO_URI?.trim();
  if (uri) return uri;
  if (process.env.NODE_ENV === 'development' || process.env.NODE_ENV === 'test') {
    return 'mongodb://127.0.0.1:27017/necxa_engagement';
  }
  throw new Error('MONGO_URI is required');
}

async function ensureIndexes(database: Db): Promise<void> {
  await Promise.all([
    database.collection('engagement_likes').createIndex(
      { entityType: 1, entityId: 1, userId: 1 },
      { unique: true, name: 'unique_entity_like' },
    ),
    database.collection('engagement_comments').createIndex(
      { entityType: 1, entityId: 1, createdAt: -1 },
      { name: 'entity_comments_recent' },
    ),
    database.collection('engagement_comments').createIndex(
      { entityType: 1, entityId: 1, userId: 1, idempotencyKey: 1 },
      {
        unique: true,
        name: 'unique_comment_request',
        partialFilterExpression: { idempotencyKey: { $type: 'string' } },
      },
    ),
    database.collection('engagement_totals').createIndex(
      { entityType: 1, entityId: 1 },
      { unique: true, name: 'unique_entity_totals' },
    ),
    database.collection('live_members').createIndex(
      { streamId: 1, userId: 1 },
      { unique: true, name: 'unique_live_member' },
    ),
    database.collection('live_comments').createIndex(
      { streamId: 1, createdAt: -1 },
      { name: 'live_comments_recent' },
    ),
    database.collection('live_reactions').createIndex(
      { streamId: 1, type: 1 },
      { unique: true, name: 'unique_live_reaction_total' },
    ),
  ]);
}

export async function connectMongo(): Promise<Db> {
  if (db) return db;
  if (connection) return connection;

  connection = (async () => {
    const nextClient = new MongoClient(requiredMongoUri(), {
      appName: 'necxa-engagement-service',
      connectTimeoutMS: 10_000,
      serverSelectionTimeoutMS: 10_000,
      maxPoolSize: Number(process.env.MONGO_MAX_POOL_SIZE || 20),
      minPoolSize: Number(process.env.MONGO_MIN_POOL_SIZE || 1),
      retryReads: true,
      retryWrites: true,
    });
    await nextClient.connect();
    const database = nextClient.db(
      process.env.MONGO_DB_NAME?.trim() || 'necxa_engagement',
    );
    await database.command({ ping: 1 });
    await ensureIndexes(database);
    client = nextClient;
    db = database;
    return database;
  })();

  try {
    return await connection;
  } catch (error) {
    connection = null;
    throw error;
  }
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
    connection = null;
  }
}
