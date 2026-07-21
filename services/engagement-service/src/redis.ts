import IORedis from 'ioredis';

let redisClient: IORedis | null = null;

export function getRedis() {
  if (redisClient) return redisClient;
  const url = process.env.REDIS_URL || process.env.UPSTASH_REDIS_URL || 'redis://127.0.0.1:6379';
  // ioredis will parse URL (including password)
  redisClient = new IORedis(url);
  redisClient.on('error', (err) => console.error('Redis error', err));
  return redisClient;
}
