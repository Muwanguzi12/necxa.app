-- Atomic, replay-safe settlement for PesaPal wallet deposits and NCX purchases.
-- Apply this migration to the isolated NECXA Finance Supabase project.

alter table public.payments
  add column if not exists settled_at timestamptz,
  add column if not exists last_checked_at timestamptz,
  add column if not exists provider_status text,
  add column if not exists provider_response jsonb not null default '{}'::jsonb;

create index if not exists payments_unsettled_pesapal_user_idx
  on public.payments (user_id, created_at desc)
  where provider = 'pesapal' and settled_at is null;

create table if not exists public.external_payment_settlements (
  payment_id uuid primary key references public.payments(id) on delete restrict,
  idempotency_key text not null unique,
  user_id uuid not null,
  payment_type text not null check (payment_type in ('wallet_deposit', 'coin_purchase')),
  amount_ugx bigint not null check (amount_ugx > 0),
  amount_ncx bigint not null default 0 check (amount_ncx >= 0),
  provider text not null default 'pesapal',
  provider_reference text,
  provider_response jsonb not null default '{}'::jsonb,
  settled_at timestamptz not null default now()
);

create index if not exists external_payment_settlements_user_idx
  on public.external_payment_settlements (user_id, settled_at desc);

alter table public.external_payment_settlements enable row level security;
revoke all on public.external_payment_settlements from anon, authenticated;

-- Mark historical payments that already have a matching immutable ledger credit.
-- Completed payments without a matching credit remain unsettled and are repaired
-- by the next IPN, status check, or wallet refresh.
insert into public.external_payment_settlements (
  payment_id, idempotency_key, user_id, payment_type,
  amount_ugx, amount_ncx, provider_reference, provider_response, settled_at
)
select
  p.id,
  p.idempotency_key,
  p.user_id,
  p.request ->> 'type',
  case
    when p.request ->> 'type' = 'wallet_deposit'
      then (p.request ->> 'amount')::bigint
    else (p.request ->> 'fiatAmount')::bigint
  end,
  case
    when p.request ->> 'type' = 'coin_purchase'
      then (p.request ->> 'ncxAmount')::bigint
    else 0
  end,
  p.provider_reference,
  coalesce(p.provider_response, p.response, '{}'::jsonb),
  coalesce(p.updated_at, p.created_at, now())
from public.payments p
where p.provider = 'pesapal'
  and p.status = 'completed'
  and p.request ->> 'type' in ('wallet_deposit', 'coin_purchase')
  and case
    when p.request ->> 'type' = 'wallet_deposit'
      then coalesce((p.request ->> 'amount')::bigint, 0) > 0
    else coalesce((p.request ->> 'fiatAmount')::bigint, 0) > 0
      and coalesce((p.request ->> 'ncxAmount')::bigint, 0) > 0
  end
  and exists (
    select 1
    from public.immutable_financial_ledger l
    where l.user_id = p.user_id
      and (
        (
          p.request ->> 'type' = 'wallet_deposit'
          and l.entry_type = 'WALLET_DEPOSIT'
          and l.metadata ->> 'idempotency_key' = p.idempotency_key
        )
        or
        (
          p.request ->> 'type' = 'coin_purchase'
          and l.entry_type = 'COIN_PURCHASE'
          and (
            l.metadata ->> 'reference_id_text' = p.idempotency_key
            or l.metadata ->> 'idempotency_key' = p.idempotency_key
          )
        )
      )
  )
on conflict (payment_id) do nothing;

update public.payments p
set settled_at = s.settled_at,
    provider_status = coalesce(p.provider_status, 'COMPLETED')
from public.external_payment_settlements s
where s.payment_id = p.id
  and p.settled_at is null;

update public.payments p
set settled_at = coalesce(p.updated_at, p.created_at, now()),
    provider_status = coalesce(p.provider_status, 'COMPLETED')
where p.provider = 'pesapal'
  and p.status = 'completed'
  and p.request ->> 'type' = 'shop_purchase'
  and exists (
    select 1 from public.commerce_orders o
    where o.payment_id = p.idempotency_key
      and o.payment_status = 'COMPLETED'
  );

