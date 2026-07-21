alter table public.listings
  add column if not exists weight_kg numeric,
  add column if not exists length_cm numeric,
  add column if not exists width_cm numeric,
  add column if not exists height_cm numeric,
  add column if not exists latitude double precision,
  add column if not exists longitude double precision;

alter table public.listings drop constraint if exists listings_sku_format;
alter table public.listings
  add constraint listings_sku_format check (sku ~ '^[0-9]{4}[A-Z]{3}$') not valid;

alter table public.listings drop constraint if exists listings_shipping_measurements_positive;
alter table public.listings
  add constraint listings_shipping_measurements_positive check (
    (weight_kg is null or weight_kg > 0) and
    (length_cm is null or length_cm > 0) and
    (width_cm is null or width_cm > 0) and
    (height_cm is null or height_cm > 0)
  );

create unique index if not exists listings_sku_unique_idx
  on public.listings (sku) where sku is not null;
