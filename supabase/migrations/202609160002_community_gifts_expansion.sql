-- ── 0. TYPES ──────────────────────────────────────────────────────
do $$ begin
  create type public.finance_currency as enum ('UGX', 'NCX', 'USD');
exception when duplicate_object then null; end $$;

-- ── 1. FINANCE USERS PROJECTION ──────────────────────────────────
-- Ensures the Primary DB can handle foreign key references to finance identities.
-- This table mirrors auth.users for financial routing.
create table if not exists public.finance_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  created_at timestamptz default now()
);

-- Backfill from existing profiles
insert into public.finance_users (user_id, email, display_name)
select id, email, full_name from public.profiles
on conflict (user_id) do nothing;

-- ── 2. COIN PACKS CATALOGUE ──────────────────────────────────────
create table if not exists public.coin_packs (
  id text not null,
  label text not null default 'unknown'::text,
  ncx_amount bigint not null,
  fiat_price bigint not null,
  fiat_currency public.finance_currency not null default 'UGX'::public.finance_currency,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  tagline text null,
  color_hex text not null default '#00E5FF'::text,
  emoji text not null default '✨'::text,
  name text not null default ''::text,
  constraint coin_packs_pkey primary key (id),
  constraint coin_packs_fiat_price_check check ((fiat_price > 0)),
  constraint coin_packs_ncx_amount_check check ((ncx_amount > 0))
);

create index if not exists coin_packs_active_idx on public.coin_packs (sort_order, fiat_price)
where is_active;

-- Seed packs (if missing)
insert into public.coin_packs (id, name, label, tagline, ncx_amount, fiat_price, sort_order, color_hex, emoji)
values
  ('spark',   'Spark Pack',   'SPARK',   'Try it out',          10,   1000,   1, '#64FFDA', '⚡'),
  ('starter', 'Starter Pack', 'STARTER', 'Get started',         50,   5000,   2, '#00E5FF', '🌟'),
  ('pro',     'Pro Pack',     'PRO',     'Most popular',       150,  15000,   3, '#2979FF', '🔵'),
  ('elite',   'Elite Pack',   'ELITE',   'Power user',         500,  50000,   4, '#D500F9', '💜'),
  ('whale',   'Whale Pack',   'WHALE',   'Go all in',         1200, 100000,  5, '#FFC400', '🐋')
on conflict (id) do update set
  name = excluded.name,
  tagline = excluded.tagline,
  ncx_amount = excluded.ncx_amount,
  fiat_price = excluded.fiat_price;

-- ── 3. COMMUNITY GIFTS REFINEMENT ────────────────────────────────
create table if not exists public.community_gifts (
  id uuid not null default gen_random_uuid (),
  post_id uuid null,
  sender_id uuid not null,
  receiver_id uuid not null,
  gift_type text not null,
  coin_amount bigint not null,
  fiat_value_generated bigint null,
  creator_fiat_cut bigint null,
  necxa_fiat_fee bigint null,
  created_at timestamp with time zone not null default now(),
  idempotency_key text null,
  listing_id uuid null,
  finance_gift_id uuid null,
  receiver_ncx bigint null,
  platform_fee_ncx bigint null,
  creator_ncx_cut bigint not null default 0,
  necxa_ncx_fee bigint not null default 0,
  sender_name text null,
  sender_avatar text null,
  constraint community_gifts_pkey primary key (id),
  constraint community_gifts_listing_id_fkey foreign key (listing_id) references public.listings (id) on delete set null,
  constraint community_gifts_receiver_id_fkey foreign key (receiver_id) references public.finance_users (user_id) on delete restrict,
  constraint community_gifts_sender_id_fkey foreign key (sender_id) references public.finance_users (user_id) on delete restrict,
  constraint community_gifts_coin_amount_check check ((coin_amount > 0))
);

create unique index if not exists community_gifts_finance_idempotency_idx on public.community_gifts (idempotency_key)
where (idempotency_key is not null);

create unique index if not exists community_gifts_finance_gift_id_idx on public.community_gifts (finance_gift_id)
where (finance_gift_id is not null);

create index if not exists idx_community_gifts_post_recent on public.community_gifts (post_id, created_at desc);
create index if not exists idx_community_gifts_sender on public.community_gifts (sender_id, created_at desc);
create index if not exists idx_community_gifts_receiver on public.community_gifts (receiver_id, created_at desc);

-- ── 4. COIN SPLIT SYNC LOGIC ──────────────────────────────────────

create or replace function public.sync_community_gift_coin_split()
returns trigger
language plpgsql
security definer
as $$
declare
  v_fee_rate numeric := 0.11; -- Default 11% platform fee
  v_ncx_to_ugx integer := 100; -- 1 NCX = 100 UGX
begin
  -- Calculate splits if they weren't provided explicitly
  if new.platform_fee_ncx is null then
    new.platform_fee_ncx := round(new.coin_amount * v_fee_rate);
  end if;

  if new.receiver_ncx is null then
    new.receiver_ncx := new.coin_amount - new.platform_fee_ncx;
  end if;

  -- Sync cuts to standardized columns
  new.creator_ncx_cut := coalesce(new.receiver_ncx, 0);
  new.necxa_ncx_fee := coalesce(new.platform_fee_ncx, 0);

  -- Sync fiat values (for reporting/trust signals)
  new.fiat_value_generated := new.coin_amount * v_ncx_to_ugx;
  new.creator_fiat_cut := new.creator_ncx_cut * v_ncx_to_ugx;
  new.necxa_fiat_fee := new.necxa_ncx_fee * v_ncx_to_ugx;

  return new;
end;
$$;

drop trigger if exists community_gifts_coin_split_sync on public.community_gifts;
create trigger community_gifts_coin_split_sync
before insert or update of receiver_ncx, platform_fee_ncx, creator_ncx_cut, necxa_ncx_fee
on public.community_gifts
for each row execute function public.sync_community_gift_coin_split();

-- ── 5. RLS ────────────────────────────────────────────────────────
alter table public.coin_packs enable row level security;
alter table public.community_gifts enable row level security;
alter table public.finance_users enable row level security;

create policy "Packs are readable by all" on public.coin_packs for select using (true);
create policy "Gifts are readable by sender/receiver" on public.community_gifts
  for select using (auth.uid() = sender_id or auth.uid() = receiver_id);
create policy "Users are public readable" on public.finance_users for select using (true);

commit;