create or replace function public.settle_pesapal_wallet_payment(
  p_payment_id uuid,
  p_provider_status text,
  p_provider_response jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments%rowtype;
  v_wallet public.wallets%rowtype;
  v_type text;
  v_amount_ugx bigint;
  v_amount_ncx bigint := 0;
  v_new_balance bigint;
begin
  select * into v_payment
  from public.payments
  where id = p_payment_id
  for update;

  if not found then
    raise exception 'Payment not found.';
  end if;
  if v_payment.provider <> 'pesapal' then
    raise exception 'Payment provider is not PesaPal.';
  end if;

  select * into v_wallet
  from public.wallets
  where user_id = v_payment.user_id
  for update;

  if exists (
    select 1 from public.external_payment_settlements
    where payment_id = v_payment.id
  ) then
    return jsonb_build_object(
      'success', true,
      'alreadySettled', true,
      'paymentId', v_payment.id,
      'fiatBalance', coalesce(v_wallet.fiat_balance, 0),
      'coinBalance', coalesce(v_wallet.coin_balance, 0)
    );
  end if;

  v_type := coalesce(v_payment.request ->> 'type', 'wallet_deposit');
  if v_type not in ('wallet_deposit', 'coin_purchase') then
    raise exception 'Unsupported wallet payment type: %', v_type;
  end if;

  v_amount_ugx := case
    when v_type = 'wallet_deposit' then nullif(v_payment.request ->> 'amount', '')::bigint
    else nullif(v_payment.request ->> 'fiatAmount', '')::bigint
  end;
  v_amount_ncx := case
    when v_type = 'coin_purchase' then nullif(v_payment.request ->> 'ncxAmount', '')::bigint
    else 0
  end;

  if coalesce(v_amount_ugx, 0) <= 0 then
    raise exception 'Payment has no valid UGX amount.';
  end if;
  if v_type = 'coin_purchase' and coalesce(v_amount_ncx, 0) <= 0 then
    raise exception 'Coin purchase has no valid NCX amount.';
  end if;

  insert into public.wallets (user_id, fiat_balance, coin_balance, escrow_balance)
  values (v_payment.user_id, 0, 0, 0)
  on conflict (user_id) do nothing;

  select * into v_wallet
  from public.wallets
  where user_id = v_payment.user_id
  for update;

  insert into public.external_payment_settlements (
    payment_id, idempotency_key, user_id, payment_type,
    amount_ugx, amount_ncx, provider_reference, provider_response
  ) values (
    v_payment.id, v_payment.idempotency_key, v_payment.user_id, v_type,
    v_amount_ugx, v_amount_ncx, v_payment.provider_reference,
    coalesce(p_provider_response, '{}'::jsonb)
  );

  if v_type = 'wallet_deposit' then
    update public.wallets
    set fiat_balance = fiat_balance + v_amount_ugx,
        updated_at = now()
    where user_id = v_payment.user_id
    returning fiat_balance into v_new_balance;

    insert into public.immutable_financial_ledger (
      user_id, entry_type, amount, currency, direction, balance_after,
      reference_id, metadata
    ) values (
      v_payment.user_id, 'WALLET_DEPOSIT', v_amount_ugx, 'UGX', 'in', v_new_balance,
      v_payment.id,
      jsonb_build_object(
        'idempotency_key', v_payment.idempotency_key,
        'provider', 'pesapal',
        'provider_reference', v_payment.provider_reference
      )
    );
  else
    update public.wallets
    set coin_balance = coin_balance + v_amount_ncx,
        updated_at = now()
    where user_id = v_payment.user_id
    returning coin_balance into v_new_balance;

    insert into public.immutable_financial_ledger (
      user_id, entry_type, amount, currency, direction, balance_after,
      reference_id, metadata
    ) values (
      v_payment.user_id, 'COIN_PURCHASE', v_amount_ncx, 'NCX', 'in', v_new_balance,
      v_payment.id,
      jsonb_build_object(
        'fiat_amount', v_amount_ugx,
        'fiat_currency', 'UGX',
        'idempotency_key', v_payment.idempotency_key,
        'provider', 'pesapal',
        'provider_reference', v_payment.provider_reference
      )
    );
  end if;

  update public.payments
  set status = 'completed',
      provider_status = p_provider_status,
      provider_response = coalesce(p_provider_response, '{}'::jsonb),
      response = coalesce(response, '{}'::jsonb) || jsonb_build_object(
        'settlement_status', 'COMPLETED',
        'settled_at', now()
      ),
      last_checked_at = now(),
      settled_at = now(),
      updated_at = now()
  where id = v_payment.id;

  insert into public.payment_reconciliations (
    payment_id, idempotency_key, user_id, provider, amount_ugx,
    pesapal_status, reconciled_status, reconciled_at, pesapal_response
  ) values (
    v_payment.id, v_payment.idempotency_key, v_payment.user_id, 'pesapal', v_amount_ugx,
    p_provider_status, 'RECONCILED', now(), coalesce(p_provider_response, '{}'::jsonb)
  )
  on conflict (idempotency_key) do update
  set pesapal_status = excluded.pesapal_status,
      reconciled_status = 'RECONCILED',
      reconciled_at = excluded.reconciled_at,
      pesapal_response = excluded.pesapal_response,
      updated_at = now();

  return jsonb_build_object(
    'success', true,
    'alreadySettled', false,
    'paymentId', v_payment.id,
    'paymentType', v_type,
    'amountUgx', v_amount_ugx,
    'amountNcx', v_amount_ncx,
    'newBalance', v_new_balance
  );
end;
$$;

revoke all on function public.settle_pesapal_wallet_payment(uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.settle_pesapal_wallet_payment(uuid, text, jsonb)
  to service_role;
