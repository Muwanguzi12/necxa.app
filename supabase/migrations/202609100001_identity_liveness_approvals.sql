-- Durable server-side record of an approved selfie liveness decision.
-- Only verify-identity-shard writes this table with the SP2 service role.
create table if not exists public.identity_liveness_approvals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  verification_session_id text not null,
  selfie_sha256 text not null,
  decision text not null check (decision = 'pass'),
  liveness_score numeric(5, 2) not null check (liveness_score between 0 and 100),
  face_detected boolean not null,
  anti_spoof_flags jsonb not null default '[]'::jsonb,
  provider text not null,
  metadata jsonb not null default '{}'::jsonb,
  approved_at timestamptz not null default now(),
  unique (user_id, verification_session_id)
);

create index if not exists identity_liveness_approvals_user_time_idx
  on public.identity_liveness_approvals (user_id, approved_at desc);

alter table public.identity_liveness_approvals enable row level security;
revoke all on table public.identity_liveness_approvals from anon, authenticated;
