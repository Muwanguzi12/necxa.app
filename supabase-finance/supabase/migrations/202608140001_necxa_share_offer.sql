create table public.share_offers (
  id text primary key,
  company_legal_name text not null,
  total_shares integer not null check (total_shares > 0),
  offered_shares integer not null check (offered_shares > 0 and offered_shares <= total_shares),
  external_ownership_bps integer not null check (external_ownership_bps between 1 and 10000),
  price_per_share_ugx integer not null check (price_per_share_ugx > 0),
  reserved_shares integer not null default 0 check (reserved_shares >= 0),
  paid_shares integer not null default 0 check (paid_shares >= 0),
  allotted_shares integer not null default 0 check (allotted_shares >= 0),
  status text not null default 'draft' check (status in ('draft', 'approved', 'open', 'paused', 'closed')),
  board_approved boolean not null default false,
  shareholder_approved boolean not null default false,
  cma_approved boolean not null default false,
  kyc_aml_program_ready boolean not null default false,
  pesapal_merchant_approved boolean not null default false,
  legal_document_refs jsonb not null default '{}'::jsonb,
  opens_at timestamptz,
  closes_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (offered_shares * 10000 = total_shares * external_ownership_bps),
  check (reserved_shares + paid_shares <= offered_shares),
  check (allotted_shares <= paid_shares),
  check (closes_at is null or opens_at is null or closes_at > opens_at)
);

