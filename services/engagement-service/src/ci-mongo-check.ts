import { connectMongo, closeMongo } from './mongo';

async function run() {
  console.log('CI Mongo Check: starting');
  try {
    const db = await connectMongo();
    console.log('CI Mongo Check: connected to', db.databaseName);
    await closeMongo();
    console.log('CI Mongo Check: closed connection');
    process.exit(0);
  } catch (err) {
    console.error('CI Mongo Check: failed', err);
    process.exit(2);
  }
}

run();
