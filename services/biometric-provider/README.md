# Necxa biometric provider

A production-oriented, fail-closed API boundary for face match and liveness. It matches the multipart contract already used by `scratch/necxa-ai/worker.js`:

- `POST /v1/verify`
- bearer-token authentication
- `selfie`, optional `reference`, and `mode` form fields
- normalized face-match, liveness, spoof and decision fields

## Four-stage model policy

Production readiness requires all four roles in `model-manifest.example.json`: face detection/alignment, two independent face embedding matchers, and presentation-attack detection. Each artifact must have a verified SHA-256 checksum, a reviewed commercial license and an explicit production approval flag.

No model weights are bundled. The service returns `503` until the model manifest and inference backend are installed, preventing a general vision model or a test double from approving a real user.

## Local setup

1. Create a virtual environment and install `.[test]`.
2. Generate a secret with `python scripts/new_token.py`; keep it in a secret manager, never Git.
3. Copy `.env.example` to `.env` and set the generated token.
4. Run `uvicorn app.main:app --reload --port 8080`.

When deployed, set `NECXA_BIOMETRIC_URL` to the full `/v1/verify` URL and `NECXA_BIOMETRIC_TOKEN` to the same secret in the Necxa AI Worker. Paid container hosting, licensed model artifacts, evaluation thresholds, biometric privacy notices, retention rules and human-review procedures are still required before automatic approvals are enabled.
