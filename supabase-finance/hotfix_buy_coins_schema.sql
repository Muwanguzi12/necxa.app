-- ════════════════════════════════════════════════════════════════════════════
-- HOTFIX: Resolve schema cache miss for buy_coins_with_fiat_balance
--
-- Error:  Could not find the function public.buy_coins_with_fiat_balance(
--           p_fiat_amount_to_spend, p_fiat_currency, p_ncx_to_receive, p_user_auth_id
--         ) in the schema cache
--
-- Root cause: PostgREST's schema cache still references the OLD parameter
-- name `p_fiat_amount_to_spend`. The Edge Function now calls with `p_fiat_amount`.
-- Solution: Drop ALL overloads (by name, since we can't know all type combos
-- in the cache), recreate the one canonical version, then force a schema reload.
--
-- Run in: Supabase Dashboard → SQL Editor → Finance Project (supabase-finance)
-- ════════════════════════════════════════════════════════════════════════════


-- ── Step 1: Ensure pgcrypto is installed ──────────────────────────────────
create extension if not exists pgcrypto with schema extensions;

-- ── Step 2: Drop every known overload by their full signature ─────────────
-- We list all variants that may have been created across migrations to ensure
-- none are lurking in the cache.

drop function if exists public.buy_coins_with_fiat_balance(uuid, bigint, bigint, text);
drop function if exists public.buy_coins_with_fiat_balance(uuid, bigint, bigint, public.finance_currency);

-- The new 8-arg version (drop if a previous partial deploy created it):
drop function if exists public.buy_coins_with_fiat_balance(uuid, bigint, bigint, text, text, uuid, text, jsonb);


-- ── Step 2: Prerequisites — ensure coin_packs table exists ────────────────
create table if not exists public.coin_packs (
  id            text primary key,
  name          text not null,
  tagline       text,
  ncx_amount    bigint not null check (ncx_amount > 0),
  fiat_price    bigint not null check (fiat_price > 0),
  fiat_currency text not null default 'UGX',
  color_hex     text not null default '#00E5FF',
  emoji         text not null default '✨',
  is_active     boolean not null default true,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now()
);

insert into public.coin_packs (id, name, tagline, ncx_amount, fiat_price, fiat_currency, color_hex, emoji, sort_order)
values
  ('spark',   'Spark Pack',   'Try it out',    10,    1000,  'UGX', '#64FFDA', '⚡', 1),
  ('starter', 'Starter Pack', 'Get started',   50,    5000,  'UGX', '#00E5FF', '🌟', 2),
  ('pro',     'Pro Pack',     'Most popular',  150,  15000,  'UGX', '#2979FF', '🔵', 3),
  ('elite',   'Elite Pack',   'Power user',    500,  50000,  'UGX', '#D500F9', '💜', 4),
  ('whale',   'Whale Pack',   'Go all in',    1200, 100000,  'UGX', '#FFC400', '🐋', 5)
on conflict (id) do update set
  name          = excluded.name,
  tagline       = excluded.tagline,
  ncx_amount    = excluded.ncx_amount,
  fiat_price    = excluded.fiat_price,
  color_hex     = excluded.color_hex,
  emoji         = excluded.emoji,
  sort_order    = excluded.sort_order;


-- ── Step 3: Prerequisites — ensure coin_issuances table exists ────────────
create table if not exists public.coin_issuances (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  ncx_amount          bigint not null check (ncx_amount > 0),
  fiat_amount         bigint not null,
  fiat_currency       text not null default 'UGX',
  exchange_rate       numeric(18,6) not null,
  issuance_type       text not null
    check (issuance_type in ('WALLET_PURCHASE','PESAPAL_PURCHASE','ADMIN_GRANT','BONUS')),
  payment_id          uuid,
  idempotency_key     text unique,
  ledger_debit_id     uuid,
  ledger_credit_id    uuid,
  origin_hash         text not null,
  coin_balance_after  bigint not null,
  fiat_balance_after  bigint not null,
  issued_at           timestamptz not null default now(),
  metadata            jsonb not null default '{}'
);

create index if not exists coin_issuances_user_idx on public.coin_issuances(user_id, issued_at desc);
create index if not exists coin_issuances_idem_idx on public.coin_issuances(idempotency_key);


