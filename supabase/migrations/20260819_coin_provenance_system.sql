-- ════════════════════════════════════════════════════════════════════════════
-- MIGRATION: Coin Provenance System
-- Date: 2026-08-19
--
-- Goals:
--   1. Create a coin_packs table (DB-driven catalog, replaces hardcoded packs)
--   2. Add the 1,000 UGX "Spark Pack" (10 NCX) and the existing packs
--   3. Create coin_issuances — every NCX batch ever minted has a verifiable
--      point of origin: who issued it, from which payment, at what rate,
--      with a cryptographic origin_hash for tamper-evidence.
--   4. Drop ALL old overloads of buy_coins_with_fiat_balance and re-create
--      a single canonical version that writes to coin_issuances + the ledger.
-- ════════════════════════════════════════════════════════════════════════════


-- ── Step 0: Ensure pgcrypto is installed ──────────────────────────────────
create extension if not exists pgcrypto with schema extensions;

-- ── Step 1: Drop the ambiguous text overload (from 20260711_coin_purchase_logic.sql) ──
drop function if exists public.buy_coins_with_fiat_balance(uuid, bigint, bigint, text);

-- ── Step 2: Drop the finance_currency enum overload (from 202608150001_finance_gap_fixes.sql) ──
-- We will replace it with a cleaner, richer version below.
drop function if exists public.buy_coins_with_fiat_balance(uuid, bigint, bigint, public.finance_currency);


-- ── Step 3: coin_packs — DB-driven catalog ────────────────────────────────
create table if not exists public.coin_packs (
  id            text primary key,                -- e.g. 'spark', 'starter', 'pro'
  name          text not null,
  tagline       text,
  ncx_amount    bigint not null check (ncx_amount > 0),
  fiat_price    bigint not null check (fiat_price > 0), -- in smallest fiat unit (UGX integer)
  fiat_currency text not null default 'UGX',
  color_hex     text not null default '#00E5FF',
  emoji         text not null default '✨',
  is_active     boolean not null default true,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now()
);

-- Seed the full pack catalog
insert into public.coin_packs (id, name, tagline, ncx_amount, fiat_price, fiat_currency, color_hex, emoji, sort_order)
values
  ('spark',   'Spark Pack',   'Try it out',          10,   1000,   'UGX', '#64FFDA', '⚡', 1),
  ('starter', 'Starter Pack', 'Get started',         50,   5000,   'UGX', '#00E5FF', '🌟', 2),
  ('pro',     'Pro Pack',     'Most popular',       150,  15000,   'UGX', '#2979FF', '🔵', 3),
  ('elite',   'Elite Pack',   'Power user',         500,  50000,   'UGX', '#D500F9', '💜', 4),
  ('whale',   'Whale Pack',   'Go all in',         1200, 100000,  'UGX', '#FFC400', '🐋', 5)
on conflict (id) do update set
  name          = excluded.name,
  tagline       = excluded.tagline,
  ncx_amount    = excluded.ncx_amount,
  fiat_price    = excluded.fiat_price,
  color_hex     = excluded.color_hex,
  emoji         = excluded.emoji,
  sort_order    = excluded.sort_order;

-- RLS: packs are public read, no direct user write
alter table public.coin_packs enable row level security;
drop policy if exists "coin_packs_public_read" on public.coin_packs;
create policy "coin_packs_public_read"
  on public.coin_packs for select
  using (is_active = true);
revoke insert, update, delete on public.coin_packs from anon, authenticated;


-- ── Step 4: coin_issuances — every NCX batch ever minted ─────────────────
-- Each row = one authoritative event of NCX entering circulation for a user.
-- The origin_hash field stores a SHA-256 hex of (user_id || ncx_amount || fiat_amount || idempotency_key)
-- computed inside the RPC, providing a lightweight tamper-evident signature.
create table if not exists public.coin_issuances (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,                          -- beneficiary
  ncx_amount          bigint not null check (ncx_amount > 0), -- coins minted
  fiat_amount         bigint not null,                        -- fiat debited (0 for bonuses/gifts)
  fiat_currency       text not null default 'UGX',
  exchange_rate       numeric(18,6) not null,                 -- ncx_amount / fiat_amount (UGX per NCX)
  issuance_type       text not null                           -- 'WALLET_PURCHASE' | 'PESAPAL_PURCHASE' | 'ADMIN_GRANT' | 'BONUS'
    check (issuance_type in ('WALLET_PURCHASE','PESAPAL_PURCHASE','ADMIN_GRANT','BONUS')),
  payment_id          uuid,                                   -- FK to payments.id if from Pesapal
  idempotency_key     text unique,                            -- prevents double-issuance
  ledger_debit_id     uuid,                                   -- FK to the COIN_PURCHASE_DEBIT ledger row
  ledger_credit_id    uuid,                                   -- FK to the COIN_PURCHASE ledger row
  origin_hash         text not null,                          -- SHA-256 tamper-evident fingerprint
  coin_balance_after  bigint not null,
  fiat_balance_after  bigint not null,
  issued_at           timestamptz not null default now(),
  metadata            jsonb not null default '{}'
);

