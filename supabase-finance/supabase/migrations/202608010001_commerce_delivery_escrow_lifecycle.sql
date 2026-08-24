-- Authoritative commerce lifecycle for the Finance Supabase project.
-- Run this migration on ayvescksetiuekoyfqar before deploying finance-engine.

create extension if not exists pgcrypto;

alter table public.listings
  add column if not exists weight_kg numeric,
  add column if not exists length_cm numeric,
  add column if not exists width_cm numeric,
  add column if not exists height_cm numeric,
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists pickup_address text;

alter table public.commerce_orders
  add column if not exists product_title text,
  add column if not exists product_media_url text,
  add column if not exists delivered_at timestamptz,
  add column if not exists completed_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists settlement_status text not null default 'pending',
  add column if not exists version integer not null default 1;

alter table public.commerce_orders
  drop constraint if exists commerce_orders_status_check;
alter table public.commerce_orders
  add constraint commerce_orders_status_check check (status in (
    'pending', 'pending_payment', 'confirmed', 'processing',
    'ready_for_pickup', 'driver_assigned', 'picked_up',
    'out_for_delivery', 'delivered', 'completed', 'cancelled',
    'refunded', 'disputed'
  )) not valid;
alter table public.commerce_orders validate constraint commerce_orders_status_check;

alter table public.commerce_orders
  drop constraint if exists commerce_orders_settlement_status_check;
alter table public.commerce_orders
  add constraint commerce_orders_settlement_status_check check (
    settlement_status in ('pending', 'funded', 'held', 'released', 'refunded', 'disputed')
  );

create index if not exists commerce_orders_seller_created_idx
  on public.commerce_orders (seller_id, created_at desc);
create index if not exists commerce_orders_buyer_created_idx
  on public.commerce_orders (buyer_id, created_at desc);
create index if not exists commerce_orders_status_created_idx
  on public.commerce_orders (status, created_at desc);

create table if not exists public.commerce_escrows (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.commerce_orders(id) on delete restrict,
  buyer_id uuid not null,
  seller_id uuid not null,
  merchandise_amount_ugx bigint not null check (merchandise_amount_ugx >= 0),
  delivery_amount_ugx bigint not null check (delivery_amount_ugx >= 0),
  total_amount_ugx bigint generated always as
    (merchandise_amount_ugx + delivery_amount_ugx) stored,
  marketplace_fee_bps integer not null default 300 check (marketplace_fee_bps between 0 and 10000),
  delivery_fee_bps integer not null default 400 check (delivery_fee_bps between 0 and 10000),
  funding_source text not null check (funding_source in ('balance', 'pesapal', 'card', 'momo', 'crypto')),
  status text not null default 'funded' check (status in ('pending', 'funded', 'held', 'released', 'refunded', 'disputed')),
  funded_at timestamptz,
  released_at timestamptz,
  refunded_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists commerce_escrows_buyer_idx
  on public.commerce_escrows (buyer_id, created_at desc);
create index if not exists commerce_escrows_seller_idx
  on public.commerce_escrows (seller_id, created_at desc);
create index if not exists commerce_escrows_status_idx
  on public.commerce_escrows (status, created_at);

create table if not exists public.commerce_delivery_jobs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.commerce_orders(id) on delete restrict,
  buyer_id uuid not null,
  seller_id uuid not null,
  driver_id uuid,
  status text not null default 'awaiting_seller' check (status in (
    'awaiting_seller', 'ready_for_pickup', 'driver_assigned',
    'picked_up', 'out_for_delivery', 'delivered', 'completed',
    'cancelled', 'disputed'
  )),
  delivery_fee_ugx bigint not null default 0 check (delivery_fee_ugx >= 0),
  delivery_method text,
  delivery_speed text,
  pickup_location jsonb not null default '{}'::jsonb,
  dropoff_location jsonb not null default '{}'::jsonb,
  dropoff_address text,
  pickup_ready_at timestamptz,
  assigned_at timestamptz,
  picked_up_at timestamptz,
  delivered_at timestamptz,
  completed_at timestamptz,
  proof jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists commerce_delivery_available_idx
  on public.commerce_delivery_jobs (status, created_at)
  where driver_id is null;
create index if not exists commerce_delivery_driver_idx
  on public.commerce_delivery_jobs (driver_id, updated_at desc);
create index if not exists commerce_delivery_seller_idx
  on public.commerce_delivery_jobs (seller_id, updated_at desc);
create index if not exists commerce_delivery_buyer_idx
  on public.commerce_delivery_jobs (buyer_id, updated_at desc);

create table if not exists public.commerce_order_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.commerce_orders(id) on delete cascade,
  actor_id uuid,
  actor_role text not null check (actor_role in ('system', 'buyer', 'seller', 'driver', 'support')),
  event_type text not null,
  order_status text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists commerce_order_events_cursor_idx
  on public.commerce_order_events (order_id, id desc);

create table if not exists public.commerce_settlements (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.commerce_orders(id) on delete restrict,
  beneficiary_id uuid,
  beneficiary_type text not null check (beneficiary_type in ('seller', 'driver', 'platform')),
  gross_amount_ugx bigint not null check (gross_amount_ugx >= 0),
  fee_amount_ugx bigint not null check (fee_amount_ugx >= 0),
  net_amount_ugx bigint not null check (net_amount_ugx >= 0),
  status text not null default 'released' check (status in ('pending', 'released', 'reversed')),
  idempotency_key text not null unique,
  released_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (order_id, beneficiary_type)
);

create index if not exists commerce_settlements_beneficiary_idx
  on public.commerce_settlements (beneficiary_id, created_at desc);

create table if not exists public.commerce_platform_revenue (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.commerce_orders(id) on delete restrict,
  source text not null check (source in ('marketplace_fee', 'delivery_fee')),
  amount_ugx bigint not null check (amount_ugx >= 0),
  created_at timestamptz not null default now(),
  unique (order_id, source)
);

create table if not exists public.commerce_reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.commerce_orders(id) on delete restrict,
  listing_id uuid not null,
  buyer_id uuid not null,
  seller_id uuid not null,
  rating smallint not null check (rating between 1 and 5),
  comment text not null check (char_length(btrim(comment)) between 3 and 2000),
  media_urls jsonb not null default '[]'::jsonb,
  status text not null default 'published' check (status in ('published', 'hidden', 'reported', 'removed')),
  seller_response text,
  seller_responded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (order_id, listing_id, buyer_id)
);

