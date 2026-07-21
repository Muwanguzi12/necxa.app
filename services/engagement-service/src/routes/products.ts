import { Router } from 'express';

const router = Router();

// Like a product
router.post('/:id/like', async (req, res) => {
  const { id } = req.params;
  // TODO: validate user, write to Mongo, publish event
  return res.status(200).json({ productId: id, liked: true });
});

// Comment on a product
router.post('/:id/comment', async (req, res) => {
  const { id } = req.params;
  const { text } = req.body;
  // TODO: create comment in Mongo, publish event
  return res.status(201).json({ productId: id, comment: { id: 'stub', text } });
});

// Get engagement summary for a product
router.get('/:id', async (req, res) => {
  const { id } = req.params;
  // TODO: read aggregated counters from Mongo / Redis
  return res.json({ productId: id, counts: { likes: 0, comments: 0, views: 0 } });
});

export default router;
