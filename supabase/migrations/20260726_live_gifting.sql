-- Live gifts use a text channel identifier and must not be attached to a feed post.
create table if not exists public.live_gifts (
  id uuid primary key default gen_random_uuid(),
  channel_id text not null,
  sender_id uuid not null,
  receiver_id uuid not null,
  sender_name text not null default 'Viewer',
  sender_avatar text not null default '',
  gift_type text not null,
  coin_amount bigint not null check (coin_amount > 0),
  creator_ncx_cut bigint not null,
  necxa_ncx_fee bigint not null,
  idempotency_key text not null unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_live_gifts_channel_recent
  on public.live_gifts(channel_id, created_at desc);
create index if not exists idx_live_gifts_channel_sender
  on public.live_gifts(channel_id, sender_id);

alter table public.live_gifts enable row level security;

create or replace function public.process_live_gift_ncx(
  p_sender_auth_id uuid,
  p_receiver_auth_id uuid,
  p_channel_id text,
  p_ncx_amount bigint,
  p_gift_platform_fee_rate double precision,
  p_gift_details jsonb
)
returns table (
  success boolean,
  message text,
  gift_id uuid,
  platform_fee_paid bigint,
  receiver_amount_credited bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender_wallet public.wallets%rowtype;
  v_receiver_wallet public.wallets%rowtype;
  v_platform_fee_ncx bigint;
  v_receiver_ncx bigint;
  v_sender_new_balance bigint;
  v_receiver_new_balance bigint;
  v_gift_id uuid;
  v_idempotency_key text := nullif(trim(p_gift_details->>'idempotency_key'), '');
begin
  if trim(coalesce(p_channel_id, '')) = '' then
    return query select false, 'Live channel is required.', null::uuid, 0::bigint, 0::bigint;
    return;
  end if;
  if p_ncx_amount <= 0 then
    return query select false, 'Gift amount must be positive.', null::uuid, 0::bigint, 0::bigint;
    return;
  end if;
  if p_sender_auth_id = p_receiver_auth_id then
    return query select false, 'Cannot send a gift to yourself.', null::uuid, 0::bigint, 0::bigint;
    return;
  end if;
  if v_idempotency_key is null then
    return query select false, 'Idempotency key is required.', null::uuid, 0::bigint, 0::bigint;
    return;
  end if;

  select id into v_gift_id
  from public.live_gifts
  where idempotency_key = v_idempotency_key;
  if v_gift_id is not null then
    return query select true, 'Gift already processed.', v_gift_id, 0::bigint, 0::bigint;
    return;
  end if;

  v_platform_fee_ncx := floor(p_ncx_amount * p_gift_platform_fee_rate);
  v_receiver_ncx := p_ncx_amount - v_platform_fee_ncx;

  insert into public.wallets (user_id)
  values (p_receiver_auth_id)
  on conflict (user_id) do nothing;

  select * into v_sender_wallet
  from public.wallets
  where user_id = p_sender_auth_id
  for update;
  if not found or v_sender_wallet.coin_balance < p_ncx_amount then
    return query select false, 'Insufficient NCX balance.', null::uuid, 0::bigint, 0::bigint;
    return;
  end if;

  select * into v_receiver_wallet
  from public.wallets
  where user_id = p_receiver_auth_id
  for update;

  update public.wallets
  set coin_balance = coin_balance - p_ncx_amount, updated_at = now()
  where id = v_sender_wallet.id
  returning coin_balance into v_sender_new_balance;

  update public.wallets
  set coin_balance = coin_balance + v_receiver_ncx, updated_at = now()
  where id = v_receiver_wallet.id
  returning coin_balance into v_receiver_new_balance;

  insert into public.live_gifts (
    channel_id,
    sender_id,
    receiver_id,
    sender_name,
    sender_avatar,
    gift_type,
    coin_amount,
    creator_ncx_cut,
    necxa_ncx_fee,
    idempotency_key
  )
  values (
    p_channel_id,
    p_sender_auth_id,
    p_receiver_auth_id,
    coalesce(nullif(trim(p_gift_details->>'sender_name'), ''), 'Viewer'),
    coalesce(p_gift_details->>'sender_avatar', ''),
    coalesce(nullif(trim(p_gift_details->>'gift_item_id'), ''), 'gift'),
    p_ncx_amount,
    v_receiver_ncx,
    v_platform_fee_ncx,
    v_idempotency_key
  )
  returning id into v_gift_id;

  insert into public.immutable_financial_ledger (
    user_id,
    entry_type,
    amount,
    currency,
    direction,
    balance_after,
    reference_id,
    metadata
  )
  values
    (
      p_sender_auth_id,
      'LIVE_GIFT_SENT',
      p_ncx_amount,
      'NCX',
      'out',
      v_sender_new_balance,
      v_gift_id,
      jsonb_build_object('receiver_id', p_receiver_auth_id, 'channel_id', p_channel_id)
    ),
    (
      p_receiver_auth_id,
      'LIVE_GIFT_RECEIVED',
      v_receiver_ncx,
      'NCX',
      'in',
      v_receiver_new_balance,
      v_gift_id,
      jsonb_build_object('sender_id', p_sender_auth_id, 'channel_id', p_channel_id)
    );

  return query
    select true, 'Gift sent successfully.', v_gift_id, v_platform_fee_ncx, v_receiver_ncx;
end;
$$;

revoke all on function public.process_live_gift_ncx(
  uuid,
  uuid,
  text,
  bigint,
  double precision,
  jsonb
) from public;
grant execute on function public.process_live_gift_ncx(
  uuid,
  uuid,
  text,
  bigint,
  double precision,
  jsonb
) to service_role;
