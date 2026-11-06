-- Gap fixes for Necxa Finance Backend

-- 1. Add missing wallets columns
alter table public.wallets
  add column if not exists escrow_balance bigint not null default 0,
  add column if not exists total_earned bigint not null default 0,
  add column if not exists total_spent bigint not null default 0,
  add column if not exists is_frozen boolean not null default false,
  add column if not exists freeze_reason text;

-- 2. Add missing payments columns
alter table public.payments
  add column if not exists settled_at timestamptz,
  add column if not exists provider_status text,
  add column if not exists provider_response jsonb default '{}'::jsonb,
  add column if not exists last_checked_at timestamptz;

-- 3. Create live_gifts table
create table if not exists public.live_gifts (
  id uuid primary key default gen_random_uuid(),
  channel_id text not null,
  sender_id uuid not null references public.finance_users(user_id) on delete restrict,
  sender_name text,
  sender_avatar text,
  gift_type text not null,
  coin_amount bigint not null check (coin_amount > 0),
  created_at timestamptz not null default now()
);
create index if not exists live_gifts_channel_idx on public.live_gifts(channel_id, created_at desc);
alter table public.live_gifts enable row level security;
revoke all on public.live_gifts from anon, authenticated;

-- 4. Create process_gift_ncx and process_live_gift_ncx RPCs
create or replace function public.process_gift_ncx(
  p_sender_auth_id uuid,
  p_receiver_auth_id uuid,
  p_post_id text,
  p_ncx_amount bigint,
  p_gift_platform_fee_rate numeric,
  p_gift_details jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_gift public.gifts;
begin
  v_gift := public.process_gift(
    p_sender_auth_id, p_receiver_auth_id,
    p_gift_details->>'gift_item_id',
    p_gift_details->>'context_type',
    p_post_id,
    p_ncx_amount,
    round(p_gift_platform_fee_rate * 10000)::integer,
    (p_gift_details->>'is_anonymous')::boolean,
    p_gift_details->>'idempotency_key',
    p_gift_details
  );
  return jsonb_build_object(
    'success', true,
    'gift_id', v_gift.id,
    'platform_fee_paid', v_gift.platform_fee_ncx,
    'receiver_amount_credited', v_gift.receiver_ncx
  );
end;
$$;
revoke all on function public.process_gift_ncx(uuid, uuid, text, bigint, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.process_gift_ncx(uuid, uuid, text, bigint, numeric, jsonb) to service_role;

create or replace function public.process_live_gift_ncx(
  p_sender_auth_id uuid,
  p_receiver_auth_id uuid,
  p_channel_id text,
  p_ncx_amount bigint,
  p_gift_platform_fee_rate numeric,
  p_gift_details jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_gift public.gifts;
begin
  v_gift := public.process_gift(
    p_sender_auth_id, p_receiver_auth_id,
    p_gift_details->>'gift_item_id',
    p_gift_details->>'context_type',
    p_channel_id,
    p_ncx_amount,
    round(p_gift_platform_fee_rate * 10000)::integer,
    (p_gift_details->>'is_anonymous')::boolean,
    p_gift_details->>'idempotency_key',
    p_gift_details
  );
  
  insert into public.live_gifts (
    channel_id, sender_id, sender_name, sender_avatar, gift_type, coin_amount
  ) values (
    p_channel_id, p_sender_auth_id, p_gift_details->>'sender_name', p_gift_details->>'sender_avatar',
    p_gift_details->>'gift_item_id', p_ncx_amount
  );

  return jsonb_build_object(
    'success', true,
    'gift_id', v_gift.id,
    'platform_fee_paid', v_gift.platform_fee_ncx,
    'receiver_amount_credited', v_gift.receiver_ncx
  );
end;
$$;
revoke all on function public.process_live_gift_ncx(uuid, uuid, text, bigint, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.process_live_gift_ncx(uuid, uuid, text, bigint, numeric, jsonb) to service_role;

-- 5. Create buy_coins_with_fiat_balance RPC
create or replace function public.buy_coins_with_fiat_balance(
  p_user_auth_id uuid,
  p_fiat_amount_to_spend bigint,
  p_ncx_to_receive bigint,
  p_fiat_currency public.finance_currency default 'UGX'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_wallet public.wallets;
  v_idempotency text;
begin
  v_idempotency := 'buy_coins_' || p_fiat_amount_to_spend || '_' || extract(epoch from now());
  v_wallet := public.debit_wallet(
    p_user_auth_id, p_fiat_amount_to_spend, p_fiat_currency, 'COIN_PURCHASE_DEBIT',
    null, v_idempotency || ':fiat'
  );
  v_wallet := public.credit_wallet(
    p_user_auth_id, p_ncx_to_receive, 'NCX', 'COIN_PURCHASE',
    null, v_idempotency || ':ncx'
  );
  return jsonb_build_object('success', true);
end;
$$;
revoke all on function public.buy_coins_with_fiat_balance(uuid, bigint, bigint, public.finance_currency) from public, anon, authenticated;
grant execute on function public.buy_coins_with_fiat_balance(uuid, bigint, bigint, public.finance_currency) to service_role;

-- 7. Missing share_investors columns
alter table public.share_investors
  add column if not exists investment_limit_ugx bigint,
  add column if not exists application_submitted_at timestamptz,
  add column if not exists kyc_reference text,
  add column if not exists aml_reference text,
  add column if not exists source_of_funds_reference text;

-- 7. close_share_subscription RPC
create or replace function public.close_share_subscription(
  p_subscription_id uuid,
  p_status text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_sub public.share_subscriptions;
begin
  select * into v_sub from public.share_subscriptions where id = p_subscription_id for update;
  if not found then raise exception 'Subscription not found'; end if;
  
  if v_sub.status in ('payment_pending', 'manual_review') then
    update public.share_subscriptions set status = p_status, updated_at = now() where id = p_subscription_id;
    if p_status in ('payment_failed', 'cancelled') then
       update public.share_offers set 
         reserved_shares = greatest(0, reserved_shares - v_sub.shares_requested),
         updated_at = now()
       where id = v_sub.offer_id;
    end if;
  end if;
end;
$$;
revoke all on function public.close_share_subscription(uuid, text) from public, anon, authenticated;
grant execute on function public.close_share_subscription(uuid, text) to service_role;
