create table if not exists public.commerce_inventory_reservations (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings(id) on delete restrict,
  customer_id uuid not null,
  quantity integer not null check (quantity > 0),
  idempotency_key text not null unique,
  finance_order_id uuid,
  status text not null default 'reserved' check (status in ('reserved','committed','released','expired')),
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists commerce_inventory_reservations_expiry_idx
  on public.commerce_inventory_reservations(status, expires_at) where status = 'reserved';

alter table public.commerce_inventory_reservations enable row level security;
revoke all on public.commerce_inventory_reservations from anon, authenticated;

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
  if v_listing.user_id = p_customer_id or v_listing.lister_id = p_customer_id then raise exception 'Cannot purchase your own listing'; end if;
  if coalesce(v_listing.stock_count, 0) < p_quantity then raise exception 'Insufficient stock'; end if;
  update public.listings set stock_count = stock_count - p_quantity where id = p_listing_id;
  insert into public.commerce_inventory_reservations(listing_id, customer_id, quantity, idempotency_key)
  values(p_listing_id, p_customer_id, p_quantity, p_idempotency_key) returning * into v_reservation;
  return v_reservation;
end;
$$;

create or replace function public.finalize_commerce_inventory(
  p_idempotency_key text, p_finance_order_id uuid, p_commit boolean
) returns public.commerce_inventory_reservations
language plpgsql security definer set search_path = public as $$
declare v_reservation public.commerce_inventory_reservations;
begin
  select * into v_reservation from public.commerce_inventory_reservations where idempotency_key = p_idempotency_key for update;
  if not found then raise exception 'Inventory reservation not found'; end if;
  if v_reservation.status <> 'reserved' then return v_reservation; end if;
  if p_commit then
    update public.commerce_inventory_reservations set status = 'committed', finance_order_id = p_finance_order_id, updated_at = now()
    where id = v_reservation.id returning * into v_reservation;
  else
    update public.listings set stock_count = stock_count + v_reservation.quantity where id = v_reservation.listing_id;
    update public.commerce_inventory_reservations set status = 'released', updated_at = now()
    where id = v_reservation.id returning * into v_reservation;
  end if;
  return v_reservation;
end;
$$;

revoke all on function public.reserve_commerce_inventory(uuid,uuid,integer,text) from public, anon, authenticated;
revoke all on function public.finalize_commerce_inventory(text,uuid,boolean) from public, anon, authenticated;
grant execute on function public.reserve_commerce_inventory(uuid,uuid,integer,text) to service_role;
grant execute on function public.finalize_commerce_inventory(text,uuid,boolean) to service_role;
