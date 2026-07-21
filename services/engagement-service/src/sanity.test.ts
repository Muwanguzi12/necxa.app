import request from 'supertest';
import app from './index';

test('health endpoint responds', async () => {
  const res = await request(app).get('/health');
  expect(res.status).toBe(200);
  expect(res.body).toHaveProperty('status', 'ok');
});
