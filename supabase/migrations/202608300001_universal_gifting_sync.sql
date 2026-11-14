begin;

-- 1. Extend community_gifts to support shop listings
alter table public.community_gifts
  add column if not exists listing_id uuid references public.listings(id) on delete set null,
  alter column post_id drop not null;

-- 2. Add aggregation columns to listings table
alter table public.listings
  add column if not exists gifts_count int default 0,
  add column if not exists gifts_fiat_value bigint default 0;

-- 3. Universal record_community_gift that handles both posts and listings
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
begin
  if p_idempotency_key is null or p_idempotency_key = '' then
    raise exception 'idempotency_key is required';
  end if;
  if p_ncx_amount <= 0 or p_receiver_ncx < 0 or p_platform_fee_ncx < 0 then
    raise exception 'Invalid gift amounts';
  end if;
  if p_sender_id = p_receiver_id then
    raise exception 'Cannot gift yourself';
  end if;

  if p_context_type = 'listing' then
    v_listing_id := p_post_id;
    execute format('select * from public.listings where id = %L', v_listing_id) into v_listing;
    if v_listing is null then raise exception 'Listing not found'; end if;
    if coalesce(v_listing.lister_id, v_listing.user_id) <> p_receiver_id then
      raise exception 'Gift receiver does not own this listing';
    end if;
  else
    v_final_post_id := p_post_id;
    execute format('select * from public.community_posts where id = %L', v_final_post_id) into v_post;
    if v_post is null then raise exception 'Community post not found'; end if;
    if v_post.author_id <> p_receiver_id then
      raise exception 'Gift receiver does not own the community post';
    end if;
  end if;

  insert into public.community_gifts (
    post_id, listing_id, sender_id, receiver_id, gift_type, coin_amount,
    finance_gift_id, idempotency_key, receiver_ncx, platform_fee_ncx,
    fiat_value_generated
  ) values (
    v_final_post_id, v_listing_id, p_sender_id, p_receiver_id, p_gift_item_id, p_ncx_amount::integer,
    p_finance_gift_id, p_idempotency_key, p_receiver_ncx, p_platform_fee_ncx,
    p_ncx_amount * 100
  )
  on conflict (idempotency_key) do nothing
  returning id into v_gift_id;

  if v_gift_id is null then
    select id into v_gift_id
    from public.community_gifts
    where idempotency_key = p_idempotency_key;
    return jsonb_build_object('recorded', false, 'gift_id', v_gift_id);
  end if;

  if p_context_type = 'listing' then
    execute format('update public.listings set gifts_count = coalesce(gifts_count, 0) + 1, gifts_fiat_value = coalesce(gifts_fiat_value, 0) + (%L * 100), updated_at = now() where id = %L', p_ncx_amount, v_listing_id);
  else
    execute format('update public.community_posts set gifts_count = coalesce(gifts_count, 0) + 1, gifts_fiat_value = coalesce(gifts_fiat_value, 0) + (%L * 100), updated_at = now() where id = %L', p_ncx_amount, v_final_post_id);
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

commit;