create index if not exists coin_issuances_user_idx  on public.coin_issuances(user_id, issued_at desc);
create index if not exists coin_issuances_idem_idx  on public.coin_issuances(idempotency_key);

alter table public.coin_issuances enable row level security;

-- Users may only read their own issuances (read-only; writes are service_role only)
drop policy if exists "coin_issuances_owner_read" on public.coin_issuances;
create policy "coin_issuances_owner_read"
  on public.coin_issuances for select
  using (auth.uid() = user_id);

revoke all on public.coin_issuances from anon, authenticated;
grant select on public.coin_issuances to authenticated;


-- ── Step 5: Canonical buy_coins_with_fiat_balance ─────────────────────────
-- Parameters:
--   p_user_auth_id      – the buyer's auth.uid()
--   p_fiat_amount       – fiat to deduct (integer UGX or other currency smallest unit)
--   p_ncx_to_receive    – coins to credit
--   p_fiat_currency     – e.g. 'UGX' (text, not enum, so caller never has cast issues)
--   p_idempotency_key   – from the payment record; used to prevent double-issuance
--   p_payment_id        – UUID of the payments row (optional, NULL for wallet-balance purchases)
--   p_issuance_type     – 'WALLET_PURCHASE' | 'PESAPAL_PURCHASE' | etc.
--   p_metadata          – any extra info to store on the issuance
--
-- Returns: jsonb with success, coin_balance_after, fiat_balance_after, issuance_id, origin_hash
create or replace function public.buy_coins_with_fiat_balance(
  p_user_auth_id    uuid,
  p_fiat_amount     bigint,
  p_ncx_to_receive  bigint,
  p_fiat_currency   text        default 'UGX',
  p_idempotency_key text        default null,
  p_payment_id      uuid        default null,
  p_issuance_type   text        default 'WALLET_PURCHASE',
  p_metadata        jsonb       default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wallet            public.wallets%rowtype;
  v_new_fiat          bigint;
  v_new_coin          bigint;
  v_idem_key          text;
  v_exchange_rate     numeric(18,6);
  v_debit_ledger_id   uuid;
  v_credit_ledger_id  uuid;
  v_issuance_id       uuid;
  v_origin_hash       text;
  v_existing          public.coin_issuances%rowtype;
begin
  -- ── 0. Validate inputs ──────────────────────────────────────────────────
  if p_fiat_amount <= 0 then
    raise exception 'Fiat amount must be positive.';
  end if;
  if p_ncx_to_receive <= 0 then
    raise exception 'NCX amount must be positive.';
  end if;
  if p_issuance_type not in ('WALLET_PURCHASE','PESAPAL_PURCHASE','ADMIN_GRANT','BONUS') then
    raise exception 'Invalid issuance type: %', p_issuance_type;
  end if;

  -- ── 1. Resolve idempotency key ──────────────────────────────────────────
  v_idem_key := coalesce(
    p_idempotency_key,
    'wallet-coin-' || p_user_auth_id::text || '-' || extract(epoch from now())::text
  );

  -- ── 2. Idempotency guard — return existing issuance if already processed ─
  select * into v_existing
  from public.coin_issuances
  where idempotency_key = v_idem_key;

  if found then
    return jsonb_build_object(
      'success',            true,
      'idempotent',         true,
      'issuance_id',        v_existing.id,
      'origin_hash',        v_existing.origin_hash,
      'coin_balance_after', v_existing.coin_balance_after,
      'fiat_balance_after', v_existing.fiat_balance_after,
      'message',            'Purchase already processed (idempotent replay).'
    );
  end if;

  -- ── 3. Lock wallet ──────────────────────────────────────────────────────
  select * into v_wallet
  from public.wallets
  where user_id = p_user_auth_id
  for update;

  if not found then
    raise exception 'Wallet not found for user %.', p_user_auth_id;
  end if;

  -- ── 4. Sufficient fiat balance check ───────────────────────────────────
  if v_wallet.fiat_balance < p_fiat_amount then
    raise exception 'Insufficient fiat balance. Have: % %, Need: % %.',
      v_wallet.fiat_balance, p_fiat_currency,
      p_fiat_amount,         p_fiat_currency;
  end if;

  -- ── 5. Compute exchange rate ────────────────────────────────────────────
  -- Stored as UGX-per-NCX (how much fiat one coin costs at this moment)
  v_exchange_rate := round(
    (p_fiat_amount::numeric / p_ncx_to_receive::numeric),
    6
  );

  -- ── 6. Atomic debit fiat + credit coins ────────────────────────────────
  update public.wallets
  set
    fiat_balance = fiat_balance - p_fiat_amount,
    coin_balance = coin_balance + p_ncx_to_receive,
    updated_at   = now()
  where user_id = p_user_auth_id
  returning fiat_balance, coin_balance
  into v_new_fiat, v_new_coin;

  -- ── 7. Write immutable ledger — FIAT DEBIT ─────────────────────────────
  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, metadata
  ) values (
    p_user_auth_id,
    'COIN_PURCHASE_DEBIT',
    p_fiat_amount,
    p_fiat_currency,
    'out',
    v_new_fiat,
    jsonb_build_object(
      'description',     'Fiat debited for coin purchase',
      'ncx_to_receive',  p_ncx_to_receive,
      'exchange_rate',   v_exchange_rate,
      'idempotency_key', v_idem_key,
      'issuance_type',   p_issuance_type
    ) || p_metadata
  )
  returning id into v_debit_ledger_id;

  -- ── 8. Write immutable ledger — NCX CREDIT ─────────────────────────────
  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, metadata
  ) values (
    p_user_auth_id,
    'COIN_PURCHASE',
    p_ncx_to_receive,
    'NCX',
    'in',
    v_new_coin,
    jsonb_build_object(
      'description',       'NCX coins issued from fiat wallet balance',
      'fiat_amount',       p_fiat_amount,
      'fiat_currency',     p_fiat_currency,
      'exchange_rate',     v_exchange_rate,
      'idempotency_key',   v_idem_key,
      'issuance_type',     p_issuance_type
    ) || p_metadata
  )
  returning id into v_credit_ledger_id;

  -- ── 9. Compute origin_hash ──────────────────────────────────────────────
  -- SHA-256 fingerprint ties together: user | ncx amount | fiat amount | idempotency key.
  -- Any tampering with those core facts would produce a different hash.
  v_origin_hash := encode(
    extensions.digest(
      (p_user_auth_id::text
        || '|' || p_ncx_to_receive::text
        || '|' || p_fiat_amount::text
        || '|' || p_fiat_currency
        || '|' || v_idem_key
        || '|' || v_credit_ledger_id::text)::text,
      'sha256'::text
    ),
    'hex'
  );

  -- ── 10. Write coin_issuances provenance record ──────────────────────────
  insert into public.coin_issuances (
    user_id,
    ncx_amount,
    fiat_amount,
    fiat_currency,
    exchange_rate,
    issuance_type,
    payment_id,
    idempotency_key,
    ledger_debit_id,
    ledger_credit_id,
    origin_hash,
    coin_balance_after,
    fiat_balance_after,
    metadata
  ) values (
    p_user_auth_id,
    p_ncx_to_receive,
    p_fiat_amount,
    p_fiat_currency,
    v_exchange_rate,
    p_issuance_type,
    p_payment_id,
    v_idem_key,
    v_debit_ledger_id,
    v_credit_ledger_id,
    v_origin_hash,
    v_new_coin,
    v_new_fiat,
    p_metadata
  )
  returning id into v_issuance_id;

  -- ── 11. Return rich result ──────────────────────────────────────────────
  return jsonb_build_object(
    'success',            true,
    'issuance_id',        v_issuance_id,
    'origin_hash',        v_origin_hash,
    'exchange_rate',      v_exchange_rate,
    'coin_balance_after', v_new_coin,
    'fiat_balance_after', v_new_fiat,
    'message',            'Coins issued successfully.'
  );
