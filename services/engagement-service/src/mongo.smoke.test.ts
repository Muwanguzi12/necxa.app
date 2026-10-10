import { MongoClient } from 'mongodb';

describe('mongo smoke', () => {
  const uri = process.env.MONGO_URI;
  if (!uri) {
    test.skip('MONGO_URI not configured - skipping mongo smoke test', () => {});
    return;
  }

  test('connect to mongo with short timeout', async () => {
    const client = new MongoClient(uri, { serverSelectionTimeoutMS: 5000 });
    try {
      const conn = await client.connect();
      const db = conn.db();
      expect(db).toBeTruthy();
      await conn.close();
    } finally {
      await client.close().catch(() => {});
    }
  }, 20000);
});
