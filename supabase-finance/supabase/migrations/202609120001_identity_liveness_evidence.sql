-- SP2 is the authoritative identity-verification database. Retain the
-- panorama used for the liveness decision with the identity shard record.
alter table public.identity_shards
  add column if not exists liveness_evidence_url text;
