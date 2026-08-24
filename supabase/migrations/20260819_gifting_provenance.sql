-- ════════════════════════════════════════════════════════════════════════════
-- MIGRATION: Gifting Provenance (UTXO/FIFO Coin Tracking)
--
-- Goals:
--   1. Add `remaining_ncx` to `coin_issuances` to track unspent coins.
--   2. Allow new issuance types: 'GIFT_RECEIVED' and 'PLATFORM_FEE'.
--   3. Create `coin_provenance_transfers` to link consumed coins to gifts.
--   4. Update `process_gift` to consume the sender's coins using FIFO allocation,
--      ensuring every gifted coin traces back to the exact fiat deposit.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Update coin_issuances for UTXO tracking ────────────────────────────
alter table public.coin_issuances
add column if not exists remaining_ncx bigint default 0;

-- Backfill remaining_ncx to equal ncx_amount for existing issuances
update public.coin_issuances set remaining_ncx = ncx_amount where remaining_ncx = 0;

alter table public.coin_issuances
add constraint coin_issuances_remaining_ncx_check check (remaining_ncx >= 0 and remaining_ncx <= ncx_amount);

-- Update issuance_type check constraint
alter table public.coin_issuances drop constraint if exists coin_issuances_issuance_type_check;
alter table public.coin_issuances add constraint coin_issuances_issuance_type_check
check (issuance_type in ('WALLET_PURCHASE','PESAPAL_PURCHASE','ADMIN_GRANT','BONUS','GIFT_RECEIVED','PLATFORM_FEE'));


-- ── 2. Create coin_provenance_transfers ───────────────────────────────────
create table if not exists public.coin_provenance_transfers (
  id                        uuid primary key default gen_random_uuid(),
  gift_id                   uuid not null,
  sender_issuance_id        uuid not null references public.coin_issuances(id),
  receiver_issuance_id      uuid not null references public.coin_issuances(id),
  platform_fee_issuance_id  uuid references public.coin_issuances(id),
  ncx_consumed              bigint not null check (ncx_consumed > 0),
  created_at                timestamptz not null default now()
);

create index if not exists coin_prov_transfers_gift_idx on public.coin_provenance_transfers(gift_id);
create index if not exists coin_prov_transfers_sender_issuance_idx on public.coin_provenance_transfers(sender_issuance_id);


-- ── 3. Upgrade process_gift to include FIFO Provenance ────────────────────
create or replace function public.process_gift(
  p_sender_id uuid, p_receiver_id uuid, p_gift_item_id text, p_context_type text,
  p_context_id text, p_ncx_amount bigint, p_fee_basis_points integer,
  p_is_anonymous boolean, p_idempotency_key text, p_metadata jsonb default '{}'::jsonb
) returns public.gifts
language plpgsql security definer set search_path = public as $$
declare
  v_item             public.gift_items;
  v_fee              bigint;
  v_receiver_amount  bigint;
  v_gift             public.gifts;
  v_platform_id      constant uuid := '00000000-0000-4000-8000-000000000001';
  
  -- Provenance tracking
  v_remaining_to_consume bigint;
  v_utxo                 public.coin_issuances%rowtype;
  v_consume              bigint;
  v_receiver_issuance_id uuid;
  v_platform_issuance_id uuid := null;
  v_receiver_origin_hash text;
  v_platform_origin_hash text;