-- Upgrade the legacy review table in place. Older NECXA deployments used
-- customer_id/vendor_id and did not have moderation or response columns.
-- Keep those legacy columns for old clients while backfilling the canonical
-- buyer_id/seller_id fields used by the finance API.
alter table public.commerce_reviews
  add column if not exists buyer_id uuid,
  add column if not exists seller_id uuid,
  add column if not exists media_urls jsonb not null default '[]'::jsonb,
  add column if not exists status text not null default 'published',
  add column if not exists seller_response text,
  add column if not exists seller_responded_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'commerce_reviews'
      and column_name = 'customer_id'
  ) then
    execute 'update public.commerce_reviews set buyer_id = customer_id where buyer_id is null';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'commerce_reviews'
      and column_name = 'vendor_id'
  ) then
    execute 'update public.commerce_reviews set seller_id = vendor_id where seller_id is null';
  end if;
end;
$$;

create unique index if not exists commerce_reviews_purchase_unique_idx
  on public.commerce_reviews (order_id, listing_id, buyer_id)
  where buyer_id is not null;

create index if not exists commerce_reviews_listing_idx
  on public.commerce_reviews (listing_id, created_at desc)
  where status = 'published';
create index if not exists commerce_reviews_seller_idx
  on public.commerce_reviews (seller_id, created_at desc);

create table if not exists public.finance_payment_effects (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null,
  effect_type text not null check (effect_type in (
    'wallet_deposit', 'commerce_escrow', 'coin_liquidation',
    'feature_unlock', 'distribution_charge', 'transport_hold'
  )),
  user_id uuid not null,
  amount_ugx bigint not null check (amount_ugx > 0),
  created_at timestamptz not null default now(),
  unique (idempotency_key, effect_type)
);

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'commerce_escrows', 'commerce_delivery_jobs', 'commerce_order_events',
    'commerce_settlements', 'commerce_platform_revenue', 'commerce_reviews',
    'finance_payment_effects'
  ] loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('revoke all on public.%I from anon, authenticated', v_table);
  end loop;
end;
$$;

alter table public.immutable_financial_ledger
  drop constraint if exists immutable_financial_ledger_entry_type_check;
alter table public.immutable_financial_ledger
  add constraint immutable_financial_ledger_entry_type_check check (entry_type in (
    'COIN_PURCHASE', 'WALLET_DEPOSIT', 'LISTING_UNLOCK', 'ESCROW_DEPOSIT',
    'ESCROW_RELEASE', 'ESCROW_REFUND', 'WITHDRAWAL', 'COMMISSION_PAYOUT',
    'SHOP_PURCHASE', 'GIFT_SENT', 'GIFT_RECEIVED', 'DELIVERY_FEE',
    'PLATFORM_FEE', 'COIN_PURCHASE_DEBIT', 'LIVE_GIFT_SENT',
    'LIVE_GIFT_RECEIVED', 'COIN_LIQUIDATION', 'FEATURE_UNLOCK',
    'ARTIST_DISTRIBUTION'
  )) not valid;

create table if not exists public.finance_feature_unlocks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  feature_id text not null,
  cost_ncx bigint not null check (cost_ncx > 0),
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  unique (user_id, feature_id)
);

