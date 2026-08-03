This edge function now expects a face embedding-based matcher contract.

For a real production deployment, replace the deterministic cosine matcher in _shared/face_match_engine.ts with a hosted embedding model or vector index that can:
- generate face embeddings from a selfie and reference image
- support approximate nearest neighbor search over 100,000+ enrolled users
- return a similarity score plus liveness signal
