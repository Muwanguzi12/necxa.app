create table public.withdrawal_otps (
  user_id uuid primary key references public.finance_users(user_id) on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts integer not null default 0,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.withdrawal_otps enable row level security;
revoke all on public.withdrawal_otps from anon, authenticated;

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
language plpgsql security definer set search_path = public as $$
declare v_otp public.withdrawal_otps; v_withdrawal public.withdrawals; v_wallet public.wallets;
begin
  if p_amount < 500 then raise exception 'Minimum withdrawal is UGX 500'; end if;
  if p_amount > 5000000 then raise exception 'Withdrawal exceeds the UGX 5,000,000 limit'; end if;
  if p_method not in ('mtn', 'airtel', 'bank') then raise exception 'Unsupported withdrawal method'; end if;
  select * into v_withdrawal from public.withdrawals where idempotency_key = p_idempotency_key;
  if found then return v_withdrawal; end if;

  select * into v_otp from public.withdrawal_otps where user_id = p_user_id for update;
  if not found or v_otp.consumed_at is not null or v_otp.expires_at < now() then raise exception 'Withdrawal code is invalid or expired'; end if;
  if v_otp.attempts >= 5 then raise exception 'Too many withdrawal verification attempts'; end if;
  if v_otp.code_hash <> p_otp_hash then
    update public.withdrawal_otps set attempts = attempts + 1 where user_id = p_user_id;
    raise exception 'Withdrawal code is invalid or expired';
  end if;

  insert into public.withdrawals(user_id, amount, currency, method, destination_ciphertext,
    recipient_name, status, idempotency_key, metadata)
  values(p_user_id, p_amount, 'UGX', p_method, p_destination_ciphertext,
    p_recipient_name, 'pending', p_idempotency_key, p_metadata)
  returning * into v_withdrawal;

  v_wallet := public.debit_wallet(p_user_id, p_amount, 'UGX', 'WITHDRAWAL',
    v_withdrawal.id::text, 'withdrawal:' || v_withdrawal.id::text,
    jsonb_build_object('withdrawal_id', v_withdrawal.id, 'method', p_method));
  update public.wallets set total_withdrawn_fiat = total_withdrawn_fiat + p_amount
    where user_id = p_user_id;
  update public.withdrawal_otps set consumed_at = now() where user_id = p_user_id;
  return v_withdrawal;
end;
$$;

create or replace function public.refund_failed_withdrawal(p_withdrawal_id uuid, p_reason text)
returns public.wallets language plpgsql security definer set search_path = public as $$
declare v_withdrawal public.withdrawals; v_wallet public.wallets;
begin
  select * into v_withdrawal from public.withdrawals where id = p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal not found'; end if;
  if v_withdrawal.status = 'refunded' then
    select * into v_wallet from public.wallets where user_id = v_withdrawal.user_id; return v_wallet;
  end if;
  if v_withdrawal.status = 'completed' then raise exception 'Completed withdrawal cannot be refunded'; end if;
  v_wallet := public.credit_wallet(v_withdrawal.user_id, v_withdrawal.amount, v_withdrawal.currency,
    'WITHDRAWAL_REFUND', v_withdrawal.id::text, 'withdrawal-refund:' || v_withdrawal.id::text,
    jsonb_build_object('reason', p_reason));
  update public.wallets set total_withdrawn_fiat = greatest(0, total_withdrawn_fiat - v_withdrawal.amount)
    where user_id = v_withdrawal.user_id;
  update public.withdrawals set status = 'refunded', metadata = metadata || jsonb_build_object('refund_reason', p_reason), updated_at = now()
    where id = v_withdrawal.id;
  return v_wallet;
end;
$$;

revoke all on function public.create_withdrawal_request(uuid,bigint,text,text,text,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.refund_failed_withdrawal(uuid,text) from public,anon,authenticated;
grant execute on function public.create_withdrawal_request(uuid,bigint,text,text,text,text,text,jsonb) to service_role;
grant execute on function public.refund_failed_withdrawal(uuid,text) to service_role;
