-- SP2 cryptographic liveness handshake.  Challenge rows are deliberately
-- single-use and public keys are scoped to the authenticated SP1 subject.
create table if not exists public.liveness_device_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  key_id text not null,
  public_key_jwk jsonb not null,
  attestation_certificates jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  unique (user_id, key_id)
);

create table if not exists public.liveness_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  key_id text not null,
  nonce text not null unique,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  manifest_hash text
);

create index if not exists liveness_challenges_user_expiry_idx
  on public.liveness_challenges (user_id, expires_at);

alter table public.liveness_device_keys enable row level security;
alter table public.liveness_challenges enable row level security;
