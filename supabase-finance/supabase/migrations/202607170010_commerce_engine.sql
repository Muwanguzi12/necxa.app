create type public.commerce_order_status as enum (
  'initiated', 'pending_payment', 'paid', 'vendor_confirmed', 'preparing',
  'ready_for_pickup', 'courier_assigned', 'picked_up', 'in_transit',
  'delivered', 'customer_approved', 'completed', 'cancelled', 'disputed', 'refunded'
);

create table public.commerce_orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default ('NXC-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))),
  customer_id uuid not null references public.finance_users(user_id) on delete restrict,
  vendor_id uuid not null references public.finance_users(user_id) on delete restrict,
  courier_id uuid references public.finance_users(user_id) on delete restrict,
  listing_id uuid not null,
  sku text not null check (sku ~ '^[0-9]{4}[A-Z]{3}$'),
  product_title text not null,
  product_thumbnail text,
  quantity integer not null check (quantity > 0),
  unit_price_ugx bigint not null check (unit_price_ugx > 0),
  items_total_ugx bigint not null check (items_total_ugx > 0),
  delivery_fee_ugx bigint not null check (delivery_fee_ugx >= 0),
  total_ugx bigint generated always as (items_total_ugx + delivery_fee_ugx) stored,
  platform_fee_ugx bigint not null check (platform_fee_ugx >= 0),
  vendor_payout_ugx bigint not null check (vendor_payout_ugx >= 0),
  courier_payout_ugx bigint not null check (courier_payout_ugx >= 0),
  status public.commerce_order_status not null default 'initiated',
  payment_method text not null,
  delivery_method text not null,
  delivery_speed text not null,
  delivery_address text not null,
  delivery_phone text not null,
  pickup_lat double precision,
  pickup_lng double precision,
  dropoff_lat double precision,
  dropoff_lng double precision,
  distance_km numeric(10,3) not null check (distance_km >= 0),
  weight_kg numeric(10,3) not null check (weight_kg > 0),
  package_dimensions jsonb not null default '{}'::jsonb,
  estimated_delivery_at timestamptz,
  delivered_at timestamptz,
  customer_approved_at timestamptz,
  completed_at timestamptz,
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (customer_id <> vendor_id),
  check (items_total_ugx = unit_price_ugx * quantity),
  check (vendor_payout_ugx + platform_fee_ugx = items_total_ugx),
  check (courier_payout_ugx <= delivery_fee_ugx)
);

create table public.commerce_order_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.commerce_orders(id) on delete restrict,
  actor_id uuid references public.finance_users(user_id) on delete restrict,
  from_status public.commerce_order_status,
  to_status public.commerce_order_status not null,
  message text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.commerce_disputes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.commerce_orders(id) on delete restrict,
  opened_by uuid not null references public.finance_users(user_id) on delete restrict,
  reason text not null check (length(trim(reason)) between 10 and 2000),
  evidence jsonb not null default '[]'::jsonb,
  status text not null default 'open' check (status in ('open','investigating','resolved_customer','resolved_vendor','closed')),
  resolution text,
  resolved_by uuid references public.finance_users(user_id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.commerce_reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.commerce_orders(id) on delete restrict,
  listing_id uuid not null,
  customer_id uuid not null references public.finance_users(user_id) on delete restrict,
  vendor_id uuid not null references public.finance_users(user_id) on delete restrict,
  rating smallint not null check (rating between 1 and 5),
  comment text check (length(comment) <= 2000),
  created_at timestamptz not null default now()
);

create table public.commerce_order_messages (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.commerce_orders(id) on delete restrict,
  sender_id uuid not null references public.finance_users(user_id) on delete restrict,
  message_type text not null default 'text' check (message_type in ('text','image','video','audio','file','location','system')),
  content text,
  attachment_url text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (nullif(trim(content), '') is not null or attachment_url is not null)
);

create index commerce_orders_customer_idx on public.commerce_orders(customer_id, created_at desc);
create index commerce_orders_vendor_idx on public.commerce_orders(vendor_id, status, created_at desc);
create index commerce_orders_courier_idx on public.commerce_orders(courier_id, status, created_at desc) where courier_id is not null;
create index commerce_orders_active_idx on public.commerce_orders(status, created_at) where status not in ('completed','cancelled','refunded');
create index commerce_order_events_order_idx on public.commerce_order_events(order_id, created_at);
create index commerce_reviews_listing_idx on public.commerce_reviews(listing_id, created_at desc);
create index commerce_order_messages_order_idx on public.commerce_order_messages(order_id, created_at desc);
create unique index commerce_disputes_one_active_idx on public.commerce_disputes(order_id)
  where status in ('open','investigating');

