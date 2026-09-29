create extension if not exists pgcrypto;

create table if not exists public.listing_submission_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key text not null check (char_length(idempotency_key) between 12 and 180),
  status text not null default 'processing'
    check (status in ('processing', 'completed', 'failed')),
  attempt_count integer not null default 1 check (attempt_count > 0),
  listing_id uuid references public.listings(id) on delete set null,
  mint_event_id text,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (user_id, idempotency_key)
);

create index if not exists listing_submission_requests_active_idx
  on public.listing_submission_requests (updated_at)
  where status = 'processing';

create index if not exists listing_submission_requests_user_recent_idx
  on public.listing_submission_requests (user_id, created_at desc);

alter table public.listing_submission_requests enable row level security;
revoke all on table public.listing_submission_requests from anon, authenticated;
grant all on table public.listing_submission_requests to service_role;

create or replace function public.claim_listing_submission(
  p_user_id uuid,
  p_idempotency_key text
)
returns table (
  request_id uuid,
  claimed boolean,
  request_status text,
  existing_listing_id uuid,
  existing_mint_event_id text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.listing_submission_requests%rowtype;
begin
  if p_user_id is null or p_idempotency_key is null
     or char_length(p_idempotency_key) not between 12 and 180 then
    raise exception 'invalid listing submission idempotency key';
  end if;

  insert into public.listing_submission_requests (user_id, idempotency_key)
  values (p_user_id, p_idempotency_key)
  on conflict (user_id, idempotency_key) do nothing
  returning * into v_request;

  if v_request.id is not null then
    return query select v_request.id, true, v_request.status,
      v_request.listing_id, v_request.mint_event_id;
    return;
  end if;

  update public.listing_submission_requests
  set status = 'processing',
      attempt_count = attempt_count + 1,
      error_code = null,
      updated_at = now()
  where user_id = p_user_id
    and idempotency_key = p_idempotency_key
    and (
      status = 'failed'
      or (status = 'processing' and updated_at < now() - interval '5 minutes')
    )
  returning * into v_request;

  if v_request.id is null then
    select * into v_request
    from public.listing_submission_requests
    where user_id = p_user_id and idempotency_key = p_idempotency_key;
    return query select v_request.id, false, v_request.status,
      v_request.listing_id, v_request.mint_event_id;
    return;
  end if;

  return query select v_request.id, true, v_request.status,
    v_request.listing_id, v_request.mint_event_id;
end;
$$;

revoke all on function public.claim_listing_submission(uuid, text)
  from public, anon, authenticated;
grant execute on function public.claim_listing_submission(uuid, text)
  to service_role;
