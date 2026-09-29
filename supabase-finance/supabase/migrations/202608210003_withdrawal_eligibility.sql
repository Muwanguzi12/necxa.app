-- A withdrawal may use only traceable, settled earnings. This is enforced in
-- the same transaction that creates the withdrawal, not in the mobile client.
insert into public.finance_config(key, value, is_public)
values (
  'withdrawal_eligibility_policy',
  jsonb_build_object(
    'settlement_hold_hours', 24,
    'minimum_account_age_hours', 24,
    'eligible_ledger_entry_types', jsonb_build_array(
      'LIQUIDATION_PROCEEDS',
      'COMMERCE_VENDOR_PAYOUT',
      'COMMERCE_COURIER_PAYOUT',
      'COIN_LIQUIDATION',
      'ESCROW_RELEASE',
      'COMMISSION_PAYOUT'
    )
  ),
  false
)
on conflict (key) do nothing;

create or replace function public.assert_withdrawal_eligible(
  p_user_id uuid,
  p_amount bigint
) returns jsonb
language plpgsql
security definer
set search_path = public as $$
declare
  v_policy jsonb;
  v_settlement_hold_hours integer := 24;
  v_minimum_account_age_hours integer := 24;
  v_user_created_at timestamptz;
  v_wallet public.wallets;
  v_ledger_earnings bigint := 0;
  v_immutable_earnings bigint := 0;
  v_withdrawn bigint := 0;
  v_refunded bigint := 0;
  v_available bigint := 0;
begin
  if p_amount <= 0 then raise exception 'Withdrawal amount must be positive'; end if;

  -- The wallet lock serializes the eligibility calculation with the later debit.
  select * into v_wallet from public.wallets where user_id = p_user_id for update;
  if not found then raise exception 'Wallet not found'; end if;
  if v_wallet.is_frozen then
    raise exception 'Withdrawals are unavailable for this account: %', coalesce(v_wallet.freeze_reason, 'account review required');
  end if;

  select created_at into v_user_created_at from public.finance_users where user_id = p_user_id;
  if not found then raise exception 'Finance account not found'; end if;

  select value into v_policy from public.finance_config where key = 'withdrawal_eligibility_policy';
  v_settlement_hold_hours := greatest(0, coalesce((v_policy ->> 'settlement_hold_hours')::integer, 24));
  v_minimum_account_age_hours := greatest(0, coalesce((v_policy ->> 'minimum_account_age_hours')::integer, 24));

  if v_user_created_at > now() - make_interval(hours => v_minimum_account_age_hours) then
    raise exception 'Withdrawals become available after the account verification period';
  end if;

  -- These entries are created only by the financial engine after a completed
  -- liquidation or a completed commerce release.
  select coalesce(sum(amount), 0) into v_ledger_earnings
    from public.ledger_entries
   where user_id = p_user_id
     and currency = 'UGX'
     and direction = 'in'
     and entry_type in ('LIQUIDATION_PROCEEDS', 'COMMERCE_VENDOR_PAYOUT', 'COMMERCE_COURIER_PAYOUT')
     and created_at <= now() - make_interval(hours => v_settlement_hold_hours);

  -- The current commerce and liquidation engine writes to the immutable
  -- ledger. Do not use commerce_settlements here too: that would count the
  -- same released payout twice.
  select coalesce(sum(amount), 0) into v_immutable_earnings
    from public.immutable_financial_ledger
   where user_id = p_user_id
     and currency = 'UGX'
     and direction = 'in'
     and entry_type in ('COIN_LIQUIDATION', 'ESCROW_RELEASE', 'COMMISSION_PAYOUT')
     and created_at <= now() - make_interval(hours => v_settlement_hold_hours);

  -- Failed MTN payouts are refunded through the append-only ledger and must
  -- restore the user's eligible amount.
  select coalesce(sum(amount), 0) into v_withdrawn
    from public.ledger_entries
   where user_id = p_user_id
     and currency = 'UGX'
     and direction = 'out'
     and entry_type = 'WITHDRAWAL';
  select coalesce(sum(amount), 0) into v_refunded
    from public.ledger_entries
   where user_id = p_user_id
     and currency = 'UGX'
     and direction = 'in'
     and entry_type = 'WITHDRAWAL_REFUND';

  v_available := greatest(0, v_ledger_earnings + v_immutable_earnings - v_withdrawn + v_refunded);
  if v_available < p_amount then
    raise exception 'Withdrawal requires settled, traceable earnings. Available UGX %, requested UGX %', v_available, p_amount;
  end if;

  return jsonb_build_object(
    'approved', true,
    'evaluated_at', now(),
    'settlement_hold_hours', v_settlement_hold_hours,
    'eligible_ledger_earnings_ugx', v_ledger_earnings,
    'eligible_immutable_earnings_ugx', v_immutable_earnings,
    'previous_withdrawals_ugx', v_withdrawn,
    'withdrawal_refunds_ugx', v_refunded,
    'available_ugx', v_available,
    'requested_ugx', p_amount
  );
end;
$$;

create or replace function public.enforce_withdrawal_eligibility()
returns trigger
language plpgsql
security definer
set search_path = public as $$
declare
  v_assessment jsonb;
begin
  if new.currency = 'UGX' then
    v_assessment := public.assert_withdrawal_eligible(new.user_id, new.amount);
    new.metadata := coalesce(new.metadata, '{}'::jsonb) || jsonb_build_object(
      'source_of_funds_assessment', v_assessment
    );
  end if;
  return new;
end;
$$;

drop trigger if exists withdrawals_require_settled_earnings on public.withdrawals;
create trigger withdrawals_require_settled_earnings
before insert on public.withdrawals
for each row execute function public.enforce_withdrawal_eligibility();

revoke all on function public.assert_withdrawal_eligible(uuid, bigint) from public, anon, authenticated;
revoke all on function public.enforce_withdrawal_eligibility() from public, anon, authenticated;
grant execute on function public.assert_withdrawal_eligible(uuid, bigint) to service_role;

-- Keep proof-of-funds checks index-backed as the ledgers grow.
create index if not exists ledger_entries_withdrawal_eligibility_idx
  on public.ledger_entries (user_id, created_at)
  where currency = 'UGX'
    and direction = 'in'
    and entry_type in ('LIQUIDATION_PROCEEDS', 'COMMERCE_VENDOR_PAYOUT', 'COMMERCE_COURIER_PAYOUT');

create index if not exists immutable_ledger_withdrawal_eligibility_idx
  on public.immutable_financial_ledger (user_id, created_at)
  where currency = 'UGX'
    and direction = 'in'
    and entry_type in ('COIN_LIQUIDATION', 'ESCROW_RELEASE', 'COMMISSION_PAYOUT');
