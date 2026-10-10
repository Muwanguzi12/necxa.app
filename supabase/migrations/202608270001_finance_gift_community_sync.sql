begin;

-- Finance is authoritative for money movement. This table stores only the
-- social projection needed by the primary community feed.
alter table public.community_gifts
  add column if not exists finance_gift_id uuid,
  add column if not exists idempotency_key text,
  add column if not exists receiver_ncx bigint,
  add column if not exists platform_fee_ncx bigint;

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  notification_type text,
  type text not null default 'social',
  title text not null,
  body text not null,
  target_id text,
  target_type text not null default 'post',
  metadata jsonb not null default '{}'::jsonb,
  dedupe_key text,
  is_read boolean not null default false,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.notifications
  add column if not exists actor_id uuid,
  add column if not exists notification_type text,
  add column if not exists type text default 'social',
  add column if not exists title text default 'Necxa notification',
  add column if not exists body text default '',
  add column if not exists target_id text,
  add column if not exists target_type text default 'post',
  add column if not exists metadata jsonb default '{}'::jsonb,
  add column if not exists dedupe_key text,
  add column if not exists is_read boolean default false,
  add column if not exists read_at timestamptz,
  add column if not exists created_at timestamptz default now();

do $$
declare
  v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.notifications'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%notification_type%'
  loop
    execute format('alter table public.notifications drop constraint if exists %I', v_constraint.conname);
  end loop;
end;
$$;

update public.notifications
set type = coalesce(type, 'social'),
    title = coalesce(title, 'Necxa notification'),
    body = coalesce(body, ''),
    target_type = coalesce(target_type, 'post'),
    metadata = coalesce(metadata, '{}'::jsonb),
    is_read = coalesce(is_read, false),
    created_at = coalesce(created_at, now());

alter table public.notifications
  alter column type set default 'social',
  alter column title set default 'Necxa notification',
  alter column body set default '',
  alter column metadata set default '{}'::jsonb,
  alter column is_read set default false,
  alter column created_at set default now();

create unique index if not exists community_gifts_finance_idempotency_idx
  on public.community_gifts (idempotency_key)
  where idempotency_key is not null;

create unique index if not exists notifications_user_dedupe_idx
  on public.notifications (user_id, dedupe_key)
  where dedupe_key is not null;

create or replace function public.record_community_gift(
  p_finance_gift_id uuid,
  p_post_id uuid,
  p_sender_id uuid,
  p_receiver_id uuid,
  p_gift_item_id text,
  p_ncx_amount bigint,
  p_receiver_ncx bigint,
  p_platform_fee_ncx bigint,
  p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post public.community_posts;
  v_gift_id uuid;
begin
  if p_post_id is null or p_idempotency_key is null or p_idempotency_key = '' then
    raise exception 'post_id and idempotency_key are required';
  end if;
  if p_ncx_amount <= 0 or p_receiver_ncx < 0 or p_platform_fee_ncx < 0 then
    raise exception 'Invalid gift amounts';
  end if;
  if p_sender_id = p_receiver_id then
    raise exception 'Cannot gift yourself';
  end if;

  select * into v_post
  from public.community_posts
  where id = p_post_id
  for share;
  if not found then raise exception 'Community post not found'; end if;
  if v_post.author_id <> p_receiver_id then
    raise exception 'Gift receiver does not own the community post';
  end if;

  insert into public.community_gifts (
    post_id, sender_id, receiver_id, gift_type, coin_amount,
    finance_gift_id, idempotency_key, receiver_ncx, platform_fee_ncx,
    fiat_value_generated, creator_fiat_cut, necxa_fiat_fee
  ) values (
    p_post_id, p_sender_id, p_receiver_id, p_gift_item_id, p_ncx_amount::integer,
    p_finance_gift_id, p_idempotency_key, p_receiver_ncx, p_platform_fee_ncx,
    p_ncx_amount * 100, null, null
  )
  on conflict do nothing
  returning id into v_gift_id;

  if v_gift_id is null then
    select id into v_gift_id
    from public.community_gifts
    where idempotency_key = p_idempotency_key;
    return jsonb_build_object('recorded', false, 'gift_id', v_gift_id);
  end if;

  update public.community_posts
  set gifts_count = coalesce(gifts_count, 0) + 1,
      gifts_fiat_value = coalesce(gifts_fiat_value, 0) + (p_ncx_amount * 100),
      updated_at = now()
  where id = p_post_id;

  insert into public.notifications (
    user_id, actor_id, notification_type, type, title, body,
    target_id, target_type, metadata, dedupe_key
  ) values (
    p_receiver_id, p_sender_id, 'social', 'social', 'New gift received',
    coalesce(p_metadata->>'sender_name', 'Someone') || ' sent you a gift.',
    p_post_id::text, 'post',
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'kind', 'gift', 'gift_item_id', p_gift_item_id,
      'ncx_amount', p_ncx_amount, 'receiver_ncx', p_receiver_ncx,
      'platform_fee_ncx', p_platform_fee_ncx,
      'finance_gift_id', p_finance_gift_id
    ),
    'gift:' || p_idempotency_key
  )
  on conflict (user_id, dedupe_key) do nothing;

  return jsonb_build_object('recorded', true, 'gift_id', v_gift_id);
end;
$$;

revoke all on function public.record_community_gift(
  uuid, uuid, uuid, uuid, text, bigint, bigint, bigint, text, jsonb
) from public, anon, authenticated;
grant execute on function public.record_community_gift(
  uuid, uuid, uuid, uuid, text, bigint, bigint, bigint, text, jsonb
) to service_role;

-- Prevent callers of the retired primary-database path from applying the old
-- 60/40 fiat model. Finance process_gift remains the only money path.
create or replace function public.send_social_gift(
  p_post_id uuid,
  p_sender_id uuid,
  p_gift_type text,
  p_coin_amount int
) returns table (success boolean, message text, creator_gained bigint)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query select false,
    'Deprecated: use the Finance send_gift/process_gift path.',
    0::bigint;
end;
$$;

revoke all on function public.send_social_gift(uuid, uuid, text, int)
  from public, anon, authenticated;

commit;