create table if not exists public.finance_transport_bookings (
  order_id uuid primary key,
  customer_id uuid not null,
  driver_id uuid not null,
  pickup text not null,
  dropoff text not null,
  amount_ugx bigint not null check (amount_ugx > 0),
  status text not null default 'funded' check (status in ('funded', 'released', 'refunded', 'disputed')),
  idempotency_key text not null unique,
  funded_at timestamptz not null default now(),
  released_at timestamptz,
  refunded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.finance_platform_revenue (
  id uuid primary key default gen_random_uuid(),
  reference_id uuid not null,
  source text not null check (source in ('transport_fee')),
  amount_ugx bigint not null check (amount_ugx >= 0),
  created_at timestamptz not null default now(),
  unique (reference_id, source)
);

alter table public.finance_feature_unlocks enable row level security;
alter table public.finance_transport_bookings enable row level security;
alter table public.finance_platform_revenue enable row level security;
revoke all on public.finance_feature_unlocks from anon, authenticated;
revoke all on public.finance_transport_bookings from anon, authenticated;
revoke all on public.finance_platform_revenue from anon, authenticated;

create or replace function public.liquidate_ncx(
  p_user_id uuid,
  p_ncx_amount bigint,
  p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_effect uuid;
  v_wallet public.wallets;
  v_ugx bigint;
  v_burned numeric;
begin
  if p_ncx_amount <= 0 then raise exception 'NCX amount must be positive.'; end if;
  v_ugx := floor(p_ncx_amount * 100 * 0.89);
  v_burned := p_ncx_amount * 0.11;

  insert into public.finance_payment_effects (idempotency_key, effect_type, user_id, amount_ugx)
  values (p_idempotency_key, 'coin_liquidation', p_user_id, v_ugx)
  on conflict (idempotency_key, effect_type) do nothing
  returning id into v_effect;
  if v_effect is null then
    select * into v_wallet from public.wallets where user_id = p_user_id;
    return jsonb_build_object(
      'success', true, 'alreadyProcessed', true, 'ugxReceived', v_ugx,
      'ncxBurned', v_burned, 'newCoinBalance', coalesce(v_wallet.coin_balance, 0),
      'newFiatBalance', coalesce(v_wallet.fiat_balance, 0)
    );
  end if;

  select * into v_wallet from public.wallets where user_id = p_user_id for update;
  if not found or v_wallet.coin_balance < p_ncx_amount then raise exception 'Insufficient NCX balance.'; end if;

  update public.wallets
  set coin_balance = coin_balance - p_ncx_amount,
      fiat_balance = fiat_balance + v_ugx,
      updated_at = now()
  where user_id = p_user_id
  returning * into v_wallet;

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, metadata
  ) values
    (p_user_id, 'COIN_LIQUIDATION', p_ncx_amount, 'NCX', 'out', v_wallet.coin_balance,
      coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('idempotency_key', p_idempotency_key, 'burned_ncx', v_burned)),
    (p_user_id, 'COIN_LIQUIDATION', v_ugx, 'UGX', 'in', v_wallet.fiat_balance,
      jsonb_build_object('idempotency_key', p_idempotency_key, 'rate_ugx', 100));

  return jsonb_build_object(
    'success', true, 'alreadyProcessed', false, 'transactionId', v_effect,
    'ugxReceived', v_ugx, 'ncxBurned', v_burned,
    'newCoinBalance', v_wallet.coin_balance, 'newFiatBalance', v_wallet.fiat_balance
  );
end;
$$;

create or replace function public.charge_ncx_purpose(
  p_user_id uuid,
  p_amount_ncx bigint,
  p_purpose text,
  p_reference text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_effect uuid;
  v_wallet public.wallets;
  v_effect_type text;
  v_entry_type text;
begin
  if p_amount_ncx <= 0 then raise exception 'NCX amount must be positive.'; end if;
  if p_purpose = 'feature_unlock' then
    v_effect_type := 'feature_unlock'; v_entry_type := 'FEATURE_UNLOCK';
  elsif p_purpose = 'distribution_charge' then
    v_effect_type := 'distribution_charge'; v_entry_type := 'ARTIST_DISTRIBUTION';
  else
    raise exception 'Unsupported NCX charge purpose.';
  end if;

  insert into public.finance_payment_effects (idempotency_key, effect_type, user_id, amount_ugx)
  values (p_idempotency_key, v_effect_type, p_user_id, p_amount_ncx)
  on conflict (idempotency_key, effect_type) do nothing
  returning id into v_effect;
  if v_effect is null then
    select * into v_wallet from public.wallets where user_id = p_user_id;
    return jsonb_build_object('success', true, 'alreadyProcessed', true, 'newCoinBalance', coalesce(v_wallet.coin_balance, 0));
  end if;

  select * into v_wallet from public.wallets where user_id = p_user_id for update;
  if not found or v_wallet.coin_balance < p_amount_ncx then raise exception 'Insufficient NCX balance.'; end if;
  update public.wallets set coin_balance = coin_balance - p_amount_ncx, updated_at = now()
  where user_id = p_user_id returning * into v_wallet;

  if p_purpose = 'feature_unlock' then
    insert into public.finance_feature_unlocks (user_id, feature_id, cost_ncx, idempotency_key)
    values (p_user_id, p_reference, p_amount_ncx, p_idempotency_key)
    on conflict (user_id, feature_id) do nothing;
  end if;

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, metadata
  ) values (
    p_user_id, v_entry_type, p_amount_ncx, 'NCX', 'out', v_wallet.coin_balance,
    jsonb_build_object('purpose', p_purpose, 'reference', p_reference, 'idempotency_key', p_idempotency_key)
  );

  return jsonb_build_object('success', true, 'alreadyProcessed', false, 'newCoinBalance', v_wallet.coin_balance);
end;
$$;

create or replace function public.create_transport_booking_hold(
  p_order_id uuid,
  p_customer_id uuid,
  p_driver_id uuid,
  p_pickup text,
  p_dropoff text,
  p_amount_ugx bigint,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.finance_transport_bookings;
  v_wallet public.wallets;
begin
  if p_amount_ugx <= 0 then raise exception 'Fare must be positive.'; end if;
  select * into v_booking from public.finance_transport_bookings where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('success', true, 'alreadyFunded', true, 'orderId', v_booking.order_id); end if;

  select * into v_wallet from public.wallets where user_id = p_customer_id for update;
  if not found or v_wallet.fiat_balance < p_amount_ugx then raise exception 'Insufficient wallet balance.'; end if;
  update public.wallets
  set fiat_balance = fiat_balance - p_amount_ugx,
      escrow_balance = escrow_balance + p_amount_ugx,
      total_spent = total_spent + p_amount_ugx,
      updated_at = now()
  where user_id = p_customer_id returning * into v_wallet;

  insert into public.finance_transport_bookings (
    order_id, customer_id, driver_id, pickup, dropoff, amount_ugx, idempotency_key
  ) values (
    p_order_id, p_customer_id, p_driver_id, p_pickup, p_dropoff, p_amount_ugx, p_idempotency_key
  ) returning * into v_booking;

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, reference_id, metadata
  ) values (
    p_customer_id, 'ESCROW_DEPOSIT', p_amount_ugx, 'UGX', 'out', v_wallet.fiat_balance,
    p_order_id, jsonb_build_object('context', 'transport', 'driver_id', p_driver_id)
  );
  return jsonb_build_object('success', true, 'alreadyFunded', false, 'orderId', p_order_id);
end;
$$;

create or replace function public.settle_transport_booking(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.finance_transport_bookings;
  v_driver_net bigint;
  v_platform_fee bigint;
  v_driver_balance bigint;
  v_customer_escrow bigint;
begin
  select * into v_booking from public.finance_transport_bookings where order_id = p_order_id for update;
  if not found then raise exception 'Transport booking not found.'; end if;
  if v_booking.status = 'released' then return jsonb_build_object('success', true, 'alreadySettled', true); end if;
  if v_booking.status <> 'funded' then raise exception 'Transport escrow is not releasable.'; end if;

  v_platform_fee := round(v_booking.amount_ugx * 0.04);
  v_driver_net := v_booking.amount_ugx - v_platform_fee;
  insert into public.wallets (user_id, fiat_balance, total_earned)
  values (v_booking.driver_id, v_driver_net, v_driver_net)
  on conflict (user_id) do update
  set fiat_balance = public.wallets.fiat_balance + excluded.fiat_balance,
      total_earned = public.wallets.total_earned + excluded.total_earned,
      updated_at = now()
  returning fiat_balance into v_driver_balance;
  update public.wallets set escrow_balance = greatest(0, escrow_balance - v_booking.amount_ugx), updated_at = now()
  where user_id = v_booking.customer_id returning escrow_balance into v_customer_escrow;

  update public.finance_transport_bookings set status = 'released', released_at = now(), updated_at = now()
  where order_id = p_order_id;
  insert into public.finance_platform_revenue (reference_id, source, amount_ugx)
  values (p_order_id, 'transport_fee', v_platform_fee)
  on conflict (reference_id, source) do nothing;
  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, reference_id, metadata
  ) values
    (v_booking.driver_id, 'COMMISSION_PAYOUT', v_driver_net, 'UGX', 'in', v_driver_balance, p_order_id, jsonb_build_object('context', 'transport')),
    (v_booking.customer_id, 'ESCROW_RELEASE', v_booking.amount_ugx, 'UGX', 'out', coalesce(v_customer_escrow, 0), p_order_id, jsonb_build_object('context', 'transport'));
  return jsonb_build_object('success', true, 'alreadySettled', false, 'driverNetUgx', v_driver_net, 'platformFeeUgx', v_platform_fee);
end;
$$;

create or replace function public.refund_transport_booking(
  p_order_id uuid,
  p_reason text default 'booking_creation_failed'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.finance_transport_bookings;
  v_fiat_balance bigint;
  v_escrow_balance bigint;
begin
  select * into v_booking
  from public.finance_transport_bookings
  where order_id = p_order_id
  for update;

  if not found then
    raise exception 'Transport booking not found.';
  end if;
  if v_booking.status = 'refunded' then
    return jsonb_build_object('success', true, 'alreadyRefunded', true);
  end if;
  if v_booking.status <> 'funded' then
    raise exception 'Transport escrow is not refundable.';
  end if;

  update public.wallets
  set fiat_balance = fiat_balance + v_booking.amount_ugx,
      escrow_balance = greatest(0, escrow_balance - v_booking.amount_ugx),
      total_spent = greatest(0, total_spent - v_booking.amount_ugx),
      updated_at = now()
  where user_id = v_booking.customer_id
  returning fiat_balance, escrow_balance into v_fiat_balance, v_escrow_balance;

  update public.finance_transport_bookings
  set status = 'refunded', refunded_at = now(), updated_at = now()
  where order_id = p_order_id;

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after,
    reference_id, metadata
  ) values (
    v_booking.customer_id, 'ESCROW_REFUND', v_booking.amount_ugx, 'UGX',
    'in', v_fiat_balance, p_order_id,
    jsonb_build_object('context', 'transport', 'reason', left(coalesce(p_reason, ''), 500), 'escrow_after', v_escrow_balance)
  );

  return jsonb_build_object(
    'success', true,
    'alreadyRefunded', false,
    'newFiatBalance', v_fiat_balance,
    'newEscrowBalance', v_escrow_balance
  );
end;
$$;

create or replace function public.dispute_transport_booking(
  p_order_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.finance_transport_bookings;
begin
  select * into v_booking
  from public.finance_transport_bookings
  where order_id = p_order_id
  for update;
  if not found then raise exception 'Transport booking not found.'; end if;
  if v_booking.status = 'disputed' then
    return jsonb_build_object('success', true, 'alreadyDisputed', true);
  end if;
  if v_booking.status <> 'funded' then
    raise exception 'Transport escrow can no longer be disputed.';
  end if;

  update public.finance_transport_bookings
  set status = 'disputed', updated_at = now()
  where order_id = p_order_id;

  return jsonb_build_object(
    'success', true,
    'alreadyDisputed', false,
    'reason', left(coalesce(p_reason, ''), 500)
  );
end;
$$;

create or replace function public.credit_wallet_fiat(
  p_user_id uuid,
  p_amount_ugx bigint,
  p_reference text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_effect_id uuid;
  v_new_fiat bigint;
begin
  if p_amount_ugx <= 0 then
    raise exception 'Deposit amount must be positive.';
  end if;

  insert into public.finance_payment_effects (
    idempotency_key, effect_type, user_id, amount_ugx
  ) values (
    p_reference, 'wallet_deposit', p_user_id, p_amount_ugx
  )
  on conflict (idempotency_key, effect_type) do nothing
  returning id into v_effect_id;

  if v_effect_id is null then
    select fiat_balance into v_new_fiat from public.wallets where user_id = p_user_id;
    return jsonb_build_object('success', true, 'alreadyCredited', true, 'newBalance', coalesce(v_new_fiat, 0));
  end if;

  insert into public.wallets (user_id, fiat_balance)
  values (p_user_id, p_amount_ugx)
  on conflict (user_id) do update
  set fiat_balance = public.wallets.fiat_balance + excluded.fiat_balance,
      updated_at = now()
  returning fiat_balance into v_new_fiat;

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, reference_id, metadata
  ) values (
    p_user_id, 'WALLET_DEPOSIT', p_amount_ugx, 'UGX', 'in', v_new_fiat, null,
    jsonb_build_object('idempotency_key', p_reference, 'provider', 'pesapal')
  );

  return jsonb_build_object('success', true, 'alreadyCredited', false, 'newBalance', v_new_fiat);
end;
$$;

create or replace function public.fund_commerce_order_from_external_payment(
  p_order_id uuid,
  p_payment_id text,
  p_funding_source text default 'pesapal'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.commerce_orders;
  v_escrow public.commerce_escrows;
  v_buyer_escrow bigint;
begin
  select * into v_order
  from public.commerce_orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found.';
  end if;
  if v_order.payment_id is distinct from p_payment_id then
    raise exception 'Payment does not belong to this order.';
  end if;

  select * into v_escrow
  from public.commerce_escrows
  where order_id = v_order.id;
  if found and v_escrow.status in ('funded', 'held', 'released') then
    return jsonb_build_object('success', true, 'orderId', v_order.id, 'alreadyFunded', true);
  end if;

  insert into public.wallets (user_id, fiat_balance, escrow_balance, total_spent)
  values (v_order.buyer_id, 0, v_order.total_ugx, v_order.total_ugx)
  on conflict (user_id) do update
  set escrow_balance = public.wallets.escrow_balance + excluded.escrow_balance,
      total_spent = public.wallets.total_spent + v_order.total_ugx,
      updated_at = now()
  returning escrow_balance into v_buyer_escrow;

  insert into public.commerce_escrows (
    order_id, buyer_id, seller_id, merchandise_amount_ugx,
    delivery_amount_ugx, funding_source, status, funded_at
  ) values (
    v_order.id, v_order.buyer_id, v_order.seller_id,
    v_order.unit_price_ugx * v_order.quantity,
    v_order.delivery_fee_ugx, p_funding_source, 'funded', now()
  )
  on conflict (order_id) do update
  set status = 'funded', funded_at = coalesce(public.commerce_escrows.funded_at, now()), updated_at = now();

  insert into public.commerce_delivery_jobs (
    order_id, buyer_id, seller_id, delivery_fee_ugx, delivery_method,
    delivery_speed, pickup_location, dropoff_location, dropoff_address
  ) values (
    v_order.id, v_order.buyer_id, v_order.seller_id,
    v_order.delivery_fee_ugx, v_order.delivery_method, v_order.delivery_speed,
    coalesce((
      select jsonb_build_object(
        'address', pickup_address,
        'latitude', latitude,
        'longitude', longitude
      )
      from public.listings where id = v_order.listing_id
    ), '{}'::jsonb),
    coalesce(v_order.customer_location, '{}'::jsonb), v_order.delivery_address
  ) on conflict (order_id) do nothing;

  update public.commerce_inventory_reservations
  set status = 'committed', finance_order_id = v_order.id, updated_at = now()
  where id = v_order.reservation_id or idempotency_key = v_order.idempotency_key || '-inv';

  update public.commerce_orders
  set payment_status = 'COMPLETED', status = 'confirmed',
      settlement_status = 'funded', updated_at = now(), version = version + 1
  where id = v_order.id;

  insert into public.commerce_order_events (order_id, actor_role, event_type, order_status, metadata)
  values (v_order.id, 'system', 'payment_confirmed', 'confirmed', jsonb_build_object('paymentId', p_payment_id));

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, reference_id, metadata
  ) values (
    v_order.buyer_id, 'ESCROW_DEPOSIT', v_order.total_ugx, 'UGX', 'out', v_buyer_escrow,
    v_order.id, jsonb_build_object('order_number', v_order.order_number, 'source', p_funding_source)
  );

  return jsonb_build_object('success', true, 'orderId', v_order.id, 'alreadyFunded', false);
end;
$$;

drop function if exists public.process_shop_purchase_with_balance(uuid, uuid, integer, bigint, text, text, text, text, jsonb, text);

create function public.process_shop_purchase_with_balance(
  p_buyer_id uuid,
  p_listing_id uuid,
  p_quantity integer,
  p_delivery_fee_ugx bigint,
  p_delivery_address text,
  p_delivery_phone text,
  p_delivery_speed text,
  p_delivery_method text,
  p_customer_location jsonb,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing public.listings;
  v_wallet public.wallets;
  v_reservation public.commerce_inventory_reservations;
  v_order public.commerce_orders;
  v_items_ugx bigint;
  v_total_ugx bigint;
  v_new_fiat bigint;
  v_new_escrow bigint;
begin
  if p_quantity <= 0 or p_quantity > 99 then
    raise exception 'Quantity must be between 1 and 99.';
  end if;
  if p_delivery_fee_ugx < 0 then
    raise exception 'Delivery fee cannot be negative.';
  end if;

  select * into v_order
  from public.commerce_orders
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'success', true, 'orderId', v_order.id, 'orderNumber', v_order.order_number,
      'deliveryFeeUgx', v_order.delivery_fee_ugx, 'totalUgx', v_order.total_ugx,
      'message', 'Order already exists.'
    );
  end if;

  select * into v_listing
  from public.listings
  where id = p_listing_id and status = 'active'
  for update;
  if not found then
    raise exception 'Listing not found or not active.';
  end if;
  if coalesce(v_listing.user_id, v_listing.lister_id) = p_buyer_id then
    raise exception 'Cannot purchase your own listing.';
  end if;
  if coalesce(v_listing.stock_count, 0) < p_quantity then
    raise exception 'Insufficient stock. Only % unit(s) available.', coalesce(v_listing.stock_count, 0);
  end if;

  insert into public.wallets (user_id, fiat_balance, escrow_balance)
  values (p_buyer_id, 0, 0)
  on conflict (user_id) do nothing;
  select * into v_wallet from public.wallets where user_id = p_buyer_id for update;

  v_items_ugx := v_listing.price::bigint * p_quantity;
  v_total_ugx := v_items_ugx + p_delivery_fee_ugx;
  if v_wallet.fiat_balance < v_total_ugx then
    raise exception using
      message = 'Insufficient funds.', hint = 'insufficient_funds',
      detail = format('Balance: %s UGX, Required: %s UGX', v_wallet.fiat_balance, v_total_ugx);
  end if;

  update public.listings
  set stock_count = stock_count - p_quantity, updated_at = now()
  where id = p_listing_id;

  insert into public.commerce_inventory_reservations (
    listing_id, customer_id, quantity, idempotency_key, status
  ) values (
    p_listing_id, p_buyer_id, p_quantity, p_idempotency_key || '-inv', 'committed'
  ) returning * into v_reservation;

  update public.wallets
  set fiat_balance = fiat_balance - v_total_ugx,
      escrow_balance = escrow_balance + v_total_ugx,
      total_spent = total_spent + v_total_ugx,
      updated_at = now()
  where user_id = p_buyer_id
  returning fiat_balance, escrow_balance into v_new_fiat, v_new_escrow;

  insert into public.commerce_orders (
    buyer_id, listing_id, seller_id, product_title, product_media_url,
    quantity, unit_price_ugx, delivery_fee_ugx, total_ugx,
    delivery_address, delivery_phone, delivery_speed, delivery_method, customer_location,
    payment_method, payment_status, status, settlement_status,
    idempotency_key, reservation_id
  ) values (
    p_buyer_id, p_listing_id, coalesce(v_listing.user_id, v_listing.lister_id),
    v_listing.title, v_listing.media_url,
    p_quantity, v_listing.price::bigint, p_delivery_fee_ugx, v_total_ugx,
    p_delivery_address, p_delivery_phone, p_delivery_speed, p_delivery_method,
    coalesce(p_customer_location, '{}'::jsonb),
    'balance', 'COMPLETED', 'confirmed', 'funded',
    p_idempotency_key, v_reservation.id
  ) returning * into v_order;

  update public.commerce_inventory_reservations
  set finance_order_id = v_order.id, updated_at = now()
  where id = v_reservation.id;

  insert into public.commerce_escrows (
    order_id, buyer_id, seller_id, merchandise_amount_ugx,
    delivery_amount_ugx, funding_source, status, funded_at
  ) values (
    v_order.id, v_order.buyer_id, v_order.seller_id,
    v_items_ugx, p_delivery_fee_ugx, 'balance', 'funded', now()
  );

  insert into public.commerce_delivery_jobs (
    order_id, buyer_id, seller_id, delivery_fee_ugx, delivery_method,
    delivery_speed, pickup_location, dropoff_location, dropoff_address
  ) values (
    v_order.id, v_order.buyer_id, v_order.seller_id,
    p_delivery_fee_ugx, p_delivery_method, p_delivery_speed,
    jsonb_build_object(
      'address', v_listing.pickup_address,
      'latitude', v_listing.latitude,
      'longitude', v_listing.longitude
    ),
    coalesce(p_customer_location, '{}'::jsonb), p_delivery_address
  );

  insert into public.commerce_order_events (order_id, actor_id, actor_role, event_type, order_status)
  values (v_order.id, p_buyer_id, 'buyer', 'order_created', 'confirmed');

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, reference_id, metadata
  ) values (
    p_buyer_id, 'SHOP_PURCHASE', v_total_ugx, 'UGX', 'out', v_new_fiat,
    v_order.id, jsonb_build_object(
      'order_number', v_order.order_number, 'listing_id', p_listing_id,
      'quantity', p_quantity, 'escrow_balance', v_new_escrow
    )
  );

  return jsonb_build_object(
    'success', true, 'orderId', v_order.id, 'orderNumber', v_order.order_number,
    'deliveryFeeUgx', v_order.delivery_fee_ugx, 'totalUgx', v_order.total_ugx,
    'newBalance', v_new_fiat, 'escrowBalance', v_new_escrow,
    'message', 'Purchase secured in escrow.'
  );
end;
$$;

create or replace function public.settle_commerce_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.commerce_orders;
  v_escrow public.commerce_escrows;
  v_delivery public.commerce_delivery_jobs;
  v_seller_fee bigint;
  v_driver_fee bigint;
  v_seller_net bigint;
  v_driver_net bigint;
  v_platform_total bigint;
  v_seller_balance bigint;
  v_driver_balance bigint;
  v_buyer_escrow bigint;
begin
  select * into v_order from public.commerce_orders where id = p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;

  select * into v_escrow from public.commerce_escrows where order_id = p_order_id for update;
  if not found or v_escrow.status not in ('funded', 'held') then
    if found and v_escrow.status = 'released' then
      return jsonb_build_object('success', true, 'alreadySettled', true, 'orderId', p_order_id);
    end if;
    raise exception 'Order escrow is not releasable.';
  end if;

  select * into v_delivery from public.commerce_delivery_jobs where order_id = p_order_id for update;
  if not found or v_delivery.status <> 'delivered' then
    raise exception 'Delivery must be verified before settlement.';
  end if;
  if v_order.delivery_fee_ugx > 0 and v_delivery.driver_id is null then
    raise exception 'A driver is required before settlement.';
  end if;

  v_seller_fee := round(v_escrow.merchandise_amount_ugx * v_escrow.marketplace_fee_bps / 10000.0);
  v_driver_fee := round(v_escrow.delivery_amount_ugx * v_escrow.delivery_fee_bps / 10000.0);
  v_seller_net := v_escrow.merchandise_amount_ugx - v_seller_fee;
  v_driver_net := v_escrow.delivery_amount_ugx - v_driver_fee;
  v_platform_total := v_seller_fee + v_driver_fee;

  insert into public.wallets (user_id, fiat_balance, total_earned)
  values (v_order.seller_id, v_seller_net, v_seller_net)
  on conflict (user_id) do update
  set fiat_balance = public.wallets.fiat_balance + excluded.fiat_balance,
      total_earned = public.wallets.total_earned + excluded.fiat_balance,
      updated_at = now()
  returning fiat_balance into v_seller_balance;

  if v_delivery.driver_id is not null and v_driver_net > 0 then
    insert into public.wallets (user_id, fiat_balance, total_earned)
    values (v_delivery.driver_id, v_driver_net, v_driver_net)
    on conflict (user_id) do update
    set fiat_balance = public.wallets.fiat_balance + excluded.fiat_balance,
        total_earned = public.wallets.total_earned + excluded.fiat_balance,
        updated_at = now()
    returning fiat_balance into v_driver_balance;
  end if;

  update public.wallets
  set escrow_balance = greatest(0, escrow_balance - v_escrow.total_amount_ugx), updated_at = now()
  where user_id = v_order.buyer_id
  returning escrow_balance into v_buyer_escrow;

  insert into public.commerce_settlements (
    order_id, beneficiary_id, beneficiary_type, gross_amount_ugx,
    fee_amount_ugx, net_amount_ugx, idempotency_key, released_at
  ) values (
    p_order_id, v_order.seller_id, 'seller', v_escrow.merchandise_amount_ugx,
    v_seller_fee, v_seller_net, p_order_id::text || ':seller', now()
  );

  if v_delivery.driver_id is not null and v_escrow.delivery_amount_ugx > 0 then
    insert into public.commerce_settlements (
      order_id, beneficiary_id, beneficiary_type, gross_amount_ugx,
      fee_amount_ugx, net_amount_ugx, idempotency_key, released_at
    ) values (
      p_order_id, v_delivery.driver_id, 'driver', v_escrow.delivery_amount_ugx,
      v_driver_fee, v_driver_net, p_order_id::text || ':driver', now()
    );
  end if;

  insert into public.commerce_settlements (
    order_id, beneficiary_type, gross_amount_ugx, fee_amount_ugx,
    net_amount_ugx, idempotency_key, released_at
  ) values (
    p_order_id, 'platform', v_platform_total, 0,
    v_platform_total, p_order_id::text || ':platform', now()
  );

  insert into public.commerce_platform_revenue (order_id, source, amount_ugx)
  values
    (p_order_id, 'marketplace_fee', v_seller_fee),
    (p_order_id, 'delivery_fee', v_driver_fee)
  on conflict (order_id, source) do nothing;

  update public.commerce_escrows
  set status = 'released', released_at = now(), updated_at = now()
  where id = v_escrow.id;
  update public.commerce_delivery_jobs
  set status = 'completed', completed_at = now(), updated_at = now()
  where id = v_delivery.id;
  update public.commerce_orders
  set status = 'completed', settlement_status = 'released', completed_at = now(),
      updated_at = now(), version = version + 1
  where id = p_order_id;

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, reference_id, metadata
  ) values
    (v_order.seller_id, 'ESCROW_RELEASE', v_seller_net, 'UGX', 'in', v_seller_balance,
      p_order_id, jsonb_build_object('beneficiary', 'seller', 'fee', v_seller_fee)),
    (v_order.buyer_id, 'ESCROW_RELEASE', v_escrow.total_amount_ugx, 'UGX', 'out', coalesce(v_buyer_escrow, 0),
      p_order_id, jsonb_build_object('beneficiary', 'buyer'));

  if v_delivery.driver_id is not null and v_driver_net > 0 then
    insert into public.immutable_financial_ledger (
      user_id, entry_type, amount, currency, direction, balance_after, reference_id, metadata
    ) values (
      v_delivery.driver_id, 'COMMISSION_PAYOUT', v_driver_net, 'UGX', 'in', v_driver_balance,
      p_order_id, jsonb_build_object('beneficiary', 'driver', 'fee', v_driver_fee)
    );
  end if;

  insert into public.commerce_order_events (order_id, actor_role, event_type, order_status, metadata)
  values (p_order_id, 'system', 'escrow_released', 'completed', jsonb_build_object(
    'sellerNetUgx', v_seller_net, 'driverNetUgx', v_driver_net, 'platformFeeUgx', v_platform_total
  ));

  return jsonb_build_object(
    'success', true, 'alreadySettled', false, 'orderId', p_order_id,
    'sellerNetUgx', v_seller_net, 'driverNetUgx', v_driver_net,
    'platformFeeUgx', v_platform_total
  );
