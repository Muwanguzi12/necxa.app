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
  -- A verified provider completion is authoritative and may recover a local
  -- failed/cancelled state caused by an interrupted order-initialization write.
  -- Refunded payments remain final because their money has already been returned.
  if v_payment.status = 'refunded' then raise exception 'Refunded payment cannot be completed'; end if;
  v_ncx_amount := (v_payment.request ->> 'ncx_amount')::bigint;
  v_pack_id := v_payment.request ->> 'pack_id';
  if v_ncx_amount is null or v_ncx_amount <= 0 or v_pack_id is null then raise exception 'Invalid coin purchase snapshot'; end if;

  v_wallet := public.credit_wallet(v_payment.user_id, v_ncx_amount, 'NCX',
    'COIN_PURCHASE', v_payment.id::text, 'coin-purchase-ncx:' || v_payment.id::text,
    jsonb_build_object('pack_id', v_pack_id, 'fiat_cost', v_payment.amount,
      'provider', v_payment.provider, 'provider_reference', p_provider_reference,
      'recovered_from_status', v_payment.status));
  update public.payments set status = 'completed',
    provider_reference = coalesce(provider_reference, p_provider_reference),
    response = coalesce(p_provider_response, '{}'::jsonb), updated_at = now()
  where id = v_payment.id;
  return v_wallet;
end;
$$;

revoke all on function public.complete_coin_purchase(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.complete_coin_purchase(uuid,text,jsonb) to service_role;
