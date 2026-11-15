# NECXA Engagement Service

Mongo-backed engagement APIs for community posts, marketplace products, and
live streams. Supabase remains the identity provider; this service verifies
the user's access token and stores engagement data in MongoDB.

## Runtime configuration

Required:

- `MONGO_URI`: MongoDB connection string.
- One or more trusted Supabase projects, provided through
  `SUPABASE_AUTH_URLS` as a comma-separated list.

Recommended:

- `SUPABASE_AUTH_PUBLISHABLE_KEYS`: comma-separated publishable keys matching
  `SUPABASE_AUTH_URLS`. These support legacy HS256 projects through the
  Supabase `/auth/v1/user` verification endpoint.
- `MONGO_DB_NAME`: explicit engagement database name when it is not present in
  `MONGO_URI`.
- `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`, or `REDIS_URL`.
- `KAFKA_BROKERS`: optional comma-separated event broker list.

Do not provide a Supabase secret/private API key to this service. User tokens
are verified with public JWKS material or a publishable key.

## API

All `/engagement/*` routes require `Authorization: Bearer <access-token>`.

- `POST /engagement/posts/:id/like`
- `DELETE /engagement/posts/:id/like`
- `POST /engagement/posts/:id/comment`
- `GET /engagement/posts/:id/comments`
- `GET /engagement/posts/:id`
- The same routes are available under `/engagement/products`.
- `POST /engagement/live/:id/join`
- `POST /engagement/live/:id/leave`
- `POST /engagement/live/:id/comment`
- `POST /engagement/live/:id/reaction`
- `GET /engagement/live/:id`

`GET /health` is a liveness check. `GET /ready` returns success only after
MongoDB is connected and indexes are ready.

## Local verification

```bash
npm ci
npm run build
npm test
npm run ci:mongo-check
```

The Flutter app currently sends community likes and comments through the
`clever-processor` Edge Function. That function mirrors successful operations
to the same Mongo engagement collections, so existing clients gain Mongo
durability without changing their request contract.
