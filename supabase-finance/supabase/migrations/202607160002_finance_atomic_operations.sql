create or replace function public.ensure_finance_wallet(
  p_user_id uuid,
  p_email text default null,
  p_display_name text default null
) returns public.wallets
language plpgsql security definer set search_path = public as $$
declare v_wallet public.wallets;
begin
  insert into public.finance_users(user_id, email, display_name)
  values (p_user_id, p_email, p_display_name)
  on conflict (user_id) do update set
    email = coalesce(excluded.email, finance_users.email),
    display_name = coalesce(excluded.display_name, finance_users.display_name),
    updated_at = now();

  insert into public.wallets(user_id) values (p_user_id)
  on conflict (user_id) do nothing;

  select * into v_wallet from public.wallets where user_id = p_user_id;
  return v_wallet;
end;
$$;

create or replace function public.credit_wallet(
  p_user_id uuid,
  p_amount bigint,
  p_currency public.finance_currency,
  p_entry_type text,
  p_reference_id text,
  p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
) returns public.wallets
language plpgsql security definer set search_path = public as $$
declare v_wallet public.wallets;
begin
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  if exists(select 1 from public.ledger_entries where user_id = p_user_id and idempotency_key = p_idempotency_key) then
    select * into v_wallet from public.wallets where user_id = p_user_id;
    return v_wallet;
  end if;

  perform public.ensure_finance_wallet(p_user_id);
  if p_currency = 'NCX' then
    update public.wallets set coin_balance = coin_balance + p_amount, version = version + 1, updated_at = now()
    where user_id = p_user_id returning * into v_wallet;
    insert into public.ledger_entries(user_id, entry_type, amount, currency, direction,
      balance_after, reference_id, idempotency_key, metadata)
    values(p_user_id, p_entry_type, p_amount, p_currency, 'in', v_wallet.coin_balance,
      p_reference_id, p_idempotency_key, p_metadata);
  else
    update public.wallets set fiat_balance = fiat_balance + p_amount, version = version + 1, updated_at = now()
    where user_id = p_user_id returning * into v_wallet;
    insert into public.ledger_entries(user_id, entry_type, amount, currency, direction,
      balance_after, reference_id, idempotency_key, metadata)
    values(p_user_id, p_entry_type, p_amount, p_currency, 'in', v_wallet.fiat_balance,
      p_reference_id, p_idempotency_key, p_metadata);
  end if;
  return v_wallet;
end;
$$;

create or replace function public.debit_wallet(
  p_user_id uuid,
  p_amount bigint,
  p_currency public.finance_currency,
  p_entry_type text,
  p_reference_id text,
  p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
) returns public.wallets
language plpgsql security definer set search_path = public as $$
declare v_wallet public.wallets;
begin
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  if exists(select 1 from public.ledger_entries where user_id = p_user_id and idempotency_key = p_idempotency_key) then
    select * into v_wallet from public.wallets where user_id = p_user_id;
    return v_wallet;
  end if;

  select * into v_wallet from public.wallets where user_id = p_user_id for update;
  if not found then raise exception 'Wallet not found'; end if;

  if p_currency = 'NCX' then
    if v_wallet.coin_balance < p_amount then raise exception 'Insufficient NCX balance'; end if;
    update public.wallets set coin_balance = coin_balance - p_amount, version = version + 1, updated_at = now()
    where user_id = p_user_id returning * into v_wallet;
    insert into public.ledger_entries(user_id, entry_type, amount, currency, direction,
      balance_after, reference_id, idempotency_key, metadata)
    values(p_user_id, p_entry_type, p_amount, p_currency, 'out', v_wallet.coin_balance,
      p_reference_id, p_idempotency_key, p_metadata);
  else
    if v_wallet.fiat_balance < p_amount then raise exception 'Insufficient fiat balance'; end if;
    update public.wallets set fiat_balance = fiat_balance - p_amount, version = version + 1, updated_at = now()
    where user_id = p_user_id returning * into v_wallet;
    insert into public.ledger_entries(user_id, entry_type, amount, currency, direction,
      balance_after, reference_id, idempotency_key, metadata)
    values(p_user_id, p_entry_type, p_amount, p_currency, 'out', v_wallet.fiat_balance,
      p_reference_id, p_idempotency_key, p_metadata);
  end if;
  return v_wallet;
