create extension if not exists pgcrypto;

create type public.finance_currency as enum ('UGX', 'NCX', 'USD');
create type public.ledger_direction as enum ('in', 'out');
create type public.payment_status as enum ('pending', 'processing', 'completed', 'failed', 'cancelled', 'refunded');
create type public.escrow_status as enum ('held', 'released', 'refunded', 'disputed');

create table public.finance_users (
  user_id uuid primary key,
  email text,
  display_name text,
  source_project text not null default 'necxa-primary',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.wallets (
  user_id uuid primary key references public.finance_users(user_id) on delete restrict,
  coin_balance bigint not null default 0 check (coin_balance >= 0),
  fiat_balance bigint not null default 0 check (fiat_balance >= 0),
  fiat_currency public.finance_currency not null default 'UGX',
  total_withdrawn_fiat bigint not null default 0 check (total_withdrawn_fiat >= 0),
  version bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.finance_users(user_id) on delete restrict,
  entry_type text not null,
  amount bigint not null check (amount > 0),
  currency public.finance_currency not null,
  direction public.ledger_direction not null,
  balance_after bigint not null check (balance_after >= 0),
  reference_id text,
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb,
  previous_hash text,
  entry_hash text not null unique,
  created_at timestamptz not null default now(),
  unique (user_id, idempotency_key)
);

create index ledger_entries_user_created_idx on public.ledger_entries(user_id, created_at desc);
create index ledger_entries_reference_idx on public.ledger_entries(reference_id) where reference_id is not null;

create table public.coin_packs (
  id text primary key,
  label text not null,
  ncx_amount bigint not null check (ncx_amount > 0),
  fiat_price bigint not null check (fiat_price > 0),
  fiat_currency public.finance_currency not null default 'UGX',
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index coin_packs_active_idx on public.coin_packs(sort_order, fiat_price) where is_active;

create table public.gift_items (
  id text primary key,
  name text not null,
  emoji text not null,
  ncx_value bigint not null check (ncx_value > 0),
  ugx_value bigint not null check (ugx_value >= 0),
  category text not null default 'standard',
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.gifts (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.finance_users(user_id) on delete restrict,
  receiver_id uuid not null references public.finance_users(user_id) on delete restrict,
  gift_item_id text references public.gift_items(id),
  context_type text not null,
  context_id text not null,
  ncx_amount bigint not null check (ncx_amount > 0),
  receiver_ncx bigint not null check (receiver_ncx >= 0),
  platform_fee_ncx bigint not null check (platform_fee_ncx >= 0),
  is_anonymous boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  idempotency_key text not null unique,
  created_at timestamptz not null default now()
);

create index gifts_context_idx on public.gifts(context_type, context_id, created_at desc);
create index gifts_sender_idx on public.gifts(sender_id, created_at desc);
create index gifts_receiver_idx on public.gifts(receiver_id, created_at desc);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.finance_users(user_id) on delete restrict,
  provider text not null,
  provider_reference text unique,
  purpose text not null,
  amount bigint not null check (amount > 0),
  currency public.finance_currency not null,
  status public.payment_status not null default 'pending',
  request jsonb not null default '{}'::jsonb,
  response jsonb not null default '{}'::jsonb,
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index payments_user_created_idx on public.payments(user_id, created_at desc);
create index payments_pending_idx on public.payments(provider, status, created_at) where status in ('pending', 'processing');

create table public.escrows (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.finance_users(user_id) on delete restrict,
  recipient_id uuid references public.finance_users(user_id) on delete restrict,
  context_type text not null,
  context_id text not null,
  amount bigint not null check (amount > 0),
  currency public.finance_currency not null,
  status public.escrow_status not null default 'held',
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index escrows_context_idx on public.escrows(context_type, context_id);
create index escrows_owner_idx on public.escrows(owner_id, status, created_at desc);

create table public.withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.finance_users(user_id) on delete restrict,
  amount bigint not null check (amount > 0),
  currency public.finance_currency not null default 'UGX',
  method text not null,
  destination_ciphertext text not null,
  recipient_name text not null,
  status public.payment_status not null default 'pending',
  provider_reference text unique,
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index withdrawals_user_created_idx on public.withdrawals(user_id, created_at desc);

create table public.finance_config (
  key text primary key,
  value jsonb not null,
  is_public boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.finance_users enable row level security;
alter table public.wallets enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.coin_packs enable row level security;
alter table public.gift_items enable row level security;
alter table public.gifts enable row level security;
alter table public.payments enable row level security;
alter table public.escrows enable row level security;
alter table public.withdrawals enable row level security;
alter table public.finance_config enable row level security;

create policy coin_packs_public_read on public.coin_packs for select to anon, authenticated using (is_active);
create policy gift_items_public_read on public.gift_items for select to anon, authenticated using (is_active);
create policy finance_config_public_read on public.finance_config for select to anon, authenticated using (is_public);

revoke all on public.finance_users, public.wallets, public.ledger_entries, public.gifts,
  public.payments, public.escrows, public.withdrawals from anon, authenticated;
grant select on public.coin_packs, public.gift_items, public.finance_config to anon, authenticated;

create or replace function public.prevent_finance_record_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'Immutable finance record cannot be changed';
end;
$$;

create trigger ledger_no_update before update or delete on public.ledger_entries
for each row execute function public.prevent_finance_record_mutation();

create or replace function public.chain_ledger_entry()
returns trigger language plpgsql as $$
declare v_previous text;
begin
  select entry_hash into v_previous from public.ledger_entries
  where user_id = new.user_id order by created_at desc, id desc limit 1;
  new.previous_hash := coalesce(v_previous, repeat('0', 64));
  new.entry_hash := encode(digest(concat_ws('|', new.previous_hash, new.user_id::text,
    new.entry_type, new.amount::text, new.currency::text, new.direction::text,
    new.balance_after::text, coalesce(new.reference_id, ''), new.created_at::text), 'sha256'), 'hex');
  return new;
end;
$$;

create trigger ledger_chain before insert on public.ledger_entries
for each row execute function public.chain_ledger_entry();

insert into public.coin_packs(id, label, ncx_amount, fiat_price, sort_order) values
  ('starter', 'Starter Pack', 100, 10000, 10),
  ('pro', 'Pro Pack', 550, 50000, 20),
  ('elite', 'Elite Pack', 1200, 100000, 30),
  ('whale', 'Whale Pack', 6500, 500000, 40)
on conflict (id) do update set label = excluded.label, ncx_amount = excluded.ncx_amount,
  fiat_price = excluded.fiat_price, sort_order = excluded.sort_order;
