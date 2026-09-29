-- Low-bandwidth buyer tracking and driver-directory privacy.

alter table public.transport_orders
  add column if not exists delivery_lat double precision,
  add column if not exists delivery_lng double precision;

alter table public.transport_orders
  drop constraint if exists transport_orders_delivery_lat_check,
  add constraint transport_orders_delivery_lat_check
    check (delivery_lat is null or delivery_lat between -90 and 90),
  drop constraint if exists transport_orders_delivery_lng_check,
  add constraint transport_orders_delivery_lng_check
    check (delivery_lng is null or delivery_lng between -180 and 180);

create index if not exists transport_orders_user_updated_idx
  on public.transport_orders (user_id, updated_at desc, id)
  include (status, driver_id, delivery_lat, delivery_lng);

create index if not exists transport_orders_driver_updated_idx
  on public.transport_orders (driver_id, updated_at desc, id)
  include (status, user_id, delivery_lat, delivery_lng);

drop policy if exists "Users can view their own orders" on public.transport_orders;
create policy "Users can view their own orders"
  on public.transport_orders
  for select
  to authenticated
  using (
    (select auth.uid()) = user_id
    or (select auth.uid()) = driver_id
  );

drop policy if exists "Customers can update their own transport orders" on public.transport_orders;
create policy "Customers can update their own transport orders"
  on public.transport_orders
  for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Assigned drivers can update transport orders" on public.transport_orders;
create policy "Assigned drivers can update transport orders"
  on public.transport_orders
  for update
  to authenticated
  using ((select auth.uid()) = driver_id)
  with check ((select auth.uid()) = driver_id);

-- RLS filters rows, while column grants prevent the public marketplace query
-- from exposing driver email, phone, permit documents or precise coordinates.
revoke select on public.transport_drivers from anon, authenticated;
grant select (
  id,
  name,
  number_plate,
  vehicle_type,
  is_verified,
  is_available
) on public.transport_drivers to anon, authenticated;
