begin;

alter table public.community_gifts
  add column if not exists finance_gift_id uuid,
  add column if not exists idempotency_key text,
  add column if not exists receiver_ncx bigint,
  add column if not exists platform_fee_ncx bigint,
  add column if not exists listing_id uuid;

alter table public.community_gifts
  alter column post_id drop not null;

alter table public.listings
  add column if not exists gifts_count integer default 0,
  add column if not exists gifts_fiat_value bigint default 0;

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

update public.notifications
set type = coalesce(type, 'social'),
    title = coalesce(title, 'Necxa notification'),
    body = coalesce(body, ''),
    target_type = coalesce(target_type, 'post'),
    metadata = coalesce(metadata, '{}'::jsonb),
    is_read = coalesce(is_read, false),
    created_at = coalesce(created_at, now());

create unique index if not exists community_gifts_finance_gift_id_idx
  on public.community_gifts (finance_gift_id)
  where finance_gift_id is not null;

drop index if exists public.notifications_user_dedupe_idx;
create unique index notifications_user_dedupe_idx
  on public.notifications (user_id, dedupe_key);

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
  p_metadata jsonb default '{}'::jsonb,
  p_context_type text default 'creator_post'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post record;
  v_listing record;
  v_gift_id uuid;
  v_listing_id uuid := null;
  v_final_post_id uuid := null;
  v_fiat_value bigint;
begin
  if p_context_type not in ('creator_post', 'listing') then
    raise exception 'Unsupported community gift context';
  end if;
  if p_idempotency_key is null or p_idempotency_key = '' then
    raise exception 'idempotency_key is required';
  end if;
  if p_finance_gift_id is null then
    raise exception 'finance_gift_id is required';
  end if;
  if p_ncx_amount <= 0 or p_receiver_ncx < 0 or p_platform_fee_ncx < 0 then
    raise exception 'Invalid gift amounts';
  end if;
  if p_sender_id = p_receiver_id then
    raise exception 'Cannot gift yourself';
  end if;
  if p_context_type = 'listing' then
    v_listing_id := p_post_id;
    select * into v_listing from public.listings where id = v_listing_id;
    if not found then raise exception 'Listing not found'; end if;
    if coalesce(v_listing.lister_id, v_listing.user_id) <> p_receiver_id then
      raise exception 'Gift receiver does not own this listing';
    end if;
  else
    v_final_post_id := p_post_id;
    select * into v_post from public.community_posts where id = v_final_post_id;
    if not found then raise exception 'Community post not found'; end if;
    if v_post.author_id <> p_receiver_id then
      raise exception 'Gift receiver does not own the community post';
    end if;
  end if;

  v_fiat_value := greatest(0, coalesce((p_metadata->>'ugx_value')::bigint, p_ncx_amount * 100));

  insert into public.community_gifts (
    post_id, listing_id, sender_id, receiver_id, gift_type, coin_amount,
    finance_gift_id, idempotency_key, receiver_ncx, platform_fee_ncx,
    fiat_value_generated
  ) values (
    v_final_post_id, v_listing_id, p_sender_id, p_receiver_id, p_gift_item_id, p_ncx_amount::integer,
    p_finance_gift_id, p_idempotency_key, p_receiver_ncx, p_platform_fee_ncx,
    v_fiat_value
  )
  on conflict do nothing
  returning id into v_gift_id;

  if v_gift_id is null then
    select id into v_gift_id
    from public.community_gifts
    where idempotency_key = p_idempotency_key
       or finance_gift_id = p_finance_gift_id
    limit 1;
    return jsonb_build_object('recorded', false, 'gift_id', v_gift_id);
  end if;

  if p_context_type = 'listing' then
    update public.listings
    set gifts_count = coalesce(gifts_count, 0) + 1,
        gifts_fiat_value = coalesce(gifts_fiat_value, 0) + v_fiat_value,
        updated_at = now()
    where id = v_listing_id;
  else
    update public.community_posts
    set gifts_count = coalesce(gifts_count, 0) + 1,
        gifts_fiat_value = coalesce(gifts_fiat_value, 0) + v_fiat_value,
        updated_at = now()
    where id = v_final_post_id;
  end if;

  insert into public.notifications (
    user_id, actor_id, notification_type, type, title, body,
    target_id, target_type, metadata, dedupe_key
  ) values (
    p_receiver_id, p_sender_id, 'social', 'social', 'New gift received',
    coalesce(p_metadata->>'sender_name', 'Someone') || ' sent you a gift.',
    p_post_id::text, p_context_type,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'kind', 'gift', 'gift_item_id', p_gift_item_id,
      'ncx_amount', p_ncx_amount, 'receiver_ncx', p_receiver_ncx,
      'platform_fee_ncx', p_platform_fee_ncx,
      'finance_gift_id', p_finance_gift_id,
      'context_type', p_context_type
    ),
    'gift:' || p_idempotency_key
  )
  on conflict (user_id, dedupe_key) do nothing;

  return jsonb_build_object('recorded', true, 'gift_id', v_gift_id);
end;
$$;

revoke all on function public.record_community_gift(
  uuid, uuid, uuid, uuid, text, bigint, bigint, bigint, text, jsonb, text
) from public, anon, authenticated;
grant execute on function public.record_community_gift(
  uuid, uuid, uuid, uuid, text, bigint, bigint, bigint, text, jsonb, text
) to service_role;

commit;
