create or replace function public.complete_deposit(
  p_payment_id uuid,
  p_provider_reference text,
  p_provider_response jsonb
) returns public.wallets
language plpgsql security definer set search_path = public as $$
declare
  v_payment public.payments;
  v_wallet public.wallets;
begin
  select * into v_payment from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_payment.purpose <> 'wallet_deposit' then raise exception 'Payment is not a wallet deposit'; end if;

  if v_payment.status = 'completed' then
    select * into v_wallet from public.wallets where user_id = v_payment.user_id;
    return v_wallet;
  end if;
  if v_payment.status in ('failed', 'cancelled', 'refunded') then
    raise exception 'Payment is already final';
  end if;

  v_wallet := public.credit_wallet(
    v_payment.user_id,
    v_payment.amount,
    v_payment.currency,
    'WALLET_DEPOSIT',
    v_payment.id::text,
    'deposit:' || v_payment.id::text,
    jsonb_build_object('provider', v_payment.provider, 'provider_reference', p_provider_reference)
  );

  update public.payments set
    status = 'completed',
    provider_reference = coalesce(provider_reference, p_provider_reference),
    response = coalesce(p_provider_response, '{}'::jsonb),
    updated_at = now()
  where id = v_payment.id;
  return v_wallet;
end;
$$;

revoke all on function public.complete_deposit(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.complete_deposit(uuid, text, jsonb) to service_role;