end;
$$;

-- Grant only service_role (Edge Functions run as service_role)
revoke all on function public.buy_coins_with_fiat_balance(uuid, bigint, bigint, text, text, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.buy_coins_with_fiat_balance(uuid, bigint, bigint, text, text, uuid, text, jsonb)
  to service_role;


-- ── Step 6: Helper view — coin_issuance_audit ────────────────────────────
-- A convenient read-only view for support/admin and future analytics.
create or replace view public.coin_issuance_audit as
select
  ci.id,
  ci.user_id,
  ci.ncx_amount,
  ci.fiat_amount,
  ci.fiat_currency,
  ci.exchange_rate,
  ci.issuance_type,
  ci.idempotency_key,
  ci.origin_hash,
  ci.coin_balance_after,
  ci.fiat_balance_after,
  ci.issued_at,
  -- Join to debit and credit ledger rows for full chain view
  dl.entry_type  as debit_entry_type,
  dl.created_at  as debit_recorded_at,
  cl.entry_type  as credit_entry_type,
  cl.created_at  as credit_recorded_at
from public.coin_issuances ci
left join public.immutable_financial_ledger dl on dl.id = ci.ledger_debit_id
left join public.immutable_financial_ledger cl on cl.id = ci.ledger_credit_id;

revoke all on public.coin_issuance_audit from anon, authenticated;
grant select on public.coin_issuance_audit to service_role;
