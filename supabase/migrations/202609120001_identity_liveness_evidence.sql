-- Retain the panorama used for the identity liveness decision so the
-- verification receipt and stored evidence can be audited together.
alter table public.identity_shards
  add column if not exists liveness_evidence_url text;
