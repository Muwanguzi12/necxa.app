`begin;

insert into public.finance_config (key, value, is_public)
values ('gift_platform_fee_basis_points', '{"basis_points": 1100}'::jsonb, false)
on conflict (key) do nothing;

alter table public.gifts
  add column if not exists community_sync_status text not null default 'not_required',
  add column if not exists community_sync_attempts integer not null default 0,
  add column if not exists community_sync_error text,
  add column if not exists community_synced_at timestamptz;

create table if not exists public.gift_projection_outbox (
  id uuid primary key default gen_random_uuid(),
  finance_gift_id uuid not null references public.gifts(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'synced', 'failed')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (finance_gift_id)
);

create index if not exists gift_projection_outbox_ready_idx
  on public.gift_projection_outbox (next_attempt_at, created_at)
  where status in ('pending', 'failed');

alter table public.gift_projection_outbox enable row level security;
revoke all on public.gift_projection_outbox from anon, authenticated;

create or replace function public.enqueue_gift_projection()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.context_type in ('creator_post', 'listing')
     and new.context_id is not null
     and new.context_id not like 'direct:%' then
    new.community_sync_status := 'pending';
    insert into public.gift_projection_outbox (finance_gift_id)
    values (new.id)
    on conflict (finance_gift_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists gifts_enqueue_projection on public.gifts;
create trigger gifts_enqueue_projection
before insert on public.gifts
for each row execute function public.enqueue_gift_projection();

update public.gifts
set community_sync_status = 'pending'
where context_type in ('creator_post', 'listing')
  and context_id is not null
  and context_id not like 'direct:%'
  and community_sync_status = 'not_required';

insert into public.gift_projection_outbox (finance_gift_id)
select g.id
from public.gifts g
where g.community_sync_status = 'pending'
on conflict (finance_gift_id) do nothing;

create or replace function public.claim_gift_projection_batch(
  p_limit integer default 50
)
returns table (
  outbox_id uuid,
  finance_gift_id uuid,
  sender_id uuid,
  receiver_id uuid,
  gift_item_id text,
  context_type text,
  context_id text,
  ncx_amount bigint,
  receiver_ncx bigint,
  platform_fee_ncx bigint,
  is_anonymous boolean,
  metadata jsonb,
  ugx_value bigint,
  idempotency_key text,
  attempts integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with candidates as (
    select o.id
    from public.gift_projection_outbox o
    where (
        o.status in ('pending', 'failed')
        and o.next_attempt_at <= now()
      )
      or (
        o.status = 'processing'
        and o.updated_at <= now() - interval '10 minutes'
      )
    order by o.created_at
    limit greatest(1, least(coalesce(p_limit, 50), 200))
    for update skip locked
  ),
  claimed as (
    update public.gift_projection_outbox o
    set status = 'processing',
        attempts = o.attempts + 1,
        updated_at = now()
    from candidates c
    where o.id = c.id
    returning o.id, o.finance_gift_id, o.attempts
  )
  select
    c.id,
    g.id,
    g.sender_id,
    g.receiver_id,
    g.gift_item_id,
    g.context_type,
    g.context_id,
    g.ncx_amount,
    g.receiver_ncx,
    g.platform_fee_ncx,
    g.is_anonymous,
    g.metadata,
    gi.ugx_value,
    g.idempotency_key,
    c.attempts
  from claimed c
  join public.gifts g on g.id = c.finance_gift_id
  left join public.gift_items gi on gi.id = g.gift_item_id;
end;
$$;

create or replace function public.complete_gift_projection(
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
  update public.gift_projection_outbox
  set status = case when p_success then 'synced' else 'failed' end,
      last_error = case when p_success then null else left(coalesce(p_error, 'Projection failed'), 2000) end,
      next_attempt_at = case
        when p_success then now()
        else now() + least(interval '1 hour', interval '1 minute' * greatest(1, attempts * 2))
      end,
      updated_at = now()
  where finance_gift_id = p_finance_gift_id;

  update public.gifts
  set community_sync_status = case when p_success then 'synced' else 'failed' end,
      community_sync_attempts = coalesce((
        select attempts from public.gift_projection_outbox
        where finance_gift_id = p_finance_gift_id
      ), community_sync_attempts),
      community_sync_error = case when p_success then null else left(coalesce(p_error, 'Projection failed'), 2000) end,
      community_synced_at = case when p_success then now() else community_synced_at end
  where id = p_finance_gift_id;
end;
$$;

revoke all on function public.claim_gift_projection_batch(integer)
  from public, anon, authenticated;
revoke all on function public.complete_gift_projection(uuid, boolean, text)
  from public, anon, authenticated;
grant execute on function public.claim_gift_projection_batch(integer) to service_role;
grant execute on function public.complete_gift_projection(uuid, boolean, text) to service_role;

commit;
`