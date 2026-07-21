import express from 'express';
import cors from 'cors';
import pino from 'pino';
import bodyParser from 'body-parser';

import postsRouter from './routes/posts';
import productsRouter from './routes/products';
import liveRouter from './routes/live';

import { connectMongo } from './mongo';
import { getRedis } from './redis';
import { getKafkaProducer } from './kafka';
import { jwksAuth } from './jwksAuth';
import rateLimit from 'express-rate-limit';
import RedisStore from 'rate-limit-redis';

const logger = pino({ level: process.env.LOG_LEVEL || 'info' });
const app = express();

app.use(cors());
app.use(bodyParser.json());
app.use((req, res, next) => {
  logger.info({ method: req.method, url: req.url }, 'incoming');
  next();
});

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

// attach redis-backed rate limiter if available
const redisClient = getRedis();
const limiter = rateLimit({
  windowMs: Number(process.env.RATE_WINDOW_MS || 60_000), // 1 minute
  max: Number(process.env.RATE_MAX || 60), // 60 requests per window per IP by default
  standardHeaders: true,
  legacyHeaders: false,
  store: redisClient ? new RedisStore({ sendCommand: (...args: any[]) => (redisClient as any).call(...args) }) : undefined,
});
app.use(limiter);

// initialize backing services and attach to app.locals so routes can access them
(async () => {
  try {
    const db = await connectMongo();
    app.locals.db = db;
  } catch (err) {
    logger.error({ err }, 'mongo connection failed');
  }

  try {
    app.locals.redis = redisClient;
  } catch (err) {
    logger.error({ err }, 'redis init failed');
  }

  try {
    app.locals.kafkaProducer = await getKafkaProducer();
  } catch (err) {
    logger.warn({ err }, 'kafka init failed or not configured');
  }
})();

// protect engagement write endpoints with JWKS-based auth
const auth = jwksAuth();
app.use('/engagement/posts', auth, postsRouter);
app.use('/engagement/products', auth, productsRouter);
app.use('/engagement/live', auth, liveRouter);

const port = process.env.PORT || 4001;
app.listen(port, () => logger.info({ port }, 'engagement-service running'));

export default app;
