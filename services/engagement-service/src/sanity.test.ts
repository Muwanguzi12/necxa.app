import request from 'supertest';
import app from './index';

test('health endpoint responds', async () => {
  const res = await request(app).get('/health');
  expect(res.status).toBe(200);
  expect(res.body).toHaveProperty('status', 'ok');
});

test('readiness reports Mongo as unavailable before startup', async () => {
  const res = await request(app).get('/ready');
  expect(res.status).toBe(503);
  expect(res.body).toHaveProperty('status', 'starting');
});

test('engagement writes require an authenticated user', async () => {
  const res = await request(app).post('/engagement/posts/post-1/like');
  expect(res.status).toBe(401);
  expect(res.body).toHaveProperty('message', 'missing Authorization header');
});
