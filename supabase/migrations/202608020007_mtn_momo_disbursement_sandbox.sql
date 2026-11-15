-- MTN MoMo disbursement: reserve only available SP2 fiat, never NCX.
-- This migration is safe to apply before the Edge Function deployment.
create extension if not exists pgcrypto;

create table if not exists public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  method text not null check (method in ('mtn_momo')),
  amount_ugx bigint not null check (amount_ugx > 0),
  destination_msisdn text not null,
  recipient_name text,
  idempotency_key text not null unique,
  provider_reference uuid not null unique,
  status text not null default 'reserved' check (status in ('reserved', 'submitted', 'paid', 'failed', 'reversed', 'sandbox_completed')),
  provider_status jsonb not null default '{}'::jsonb,
  failure_reason text,
  submitted_at timestamptz,
  paid_at timestamptz,
  reversed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists withdrawal_requests_user_created_idx
  on public.withdrawal_requests (user_id, created_at desc);

alter table public.withdrawal_requests enable row level security;
revoke all on table public.withdrawal_requests from anon, authenticated;

create or replace function public.reserve_mtn_withdrawal(
  p_user_id uuid,
  p_amount_ugx bigint,
  p_destination_msisdn text,
  p_recipient_name text,
  p_idempotency_key text
)
returns table (withdrawal_id uuid, provider_reference uuid, status text, created boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.withdrawal_requests%rowtype;
  v_wallet public.wallets%rowtype;
  v_withdrawal_id uuid;
  v_provider_reference uuid;
begin
  if p_amount_ugx <= 0 then
    raise exception 'Withdrawal amount must be positive.';
  end if;
  if p_destination_msisdn !~ '^2567[0-9]{8}$' then
    raise exception 'An MTN Uganda number must use the 2567XXXXXXXX format.';
  end if;

  select * into v_existing
  from public.withdrawal_requests
  where idempotency_key = p_idempotency_key
  for update;

  if found then
    if v_existing.user_id <> p_user_id then
      raise exception 'Withdrawal reference belongs to another user.';
    end if;
    if v_existing.amount_ugx <> p_amount_ugx
       or v_existing.destination_msisdn <> p_destination_msisdn then
      raise exception 'Withdrawal reference does not match the original request.';
    end if;
    return query select v_existing.id, v_existing.provider_reference, v_existing.status, false;
    return;
  end if;

  select * into v_wallet
  from public.wallets
  where user_id = p_user_id
  for update;
  if not found then
    raise exception 'Wallet not found.';
  end if;
  if v_wallet.fiat_balance < p_amount_ugx then
    raise exception 'Insufficient available fiat balance.';
  end if;

  v_withdrawal_id := gen_random_uuid();
  v_provider_reference := gen_random_uuid();

  update public.wallets
  set fiat_balance = fiat_balance - p_amount_ugx,
      updated_at = now()
  where id = v_wallet.id;

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, metadata
  ) values (
    p_user_id,
    'WITHDRAWAL',
    p_amount_ugx,
    'UGX',
    'out',
    v_wallet.fiat_balance - p_amount_ugx,
    jsonb_build_object(
      'withdrawal_id', v_withdrawal_id,
      'idempotency_key', p_idempotency_key,
      'method', 'mtn_momo',
      'provider_reference', v_provider_reference,
      'status', 'reserved'
    )
  );

  insert into public.withdrawal_requests (
    id, user_id, method, amount_ugx, destination_msisdn, recipient_name,
    idempotency_key, provider_reference, status
  ) values (
    v_withdrawal_id, p_user_id, 'mtn_momo', p_amount_ugx, p_destination_msisdn,
    nullif(left(p_recipient_name, 160), ''), p_idempotency_key, v_provider_reference, 'reserved'
  );

  return query select v_withdrawal_id, v_provider_reference, 'reserved'::text, true;
end;
$$;

