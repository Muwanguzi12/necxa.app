-- ════════════════════════════════════════════════════════════════════════════
-- MIGRATION: Unified Gifting Engine (Live Architecture for Community)
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Update gifts table constraints ─────────────────────────────────────
alter table public.gifts drop constraint if exists gifts_context_type_check;
alter table public.gifts add constraint gifts_context_type_check
  check (context_type in ('direct', 'creator_post', 'listing', 'live_stream'));

-- ── 2. Enhance process_gift for universal context ──────────────────────────
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
  if not found then raise exception 'Gift item unavailable'; end if;
  if p_ncx_amount <> v_item.ncx_value then raise exception 'Gift price mismatch'; end if;

  perform public.ensure_finance_wallet(p_sender_id);
  perform public.ensure_finance_wallet(p_receiver_id);
  perform public.ensure_finance_wallet(v_platform_id, null, 'Necxa Platform');
  perform 1 from public.wallets
    where user_id in (p_sender_id,p_receiver_id,v_platform_id) order by user_id for update;

  v_fee := floor(v_item.ncx_value * greatest(0,least(p_fee_basis_points,10000)) / 10000.0);
  v_receiver_amount := v_item.ncx_value - v_fee;

  perform public.debit_wallet(p_sender_id,v_item.ncx_value,'NCX','GIFT_SENT',p_context_id,
    p_idempotency_key || ':sender',p_metadata || jsonb_build_object('gift_item_id',v_item.id, 'context_type', p_context_type));
  perform public.credit_wallet(p_receiver_id,v_receiver_amount,'NCX','GIFT_RECEIVED',p_context_id,
    p_idempotency_key || ':receiver',p_metadata || jsonb_build_object('gift_item_id',v_item.id, 'context_type', p_context_type));
  if v_fee > 0 then
    perform public.credit_wallet(v_platform_id,v_fee,'NCX','GIFT_PLATFORM_FEE',p_context_id,
      p_idempotency_key || ':platform',jsonb_build_object('gift_item_id',v_item.id,'sender_id',p_sender_id,'receiver_id',p_receiver_id, 'context_type', p_context_type));
  end if;

  insert into public.gifts(sender_id,receiver_id,gift_item_id,context_type,context_id,ncx_amount,
    receiver_ncx,platform_fee_ncx,is_anonymous,idempotency_key,metadata)
  values(p_sender_id,p_receiver_id,v_item.id,p_context_type,p_context_id,v_item.ncx_value,
    v_receiver_amount,v_fee,p_is_anonymous,p_idempotency_key,p_metadata)
  returning * into v_gift;

  -- Use explicit schema prefix for digest (Supabase standard)
  v_receiver_origin_hash := encode(extensions.digest((p_receiver_id::text || '|GIFT|' || v_gift.id::text)::text, 'sha256'::text), 'hex');
  insert into public.coin_issuances (user_id, ncx_amount, remaining_ncx, fiat_amount, fiat_currency, exchange_rate, issuance_type, idempotency_key, origin_hash, coin_balance_after, fiat_balance_after)
  values (p_receiver_id, v_receiver_amount, v_receiver_amount, 0, 'UGX', 0, 'GIFT_RECEIVED', p_idempotency_key || ':receiver', v_receiver_origin_hash, 0, 0)
  returning id into v_receiver_issuance_id;

  if v_fee > 0 then
    v_platform_origin_hash := encode(extensions.digest((v_platform_id::text || '|FEE|' || v_gift.id::text)::text, 'sha256'::text), 'hex');
    insert into public.coin_issuances (user_id, ncx_amount, remaining_ncx, fiat_amount, fiat_currency, exchange_rate, issuance_type, idempotency_key, origin_hash, coin_balance_after, fiat_balance_after)
    values (v_platform_id, v_fee, v_fee, 0, 'UGX', 0, 'PLATFORM_FEE', p_idempotency_key || ':platform', v_platform_origin_hash, 0, 0)
    returning id into v_platform_issuance_id;
  end if;

  v_remaining_to_consume := v_item.ncx_value;
  for v_utxo in (select * from public.coin_issuances where user_id = p_sender_id and remaining_ncx > 0 order by issued_at asc for update) loop
    v_consume := least(v_remaining_to_consume, v_utxo.remaining_ncx);
    update public.coin_issuances set remaining_ncx = remaining_ncx - v_consume where id = v_utxo.id;
    insert into public.coin_provenance_transfers (gift_id, sender_issuance_id, receiver_issuance_id, platform_fee_issuance_id, ncx_consumed)
    values (v_gift.id, v_utxo.id, v_receiver_issuance_id, v_platform_issuance_id, v_consume);
    v_remaining_to_consume := v_remaining_to_consume - v_consume;
    exit when v_remaining_to_consume = 0;
  end loop;

  return v_gift;
end;
$$;

-- ── 3. Unified Edge Function RPC ──────────────────────────────────────────
create or replace function public.process_gift_ncx(
  p_sender_auth_id uuid, p_receiver_auth_id uuid, p_target_id uuid,
  p_ncx_amount bigint, p_gift_platform_fee_rate double precision, p_gift_details jsonb
) returns table (success boolean, message text, platform_fee_paid bigint, receiver_amount_credited bigint, gift_id uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_gift public.gifts;
  v_context_type text := coalesce(p_gift_details->>'context_type', 'creator_post');
  v_context_id text;
begin
  v_context_id := case
    when v_context_type = 'direct' then 'direct:' || p_receiver_auth_id::text
    when v_context_type = 'live_stream' then coalesce(p_gift_details->>'channel_id', p_gift_details->>'context_id', 'global_live')
    else coalesce(p_target_id::text, p_gift_details->>'context_id', 'unknown')
  end;

  select * into v_gift from public.process_gift(
    p_sender_auth_id, p_receiver_auth_id, p_gift_details->>'gift_item_id', v_context_type, v_context_id,
    p_ncx_amount, (round(coalesce(p_gift_platform_fee_rate, 0.11) * 10000))::integer,
    coalesce((p_gift_details->>'is_anonymous')::boolean, false),
    coalesce(p_gift_details->>'idempotency_key', gen_random_uuid()::text), p_gift_details
  );

  return query select true, 'Gift sent successfully.'::text, v_gift.platform_fee_ncx, v_gift.receiver_ncx, v_gift.id;
end;
$$;
