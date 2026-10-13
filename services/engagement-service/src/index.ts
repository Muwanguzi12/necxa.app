import express from 'express';
import cors from 'cors';
import pino from 'pino';
import rateLimit from 'express-rate-limit';

import postsRouter from './routes/posts';
import productsRouter from './routes/products';
import liveRouter from './routes/live';
import { closeMongo, connectMongo } from './mongo';
import { getRedis } from './redis';
import { getKafkaProducer } from './kafka';
import { jwksAuth } from './jwksAuth';

const logger = pino({ level: process.env.LOG_LEVEL || 'info' });

export function createApp() {
  const app = express();
  const redis = getRedis();
  app.locals.logger = logger;
  app.locals.redis = redis;

  app.use(cors());
  app.use(express.json({ limit: process.env.JSON_BODY_LIMIT || '64kb' }));
  app.use((req, _res, next) => {
    logger.info({ method: req.method, path: req.path }, 'incoming request');
    next();
  });

  app.get('/health', (_req, res) => {
    const ready = Boolean(app.locals.db);
    return res.status(200).json({
      status: 'ok',
      mongo: ready ? 'connected' : 'disconnected',
      redis: redis ? 'configured' : 'disabled',
    });
  });

  app.get('/ready', (_req, res) => {
    const ready = Boolean(app.locals.db);
    return res.status(ready ? 200 : 503).json({
      status: ready ? 'ready' : 'starting',
      mongo: ready ? 'connected' : 'disconnected',
    });
  });

  const limiter = rateLimit({
    windowMs: Number(process.env.RATE_WINDOW_MS || 60_000),
    max: Number(process.env.RATE_MAX || 120),
    standardHeaders: true,
    legacyHeaders: false,
  });
  app.use(limiter);

  const auth = jwksAuth();
  app.use('/engagement/posts', auth, postsRouter);
  app.use('/engagement/products', auth, productsRouter);
  app.use('/engagement/live', auth, liveRouter);

  return app;
}

const app = createApp();

export async function startServer() {
  app.locals.db = await connectMongo();
  app.locals.kafkaProducer = await getKafkaProducer();
  const port = Number(process.env.PORT || 4001);
  return app.listen(port, () => {
    logger.info(
      { port, database: app.locals.db.databaseName },
      'engagement service running',
    );
  });
}

async function shutdown(signal: string) {
  logger.info({ signal }, 'engagement service shutting down');
  await Promise.allSettled([closeMongo(), getRedis()?.quit()]);
  process.exit(0);
}

if (require.main === module) {
  startServer().catch((error) => {
    logger.fatal({ error }, 'engagement service failed to start');
    process.exit(1);
  });
  process.once('SIGTERM', () => void shutdown('SIGTERM'));
  process.once('SIGINT', () => void shutdown('SIGINT'));
}

export default app;
