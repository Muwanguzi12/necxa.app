begin;

alter table public.community_gifts
  add column if not exists idempotency_key text;

create unique index if not exists community_gifts_finance_idempotency_idx
  on public.community_gifts (idempotency_key)
  where idempotency_key is not null;

-- The added gift_id lets finance-engine correlate the canonical transfer with
-- the primary community projection. PostgreSQL requires replacing the
-- function when its table-return shape changes.
drop function if exists public.process_gift_ncx(
  uuid, uuid, uuid, bigint, float, jsonb
);

create or replace function public.process_gift_ncx(
  p_sender_auth_id uuid,
  p_receiver_auth_id uuid,
  p_post_id uuid,
  p_ncx_amount bigint,
  p_gift_platform_fee_rate float,
  p_gift_details jsonb
)
returns table (
  success boolean,
  message text,
  platform_fee_paid bigint,
  receiver_amount_credited bigint,
  gift_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender_wallet public.wallets%rowtype;
  v_receiver_wallet public.wallets%rowtype;
  v_platform_wallet public.wallets%rowtype;
  v_item public.gift_items%rowtype;
  v_platform_wallet_user_id constant uuid :=
    '00000000-0000-0000-0000-000000000001';
  v_idempotency_key text := nullif(trim(p_gift_details->>'idempotency_key'), '');
  v_platform_fee_ncx bigint;
  v_receiver_ncx bigint;
  v_sender_new_balance bigint;
  v_receiver_new_balance bigint;
  v_platform_new_balance bigint;
  v_gift_id uuid;
begin
  if p_sender_auth_id is null or p_receiver_auth_id is null
     or p_sender_auth_id = p_receiver_auth_id then
    return query select false, 'Cannot send a gift to yourself.', 0::bigint,
      0::bigint, null::uuid;
    return;
  end if;
  if p_ncx_amount <= 0 then
    return query select false, 'Gift amount must be positive.', 0::bigint,
      0::bigint, null::uuid;
    return;
  end if;
  if v_idempotency_key is null then
    return query select false, 'Idempotency key is required.', 0::bigint,
      0::bigint, null::uuid;
    return;
  end if;

  -- Serialize retries before checking the projection or changing balances.
  perform pg_advisory_xact_lock(hashtextextended(v_idempotency_key, 0));

  select id, creator_fiat_cut, necxa_fiat_fee
    into v_gift_id, v_receiver_ncx, v_platform_fee_ncx
  from public.community_gifts
  where idempotency_key = v_idempotency_key
  limit 1;
  if found then
    return query select true, 'Gift already processed.', v_platform_fee_ncx,
      v_receiver_ncx, v_gift_id;
    return;
  end if;

  select * into v_item
  from public.gift_items
  where id = p_gift_details->>'gift_item_id'
    and is_active
  for share;
  if not found then
    return query select false, 'Gift item is unavailable.', 0::bigint,
      0::bigint, null::uuid;
    return;
  end if;
  if p_ncx_amount <> v_item.ncx_value then
    return query select false, 'Gift price does not match the catalogue.',
      0::bigint, 0::bigint, null::uuid;
    return;
  end if;

  v_platform_fee_ncx := floor(
    p_ncx_amount * greatest(0, least(p_gift_platform_fee_rate, 1))
  );
  v_receiver_ncx := p_ncx_amount - v_platform_fee_ncx;

  select * into v_sender_wallet
  from public.wallets
  where user_id = p_sender_auth_id
  for update;
  if not found or v_sender_wallet.coin_balance < p_ncx_amount then
    return query select false, 'Insufficient NCX balance.', 0::bigint,
      0::bigint, null::uuid;
    return;
  end if;

  insert into public.wallets (user_id)
  values (p_receiver_auth_id)
  on conflict (user_id) do nothing;
  select * into v_receiver_wallet
  from public.wallets
  where user_id = p_receiver_auth_id
  for update;

  insert into public.wallets (user_id)
  values (v_platform_wallet_user_id)
  on conflict (user_id) do nothing;
  select * into v_platform_wallet
  from public.wallets
  where user_id = v_platform_wallet_user_id
  for update;

  update public.wallets
  set coin_balance = coin_balance - p_ncx_amount, updated_at = now()
  where id = v_sender_wallet.id
  returning coin_balance into v_sender_new_balance;
  update public.wallets
  set coin_balance = coin_balance + v_receiver_ncx, updated_at = now()
  where id = v_receiver_wallet.id
  returning coin_balance into v_receiver_new_balance;
  if v_platform_fee_ncx > 0 then
    update public.wallets
    set coin_balance = coin_balance + v_platform_fee_ncx, updated_at = now()
    where id = v_platform_wallet.id
    returning coin_balance into v_platform_new_balance;
  else
    v_platform_new_balance := v_platform_wallet.coin_balance;
  end if;

  insert into public.community_gifts (
    post_id, sender_id, receiver_id, gift_type, coin_amount,
    creator_fiat_cut, necxa_fiat_fee, idempotency_key
  )
  values (
    p_post_id, p_sender_auth_id, p_receiver_auth_id,
    v_item.id, p_ncx_amount, v_receiver_ncx, v_platform_fee_ncx,
    v_idempotency_key
  )
  returning id into v_gift_id;

  insert into public.immutable_financial_ledger (
    user_id, entry_type, amount, currency, direction, balance_after,
    reference_id, metadata
  )
  values
    (p_sender_auth_id, 'GIFT_SENT', p_ncx_amount, 'NCX', 'out',
     v_sender_new_balance, v_gift_id,
     jsonb_build_object('receiver_id', p_receiver_auth_id,
       'post_id', p_post_id, 'idempotency_key', v_idempotency_key)),
    (p_receiver_auth_id, 'GIFT_RECEIVED', v_receiver_ncx, 'NCX', 'in',
     v_receiver_new_balance, v_gift_id,
     jsonb_build_object('sender_id', p_sender_auth_id,
       'post_id', p_post_id, 'idempotency_key', v_idempotency_key));

  if v_platform_fee_ncx > 0 then
    insert into public.immutable_financial_ledger (
      user_id, entry_type, amount, currency, direction, balance_after,
      reference_id, metadata
    )
    values (
      v_platform_wallet_user_id, 'PLATFORM_FEE', v_platform_fee_ncx, 'NCX',
      'in', v_platform_new_balance, v_gift_id,
      jsonb_build_object('source', 'gifting', 'sender_id', p_sender_auth_id,
        'receiver_id', p_receiver_auth_id, 'idempotency_key', v_idempotency_key)
    );
  end if;

  return query select true, 'Gift sent successfully.', v_platform_fee_ncx,
    v_receiver_ncx, v_gift_id;
end;
$$;

revoke all on function public.process_gift_ncx(
  uuid, uuid, uuid, bigint, float, jsonb
) from public, anon, authenticated;
grant execute on function public.process_gift_ncx(
  uuid, uuid, uuid, bigint, float, jsonb
) to service_role;

commit;