create table public.share_investors (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique,
  full_name text not null,
  email text not null,
  phone text,
  country_code text not null default 'UG',
  kyc_status text not null default 'not_started' check (kyc_status in ('not_started', 'pending', 'verified', 'rejected', 'expired')),
  aml_status text not null default 'not_started' check (aml_status in ('not_started', 'pending', 'cleared', 'review', 'rejected', 'expired')),
  source_of_funds_status text not null default 'not_started' check (source_of_funds_status in ('not_started', 'pending', 'cleared', 'review', 'rejected')),
  terms_accepted_at timestamptz,
  risk_acknowledged_at timestamptz,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index share_investors_email_unique_idx on public.share_investors (lower(email));

create table public.share_subscriptions (
  id uuid primary key default gen_random_uuid(),
  offer_id text not null references public.share_offers(id) on delete restrict,
  investor_id uuid not null references public.share_investors(id) on delete restrict,
  share_count integer not null check (share_count > 0),
  unit_price_ugx integer not null check (unit_price_ugx > 0),
  amount_ugx bigint generated always as (share_count::bigint * unit_price_ugx::bigint) stored,
  status text not null default 'reserved' check (status in (
    'reserved', 'payment_pending', 'paid_pending_allotment', 'allotted',
    'expired', 'cancelled', 'failed', 'manual_review', 'refunded'
  )),
  provider text not null default 'pesapal' check (provider = 'pesapal'),
  provider_tracking_id text unique,
  merchant_reference text unique,
  idempotency_key text not null unique,
  expires_at timestamptz not null,
  payment_request jsonb not null default '{}'::jsonb,
  payment_verification jsonb not null default '{}'::jsonb,
  paid_at timestamptz,
  allotted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index share_subscriptions_offer_status_idx on public.share_subscriptions (offer_id, status, expires_at);
create index share_subscriptions_investor_created_idx on public.share_subscriptions (investor_id, created_at desc);

alter table public.share_offers enable row level security;
alter table public.share_investors enable row level security;
alter table public.share_subscriptions enable row level security;

revoke all on public.share_offers, public.share_investors, public.share_subscriptions from public, anon, authenticated;
grant select, insert, update on public.share_offers, public.share_investors, public.share_subscriptions to service_role;

create or replace function public.enforce_open_share_offer_approvals()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'open' and not (
    new.board_approved and
    new.shareholder_approved and
    new.cma_approved and
    new.kyc_aml_program_ready and
    new.pesapal_merchant_approved
  ) then
    raise exception 'Share offer cannot open until every approval gate is satisfied';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger enforce_open_share_offer_approvals_trigger
before insert or update on public.share_offers
for each row execute function public.enforce_open_share_offer_approvals();

create or replace function public.reserve_share_subscription(
  p_offer_id text,
  p_investor_id uuid,
  p_share_count integer,
  p_idempotency_key text
) returns public.share_subscriptions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_offer public.share_offers;
  v_existing public.share_subscriptions;
  v_subscription public.share_subscriptions;
  v_expired_shares integer := 0;
begin
  if p_share_count is null or p_share_count < 1 then
    raise exception 'Share count must be at least one';
  end if;

  select * into v_offer from public.share_offers where id = p_offer_id for update;
  if not found then raise exception 'Share offer not found'; end if;

  with expired as (
    update public.share_subscriptions
      set status = 'expired', updated_at = now()
      where offer_id = p_offer_id
        and status in ('reserved', 'payment_pending')
        and expires_at <= now()
      returning share_count
  ) select coalesce(sum(share_count), 0)::integer into v_expired_shares from expired;

  if v_expired_shares > 0 then
    update public.share_offers
      set reserved_shares = greatest(0, reserved_shares - v_expired_shares), updated_at = now()
      where id = p_offer_id
      returning * into v_offer;
  end if;

  select * into v_existing from public.share_subscriptions
    where idempotency_key = p_idempotency_key;
  if found then return v_existing; end if;

  if v_offer.status <> 'open' or not (
    v_offer.board_approved and v_offer.shareholder_approved and v_offer.cma_approved and
    v_offer.kyc_aml_program_ready and v_offer.pesapal_merchant_approved
  ) then
    raise exception 'Share offer is not open';
  end if;
  if v_offer.opens_at is not null and v_offer.opens_at > now() then raise exception 'Share offer has not opened'; end if;
  if v_offer.closes_at is not null and v_offer.closes_at <= now() then raise exception 'Share offer has closed'; end if;
  if v_offer.reserved_shares + v_offer.paid_shares + p_share_count > v_offer.offered_shares then
    raise exception 'Requested shares exceed remaining offer inventory';
  end if;

  insert into public.share_subscriptions (
    offer_id, investor_id, share_count, unit_price_ugx, idempotency_key, merchant_reference, expires_at
  ) values (
    p_offer_id, p_investor_id, p_share_count, v_offer.price_per_share_ugx,
    p_idempotency_key, p_idempotency_key, now() + interval '30 minutes'
  ) returning * into v_subscription;

  update public.share_offers
    set reserved_shares = reserved_shares + p_share_count, updated_at = now()
    where id = p_offer_id;
  return v_subscription;
end;
$$;

create or replace function public.complete_share_subscription(
  p_subscription_id uuid,
  p_provider_tracking_id text,
  p_payment_verification jsonb
) returns public.share_subscriptions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subscription public.share_subscriptions;
  v_offer public.share_offers;
  v_was_reserved boolean;
begin
  select * into v_subscription from public.share_subscriptions
    where id = p_subscription_id for update;
  if not found then raise exception 'Share subscription not found'; end if;
  if v_subscription.status in ('paid_pending_allotment', 'allotted') then return v_subscription; end if;
  if v_subscription.status = 'refunded' then raise exception 'Refunded subscription cannot be completed'; end if;

  select * into v_offer from public.share_offers where id = v_subscription.offer_id for update;
  v_was_reserved := v_subscription.status in ('reserved', 'payment_pending') and v_subscription.expires_at > now();

  if not v_was_reserved and v_offer.reserved_shares + v_offer.paid_shares + v_subscription.share_count > v_offer.offered_shares then
    update public.share_subscriptions set
      status = 'manual_review',
      provider_tracking_id = coalesce(provider_tracking_id, p_provider_tracking_id),
      payment_verification = coalesce(p_payment_verification, '{}'::jsonb),
      paid_at = coalesce(paid_at, now()),
      updated_at = now()
    where id = p_subscription_id returning * into v_subscription;
    return v_subscription;
  end if;

  update public.share_offers set
    reserved_shares = case when v_was_reserved then greatest(0, reserved_shares - v_subscription.share_count) else reserved_shares end,
    paid_shares = paid_shares + v_subscription.share_count,
    updated_at = now()
  where id = v_offer.id;

  update public.share_subscriptions set
    status = 'paid_pending_allotment',
    provider_tracking_id = coalesce(provider_tracking_id, p_provider_tracking_id),
    payment_verification = coalesce(p_payment_verification, '{}'::jsonb),
    paid_at = coalesce(paid_at, now()),
    updated_at = now()
  where id = p_subscription_id returning * into v_subscription;
  return v_subscription;
end;
$$;

revoke all on function public.reserve_share_subscription(text,uuid,integer,text) from public, anon, authenticated;
revoke all on function public.complete_share_subscription(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.reserve_share_subscription(text,uuid,integer,text) to service_role;
grant execute on function public.complete_share_subscription(uuid,text,jsonb) to service_role;

insert into public.share_offers (
  id, company_legal_name, total_shares, offered_shares, external_ownership_bps,
  price_per_share_ugx, status
) values (
  'necxa-technology-2026', 'Necxa Technology Ltd', 1000, 400, 4000, 10000, 'draft'
) on conflict (id) do nothing;

select pg_notify('pgrst', 'reload schema');
