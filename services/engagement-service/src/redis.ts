import IORedis from 'ioredis';

export interface RedisLike {
  call(command: string, ...args: Array<string | number>): Promise<unknown>;
  get(key: string): Promise<string | null>;
  quit(): Promise<unknown>;
}

class UpstashRestRedis implements RedisLike {
  constructor(
    private readonly url: string,
    private readonly token: string,
  ) {}

  async call(command: string, ...args: Array<string | number>): Promise<unknown> {
    const response = await fetch(this.url, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${this.token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify([command, ...args]),
    });
    if (!response.ok) {
      throw new Error(`Upstash Redis request failed (${response.status})`);
    }
    const body = (await response.json()) as { result?: unknown; error?: string };
    if (body.error) throw new Error(body.error);
    return body.result;
  }

  async get(key: string): Promise<string | null> {
    const value = await this.call('GET', key);
    return value == null ? null : String(value);
  }

  async quit(): Promise<void> {
    // REST connections do not maintain a socket.
  }
}

let redisClient: RedisLike | null | undefined;

export function getRedis(): RedisLike | null {
  if (redisClient !== undefined) return redisClient;
  const redisUrl = process.env.REDIS_URL?.trim() || process.env.UPSTASH_REDIS_URL?.trim();
  if (redisUrl) {
    const client = new IORedis(redisUrl, {
      lazyConnect: true,
      maxRetriesPerRequest: 2,
      enableOfflineQueue: false,
    });
    client.on('error', (error) => console.error('Redis error', error));
    redisClient = {
      call: (command, ...args) => client.call(command, ...args),
      get: (key) => client.get(key),
      quit: () => client.quit(),
    };
    return redisClient;
  }

  const restUrl = process.env.UPSTASH_REDIS_REST_URL?.trim();
  const restToken = process.env.UPSTASH_REDIS_REST_TOKEN?.trim();
  if (restUrl && restToken) {
    redisClient = new UpstashRestRedis(restUrl, restToken);
    return redisClient;
  }

  redisClient = null;
  return null;
}
