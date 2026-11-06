-- SP2 is the authoritative store for listing identity verification artifacts.
-- Flutter authenticates with SP1; only SP2 Edge Functions write these records.

create table if not exists public.identity_shards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  doc_type text not null,
  doc_number text,
  id_front_url text not null,
  id_back_url text not null,
  id_holding_url text not null,
  face_scan_url text not null,
  verified boolean not null default false,
  verification_confidence numeric(5, 2),
  extracted_name text,
  extracted_nin text,
  fraud_risk text check (fraud_risk in ('low', 'medium', 'high')),
  rejection_reason text,
  ai_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- SP2 already has a legacy identity_shards table in some environments. Extend
-- it in place instead of assuming CREATE TABLE added the current columns.
alter table public.identity_shards
  add column if not exists user_id uuid,
  add column if not exists doc_type text,
  add column if not exists doc_number text,
  add column if not exists id_front_url text,
  add column if not exists id_back_url text,
  add column if not exists id_holding_url text,
  add column if not exists face_scan_url text,
  add column if not exists verified boolean default false,
  add column if not exists verification_confidence numeric(5, 2),
  add column if not exists extracted_name text,
  add column if not exists extracted_nin text,
  add column if not exists fraud_risk text,
  add column if not exists rejection_reason text,
  add column if not exists ai_metadata jsonb default '{}'::jsonb,
  add column if not exists created_at timestamptz default now();

-- Preserve legacy rows when the older schema used profile_id instead of
-- user_id. New verification rows always have user_id supplied by SP2.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'identity_shards' and column_name = 'profile_id'
  ) then
    execute 'update public.identity_shards set user_id = profile_id where user_id is null';
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'identity_shards_user_id_fkey'
      and conrelid = 'public.identity_shards'::regclass
  ) then
    alter table public.identity_shards
      add constraint identity_shards_user_id_fkey
      foreign key (user_id) references public.profiles(id) on delete cascade;
  end if;
end;
$$;

create index if not exists identity_shards_user_created_idx
  on public.identity_shards (user_id, created_at desc);

-- PII is never read or written through the public client. The service-role
-- identity function has the sole write path after validating the SP1 session.
alter table public.identity_shards enable row level security;
revoke all on table public.identity_shards from anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('identity-shards', 'identity-shards', false, 10485760, array['image/jpeg', 'image/png'])
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;
