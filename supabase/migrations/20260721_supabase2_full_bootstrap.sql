-- ════════════════════════════════════════════════════════════════════════════
-- SUPABASE 2 (Finance Project) – Bootstrapping Schema for Commerce
-- This creates the MINIMAL tables and functions needed by the finance-engine
-- to run shop purchases. The real listings live on Supabase 1; stub rows
-- are synced at request time by the Edge Function.
-- Run this in: Supabase Dashboard → SQL Editor → ayvescksetiuekoyfqar
-- ════════════════════════════════════════════════════════════════════════════

-- 0. Helper trigger function (if it doesn't already exist)
create or replace function public.update_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- 1. Minimal profiles stub (may already exist from the ledger migration)
create table if not exists public.profiles (
  id         uuid primary key,
  email      text,
  full_name  text,
  phone      text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 2. Minimal listings stub (the finance-engine syncs rows on demand)
create table if not exists public.listings (
  id            uuid primary key default gen_random_uuid(),
  title         text,
  price         numeric not null default 0,
  stock_count   integer not null default 0,
  status        text not null default 'active',
  user_id       uuid,
  lister_id     uuid,
  category      text,
  media_url     text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- 3. Wallets (may already exist)
create table if not exists public.wallets (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null unique,
  fiat_balance   bigint not null default 0,
  coin_balance   bigint not null default 0,
  escrow_balance bigint not null default 0,
  total_spent    bigint not null default 0,
  total_earned   bigint not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- 4. Immutable financial ledger (may already exist)
create table if not exists public.immutable_financial_ledger (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null,
  entry_type    text not null,
  amount        bigint not null,
  currency      text not null default 'UGX',
  direction     text not null check (direction in ('in','out')),
  balance_after bigint not null,
  reference_id  uuid,
  previous_id   uuid,
  hash          text,
  metadata      jsonb default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

-- 5. Payments table (may already exist)
create table if not exists public.payments (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null,
  provider           text not null,
  provider_reference text,
  idempotency_key    text unique,
  status             text not null default 'PENDING',
  request            jsonb default '{}'::jsonb,
  response           jsonb default '{}'::jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- 6. Community gifts (may already exist)
create table if not exists public.community_gifts (
  id               uuid primary key default gen_random_uuid(),
  post_id          uuid not null,
  sender_id        uuid not null,
  receiver_id      uuid not null,
  gift_type        text not null,
  coin_amount      integer not null,
  fiat_value_generated bigint,
  creator_fiat_cut bigint,
  necxa_fiat_fee   bigint,
  created_at       timestamptz default now()
);

-- 7. Commerce inventory reservations
create table if not exists public.commerce_inventory_reservations (
  id              uuid primary key default gen_random_uuid(),
  listing_id      uuid not null,
  customer_id     uuid not null,
  quantity        integer not null check (quantity > 0),
  idempotency_key text not null unique,
  finance_order_id uuid,
  status          text not null default 'reserved' check (status in ('reserved','committed','released','expired')),
  expires_at      timestamptz not null default (now() + interval '15 minutes'),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- 8. Commerce orders
create table if not exists public.commerce_orders (
  id                uuid primary key default gen_random_uuid(),
  order_number      text not null unique default ('ORD-' || upper(substr(gen_random_uuid()::text, 1, 8))),
  buyer_id          uuid not null,
  listing_id        uuid not null,
  seller_id         uuid not null,
  quantity          integer not null check (quantity > 0),
  unit_price_ugx    bigint not null,
  delivery_fee_ugx  bigint not null default 0,
  total_ugx         bigint not null,
  delivery_address  text,
  delivery_phone    text,
  delivery_speed    text,
  delivery_method   text,
  customer_location jsonb,
  payment_method    text not null default 'balance',
  payment_id        text,
  payment_status    text not null default 'PENDING',
  status            text not null default 'pending',
  idempotency_key   text not null unique,
  reservation_id    uuid,
  metadata          jsonb default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- Indexes
create index if not exists commerce_orders_buyer_idx on public.commerce_orders(buyer_id);
create index if not exists commerce_orders_listing_idx on public.commerce_orders(listing_id);

-- 9. Reserve commerce inventory function
create or replace function public.reserve_commerce_inventory(
  p_listing_id uuid, p_customer_id uuid, p_quantity integer, p_idempotency_key text
) returns public.commerce_inventory_reservations
language plpgsql security definer set search_path = public as $$
declare v_listing public.listings; v_reservation public.commerce_inventory_reservations;
begin
  select * into v_reservation from public.commerce_inventory_reservations where idempotency_key = p_idempotency_key;
  if found then return v_reservation; end if;
  if p_quantity <= 0 then raise exception 'Quantity must be positive'; end if;
  select * into v_listing from public.listings where id = p_listing_id and status = 'active' for update;
  if not found then raise exception 'Listing unavailable'; end if;
  if coalesce(v_listing.stock_count, 0) < p_quantity then raise exception 'Insufficient stock'; end if;
  update public.listings set stock_count = stock_count - p_quantity where id = p_listing_id;
  insert into public.commerce_inventory_reservations(listing_id, customer_id, quantity, idempotency_key)
  values(p_listing_id, p_customer_id, p_quantity, p_idempotency_key) returning * into v_reservation;
  return v_reservation;
end;
$$;

-- 10. Process shop purchase with balance (atomic function)
create or replace function public.process_shop_purchase_with_balance(
  p_buyer_id          uuid,
  p_listing_id        uuid,
  p_quantity          integer,
  p_delivery_fee_ugx  bigint,
  p_delivery_address  text,
  p_delivery_phone    text,
  p_delivery_speed    text,
  p_delivery_method   text,
  p_customer_location jsonb,
  p_idempotency_key   text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_listing           public.listings;
  v_wallet            public.wallets;
  v_order             public.commerce_orders;
  v_unit_price        bigint;
  v_items_ugx         bigint;
  v_total_ugx         bigint;
  v_new_fiat          bigint;
begin
  -- 1. Idempotency guard
  select * into v_order from public.commerce_orders
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'success', true,
      'orderId', v_order.id,
      'orderNumber', v_order.order_number,
      'deliveryFeeUgx', v_order.delivery_fee_ugx,
      'message', 'Order already exists.'
    );
  end if;

  -- 2. Lock & validate listing
  select * into v_listing from public.listings
  where id = p_listing_id and status = 'active' for update;
  if not found then
    raise exception 'Listing not found or not active.';
  end if;
  if coalesce(v_listing.stock_count, 0) < p_quantity then
    raise exception 'Insufficient stock. Only % unit(s) available.', coalesce(v_listing.stock_count, 0);
  end if;

  -- 3. Lock & validate buyer wallet
  select * into v_wallet from public.wallets
  where user_id = p_buyer_id for update;
  if not found then
    raise exception 'Wallet not found.';
  end if;

  v_unit_price := v_listing.price::bigint;
  v_items_ugx  := v_unit_price * p_quantity;
  v_total_ugx  := v_items_ugx + p_delivery_fee_ugx;

  if v_wallet.fiat_balance < v_total_ugx then
    raise exception using
      message = 'Insufficient funds.',
      hint    = 'insufficient_funds',
      detail  = format('Balance: %s UGX, Required: %s UGX', v_wallet.fiat_balance, v_total_ugx);
  end if;

  -- 4. Deduct stock
  update public.listings
  set stock_count = stock_count - p_quantity
  where id = p_listing_id;

  -- 5. Deduct wallet
  update public.wallets
  set fiat_balance = fiat_balance - v_total_ugx,
      updated_at   = now()
  where user_id = p_buyer_id
  returning fiat_balance into v_new_fiat;

  -- 6. Create order
  insert into public.commerce_orders(
    buyer_id, listing_id, seller_id,
    quantity, unit_price_ugx, delivery_fee_ugx, total_ugx,
    delivery_address, delivery_phone, delivery_speed, delivery_method, customer_location,
    payment_method, payment_status, status,
    idempotency_key
  ) values (
    p_buyer_id, p_listing_id, coalesce(v_listing.user_id, v_listing.lister_id),
    p_quantity, v_unit_price, p_delivery_fee_ugx, v_total_ugx,
    p_delivery_address, p_delivery_phone, p_delivery_speed, p_delivery_method, p_customer_location,
    'balance', 'COMPLETED', 'confirmed',
    p_idempotency_key
  ) returning * into v_order;

  -- 7. Immutable ledger entry
  insert into public.immutable_financial_ledger(
    user_id, entry_type, amount, currency, direction, balance_after,
    reference_id, metadata
  ) values (
    p_buyer_id, 'SHOP_PURCHASE', v_total_ugx, 'UGX', 'out', v_new_fiat,
    v_order.id,
    jsonb_build_object('order_number', v_order.order_number, 'listing_id', p_listing_id, 'quantity', p_quantity)
  );

  return jsonb_build_object(
    'success', true,
    'orderId', v_order.id,
    'orderNumber', v_order.order_number,
    'deliveryFeeUgx', v_order.delivery_fee_ugx,
    'totalUgx', v_order.total_ugx,
    'newBalance', v_new_fiat,
    'message', 'Purchase successful.'
  );
end;
$$;

-- 11. Credit NCX function (may already exist)
create or replace function public.credit_ncx(
  p_user_auth_id uuid,
  p_amount_ncx bigint,
  p_transaction_type text,
  p_fiat_amount bigint,
  p_fiat_currency text,
  p_reference_id text,
  p_reference_type text,
  p_metadata jsonb
)
returns bigint language plpgsql security definer as $$
declare
  v_wallet public.wallets%rowtype;
  new_balance bigint;
begin
  select * into v_wallet from public.wallets where user_id = p_user_auth_id for update;
  if not found then
    raise exception 'Wallet not found for user %', p_user_auth_id;
  end if;
  new_balance := v_wallet.coin_balance + p_amount_ncx;
  update public.wallets
  set coin_balance = new_balance, updated_at = now()
  where id = v_wallet.id;
  insert into public.immutable_financial_ledger (user_id, entry_type, amount, currency, direction, balance_after, metadata)
  values (
    p_user_auth_id, p_transaction_type, p_amount_ncx, 'NCX', 'in', new_balance,
    jsonb_build_object('fiat_amount', p_fiat_amount, 'fiat_currency', p_fiat_currency,
      'reference_id_text', p_reference_id, 'reference_type', p_reference_type)
    || coalesce(p_metadata, '{}'::jsonb)
  );
  return new_balance;
end;
$$;

-- 12. Buy coins with fiat balance (may already exist)
create or replace function public.buy_coins_with_fiat_balance(
  p_user_auth_id uuid,
  p_fiat_amount_to_spend bigint,
  p_ncx_to_receive bigint,
  p_fiat_currency text
)
returns bigint language plpgsql security definer as $$
declare
  v_wallet public.wallets%rowtype;
  new_fiat_balance bigint;
  new_coin_balance bigint;
begin
  select * into v_wallet from public.wallets where user_id = p_user_auth_id for update;
  if not found then
    raise exception 'Wallet not found for user %', p_user_auth_id;
  end if;
  if v_wallet.fiat_balance < p_fiat_amount_to_spend then
    raise exception 'Insufficient Fiat balance. Have: %, Need: %', v_wallet.fiat_balance, p_fiat_amount_to_spend;
  end if;
  update public.wallets
  set
    fiat_balance = fiat_balance - p_fiat_amount_to_spend,
    coin_balance = coin_balance + p_ncx_to_receive,
    updated_at = now()
  where id = v_wallet.id
  returning fiat_balance, coin_balance into new_fiat_balance, new_coin_balance;
  insert into public.immutable_financial_ledger (user_id, entry_type, amount, currency, direction, balance_after, metadata)
  values
    (p_user_auth_id, 'COIN_PURCHASE_DEBIT', p_fiat_amount_to_spend, p_fiat_currency, 'out', new_fiat_balance,
     jsonb_build_object('description', 'Converted ' || p_fiat_amount_to_spend || ' ' || p_fiat_currency || ' to NCX')),
    (p_user_auth_id, 'COIN_PURCHASE', p_ncx_to_receive, 'NCX', 'in', new_coin_balance,
     jsonb_build_object('description', 'Received ' || p_ncx_to_receive || ' NCX from ' || p_fiat_currency || ' balance'));
  return new_coin_balance;
end;
$$;

-- 13. Process gift NCX (may already exist)
create or replace function public.process_gift_ncx(
  p_sender_auth_id uuid,
  p_receiver_auth_id uuid,
  p_post_id uuid,
  p_ncx_amount bigint,
  p_gift_platform_fee_rate float,
  p_gift_details jsonb
)
returns table (
  success boolean,
  message text,
  platform_fee_paid bigint,
  receiver_amount_credited bigint
) language plpgsql security definer as $$
declare
  v_sender_wallet public.wallets%rowtype;
  v_receiver_wallet public.wallets%rowtype;
  v_platform_fee_ncx bigint;
  v_receiver_ncx bigint;
  v_sender_new_balance bigint;
  v_receiver_new_balance bigint;
begin
  if p_ncx_amount <= 0 then return query select false, 'Gift amount must be positive.', 0::bigint, 0::bigint; return; end if;
  if p_sender_auth_id = p_receiver_auth_id then return query select false, 'Cannot send a gift to yourself.', 0::bigint, 0::bigint; return; end if;
  v_platform_fee_ncx := floor(p_ncx_amount * p_gift_platform_fee_rate);
  v_receiver_ncx := p_ncx_amount - v_platform_fee_ncx;

  select * into v_sender_wallet from public.wallets where user_id = p_sender_auth_id for update;
  if not found or v_sender_wallet.coin_balance < p_ncx_amount then
    return query select false, 'Insufficient NCX balance.', 0::bigint, 0::bigint;
    return;
  end if;

  -- Ensure receiver wallet exists
  insert into public.wallets (user_id) values (p_receiver_auth_id) on conflict (user_id) do nothing;
  select * into v_receiver_wallet from public.wallets where user_id = p_receiver_auth_id for update;

  update public.wallets set coin_balance = coin_balance - p_ncx_amount, updated_at = now() where id = v_sender_wallet.id returning coin_balance into v_sender_new_balance;
  update public.wallets set coin_balance = coin_balance + v_receiver_ncx, updated_at = now() where id = v_receiver_wallet.id returning coin_balance into v_receiver_new_balance;

  insert into public.community_gifts (post_id, sender_id, receiver_id, gift_type, coin_amount, creator_fiat_cut, necxa_fiat_fee)
  values (p_post_id, p_sender_auth_id, p_receiver_auth_id, p_gift_details->>'gift_item_id', p_ncx_amount, v_receiver_ncx, v_platform_fee_ncx);

  insert into public.immutable_financial_ledger (user_id, entry_type, amount, currency, direction, balance_after, metadata)
  values
    (p_sender_auth_id, 'GIFT_SENT', p_ncx_amount, 'NCX', 'out', v_sender_new_balance, jsonb_build_object('receiver_id', p_receiver_auth_id)),
    (p_receiver_auth_id, 'GIFT_RECEIVED', v_receiver_ncx, 'NCX', 'in', v_receiver_new_balance, jsonb_build_object('sender_id', p_sender_auth_id));

  return query select true, 'Gift sent successfully.', v_platform_fee_ncx, v_receiver_ncx;
end;
$$;

-- 14. Ensure auto-provision of wallets for new users
create or replace function public.auto_provision_wallet()
returns trigger language plpgsql security definer as $$
begin
  insert into public.wallets (user_id) values (new.id) on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_profile_created_wallet on public.profiles;
create trigger on_profile_created_wallet
  after insert on public.profiles
  for each row execute function public.auto_provision_wallet();