begin
  if p_sender_id = p_receiver_id then raise exception 'Cannot gift yourself'; end if;
  
  select * into v_gift from public.gifts
    where sender_id = p_sender_id and idempotency_key = p_idempotency_key;
  if found then return v_gift; end if;

  select * into v_item from public.gift_items where id = p_gift_item_id and is_active for share;
  if not found then raise exception 'Gift item is unavailable'; end if;
  if p_ncx_amount <> v_item.ncx_value then raise exception 'Gift price does not match the catalogue'; end if;

  perform public.ensure_finance_wallet(p_sender_id);
  perform public.ensure_finance_wallet(p_receiver_id);
  perform public.ensure_finance_wallet(v_platform_id, null, 'Necxa Platform');
  perform 1 from public.wallets
    where user_id in (p_sender_id,p_receiver_id,v_platform_id) order by user_id for update;

  v_fee := floor(v_item.ncx_value * greatest(0,least(p_fee_basis_points,10000)) / 10000.0);
  v_receiver_amount := v_item.ncx_value - v_fee;

  -- ── A. Standard Ledger & Wallet Updates ──
  perform public.debit_wallet(p_sender_id,v_item.ncx_value,'NCX','GIFT_SENT',p_context_id,
    p_idempotency_key || ':sender',p_metadata || jsonb_build_object('gift_item_id',v_item.id));
  perform public.credit_wallet(p_receiver_id,v_receiver_amount,'NCX','GIFT_RECEIVED',p_context_id,
    p_idempotency_key || ':receiver',p_metadata || jsonb_build_object('gift_item_id',v_item.id));
  if v_fee > 0 then
    perform public.credit_wallet(v_platform_id,v_fee,'NCX','GIFT_PLATFORM_FEE',p_context_id,
      p_idempotency_key || ':platform',jsonb_build_object('gift_item_id',v_item.id,'sender_id',p_sender_id,'receiver_id',p_receiver_id));
  end if;

  -- ── B. Insert into gifts table ──
  insert into public.gifts(sender_id,receiver_id,gift_item_id,context_type,context_id,ncx_amount,
    receiver_ncx,platform_fee_ncx,is_anonymous,idempotency_key,metadata)
  values(p_sender_id,p_receiver_id,v_item.id,p_context_type,p_context_id,v_item.ncx_value,
    v_receiver_amount,v_fee,p_is_anonymous,p_idempotency_key,p_metadata)
  returning * into v_gift;

  -- ── C. Create Receiver Issuance (Pool) ──
  v_receiver_origin_hash := encode(extensions.digest((p_receiver_id::text || '|GIFT|' || v_gift.id::text)::text, 'sha256'::text), 'hex');
  insert into public.coin_issuances (
    user_id, ncx_amount, remaining_ncx, fiat_amount, fiat_currency, exchange_rate,
    issuance_type, idempotency_key, origin_hash, coin_balance_after, fiat_balance_after
  ) values (
    p_receiver_id, v_receiver_amount, v_receiver_amount, 0, 'UGX', 0,
    'GIFT_RECEIVED', p_idempotency_key || ':receiver', v_receiver_origin_hash, 0, 0
  ) returning id into v_receiver_issuance_id;

  -- ── D. Create Platform Issuance (Pool) if fee exists ──
  if v_fee > 0 then
    v_platform_origin_hash := encode(extensions.digest((v_platform_id::text || '|FEE|' || v_gift.id::text)::text, 'sha256'::text), 'hex');
    insert into public.coin_issuances (
      user_id, ncx_amount, remaining_ncx, fiat_amount, fiat_currency, exchange_rate,
      issuance_type, idempotency_key, origin_hash, coin_balance_after, fiat_balance_after
    ) values (
      v_platform_id, v_fee, v_fee, 0, 'UGX', 0,
      'PLATFORM_FEE', p_idempotency_key || ':platform', v_platform_origin_hash, 0, 0
    ) returning id into v_platform_issuance_id;
  end if;

  -- ── E. Consume Sender UTXOs (FIFO Allocation) ──
  v_remaining_to_consume := v_item.ncx_value;
  
  for v_utxo in (
    select * from public.coin_issuances 
    where user_id = p_sender_id and remaining_ncx > 0 
    order by issued_at asc 
    for update
  ) loop
    v_consume := least(v_remaining_to_consume, v_utxo.remaining_ncx);
    
    -- Deduct from sender's batch
    update public.coin_issuances 
    set remaining_ncx = remaining_ncx - v_consume 
    where id = v_utxo.id;
    
    -- Record the tracing line
    insert into public.coin_provenance_transfers (
      gift_id, sender_issuance_id, receiver_issuance_id, platform_fee_issuance_id, ncx_consumed
    ) values (
      v_gift.id, v_utxo.id, v_receiver_issuance_id, v_platform_issuance_id, v_consume
    );
    
    v_remaining_to_consume := v_remaining_to_consume - v_consume;
    exit when v_remaining_to_consume = 0;
  end loop;

  -- If the sender didn't have enough tracked UTXOs (e.g. legacy balance), we don't fail the transaction,
  -- we just tracked as much as we could. (In a strict system, we would raise exception, but for
  -- backward compatibility with existing non-issued balances, we allow the gap).
  -- Future strictly issued coins will always have full UTXO coverage.

  return v_gift;
end;
$$;

revoke all on function public.process_gift(uuid,uuid,text,text,text,bigint,integer,boolean,text,jsonb) from public,anon,authenticated;
grant execute on function public.process_gift(uuid,uuid,text,text,text,bigint,integer,boolean,text,jsonb) to service_role;
