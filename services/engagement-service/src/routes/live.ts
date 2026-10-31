import { Router } from 'express';
import type { Db } from 'mongodb';
import type { AuthRequest } from '../jwksAuth';
import {
  addLiveComment,
  addLiveReaction,
  getLiveSummary,
  joinLive,
  leaveLive,
} from '../liveRepo';

const router = Router();
const allowedReactions = new Set(['like', 'love', 'laugh', 'wow', 'fire', 'applause']);

function userIdFrom(req: AuthRequest): string | null {
  const user = req.user as { sub?: string; id?: string } | undefined;
  return user?.sub || user?.id || null;
}

function databaseFrom(req: AuthRequest): Db {
  const db = req.app.locals.db as Db | undefined;
  if (!db) throw new Error('engagement database is not ready');
  return db;
}

router.post('/:id/join', async (req: AuthRequest, res) => {
  const userId = userIdFrom(req);
  if (!userId) return res.status(401).json({ message: 'unauthenticated' });
  try {
    const state = await joinLive(databaseFrom(req), req.params.id, userId);
    const summary = await getLiveSummary(databaseFrom(req), req.params.id);
    return res.status(200).json({ streamId: req.params.id, ...state, summary });
  } catch (error) {
    return res.status(503).json({ message: 'engagement store unavailable' });
  }
});

router.post('/:id/leave', async (req: AuthRequest, res) => {
  const userId = userIdFrom(req);
  if (!userId) return res.status(401).json({ message: 'unauthenticated' });
  try {
    const state = await leaveLive(databaseFrom(req), req.params.id, userId);
    const summary = await getLiveSummary(databaseFrom(req), req.params.id);
    return res.status(200).json({ streamId: req.params.id, ...state, summary });
  } catch (error) {
    return res.status(503).json({ message: 'engagement store unavailable' });
  }
});

router.post('/:id/comment', async (req: AuthRequest, res) => {
  const userId = userIdFrom(req);
  if (!userId) return res.status(401).json({ message: 'unauthenticated' });
  const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
  if (!text || text.length > 500) {
    return res.status(400).json({ message: 'text must be 1-500 characters' });
  }
  try {
    const comment = await addLiveComment(databaseFrom(req), req.params.id, userId, text);
    return res.status(201).json({ streamId: req.params.id, comment });
  } catch (error) {
    return res.status(503).json({ message: 'engagement store unavailable' });
  }
});

router.post('/:id/reaction', async (req: AuthRequest, res) => {
  const userId = userIdFrom(req);
  if (!userId) return res.status(401).json({ message: 'unauthenticated' });
  const type = typeof req.body?.type === 'string' ? req.body.type.trim().toLowerCase() : '';
  if (!allowedReactions.has(type)) {
    return res.status(400).json({ message: 'unsupported reaction type' });
  }
  try {
    const reaction = await addLiveReaction(
      databaseFrom(req),
      req.params.id,
      userId,
      type,
    );
    return res.status(200).json({ streamId: req.params.id, reaction });
  } catch (error) {
    return res.status(503).json({ message: 'engagement store unavailable' });
  }
});

router.get('/:id', async (req: AuthRequest, res) => {
  try {
    const summary = await getLiveSummary(databaseFrom(req), req.params.id);
    return res.json({ streamId: req.params.id, summary });
  } catch (error) {
    return res.status(503).json({ message: 'engagement store unavailable' });
  }
});

export default router;
