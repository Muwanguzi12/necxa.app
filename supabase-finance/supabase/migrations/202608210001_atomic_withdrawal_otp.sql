create or replace function public.verify_and_consume_withdrawal_otp(
  p_user_id uuid,
  p_otp_hash text
) returns void
language plpgsql
security definer
set search_path = public as $$
declare
  v_otp public.withdrawal_otps;
begin
  select * into v_otp
  from public.withdrawal_otps
  where user_id = p_user_id
  for update;

  if not found then
    raise exception 'Withdrawal code is invalid or expired';
  end if;

  if v_otp.consumed_at is not null then
    raise exception 'Withdrawal code is invalid or expired';
  end if;

  if v_otp.expires_at < now() then
    raise exception 'Withdrawal code is invalid or expired';
  end if;

  if v_otp.attempts >= 5 then
    raise exception 'Too many withdrawal verification attempts';
  end if;

  if v_otp.code_hash <> p_otp_hash then
    update public.withdrawal_otps
    set attempts = attempts + 1
    where user_id = p_user_id;
    raise exception 'Withdrawal code is invalid or expired';
  end if;

  update public.withdrawal_otps
  set attempts = 0,
      consumed_at = now()
  where user_id = p_user_id;
end;
$$;

revoke all on function public.verify_and_consume_withdrawal_otp(uuid, text) from public, anon, authenticated;
grant execute on function public.verify_and_consume_withdrawal_otp(uuid, text) to service_role;

create or replace function public.create_withdrawal_request(
  p_user_id uuid,
  p_amount bigint,
  p_method text,
  p_destination_ciphertext text,
  p_recipient_name text,
  p_otp_hash text,
  p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
) returns public.withdrawals
language plpgsql
security definer
set search_path = public as $$
declare
  v_withdrawal public.withdrawals;
  v_wallet public.wallets;
begin
  if p_amount < 500 then
    raise exception 'Minimum withdrawal is UGX 500';
  end if;

  if p_amount > 5000000 then
    raise exception 'Withdrawal exceeds the UGX 5,000,000 limit';
  end if;

  if p_method not in ('mtn', 'airtel', 'bank') then
    raise exception 'Unsupported withdrawal method';
  end if;

  select * into v_withdrawal
  from public.withdrawals
  where user_id = p_user_id and idempotency_key = p_idempotency_key
  for update;

  if found then
    return v_withdrawal;
  end if;

  perform public.verify_and_consume_withdrawal_otp(p_user_id, p_otp_hash);

  insert into public.withdrawals(
    user_id,
    amount,
    currency,
    method,
    destination_ciphertext,
    recipient_name,
    status,
    workflow_status,
    idempotency_key,
    metadata
  )
  values (
    p_user_id,
    p_amount,
    'UGX',
    p_method,
    p_destination_ciphertext,
    p_recipient_name,
    'pending',
    'initiated',
    p_idempotency_key,
    p_metadata
  )
  returning * into v_withdrawal;

  v_wallet := public.debit_wallet(
    p_user_id,
    p_amount,
    'UGX',
    'WITHDRAWAL',
    v_withdrawal.id::text,
    'withdrawal:' || v_withdrawal.id::text,
    jsonb_build_object('withdrawal_id', v_withdrawal.id, 'method', p_method)
  );

  update public.wallets
  set total_withdrawn_fiat = total_withdrawn_fiat + p_amount
  where user_id = p_user_id;

  insert into public.withdrawal_status_events(
    withdrawal_id,
    previous_status,
    new_status,
    operator_id,
    note
  )
  values (
    v_withdrawal.id,
    null,
    'initiated',
    'system',
    'Withdrawal submitted by user'
  );

  return v_withdrawal;
end;
$$;

revoke all on function public.create_withdrawal_request(uuid, bigint, text, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.create_withdrawal_request(uuid, bigint, text, text, text, text, text, jsonb) to service_role;
