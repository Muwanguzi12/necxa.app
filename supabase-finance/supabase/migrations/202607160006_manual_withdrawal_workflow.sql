alter table public.withdrawals
  add column workflow_status text not null default 'initiated';

update public.withdrawals set workflow_status = case status
  when 'processing' then 'processing'
  when 'completed' then 'paid'
  when 'failed' then 'failed'
  when 'refunded' then 'refunded'
  else 'initiated' end;

alter table public.withdrawals add constraint withdrawals_workflow_status_check
  check (workflow_status in ('initiated', 'pending', 'processing', 'paid', 'failed', 'refunded'));

create index withdrawals_workflow_queue_idx
  on public.withdrawals(workflow_status, created_at)
  where workflow_status in ('initiated', 'pending', 'processing');

create table public.withdrawal_status_events (
  id bigint generated always as identity primary key,
  withdrawal_id uuid not null references public.withdrawals(id) on delete restrict,
  previous_status text,
  new_status text not null,
  operator_id text not null,
  provider_reference text,
  note text,
  created_at timestamptz not null default now()
);

create index withdrawal_status_events_withdrawal_idx
  on public.withdrawal_status_events(withdrawal_id, created_at desc);

alter table public.withdrawal_status_events enable row level security;
revoke all on public.withdrawal_status_events from anon, authenticated;

create or replace function public.transition_withdrawal_status(
  p_withdrawal_id uuid,
  p_new_status text,
  p_operator_id text,
  p_provider_reference text default null,
  p_note text default null
) returns public.withdrawals
language plpgsql security definer set search_path = public as $$
declare v_withdrawal public.withdrawals; v_previous text;
begin
  if p_operator_id is null or btrim(p_operator_id) = '' then raise exception 'Operator is required'; end if;
  select * into v_withdrawal from public.withdrawals where id = p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal not found'; end if;
  v_previous := v_withdrawal.workflow_status;
  if v_previous = p_new_status then return v_withdrawal; end if;
  if not (
    (v_previous = 'initiated' and p_new_status in ('pending', 'failed')) or
    (v_previous = 'pending' and p_new_status in ('processing', 'failed')) or
    (v_previous = 'processing' and p_new_status in ('paid', 'failed'))
  ) then raise exception 'Invalid withdrawal status transition: % to %', v_previous, p_new_status; end if;
  if p_new_status = 'paid' and (p_provider_reference is null or btrim(p_provider_reference) = '') then
    raise exception 'Pesapal payment reference is required before marking a withdrawal paid';
  end if;
  update public.withdrawals set
    workflow_status = p_new_status,
    status = case p_new_status
      when 'processing' then 'processing'::public.payment_status
      when 'paid' then 'completed'::public.payment_status
      when 'failed' then 'failed'::public.payment_status
      when 'refunded' then 'refunded'::public.payment_status
      else 'pending'::public.payment_status end,
    provider_reference = coalesce(p_provider_reference, provider_reference),
    updated_at = now()
  where id = p_withdrawal_id returning * into v_withdrawal;
  insert into public.withdrawal_status_events(
    withdrawal_id, previous_status, new_status, operator_id, provider_reference, note
  ) values(p_withdrawal_id, v_previous, p_new_status, p_operator_id, p_provider_reference, p_note);
  return v_withdrawal;
end;
$$;

create or replace function public.refund_failed_withdrawal(p_withdrawal_id uuid, p_reason text)
returns public.wallets language plpgsql security definer set search_path = public as $$
declare v_withdrawal public.withdrawals; v_wallet public.wallets; v_previous text;
begin
  select * into v_withdrawal from public.withdrawals where id = p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal not found'; end if;
  if v_withdrawal.workflow_status = 'refunded' then
    select * into v_wallet from public.wallets where user_id = v_withdrawal.user_id; return v_wallet;
  end if;
  if v_withdrawal.workflow_status <> 'failed' then raise exception 'Only a failed withdrawal can be refunded'; end if;
  v_previous := v_withdrawal.workflow_status;
  v_wallet := public.credit_wallet(v_withdrawal.user_id, v_withdrawal.amount, v_withdrawal.currency,
    'WITHDRAWAL_REFUND', v_withdrawal.id::text, 'withdrawal-refund:' || v_withdrawal.id::text,
    jsonb_build_object('reason', p_reason));
  update public.wallets set total_withdrawn_fiat = greatest(0, total_withdrawn_fiat - v_withdrawal.amount)
    where user_id = v_withdrawal.user_id;
  update public.withdrawals set status = 'refunded', workflow_status = 'refunded',
    metadata = metadata || jsonb_build_object('refund_reason', p_reason), updated_at = now()
    where id = v_withdrawal.id;
  insert into public.withdrawal_status_events(withdrawal_id, previous_status, new_status, operator_id, note)
    values(v_withdrawal.id, v_previous, 'refunded', 'system-refund', p_reason);
  return v_wallet;
end;
$$;

revoke all on function public.transition_withdrawal_status(uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.transition_withdrawal_status(uuid,text,text,text,text) to service_role;

create or replace function public.create_withdrawal_request(
  p_user_id uuid, p_amount bigint, p_method text, p_destination_ciphertext text,
  p_recipient_name text, p_otp_hash text, p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
) returns public.withdrawals
language plpgsql security definer set search_path = public as $$
declare v_otp public.withdrawal_otps; v_withdrawal public.withdrawals; v_wallet public.wallets;
begin
  if p_amount < 500 then raise exception 'Minimum withdrawal is UGX 500'; end if;
  if p_amount > 5000000 then raise exception 'Withdrawal exceeds the UGX 5,000,000 limit'; end if;
  if p_method not in ('mtn', 'airtel', 'bank') then raise exception 'Unsupported withdrawal method'; end if;
  select * into v_withdrawal from public.withdrawals
    where user_id = p_user_id and idempotency_key = p_idempotency_key;
  if found then return v_withdrawal; end if;
  select * into v_otp from public.withdrawal_otps where user_id = p_user_id for update;
  if not found or v_otp.consumed_at is not null or v_otp.expires_at < now() or v_otp.attempts >= 5
    then raise exception 'Withdrawal code is invalid or expired'; end if;
  if v_otp.code_hash <> p_otp_hash then raise exception 'Withdrawal code is invalid or expired'; end if;
  insert into public.withdrawals(user_id, amount, currency, method, destination_ciphertext,
    recipient_name, status, workflow_status, idempotency_key, metadata)
  values(p_user_id, p_amount, 'UGX', p_method, p_destination_ciphertext,
    p_recipient_name, 'pending', 'initiated', p_idempotency_key, p_metadata)
  returning * into v_withdrawal;
  v_wallet := public.debit_wallet(p_user_id, p_amount, 'UGX', 'WITHDRAWAL',
    v_withdrawal.id::text, 'withdrawal:' || v_withdrawal.id::text,
    jsonb_build_object('withdrawal_id', v_withdrawal.id, 'method', p_method));
  update public.wallets set total_withdrawn_fiat = total_withdrawn_fiat + p_amount where user_id = p_user_id;
  update public.withdrawal_otps set consumed_at = now() where user_id = p_user_id;
  insert into public.withdrawal_status_events(withdrawal_id, previous_status, new_status, operator_id, note)
    values(v_withdrawal.id, null, 'initiated', 'system', 'Withdrawal submitted by user');
  return v_withdrawal;
end;
$$;