end;
$$;

create or replace function public.process_gift(
  p_sender_id uuid,
  p_receiver_id uuid,
  p_gift_item_id text,
  p_context_type text,
  p_context_id text,
  p_ncx_amount bigint,
  p_fee_basis_points integer,
  p_is_anonymous boolean,
  p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
) returns public.gifts
language plpgsql security definer set search_path = public as $$
declare
  v_fee bigint;
  v_receiver_amount bigint;
  v_sender public.wallets;
  v_receiver public.wallets;
  v_gift public.gifts;
begin
  if p_sender_id = p_receiver_id then raise exception 'Cannot gift yourself'; end if;
  if p_ncx_amount <= 0 then raise exception 'Gift amount must be positive'; end if;
  select * into v_gift from public.gifts where idempotency_key = p_idempotency_key;
  if found then return v_gift; end if;

  perform public.ensure_finance_wallet(p_receiver_id);
  v_fee := floor(p_ncx_amount * greatest(0, least(p_fee_basis_points, 10000)) / 10000.0);
  v_receiver_amount := p_ncx_amount - v_fee;
  v_sender := public.debit_wallet(p_sender_id, p_ncx_amount, 'NCX', 'GIFT_SENT',
    p_context_id, p_idempotency_key || ':sender', p_metadata);
  v_receiver := public.credit_wallet(p_receiver_id, v_receiver_amount, 'NCX', 'GIFT_RECEIVED',
    p_context_id, p_idempotency_key || ':receiver', p_metadata);

  insert into public.gifts(sender_id, receiver_id, gift_item_id, context_type, context_id,
    ncx_amount, receiver_ncx, platform_fee_ncx, is_anonymous, idempotency_key, metadata)
  values(p_sender_id, p_receiver_id, p_gift_item_id, p_context_type, p_context_id,
    p_ncx_amount, v_receiver_amount, v_fee, p_is_anonymous, p_idempotency_key, p_metadata)
  returning * into v_gift;
  return v_gift;
end;
$$;

create or replace function public.liquidate_ncx(
  p_user_id uuid,
  p_ncx_amount bigint,
  p_ugx_per_ncx bigint,
  p_burn_basis_points integer,
  p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
) returns public.wallets
language plpgsql security definer set search_path = public as $$
declare v_wallet public.wallets; v_ugx bigint;
begin
  v_wallet := public.debit_wallet(p_user_id, p_ncx_amount, 'NCX', 'LIQUIDATION', null,
    p_idempotency_key || ':ncx', p_metadata);
  v_ugx := floor(p_ncx_amount * p_ugx_per_ncx *
    (10000 - greatest(0, least(p_burn_basis_points, 10000))) / 10000.0);
  return public.credit_wallet(p_user_id, v_ugx, 'UGX', 'LIQUIDATION_PROCEEDS', null,
    p_idempotency_key || ':ugx', p_metadata);
end;
$$;

revoke all on function public.ensure_finance_wallet(uuid, text, text) from public, anon, authenticated;
revoke all on function public.credit_wallet(uuid, bigint, public.finance_currency, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.debit_wallet(uuid, bigint, public.finance_currency, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.process_gift(uuid, uuid, text, text, text, bigint, integer, boolean, text, jsonb) from public, anon, authenticated;
revoke all on function public.liquidate_ncx(uuid, bigint, bigint, integer, text, jsonb) from public, anon, authenticated;
grant execute on function public.ensure_finance_wallet(uuid, text, text) to service_role;
grant execute on function public.credit_wallet(uuid, bigint, public.finance_currency, text, text, text, jsonb) to service_role;
grant execute on function public.debit_wallet(uuid, bigint, public.finance_currency, text, text, text, jsonb) to service_role;
grant execute on function public.process_gift(uuid, uuid, text, text, text, bigint, integer, boolean, text, jsonb) to service_role;
grant execute on function public.liquidate_ncx(uuid, bigint, bigint, integer, text, jsonb) to service_role;
