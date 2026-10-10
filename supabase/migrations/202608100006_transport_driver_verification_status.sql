alter table public.transport_drivers
  alter column number_plate drop not null,
  add column if not exists country_code text,
  add column if not exists verification_status text not null default 'not_submitted',
  add column if not exists verification_reason_code text,
  add column if not exists verification_submitted_at timestamptz,
  add column if not exists verification_reviewed_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'transport_drivers_country_code_check'
      and conrelid = 'public.transport_drivers'::regclass
  ) then
    alter table public.transport_drivers
      add constraint transport_drivers_country_code_check
      check (country_code is null or country_code ~ '^[A-Z]{2}$');
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'transport_drivers_verification_status_check'
      and conrelid = 'public.transport_drivers'::regclass
  ) then
    alter table public.transport_drivers
      add constraint transport_drivers_verification_status_check
      check (verification_status in ('not_submitted', 'manual_review', 'verified', 'rejected'));
  end if;
end
$$;

create index if not exists transport_drivers_manual_review_idx
  on public.transport_drivers (verification_submitted_at, id)
  where verification_status = 'manual_review';

create index if not exists transport_drivers_country_verified_idx
  on public.transport_drivers (country_code, is_available, id)
  where is_verified = true;

update public.transport_drivers
set verification_status = case when is_verified then 'verified' else verification_status end,
    verification_reviewed_at = case when is_verified then coalesce(verification_reviewed_at, updated_at) else verification_reviewed_at end
where is_verified = true;

grant select (
  country_code,
  verification_status,
  verification_reason_code,
  verification_submitted_at,
  verification_reviewed_at
) on public.transport_drivers to authenticated;