end;
$$;

create or replace function public.transition_commerce_order(
  p_order_id uuid,
  p_actor_id uuid,
  p_actor_role text,
  p_action text,
  p_driver_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.commerce_orders;
  v_delivery public.commerce_delivery_jobs;
  v_next_status text;
begin
  select * into v_order from public.commerce_orders where id = p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;
  select * into v_delivery from public.commerce_delivery_jobs where order_id = p_order_id for update;
  if not found then raise exception 'Delivery job not found.'; end if;

  if p_actor_role = 'seller' and v_order.seller_id <> p_actor_id then raise exception 'Seller access denied.'; end if;
  if p_actor_role = 'buyer' and v_order.buyer_id <> p_actor_id then raise exception 'Buyer access denied.'; end if;
  if p_actor_role = 'driver' and p_driver_id is distinct from p_actor_id then raise exception 'Driver access denied.'; end if;

  -- A repeated authorized ready-for-pickup request is safe after a delayed
  -- mobile response; skipped lifecycle states remain invalid below.
  if p_action = 'seller_ready'
    and p_actor_role = 'seller'
    and v_delivery.status = 'ready_for_pickup' then
    return jsonb_build_object('success', true, 'alreadyApplied', true, 'orderId', p_order_id, 'status', v_delivery.status);
  end if;

  if p_action = 'seller_ready' then
    if p_actor_role <> 'seller' or v_delivery.status <> 'awaiting_seller' then raise exception 'Invalid ready-for-pickup transition.'; end if;
    v_next_status := 'ready_for_pickup';
    update public.commerce_delivery_jobs set status = v_next_status, pickup_ready_at = now(), updated_at = now() where id = v_delivery.id;
  elsif p_action = 'driver_accept' then
    if p_actor_role <> 'driver' or v_delivery.status <> 'ready_for_pickup' or v_delivery.driver_id is not null then raise exception 'Delivery is no longer available.'; end if;
    v_next_status := 'driver_assigned';
    update public.commerce_delivery_jobs set status = v_next_status, driver_id = p_actor_id, assigned_at = now(), updated_at = now() where id = v_delivery.id;
  elsif p_action = 'driver_pickup' then
    if p_actor_role <> 'driver' or v_delivery.driver_id is distinct from p_actor_id or v_delivery.status <> 'driver_assigned' then raise exception 'Invalid pickup transition.'; end if;
    v_next_status := 'picked_up';
    update public.commerce_delivery_jobs set status = v_next_status, picked_up_at = now(), updated_at = now() where id = v_delivery.id;
  elsif p_action = 'driver_depart' then
    if p_actor_role <> 'driver' or v_delivery.driver_id is distinct from p_actor_id or v_delivery.status <> 'picked_up' then raise exception 'Invalid departure transition.'; end if;
    v_next_status := 'out_for_delivery';
    update public.commerce_delivery_jobs set status = v_next_status, updated_at = now() where id = v_delivery.id;
  elsif p_action = 'driver_delivered' then
    if p_actor_role <> 'driver' or v_delivery.driver_id is distinct from p_actor_id or v_delivery.status not in ('picked_up', 'out_for_delivery') then raise exception 'Invalid delivery transition.'; end if;
    v_next_status := 'delivered';
    update public.commerce_delivery_jobs set status = v_next_status, delivered_at = now(), proof = coalesce(p_metadata, '{}'::jsonb), updated_at = now() where id = v_delivery.id;
    update public.commerce_orders set delivered_at = now() where id = p_order_id;
  elsif p_action = 'buyer_confirm' then
    if p_actor_role <> 'buyer' or v_delivery.status <> 'delivered' then raise exception 'Delivery has not been verified.'; end if;
    perform public.settle_commerce_order(p_order_id);
    return jsonb_build_object('success', true, 'orderId', p_order_id, 'status', 'completed');
  elsif p_action = 'open_dispute' then
    if p_actor_role not in ('buyer', 'seller') or v_order.status in ('completed', 'cancelled', 'refunded') then raise exception 'This order cannot be disputed.'; end if;
    v_next_status := 'disputed';
    update public.commerce_delivery_jobs set status = v_next_status, updated_at = now() where id = v_delivery.id;
    update public.commerce_escrows set status = 'disputed', updated_at = now() where order_id = p_order_id;
  else
    raise exception 'Unsupported commerce action.';
  end if;

  update public.commerce_orders
  set status = v_next_status,
      settlement_status = case when v_next_status = 'disputed' then 'disputed' else settlement_status end,
      updated_at = now(), version = version + 1
  where id = p_order_id;

  insert into public.commerce_order_events (order_id, actor_id, actor_role, event_type, order_status, metadata)
  values (p_order_id, p_actor_id, p_actor_role, p_action, v_next_status, coalesce(p_metadata, '{}'::jsonb));

  return jsonb_build_object('success', true, 'orderId', p_order_id, 'status', v_next_status);
end;
$$;

revoke all on function public.fund_commerce_order_from_external_payment(uuid, text, text) from public, anon, authenticated;
revoke all on function public.credit_wallet_fiat(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.process_shop_purchase_with_balance(uuid, uuid, integer, bigint, text, text, text, text, jsonb, text) from public, anon, authenticated;
revoke all on function public.settle_commerce_order(uuid) from public, anon, authenticated;
revoke all on function public.transition_commerce_order(uuid, uuid, text, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.liquidate_ncx(uuid, bigint, text, jsonb) from public, anon, authenticated;
revoke all on function public.charge_ncx_purpose(uuid, bigint, text, text, text) from public, anon, authenticated;
revoke all on function public.create_transport_booking_hold(uuid, uuid, uuid, text, text, bigint, text) from public, anon, authenticated;
revoke all on function public.settle_transport_booking(uuid) from public, anon, authenticated;
revoke all on function public.refund_transport_booking(uuid, text) from public, anon, authenticated;
revoke all on function public.dispute_transport_booking(uuid, text) from public, anon, authenticated;

grant execute on function public.fund_commerce_order_from_external_payment(uuid, text, text) to service_role;
grant execute on function public.credit_wallet_fiat(uuid, bigint, text) to service_role;
grant execute on function public.process_shop_purchase_with_balance(uuid, uuid, integer, bigint, text, text, text, text, jsonb, text) to service_role;
grant execute on function public.settle_commerce_order(uuid) to service_role;
grant execute on function public.transition_commerce_order(uuid, uuid, text, text, uuid, jsonb) to service_role;
grant execute on function public.liquidate_ncx(uuid, bigint, text, jsonb) to service_role;
grant execute on function public.charge_ncx_purpose(uuid, bigint, text, text, text) to service_role;
grant execute on function public.create_transport_booking_hold(uuid, uuid, uuid, text, text, bigint, text) to service_role;
grant execute on function public.settle_transport_booking(uuid) to service_role;
grant execute on function public.refund_transport_booking(uuid, text) to service_role;
grant execute on function public.dispute_transport_booking(uuid, text) to service_role;
