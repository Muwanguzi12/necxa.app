import { MongoClient, Db } from 'mongodb';

let client: MongoClient | null = null;
let db: Db | null = null;

export async function connectMongo(): Promise<Db> {
  if (db) return db;
  const uri = process.env.MONGO_URI || 'mongodb://localhost:27017/necxa_engagement';
  client = new MongoClient(uri, {});
  await client.connect();
  db = client.db();
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
