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
import { authMiddleware } from './auth';

const logger = pino({ level: process.env.LOG_LEVEL || 'info' });
const app = express();

app.use(cors());
app.use(bodyParser.json());
app.use((req, res, next) => {
  logger.info({ method: req.method, url: req.url }, 'incoming');
  next();
});

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

// initialize backing services and attach to app.locals so routes can access them
(async () => {
  try {
    const db = await connectMongo();
    app.locals.db = db;
  } catch (err) {
    logger.error({ err }, 'mongo connection failed');
  }

  try {
    app.locals.redis = getRedis();
  } catch (err) {
    logger.error({ err }, 'redis init failed');
  }

  try {
    app.locals.kafkaProducer = await getKafkaProducer();
  } catch (err) {
    logger.warn({ err }, 'kafka init failed or not configured');
  }
})();

// protect engagement write endpoints with auth
app.use('/engagement/posts', authMiddleware, postsRouter);
app.use('/engagement/products', authMiddleware, productsRouter);
app.use('/engagement/live', authMiddleware, liveRouter);

const port = process.env.PORT || 4001;
app.listen(port, () => logger.info({ port }, 'engagement-service running'));

export default app;