alter table public.commerce_orders enable row level security;
alter table public.commerce_order_events enable row level security;
alter table public.commerce_disputes enable row level security;
alter table public.commerce_reviews enable row level security;
alter table public.commerce_order_messages enable row level security;
revoke all on public.commerce_orders, public.commerce_order_events, public.commerce_disputes, public.commerce_reviews, public.commerce_order_messages from anon, authenticated;

create or replace function public.create_commerce_order(
  p_customer_id uuid, p_vendor_id uuid, p_listing_id uuid, p_sku text,
  p_product_title text, p_product_thumbnail text, p_quantity integer,
  p_unit_price_ugx bigint, p_delivery_fee_ugx bigint, p_delivery_method text,
  p_delivery_speed text, p_delivery_address text, p_delivery_phone text,
  p_pickup_lat double precision, p_pickup_lng double precision,
  p_dropoff_lat double precision, p_dropoff_lng double precision,
  p_distance_km numeric, p_weight_kg numeric, p_package_dimensions jsonb,
  p_estimated_delivery_at timestamptz, p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
) returns public.commerce_orders
language plpgsql security definer set search_path = public as $$
declare
  v_order public.commerce_orders;
  v_items bigint;
  v_fee bigint;
  v_vendor_payout bigint;
  v_total bigint;
begin
  select * into v_order from public.commerce_orders where idempotency_key = p_idempotency_key;
  if found then return v_order; end if;
  if p_customer_id = p_vendor_id then raise exception 'Cannot purchase your own listing'; end if;
  if p_quantity <= 0 or p_unit_price_ugx <= 0 or p_delivery_fee_ugx < 0 then raise exception 'Invalid order totals'; end if;

  perform public.ensure_finance_wallet(p_vendor_id);
  v_items := p_unit_price_ugx * p_quantity;
  v_fee := floor(v_items * 300 / 10000.0);
  v_vendor_payout := v_items - v_fee;
  v_total := v_items + p_delivery_fee_ugx;

  perform public.debit_wallet(p_customer_id, v_total, 'UGX', 'COMMERCE_ESCROW_HOLD',
    p_listing_id::text, p_idempotency_key || ':debit',
    p_metadata || jsonb_build_object('items_total_ugx', v_items, 'delivery_fee_ugx', p_delivery_fee_ugx));

  insert into public.commerce_orders(
    customer_id, vendor_id, listing_id, sku, product_title, product_thumbnail,
    quantity, unit_price_ugx, items_total_ugx, delivery_fee_ugx,
    platform_fee_ugx, vendor_payout_ugx, courier_payout_ugx, status, payment_method,
    delivery_method, delivery_speed, delivery_address, delivery_phone,
    pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, distance_km, weight_kg,
    package_dimensions, estimated_delivery_at, idempotency_key, metadata
  ) values (
    p_customer_id, p_vendor_id, p_listing_id, upper(p_sku), p_product_title, p_product_thumbnail,
    p_quantity, p_unit_price_ugx, v_items, p_delivery_fee_ugx,
    v_fee, v_vendor_payout, p_delivery_fee_ugx, 'paid', 'fiat_balance',
    p_delivery_method, p_delivery_speed, p_delivery_address, p_delivery_phone,
    p_pickup_lat, p_pickup_lng, p_dropoff_lat, p_dropoff_lng, p_distance_km, p_weight_kg,
    coalesce(p_package_dimensions, '{}'::jsonb), p_estimated_delivery_at, p_idempotency_key, p_metadata
  ) returning * into v_order;

  insert into public.escrows(owner_id, recipient_id, context_type, context_id, amount, currency, status, idempotency_key, metadata)
  values(p_customer_id, p_vendor_id, 'commerce_order', v_order.id::text, v_total, 'UGX', 'held',
    p_idempotency_key || ':escrow', jsonb_build_object('order_number', v_order.order_number));
  insert into public.commerce_order_events(order_id, actor_id, to_status, message)
  values(v_order.id, p_customer_id, 'paid', 'Payment secured in escrow');
  return v_order;
end;
$$;