create or replace function public.mark_mtn_withdrawal_submitted(
  p_withdrawal_id uuid,
  p_provider_status jsonb default '{}'::jsonb
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  select status into v_status from public.withdrawal_requests where id = p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal not found.'; end if;
  if v_status in ('paid', 'failed', 'reversed', 'sandbox_completed') then return v_status; end if;

  update public.withdrawal_requests
  set status = 'submitted', provider_status = coalesce(p_provider_status, '{}'::jsonb),
      submitted_at = coalesce(submitted_at, now()), updated_at = now()
  where id = p_withdrawal_id;
  return 'submitted';
end;
$$;

create or replace function public.complete_mtn_withdrawal(
  p_withdrawal_id uuid,
  p_provider_status jsonb default '{}'::jsonb
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  select status into v_status from public.withdrawal_requests where id = p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal not found.'; end if;
  if v_status in ('paid', 'failed', 'reversed', 'sandbox_completed') then return v_status; end if;

  update public.withdrawal_requests
  set status = 'paid', provider_status = coalesce(p_provider_status, '{}'::jsonb),
      paid_at = now(), updated_at = now()
  where id = p_withdrawal_id;
  return 'paid';
end;
$$;

create or replace function public.reverse_mtn_withdrawal(
  p_withdrawal_id uuid,
  p_failure_reason text,
  p_provider_status jsonb default '{}'::jsonb
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_withdrawal public.withdrawal_requests%rowtype;
  v_wallet public.wallets%rowtype;
  v_new_fiat bigint;
begin
  select * into v_withdrawal from public.withdrawal_requests where id = p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal not found.'; end if;
  if v_withdrawal.status = 'paid' then raise exception 'A paid withdrawal cannot be reversed automatically.'; end if;
  if v_withdrawal.status in ('failed', 'reversed', 'sandbox_completed') then return v_withdrawal.status; end if;

  select * into v_wallet from public.wallets where user_id = v_withdrawal.user_id for update;
  if not found then raise exception 'Wallet not found.'; end if;

  update public.wallets
  set fiat_balance = fiat_balance + v_withdrawal.amount_ugx,
      updated_at = now()
  where id = v_wallet.id
  returning fiat_balance into v_new_fiat;

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, metadata
  ) values (
    v_withdrawal.user_id,
    'WALLET_DEPOSIT',
    v_withdrawal.amount_ugx,
    'UGX',
    'in',
    v_new_fiat,
    jsonb_build_object(
      'withdrawal_id', v_withdrawal.id,
      'method', 'mtn_momo',
      'reason', 'withdrawal_reversal',
      'provider_reference', v_withdrawal.provider_reference,
      'failure_reason', left(coalesce(p_failure_reason, 'MTN disbursement failed.'), 500)
    )
  );

  update public.withdrawal_requests
  set status = 'reversed', failure_reason = left(coalesce(p_failure_reason, 'MTN disbursement failed.'), 500),
      provider_status = coalesce(p_provider_status, '{}'::jsonb), reversed_at = now(), updated_at = now()
  where id = v_withdrawal.id;
  return 'reversed';
end;
$$;

-- A sandbox transfer proves the provider integration only. It must not consume
-- real UGX held in the finance wallet, so the reservation is refunded.
create or replace function public.complete_mtn_sandbox_withdrawal(
  p_withdrawal_id uuid,
  p_provider_status jsonb default '{}'::jsonb
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_withdrawal public.withdrawal_requests%rowtype;
  v_new_fiat bigint;
begin
  select * into v_withdrawal from public.withdrawal_requests where id = p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal not found.'; end if;
  if v_withdrawal.status in ('paid', 'failed', 'reversed', 'sandbox_completed') then return v_withdrawal.status; end if;

  update public.wallets
  set fiat_balance = fiat_balance + v_withdrawal.amount_ugx, updated_at = now()
  where user_id = v_withdrawal.user_id
  returning fiat_balance into v_new_fiat;
  if not found then raise exception 'Wallet not found.'; end if;

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after, metadata
  ) values (
    v_withdrawal.user_id, 'WITHDRAWAL_SANDBOX_REVERSAL', v_withdrawal.amount_ugx,
    'UGX', 'in', v_new_fiat,
    jsonb_build_object('withdrawal_id', v_withdrawal.id, 'method', 'mtn_momo',
      'reason', 'sandbox_transfer_completed', 'provider_reference', v_withdrawal.provider_reference)
  );

  update public.withdrawal_requests
  set status = 'sandbox_completed', provider_status = coalesce(p_provider_status, '{}'::jsonb),
      paid_at = now(), updated_at = now()
  where id = v_withdrawal.id;
  return 'sandbox_completed';
end;
$$;

revoke all on function public.reserve_mtn_withdrawal(uuid, bigint, text, text, text) from public, anon, authenticated;
revoke all on function public.mark_mtn_withdrawal_submitted(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.complete_mtn_withdrawal(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.reverse_mtn_withdrawal(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.complete_mtn_sandbox_withdrawal(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.reserve_mtn_withdrawal(uuid, bigint, text, text, text) to service_role;
grant execute on function public.mark_mtn_withdrawal_submitted(uuid, jsonb) to service_role;
grant execute on function public.complete_mtn_withdrawal(uuid, jsonb) to service_role;
grant execute on function public.reverse_mtn_withdrawal(uuid, text, jsonb) to service_role;
grant execute on function public.complete_mtn_sandbox_withdrawal(uuid, jsonb) to service_role;

notify pgrst, 'reload schema';
