-- Primary Supabase transport lifecycle and ownership hardening.

alter table public.transport_orders
  add column if not exists delivery_lat double precision,
  add column if not exists delivery_lng double precision;

alter table public.transport_orders
  drop constraint if exists transport_orders_status_check;
alter table public.transport_orders
  add constraint transport_orders_status_check check (status in (
    'pending', 'accepted', 'inProgress', 'delivered',
    'completed', 'cancelled', 'disputed'
  ));

drop policy if exists "Drivers can update orders assigned to them" on public.transport_orders;
drop policy if exists "Customers can update their own transport orders" on public.transport_orders;
drop policy if exists "Assigned drivers can update transport orders" on public.transport_orders;

create policy "Customers can update their own transport orders"
  on public.transport_orders
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Assigned drivers can update transport orders"
  on public.transport_orders
  for update
  to authenticated
  using (auth.uid() = driver_id)
  with check (auth.uid() = driver_id);

create or replace function public.enforce_transport_order_transition()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
begin
  if auth.role() <> 'authenticated' then
    return new;
  end if;

  if new.user_id is distinct from old.user_id
     or new.driver_id is distinct from old.driver_id
     or new.pickup_location is distinct from old.pickup_location
     or new.dropoff_location is distinct from old.dropoff_location
     or new.price is distinct from old.price then
    raise exception 'Transport booking identity and price are immutable.';
  end if;

  if new.status = old.status then
    return new;
  end if;

  if v_actor = old.user_id then
    if not (
      (old.status in ('pending', 'accepted') and new.status = 'cancelled')
      or (old.status = 'delivered' and new.status = 'completed')
      or (old.status not in ('completed', 'cancelled') and new.status = 'disputed')
    ) then
      raise exception 'The customer cannot make this transport status change.';
    end if;
  elsif v_actor = old.driver_id then
    if not (
      (old.status = 'pending' and new.status = 'accepted')
      or (old.status = 'accepted' and new.status = 'inProgress')
      or (old.status = 'inProgress' and new.status = 'delivered')
      or (old.status not in ('completed', 'cancelled') and new.status = 'disputed')
    ) then
      raise exception 'The assigned driver cannot make this transport status change.';
    end if;
  else
    raise exception 'Transport order access denied.';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists protect_transport_order_transition on public.transport_orders;
create trigger protect_transport_order_transition
  before update on public.transport_orders
  for each row execute function public.enforce_transport_order_transition();

create table if not exists public.transport_disputes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.transport_orders(id) on delete restrict,
  disputer_id uuid not null references auth.users(id) on delete restrict,
  reason text not null check (char_length(btrim(reason)) between 5 and 2000),
  evidence_url text,
  lat double precision,
  lng double precision,
  status text not null default 'open' check (status in ('open', 'investigating', 'resolved', 'rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists transport_disputes_order_idx
  on public.transport_disputes (order_id, created_at desc);

alter table public.transport_disputes enable row level security;

drop policy if exists "Participants can view transport disputes" on public.transport_disputes;
create policy "Participants can view transport disputes"
  on public.transport_disputes
  for select
  to authenticated
  using (
    disputer_id = auth.uid()
    or exists (
      select 1 from public.transport_orders o
      where o.id = order_id
        and auth.uid() in (o.user_id, o.driver_id)
    )
  );

drop policy if exists "Participants can open transport disputes" on public.transport_disputes;
create policy "Participants can open transport disputes"
  on public.transport_disputes
  for insert
  to authenticated
  with check (
    disputer_id = auth.uid()
    and exists (
      select 1 from public.transport_orders o
      where o.id = order_id
        and auth.uid() in (o.user_id, o.driver_id)
        and o.status not in ('completed', 'cancelled')
    )
  );

revoke update, delete on public.transport_disputes from authenticated;
