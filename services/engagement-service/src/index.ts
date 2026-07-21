import express from 'express';
import cors from 'cors';
import pino from 'pino';
import bodyParser from 'body-parser';

import postsRouter from './routes/posts';
import productsRouter from './routes/products';
import liveRouter from './routes/live';

const logger = pino({ level: process.env.LOG_LEVEL || 'info' });
const app = express();

app.use(cors());
app.use(bodyParser.json());
app.use((req, res, next) => {
  logger.info({ method: req.method, url: req.url }, 'incoming');
  next();
});

app.get('/health', (_req, res) => res.json({ status: 'ok' }));
app.use('/engagement/posts', postsRouter);
app.use('/engagement/products', productsRouter);
app.use('/engagement/live', liveRouter);

const port = process.env.PORT || 4001;
app.listen(port, () => logger.info({ port }, 'engagement-service running'));

export default app;
