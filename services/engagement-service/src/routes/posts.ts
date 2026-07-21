import { Router } from 'express';
import type { Request } from 'express';
import { likePost, commentPost, getEngagement } from '../postRepo';

const router = Router();

// Like a post
router.post('/:id/like', async (req: Request, res) => {
  const { id } = req.params;
  const user = (req as any).user;
  if (!user) return res.status(401).json({ message: 'unauthenticated' });
  try {
    const db = req.app.locals.db;
    const result = await likePost(db, id, user.sub || user.id || 'unknown');
    // publish to kafka if available
    if (req.app.locals.kafkaProducer) {
      try { await req.app.locals.kafkaProducer.send({ topic: 'post.liked', messages: [{ value: JSON.stringify({ postId: id, userId: user.sub || user.id }) }] }); } catch (e) { /* noop */ }
    }
    return res.status(200).json({ postId: id, liked: true, meta: result });
  } catch (err) {
    return res.status(500).json({ message: 'failed to like', err: String(err) });
  }
});

// Comment on a post
router.post('/:id/comment', async (req: Request, res) => {
  const { id } = req.params;
  const { text } = req.body;
  const user = (req as any).user;
  if (!user) return res.status(401).json({ message: 'unauthenticated' });
  if (!text || typeof text !== 'string') return res.status(400).json({ message: 'text required' });
  try {
    const db = req.app.locals.db;
    const comment = await commentPost(db, id, user.sub || user.id || 'unknown', text);
    if (req.app.locals.kafkaProducer) {
      try { await req.app.locals.kafkaProducer.send({ topic: 'post.commented', messages: [{ value: JSON.stringify({ postId: id, userId: user.sub || user.id, commentId: comment.id }) }] }); } catch (e) { /* noop */ }
    }
    return res.status(201).json({ postId: id, comment });
  } catch (err) {
    return res.status(500).json({ message: 'failed to create comment', err: String(err) });
  }
});

// Get engagement summary for a post
router.get('/:id', async (req, res) => {
  const { id } = req.params;
  try {
    const db = req.app.locals.db;
    const summary = await getEngagement(db, id);
    // try Redis hot counters
    const redis = req.app.locals.redis;
    if (redis) {
      try {
        const likes = await redis.get(`post:${id}:likes`);
        if (likes) summary.likes = parseInt(likes, 10);
      } catch (e) { /* ignore redis errors */ }
    }
    return res.json({ postId: id, counts: summary });
  } catch (err) {
    return res.status(500).json({ message: 'failed to read engagement', err: String(err) });
  }
});

export default router;
