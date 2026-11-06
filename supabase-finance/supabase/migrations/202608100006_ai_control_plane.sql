create extension if not exists pgcrypto;

create table if not exists public.ai_country_profiles (
  country_code text primary key check (country_code ~ '^[A-Z]{2}$'),
  display_name text not null,
  revision bigint generated always as identity unique,
  supported_document_types text[] not null default '{}',
  document_rules jsonb not null default '{}'::jsonb,
  plate_rules jsonb not null default '{}'::jsonb,
  languages text[] not null default '{}',
  automatic_approval_enabled boolean not null default false,
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.ai_verification_jobs (
  id uuid primary key default gen_random_uuid(),
  subject_user_id uuid not null,
  idempotency_key text not null,
  workflow text not null check (workflow in ('courier', 'identity', 'vehicle', 'property', 'content')),
  country_code text not null default 'ZZ' check (country_code ~ '^[A-Z]{2}$'),
  status text not null default 'queued'
    check (status in ('queued', 'processing', 'completed', 'failed', 'cancelled')),
  decision text not null default 'pending'
    check (decision in ('pending', 'pass', 'reject', 'manual_review')),
  reason_codes text[] not null default '{}',
  policy_version text not null,
  media_fingerprints text[] not null default '{}',
  media_expires_at timestamptz,
  result_summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists public.ai_verification_stage_results (
  id bigint generated always as identity primary key,
  job_id uuid not null references public.ai_verification_jobs(id) on delete cascade,
  stage text not null,
  attempt smallint not null default 1 check (attempt > 0),
  provider text not null,
  model text,
  model_version text,
  decision text not null check (decision in ('pass', 'reject', 'manual_review', 'error')),
  confidence numeric(5,4) check (confidence between 0 and 1),
  latency_ms integer check (latency_ms >= 0),
  reason_codes text[] not null default '{}',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (job_id, stage, attempt)
);

create table if not exists public.ai_audit_events (
  id bigint generated always as identity primary key,
  job_id uuid references public.ai_verification_jobs(id) on delete cascade,
  event_type text not null,
  actor_type text not null check (actor_type in ('user', 'system', 'reviewer', 'provider')),
  actor_id uuid,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create unique index if not exists ai_verification_jobs_user_idempotency_idx
  on public.ai_verification_jobs (subject_user_id, idempotency_key);

create index if not exists ai_verification_jobs_active_user_idx
  on public.ai_verification_jobs (subject_user_id, created_at desc)
  where status in ('queued', 'processing');

create index if not exists ai_verification_jobs_manual_review_idx
  on public.ai_verification_jobs (created_at)
  where decision = 'manual_review' and status = 'completed';

create index if not exists ai_verification_stage_results_job_idx
  on public.ai_verification_stage_results (job_id, created_at);

create index if not exists ai_audit_events_job_idx
  on public.ai_audit_events (job_id, created_at);

create or replace function public.set_ai_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists ai_country_profiles_set_updated_at on public.ai_country_profiles;
create trigger ai_country_profiles_set_updated_at
before update on public.ai_country_profiles
for each row execute function public.set_ai_updated_at();

drop trigger if exists ai_verification_jobs_set_updated_at on public.ai_verification_jobs;
create trigger ai_verification_jobs_set_updated_at
before update on public.ai_verification_jobs
for each row execute function public.set_ai_updated_at();

insert into public.ai_country_profiles (
  country_code,
  display_name,
  supported_document_types,
  document_rules,
  plate_rules,
  languages,
  automatic_approval_enabled
)
values (
  'ZZ',
  'Global fallback',
  array['passport', 'national_id', 'driving_permit'],
  '{"unknown_format_decision":"manual_review","require_expiry_when_present":true}'::jsonb,
  '{"unknown_format_decision":"manual_review","generic_length":{"min":4,"max":12}}'::jsonb,
  '{}',
  false
)
on conflict (country_code) do nothing;

alter table public.ai_country_profiles enable row level security;
alter table public.ai_verification_jobs enable row level security;
alter table public.ai_verification_stage_results enable row level security;
alter table public.ai_audit_events enable row level security;

create or replace function public.record_ai_verification_result(
  p_job_id uuid,
  p_subject_user_id uuid,
  p_idempotency_key text,
  p_workflow text,
  p_country_code text,
  p_decision text,
  p_reason_codes text[],
  p_policy_version text,
  p_stage text,
  p_provider text,
  p_model text,
  p_confidence numeric,
  p_latency_ms integer,
  p_result_summary jsonb,
  p_stage_metadata jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job_id uuid;
begin
  insert into public.ai_verification_jobs (
    id, subject_user_id, idempotency_key, workflow, country_code, status,
    decision, reason_codes, policy_version, result_summary, completed_at
  ) values (
    p_job_id, p_subject_user_id, p_idempotency_key, p_workflow, p_country_code,
    'completed', p_decision, coalesce(p_reason_codes, '{}'), p_policy_version,
    coalesce(p_result_summary, '{}'::jsonb), now()
  )
  on conflict (subject_user_id, idempotency_key) do update set
    status = excluded.status,
    decision = excluded.decision,
    reason_codes = excluded.reason_codes,
    result_summary = excluded.result_summary,
    completed_at = excluded.completed_at
  returning id into v_job_id;

  insert into public.ai_verification_stage_results (
    job_id, stage, provider, model, decision, confidence, latency_ms,
    reason_codes, metadata
  ) values (
    v_job_id, p_stage, p_provider, p_model, p_decision, p_confidence,
    p_latency_ms, coalesce(p_reason_codes, '{}'), coalesce(p_stage_metadata, '{}'::jsonb)
  )
  on conflict (job_id, stage, attempt) do update set
    provider = excluded.provider,
    model = excluded.model,
    decision = excluded.decision,
    confidence = excluded.confidence,
    latency_ms = excluded.latency_ms,
    reason_codes = excluded.reason_codes,
    metadata = excluded.metadata;

  insert into public.ai_audit_events (job_id, event_type, actor_type, actor_id, data)
  values (
    v_job_id,
    'stage_completed',
    'system',
    null,
    jsonb_build_object('stage', p_stage, 'decision', p_decision, 'policy_version', p_policy_version)
  );

  return v_job_id;
end;
$$;

revoke all on public.ai_country_profiles from anon, authenticated;
revoke all on public.ai_verification_jobs from anon, authenticated;
revoke all on public.ai_verification_stage_results from anon, authenticated;
revoke all on public.ai_audit_events from anon, authenticated;

grant all on public.ai_country_profiles to service_role;
grant all on public.ai_verification_jobs to service_role;
grant all on public.ai_verification_stage_results to service_role;
grant all on public.ai_audit_events to service_role;
revoke all on function public.record_ai_verification_result(
  uuid, uuid, text, text, text, text, text[], text, text, text, text,
  numeric, integer, jsonb, jsonb
) from public, anon, authenticated;
grant execute on function public.record_ai_verification_result(
  uuid, uuid, text, text, text, text, text[], text, text, text, text,
  numeric, integer, jsonb, jsonb
) to service_role;