create or replace function public.transition_commerce_order(
  p_order_id uuid, p_actor_id uuid, p_next_status public.commerce_order_status,
  p_message text default null, p_courier_id uuid default null, p_metadata jsonb default '{}'::jsonb
) returns public.commerce_orders
language plpgsql security definer set search_path = public as $$
declare v_order public.commerce_orders; v_previous public.commerce_order_status; v_allowed boolean := false;
begin
  select * into v_order from public.commerce_orders where id = p_order_id for update;
  if not found then raise exception 'Order not found'; end if;
  v_previous := v_order.status;
  if p_actor_id = v_order.vendor_id then
    v_allowed := (v_previous, p_next_status) in (('paid','vendor_confirmed'),('vendor_confirmed','preparing'),('preparing','ready_for_pickup'));
  elsif p_actor_id = v_order.courier_id then
    v_allowed := (v_previous, p_next_status) in (('courier_assigned','picked_up'),('picked_up','in_transit'),('in_transit','delivered'));
  elsif p_actor_id = v_order.customer_id then
    v_allowed := (v_previous, p_next_status) in (('delivered','customer_approved'));
  end if;
  if p_next_status = 'courier_assigned' and p_courier_id is not null and p_actor_id = v_order.vendor_id and v_previous = 'ready_for_pickup' then
    perform public.ensure_finance_wallet(p_courier_id); v_allowed := true;
  end if;
  if not v_allowed then raise exception 'Order transition is not allowed'; end if;

  update public.commerce_orders set status = p_next_status,
    courier_id = coalesce(p_courier_id, courier_id),
    delivered_at = case when p_next_status = 'delivered' then now() else delivered_at end,
    customer_approved_at = case when p_next_status = 'customer_approved' then now() else customer_approved_at end,
    updated_at = now() where id = p_order_id returning * into v_order;
  insert into public.commerce_order_events(order_id, actor_id, from_status, to_status, message, metadata)
  values(p_order_id, p_actor_id, v_previous, p_next_status, p_message, coalesce(p_metadata, '{}'::jsonb));
  return v_order;
end;
$$;

create or replace function public.release_commerce_escrow(p_order_id uuid, p_customer_id uuid)
returns public.commerce_orders language plpgsql security definer set search_path = public as $$
declare v_order public.commerce_orders; v_escrow public.escrows; v_previous public.commerce_order_status;
begin
  select * into v_order from public.commerce_orders where id = p_order_id for update;
  if not found or v_order.customer_id <> p_customer_id then raise exception 'Order not found'; end if;
  if v_order.status not in ('delivered','customer_approved') then raise exception 'Delivery must be confirmed first'; end if;
  v_previous := v_order.status;
  select * into v_escrow from public.escrows where context_type = 'commerce_order' and context_id = p_order_id::text for update;
  if v_escrow.status = 'released' then return v_order; end if;
  if v_escrow.status <> 'held' then raise exception 'Escrow cannot be released'; end if;
  if v_order.delivery_fee_ugx > 0 and v_order.courier_id is null then raise exception 'Courier must be assigned before escrow release'; end if;
  perform public.credit_wallet(v_order.vendor_id, v_order.vendor_payout_ugx, 'UGX', 'COMMERCE_VENDOR_PAYOUT', p_order_id::text, 'commerce:' || p_order_id::text || ':vendor');
  if v_order.courier_id is not null and v_order.courier_payout_ugx > 0 then
    perform public.credit_wallet(v_order.courier_id, v_order.courier_payout_ugx, 'UGX', 'COMMERCE_COURIER_PAYOUT', p_order_id::text, 'commerce:' || p_order_id::text || ':courier');
  end if;
  if v_order.platform_fee_ugx > 0 then
    perform public.credit_wallet('00000000-0000-4000-8000-000000000001', v_order.platform_fee_ugx, 'UGX', 'COMMERCE_PLATFORM_FEE', p_order_id::text, 'commerce:' || p_order_id::text || ':platform');
  end if;
  update public.escrows set status = 'released', updated_at = now() where id = v_escrow.id;
  update public.commerce_orders set status = 'completed', completed_at = now(), updated_at = now() where id = p_order_id returning * into v_order;
  insert into public.commerce_order_events(order_id, actor_id, from_status, to_status, message)
  values(p_order_id, p_customer_id, v_previous, 'completed', 'Customer approved delivery; escrow released');
  return v_order;
end;
$$;

revoke all on function public.create_commerce_order(uuid,uuid,uuid,text,text,text,integer,bigint,bigint,text,text,text,text,double precision,double precision,double precision,double precision,numeric,numeric,jsonb,timestamptz,text,jsonb) from public, anon, authenticated;
revoke all on function public.transition_commerce_order(uuid,uuid,public.commerce_order_status,text,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.release_commerce_escrow(uuid,uuid) from public, anon, authenticated;
grant execute on function public.create_commerce_order(uuid,uuid,uuid,text,text,text,integer,bigint,bigint,text,text,text,text,double precision,double precision,double precision,double precision,numeric,numeric,jsonb,timestamptz,text,jsonb) to service_role;
grant execute on function public.transition_commerce_order(uuid,uuid,public.commerce_order_status,text,uuid,jsonb) to service_role;
grant execute on function public.release_commerce_escrow(uuid,uuid) to service_role;
