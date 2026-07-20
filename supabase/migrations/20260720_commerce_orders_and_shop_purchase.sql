-- ── COMMERCE ORDERS TABLE ─────────────────────────────────────────────────────
-- Tracks all shop purchases: both wallet-balance and Pesapal-paid orders.

create table if not exists public.commerce_orders (
  id                  uuid primary key default gen_random_uuid(),
  order_number        text not null unique default ('ORD-' || upper(substr(gen_random_uuid()::text, 1, 8))),
  buyer_id            uuid not null references public.profiles(id) on delete restrict,
  listing_id          uuid not null references public.listings(id) on delete restrict,
  seller_id           uuid not null,

  -- Item & delivery
  quantity            integer not null check (quantity > 0),
  unit_price_ugx      bigint not null,
  delivery_fee_ugx    bigint not null default 0,
  total_ugx           bigint not null,
  delivery_address    text,
  delivery_phone      text,
  delivery_speed      text,
  delivery_method     text,
  customer_location   jsonb,

  -- Payment
  payment_method      text not null check (payment_method in ('balance', 'momo', 'card', 'crypto')),
  payment_id          text,   -- idempotency_key from payments table (for Pesapal orders)
  payment_status      text not null default 'PENDING' check (payment_status in ('PENDING','COMPLETED','FAILED','REFUNDED')),

  -- Fulfilment
  status              text not null default 'pending' check (status in (
    'pending','confirmed','processing','dispatched','delivered','completed','cancelled','refunded'
  )),

  idempotency_key     text not null unique,
  reservation_id      uuid references public.commerce_inventory_reservations(id),
  metadata            jsonb default '{}'::jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists commerce_orders_buyer_idx on public.commerce_orders(buyer_id);
create index if not exists commerce_orders_seller_idx on public.commerce_orders(seller_id);
create index if not exists commerce_orders_listing_idx on public.commerce_orders(listing_id);
create index if not exists commerce_orders_status_idx on public.commerce_orders(status, payment_status);

-- Auto-update updated_at
create trigger commerce_orders_updated_at
  before update on public.commerce_orders
  for each row execute function update_updated_at();

-- RLS: only service_role can write; buyer can read their own
alter table public.commerce_orders enable row level security;
revoke all on public.commerce_orders from anon, authenticated;
grant select on public.commerce_orders to authenticated;

create policy "buyers_read_own_orders"
  on public.commerce_orders for select
  using (buyer_id = auth.uid());

-- ── SHOP PURCHASE WITH WALLET BALANCE (atomic SQL function) ──────────────────
-- Called by finance-engine with service_role.
-- 1. Validates listing & stock (via reserve_commerce_inventory)
-- 2. Checks buyer has enough fiat_balance
-- 3. Deducts buyer wallet
-- 4. Creates the commerce_order
-- 5. Writes an immutable ledger entry (SHOP_PURCHASE + DELIVERY_FEE)
-- Returns the order details for the Flutter client.

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
  v_reservation       public.commerce_inventory_reservations;
  v_order             public.commerce_orders;
  v_unit_price        bigint;
  v_items_ugx         bigint;
  v_total_ugx         bigint;
  v_new_fiat          bigint;
  v_prev_ledger_id    uuid;
  v_hash              text;
begin
  -- 1. Idempotency guard — return existing order if already processed
  select * into v_order from public.commerce_orders
  where idempotency_key = p_idempotency_key for update;
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
  if v_listing.user_id = p_buyer_id or v_listing.lister_id = p_buyer_id then
    raise exception 'Cannot purchase your own listing.';
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

  -- 5. Reserve inventory
  insert into public.commerce_inventory_reservations(listing_id, customer_id, quantity, idempotency_key, status)
  values(p_listing_id, p_buyer_id, p_quantity, p_idempotency_key || '-inv', 'committed')
  returning * into v_reservation;

  -- 6. Deduct wallet
  update public.wallets
  set fiat_balance = fiat_balance - v_total_ugx,
      updated_at   = now()
  where user_id = p_buyer_id
  returning fiat_balance into v_new_fiat;

  -- 7. Create order
  insert into public.commerce_orders(
    buyer_id, listing_id, seller_id,
    quantity, unit_price_ugx, delivery_fee_ugx, total_ugx,
    delivery_address, delivery_phone, delivery_speed, delivery_method, customer_location,
    payment_method, payment_status, status,
    idempotency_key, reservation_id
  ) values (
    p_buyer_id, p_listing_id, coalesce(v_listing.user_id, v_listing.lister_id),
    p_quantity, v_unit_price, p_delivery_fee_ugx, v_total_ugx,
    p_delivery_address, p_delivery_phone, p_delivery_speed, p_delivery_method, p_customer_location,
    'balance', 'COMPLETED', 'confirmed',
    p_idempotency_key, v_reservation.id
  ) returning * into v_order;

  -- 8. Immutable ledger — items cost
  select id into v_prev_ledger_id from public.immutable_financial_ledger
  where user_id = p_buyer_id order by created_at desc limit 1;

  v_hash := encode(digest(
    coalesce(v_prev_ledger_id::text, '') || p_buyer_id::text ||
    'SHOP_PURCHASE' || v_items_ugx::text || now()::text,
    'sha256'), 'hex');

  insert into public.immutable_financial_ledger(
    user_id, entry_type, amount, currency, direction, balance_after,
    previous_id, hash, reference_id, metadata
  ) values (
    p_buyer_id, 'SHOP_PURCHASE', v_items_ugx, 'UGX', 'out', v_new_fiat + p_delivery_fee_ugx,
    v_prev_ledger_id, v_hash, v_order.id,
    jsonb_build_object('order_number', v_order.order_number, 'listing_id', p_listing_id, 'quantity', p_quantity)
  ) returning id into v_prev_ledger_id;

  -- Delivery fee ledger entry (if any)
  if p_delivery_fee_ugx > 0 then
    v_hash := encode(digest(
      v_prev_ledger_id::text || p_buyer_id::text ||
      'DELIVERY_FEE' || p_delivery_fee_ugx::text || now()::text,
      'sha256'), 'hex');

    insert into public.immutable_financial_ledger(
      user_id, entry_type, amount, currency, direction, balance_after,
      previous_id, hash, reference_id, metadata
    ) values (
      p_buyer_id, 'DELIVERY_FEE', p_delivery_fee_ugx, 'UGX', 'out', v_new_fiat,
      v_prev_ledger_id, v_hash, v_order.id,
      jsonb_build_object('order_number', v_order.order_number, 'delivery_speed', p_delivery_speed)
    );
  end if;

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

revoke all on function public.process_shop_purchase_with_balance(uuid,uuid,integer,bigint,text,text,text,text,jsonb,text)
  from public, anon, authenticated;
grant execute on function public.process_shop_purchase_with_balance(uuid,uuid,integer,bigint,text,text,text,text,jsonb,text)
  to service_role;