-- ── Step 4: Create the ONE canonical function ─────────────────────────────
-- Parameter names MUST exactly match what the Edge Function sends.
-- The Edge Function calls with:
--   p_user_auth_id, p_fiat_amount, p_ncx_to_receive, p_fiat_currency,
--   p_idempotency_key, p_payment_id, p_issuance_type, p_metadata
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
  -- ── 0. Validate ─────────────────────────────────────────────────────────
  if p_fiat_amount <= 0 then
    raise exception 'Fiat amount must be positive.';
  end if;
  if p_ncx_to_receive <= 0 then
    raise exception 'NCX amount must be positive.';
  end if;
  if p_issuance_type not in ('WALLET_PURCHASE','PESAPAL_PURCHASE','ADMIN_GRANT','BONUS') then
    raise exception 'Invalid issuance type: %', p_issuance_type;
  end if;

  -- ── 1. Resolve idempotency key ───────────────────────────────────────────
  v_idem_key := coalesce(
    p_idempotency_key,
    'wallet-coin-' || p_user_auth_id::text || '-' || extract(epoch from now())::text
  );

  -- ── 2. Idempotency guard — replay already-completed purchase ────────────
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

  -- ── 3. Lock wallet row ───────────────────────────────────────────────────
  select * into v_wallet
  from public.wallets
  where user_id = p_user_auth_id
  for update;

  if not found then
    raise exception 'Wallet not found for user %.', p_user_auth_id;
  end if;

  -- ── 4. Balance check ─────────────────────────────────────────────────────
  if v_wallet.fiat_balance < p_fiat_amount then
    raise exception 'Insufficient fiat balance. Have: % %, Need: % %.',
      v_wallet.fiat_balance, p_fiat_currency,
      p_fiat_amount,         p_fiat_currency;
  end if;

  -- ── 5. Exchange rate snapshot ────────────────────────────────────────────
  v_exchange_rate := round((p_fiat_amount::numeric / p_ncx_to_receive::numeric), 6);

  -- ── 6. Atomic wallet update ──────────────────────────────────────────────
  update public.wallets
  set
    fiat_balance = fiat_balance - p_fiat_amount,
    coin_balance = coin_balance + p_ncx_to_receive,
    updated_at   = now()
  where user_id = p_user_auth_id
  returning fiat_balance, coin_balance
  into v_new_fiat, v_new_coin;

  -- ── 7. Ledger: fiat debit ────────────────────────────────────────────────
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
    ) || coalesce(p_metadata, '{}')
  )
  returning id into v_debit_ledger_id;

  -- ── 8. Ledger: NCX credit ────────────────────────────────────────────────
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
      'description',     'NCX coins issued from fiat wallet balance',
      'fiat_amount',     p_fiat_amount,
      'fiat_currency',   p_fiat_currency,
      'exchange_rate',   v_exchange_rate,
      'idempotency_key', v_idem_key,
      'issuance_type',   p_issuance_type
    ) || coalesce(p_metadata, '{}')
  )
  returning id into v_credit_ledger_id;

  -- ── 9. Origin hash — tamper-evident fingerprint ──────────────────────────
  -- We cast the whole string explicitly to text, and the algorithm to text
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

  -- ── 10. Provenance record ────────────────────────────────────────────────
  insert into public.coin_issuances (
    user_id, ncx_amount, fiat_amount, fiat_currency, exchange_rate,
    issuance_type, payment_id, idempotency_key, ledger_debit_id,
    ledger_credit_id, origin_hash, coin_balance_after, fiat_balance_after, metadata
  ) values (
    p_user_auth_id, p_ncx_to_receive, p_fiat_amount, p_fiat_currency, v_exchange_rate,
    p_issuance_type, p_payment_id, v_idem_key, v_debit_ledger_id,
    v_credit_ledger_id, v_origin_hash, v_new_coin, v_new_fiat, coalesce(p_metadata, '{}')
  )
  returning id into v_issuance_id;

  -- ── 11. Return ───────────────────────────────────────────────────────────
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

-- ── Step 5: Permissions ───────────────────────────────────────────────────
-- Only service_role (Edge Functions) may call this.
revoke all on function public.buy_coins_with_fiat_balance(uuid, bigint, bigint, text, text, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.buy_coins_with_fiat_balance(uuid, bigint, bigint, text, text, uuid, text, jsonb)
  to service_role;


-- ── Step 6: Force PostgREST schema cache reload ───────────────────────────
-- This is the critical step that resolves "Could not find function in schema cache".
-- PostgREST listens on the 'pgrst' channel for this exact notification.
notify pgrst, 'reload schema';
