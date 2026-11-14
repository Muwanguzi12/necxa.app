# Engagement Authentication

The service accepts Supabase user access tokens from Supabase 1 and Supabase 2.
Configure both project URLs through the comma-separated `SUPABASE_AUTH_URLS`
environment variable.

For projects using asymmetric JWT signing keys, tokens are verified against:

```text
https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json
```

For a project still using legacy HS256 signing, configure the corresponding
publishable key in `SUPABASE_AUTH_PUBLISHABLE_KEYS`. The service verifies the
token with that project's `/auth/v1/user` endpoint.

Optional compatibility variables are `JWKS_URIS`, `JWT_ISSUERS`,
`JWT_PUBLIC_KEY`, `JWT_ALG`, and `JWT_AUDIENCE`.

Never copy a Supabase secret/private API key or JWT private signing key into
the engagement container. Private material remains in Supabase Edge Function
secrets. The engagement service needs only public verification material.
