-- Durable community-gift projection queue for the Finance project.
-- The Finance Edge Function settles money first, then mirrors eligible gifts
-- to the primary/community project. This queue makes that mirror retryable.

create table if not exists public.finance_config (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

insert into public.finance_config (key, value)
values ('gift_platform_fee_basis_points', '{"basis_points": 1100}'::jsonb)
on conflict (key) do nothing;

create table if not exists public.gift_projections (
  finance_gift_id uuid primary key references public.gifts(id) on delete cascade,
  sender_id uuid not null,
  receiver_id uuid not null,
  context_type text not null check (context_type in ('creator_post', 'listing')),
  context_id text not null,
  gift_item_id text not null,
  ncx_amount bigint not null check (ncx_amount > 0),
  receiver_ncx bigint not null check (receiver_ncx >= 0),
  platform_fee_ncx bigint not null check (platform_fee_ncx >= 0),
  ugx_value bigint not null check (ugx_value >= 0),
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'completed', 'failed')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  available_at timestamptz not null default now(),
  claimed_at timestamptz,
  completed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists gift_projections_claim_idx
  on public.gift_projections (status, available_at, created_at);

-- Every eligible settled Finance gift receives one projection row. Existing
-- gifts are backfilled below, so this migration also repairs records created
-- before the queue existed.
create or replace function public.queue_community_gift_projection()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ugx_value bigint;
begin
  if new.context_type not in ('creator_post', 'listing') then
    return new;
  end if;

  select coalesce(ugx_value, ncx_value * 100, 0)
  into v_ugx_value
  from public.gift_items
  where id = new.gift_item_id;

  insert into public.gift_projections (
    finance_gift_id, sender_id, receiver_id, context_type, context_id,
    gift_item_id, ncx_amount, receiver_ncx, platform_fee_ncx, ugx_value,
    idempotency_key, metadata
  ) values (
    new.id, new.sender_id, new.receiver_id, new.context_type, new.context_id,
    new.gift_item_id, new.ncx_amount, new.receiver_ncx, new.platform_fee_ncx,
    coalesce(v_ugx_value, 0), new.idempotency_key, coalesce(new.metadata, '{}'::jsonb)
  )
  on conflict (finance_gift_id) do nothing;

  return new;
end;
$$;

drop trigger if exists queue_community_gift_projection_after_insert on public.gifts;
create trigger queue_community_gift_projection_after_insert
after insert on public.gifts
for each row execute function public.queue_community_gift_projection();

insert into public.gift_projections (
  finance_gift_id, sender_id, receiver_id, context_type, context_id,
  gift_item_id, ncx_amount, receiver_ncx, platform_fee_ncx, ugx_value,
  idempotency_key, metadata
)
select
  g.id, g.sender_id, g.receiver_id, g.context_type, g.context_id,
  g.gift_item_id, g.ncx_amount, g.receiver_ncx, g.platform_fee_ncx,
  coalesce(i.ugx_value, i.ncx_value * 100, 0), g.idempotency_key,
  coalesce(g.metadata, '{}'::jsonb)
from public.gifts g
left join public.gift_items i on i.id = g.gift_item_id
where g.context_type in ('creator_post', 'listing')
on conflict (finance_gift_id) do nothing;

-- Atomically claim a bounded batch. SKIP LOCKED makes this safe for multiple
-- schedulers/workers without sending the same projection concurrently.
-- PostgreSQL treats OUT columns as part of a function's type. Drop the legacy
-- signature first so installations with an earlier projection queue can adopt
-- this expanded result contract.
drop function if exists public.claim_gift_projection_batch(integer);
create or replace function public.claim_gift_projection_batch(p_limit integer default 50)
returns table (
  finance_gift_id uuid,
  sender_id uuid,
  receiver_id uuid,
  context_type text,
  context_id text,
  gift_item_id text,
  ncx_amount bigint,
  receiver_ncx bigint,
  platform_fee_ncx bigint,
  ugx_value bigint,
  idempotency_key text,
  metadata jsonb
)
language sql
security definer
set search_path = public
as $$
  with candidates as (
    select p.finance_gift_id
    from public.gift_projections p
    where p.status in ('pending', 'failed')
      and p.available_at <= now()
    order by p.created_at
    for update skip locked
    limit greatest(1, least(coalesce(p_limit, 50), 200))
  ), claimed as (
    update public.gift_projections p
    set status = 'processing',
        attempt_count = p.attempt_count + 1,
        claimed_at = now(),
        updated_at = now()
    from candidates c
    where p.finance_gift_id = c.finance_gift_id
    returning p.*
  )
  select
    finance_gift_id, sender_id, receiver_id, context_type, context_id,
    gift_item_id, ncx_amount, receiver_ncx, platform_fee_ncx, ugx_value,
    idempotency_key, metadata
  from claimed;
$$;

drop function if exists public.complete_gift_projection(uuid, boolean, text);
create function public.complete_gift_projection(
  p_finance_gift_id uuid,
  p_success boolean,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_success then
    update public.gift_projections
    set status = 'completed',
        completed_at = now(),
        last_error = null,
        updated_at = now()
    where finance_gift_id = p_finance_gift_id;
  else
    update public.gift_projections
    set status = 'failed',
        last_error = left(coalesce(p_error, 'Community projection failed.'), 2000),
        available_at = now() + make_interval(
          secs => least(3600, power(2, least(attempt_count, 10))::integer * 30)
        ),
        updated_at = now()
    where finance_gift_id = p_finance_gift_id;
  end if;
end;
$$;

-- Keep the Edge Function's established RPC name while delegating to the
-- validated, idempotent provenance-aware gift transfer. The older version of
-- this function did not return a gift UUID, which made projection impossible.
drop function if exists public.process_gift_ncx(uuid, uuid, uuid, bigint, double precision, jsonb);
create function public.process_gift_ncx(
  p_sender_auth_id uuid,
  p_receiver_auth_id uuid,
  p_post_id uuid,
  p_ncx_amount bigint,
  p_gift_platform_fee_rate double precision,
  p_gift_details jsonb
)
returns table (
  success boolean,
  message text,
  platform_fee_paid bigint,
  receiver_amount_credited bigint,
  gift_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gift public.gifts;
  v_context_type text := coalesce(p_gift_details->>'context_type', 'creator_post');
  v_context_id text;
  v_fee_basis_points integer;
begin
  if v_context_type not in ('direct', 'creator_post', 'listing') then
    raise exception 'Unsupported gift context.';
  end if;

  v_context_id := case
    when v_context_type = 'direct' then 'direct:' || p_receiver_auth_id::text
    else p_post_id::text
  end;
  v_fee_basis_points := greatest(0, least(10000,
    round(coalesce(p_gift_platform_fee_rate, 0.11) * 10000)::integer
  ));

  select * into v_gift
  from public.process_gift(
    p_sender_auth_id,
    p_receiver_auth_id,
    p_gift_details->>'gift_item_id',
    v_context_type,
    v_context_id,
    p_ncx_amount,
    v_fee_basis_points,
    coalesce((p_gift_details->>'is_anonymous')::boolean, false),
    coalesce(p_gift_details->>'idempotency_key', gen_random_uuid()::text),
    coalesce(p_gift_details, '{}'::jsonb)
  );

  return query select
    true,
    'Gift sent successfully.'::text,
    v_gift.platform_fee_ncx,
    v_gift.receiver_ncx,
    v_gift.id;
end;
$$;

revoke all on table public.gift_projections from anon, authenticated;
revoke all on function public.claim_gift_projection_batch(integer) from public, anon, authenticated;
revoke all on function public.complete_gift_projection(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.process_gift_ncx(uuid, uuid, uuid, bigint, double precision, jsonb) from public, anon, authenticated;
grant execute on function public.claim_gift_projection_batch(integer) to service_role;
grant execute on function public.complete_gift_projection(uuid, boolean, text) to service_role;
grant execute on function public.process_gift_ncx(uuid, uuid, uuid, bigint, double precision, jsonb) to service_role;
