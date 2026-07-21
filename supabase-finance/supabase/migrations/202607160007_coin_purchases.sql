create or replace function public.purchase_coins_from_wallet(
  p_user_id uuid,
  p_pack_id text,
  p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
) returns public.payments
language plpgsql security definer set search_path = public as $$
declare v_pack public.coin_packs; v_payment public.payments; v_wallet public.wallets;
begin
  select * into v_payment from public.payments
    where user_id = p_user_id and idempotency_key = p_idempotency_key and purpose = 'coin_purchase';
  if found then return v_payment; end if;

  select * into v_pack from public.coin_packs where id = p_pack_id and is_active for share;
  if not found then raise exception 'Coin pack not found'; end if;

  insert into public.payments(user_id, provider, purpose, amount, currency, status,
    idempotency_key, request, response)
  values(p_user_id, 'wallet_balance', 'coin_purchase', v_pack.fiat_price, v_pack.fiat_currency,
    'processing', p_idempotency_key,
    jsonb_build_object('pack_id', v_pack.id, 'ncx_amount', v_pack.ncx_amount, 'metadata', p_metadata),
    '{}'::jsonb)
  returning * into v_payment;

  v_wallet := public.debit_wallet(p_user_id, v_pack.fiat_price, v_pack.fiat_currency,
    'COIN_PURCHASE_FIAT', v_payment.id::text, 'coin-purchase-fiat:' || v_payment.id::text,
    jsonb_build_object('pack_id', v_pack.id, 'ncx_amount', v_pack.ncx_amount));
  v_wallet := public.credit_wallet(p_user_id, v_pack.ncx_amount, 'NCX',
    'COIN_PURCHASE', v_payment.id::text, 'coin-purchase-ncx:' || v_payment.id::text,
    jsonb_build_object('pack_id', v_pack.id, 'fiat_cost', v_pack.fiat_price));

  update public.payments set status = 'completed', updated_at = now()
    where id = v_payment.id returning * into v_payment;
  return v_payment;
end;
$$;

create or replace function public.complete_coin_purchase(
  p_payment_id uuid,
  p_provider_reference text,
  p_provider_response jsonb
) returns public.wallets
language plpgsql security definer set search_path = public as $$
declare v_payment public.payments; v_wallet public.wallets; v_ncx_amount bigint; v_pack_id text;
begin
  select * into v_payment from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_payment.purpose <> 'coin_purchase' then raise exception 'Payment is not a coin purchase'; end if;
  if v_payment.status = 'completed' then
    select * into v_wallet from public.wallets where user_id = v_payment.user_id;
    return v_wallet;
  end if;
  if v_payment.status in ('failed', 'cancelled', 'refunded') then raise exception 'Payment is already final'; end if;
  v_ncx_amount := (v_payment.request ->> 'ncx_amount')::bigint;
  v_pack_id := v_payment.request ->> 'pack_id';
  if v_ncx_amount is null or v_ncx_amount <= 0 or v_pack_id is null then raise exception 'Invalid coin purchase snapshot'; end if;

  v_wallet := public.credit_wallet(v_payment.user_id, v_ncx_amount, 'NCX',
    'COIN_PURCHASE', v_payment.id::text, 'coin-purchase-ncx:' || v_payment.id::text,
    jsonb_build_object('pack_id', v_pack_id, 'fiat_cost', v_payment.amount,
      'provider', v_payment.provider, 'provider_reference', p_provider_reference));
  update public.payments set status = 'completed',
    provider_reference = coalesce(provider_reference, p_provider_reference),
    response = coalesce(p_provider_response, '{}'::jsonb), updated_at = now()
  where id = v_payment.id;
  return v_wallet;
end;
$$;

revoke all on function public.purchase_coins_from_wallet(uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.complete_coin_purchase(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.purchase_coins_from_wallet(uuid,text,text,jsonb) to service_role;
grant execute on function public.complete_coin_purchase(uuid,text,jsonb) to service_role;
