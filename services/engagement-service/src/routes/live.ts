import { Router } from 'express';

const router = Router();

// Join a live stream
router.post('/:id/join', async (req, res) => {
  const { id } = req.params;
  // TODO: increment viewer count in Redis, publish event
  return res.status(200).json({ streamId: id, joined: true });
});

// Leave a live stream
router.post('/:id/leave', async (req, res) => {
  const { id } = req.params;
  // TODO: decrement viewer count in Redis, publish event
  return res.status(200).json({ streamId: id, left: true });
});

// Post a live comment
router.post('/:id/comment', async (req, res) => {
  const { id } = req.params;
  const { text } = req.body;
  // TODO: persist to Mongo and fan-out via Redis
  return res.status(201).json({ streamId: id, comment: { id: 'stub', text } });
});

// React to a live stream (like/reaction)
router.post('/:id/reaction', async (req, res) => {
  const { id } = req.params;
  const { type } = req.body;
  // TODO: increment reaction counter, publish event
  return res.status(200).json({ streamId: id, reaction: type });
});

export default router;
