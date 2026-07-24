import { Router } from 'express';
import type { Db } from 'mongodb';
import type { AuthRequest } from '../jwksAuth';
import {
  addEntityComment,
  getEntityEngagement,
  likeEntity,
  listEntityComments,
  unlikeEntity,
  type EngagementEntityType,
} from '../engagementRepo';

function userIdFrom(req: AuthRequest): string | null {
  const user = req.user as { sub?: string; id?: string } | undefined;
  return user?.sub || user?.id || null;
}

function databaseFrom(req: AuthRequest): Db {
  const db = req.app.locals.db as Db | undefined;
  if (!db) throw new Error('engagement database is not ready');
  return db;
}

async function publish(req: AuthRequest, topic: string, value: object) {
  const producer = req.app.locals.kafkaProducer;
  if (!producer) return;
  try {
    await producer.send({
      topic,
      messages: [{ value: JSON.stringify(value) }],
    });
  } catch (error) {
    req.app.locals.logger?.warn({ error, topic }, 'engagement event publish failed');
  }
}

export function createEntityRouter(entityType: EngagementEntityType) {
  const router = Router();

  router.post('/:id/like', async (req: AuthRequest, res) => {
    const userId = userIdFrom(req);
    if (!userId) return res.status(401).json({ message: 'unauthenticated' });
    try {
      const state = await likeEntity(databaseFrom(req), entityType, req.params.id, userId);
      const counts = await getEntityEngagement(
        databaseFrom(req),
        entityType,
        req.params.id,
        userId,
      );
      await publish(req, `${entityType}.liked`, {
        entityId: req.params.id,
        userId,
      });
      return res.status(200).json({
        [`${entityType}Id`]: req.params.id,
        ...state,
        counts,
      });
    } catch (error) {
      return res.status(503).json({ message: 'engagement store unavailable' });
    }
  });

  router.delete('/:id/like', async (req: AuthRequest, res) => {
    const userId = userIdFrom(req);
    if (!userId) return res.status(401).json({ message: 'unauthenticated' });
    try {
      const state = await unlikeEntity(databaseFrom(req), entityType, req.params.id, userId);
      const counts = await getEntityEngagement(
        databaseFrom(req),
        entityType,
        req.params.id,
        userId,
      );
      await publish(req, `${entityType}.unliked`, {
        entityId: req.params.id,
        userId,
      });
      return res.status(200).json({
        [`${entityType}Id`]: req.params.id,
        ...state,
        counts,
      });
    } catch (error) {
      return res.status(503).json({ message: 'engagement store unavailable' });
    }
  });

  router.post('/:id/comment', async (req: AuthRequest, res) => {
    const userId = userIdFrom(req);
    if (!userId) return res.status(401).json({ message: 'unauthenticated' });
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text || text.length > 2000) {
      return res.status(400).json({ message: 'text must be 1-2000 characters' });
    }
    try {
      const comment = await addEntityComment(
        databaseFrom(req),
        entityType,
        req.params.id,
        userId,
        text,
        req.get('idempotency-key') || undefined,
      );
      await publish(req, `${entityType}.commented`, {
        entityId: req.params.id,
        userId,
        commentId: comment.id,
      });
      return res.status(201).json({
        [`${entityType}Id`]: req.params.id,
        comment,
      });
    } catch (error) {
      return res.status(503).json({ message: 'engagement store unavailable' });
    }
  });

  router.get('/:id/comments', async (req: AuthRequest, res) => {
    try {
      const requested = Number.parseInt(String(req.query.limit || '50'), 10);
      const limit = Number.isFinite(requested) ? Math.min(Math.max(requested, 1), 100) : 50;
      const comments = await listEntityComments(
        databaseFrom(req),
        entityType,
        req.params.id,
        limit,
      );
      return res.json({ [`${entityType}Id`]: req.params.id, comments });
    } catch (error) {
      return res.status(503).json({ message: 'engagement store unavailable' });
    }
  });

  router.get('/:id', async (req: AuthRequest, res) => {
    try {
      const counts = await getEntityEngagement(
        databaseFrom(req),
        entityType,
        req.params.id,
        userIdFrom(req) || undefined,
      );
      return res.json({ [`${entityType}Id`]: req.params.id, counts });
    } catch (error) {
      return res.status(503).json({ message: 'engagement store unavailable' });
    }
  });

  return router;
}
