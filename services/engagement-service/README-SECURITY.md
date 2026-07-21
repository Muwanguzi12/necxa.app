JWT & JWKS configuration (engagement-service)

This service supports two modes for verifying incoming JWTs used to authenticate engagement API requests:

1) JWKS (recommended for production)
   - Set JWKS_URI to the JWKS endpoint provided by the identity provider (e.g., Supabase, Auth0, Keycloak).
   - Set JWT_ISSUER and JWT_AUDIENCE as appropriate.
   - Example secrets to add to GitHub repo secrets:
     - JWKS_URI
     - JWT_ISSUER
     - JWT_AUDIENCE

2) Local public key fallback (PEM)
   - If JWKS_URI is not available, provide a PEM-formatted public key via JWT_PUBLIC_KEY.
   - The service will import the SPKI key and verify RS256 tokens using that key.
   - Example secrets to add:
     - JWT_PUBLIC_KEY (PEM data, including -----BEGIN PUBLIC KEY----- / -----END PUBLIC KEY-----)
     - JWT_ALG (optional, defaults to RS256)

Mapping to your environment
- For CI and GitHub Actions, add the above secrets to repository secrets and the engagement CI workflow will export them into the job environment.
- For deployed containers, provide the same variables as environment variables (e.g., Kubernetes secrets or container service secrets).

Notes
- Do NOT store private signing keys (the JWT private key) in this service's runtime environment; only the public key is necessary for verification.
- If using Supabase as the identity provider, the JWKS endpoint is typically:
  https://<PROJECT>.supabase.co/auth/v1/.well-known/jwks.json
  and the issuer is https://<PROJECT>.supabase.co/auth/v1

If you want, I can:
- Copy your existing Supabase secrets into appropriately named GitHub secrets (you previously said you added public key and secret key in Supabase). To do that I need the exact GitHub secret names or permission to copy them.
- Or, I can update the CI workflow to print a short verification step showing which auth environment vars are present (not their values) to confirm configuration.
