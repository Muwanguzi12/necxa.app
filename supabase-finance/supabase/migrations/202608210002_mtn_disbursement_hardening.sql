-- Server-side rate limits and an atomic claim prevent duplicate MTN payouts.
-- Client risk scores are deliberately not used as an allow-list: a client can
-- forge them. They may still be retained in withdrawal metadata for review.
create or replace function public.reserve_mtn_withdrawal(
  p_user_id uuid,
  p_amount bigint,
  p_device_fingerprint text,
  p_risk_score numeric default null,
  p_is_device_trusted boolean default null,
  p_idempotency_key text default null
) returns void
language plpgsql
security definer
set search_path = public as $$
declare
  v_recent_count integer;
  v_recent_total bigint;
  v_shared_device_users integer;
begin
  if p_amount < 500 or p_amount > 5000000 then
    raise exception 'Withdrawal amount is outside the permitted range';
  end if;
  if p_device_fingerprint is null or length(btrim(p_device_fingerprint)) < 16 then
    raise exception 'A valid device identifier is required for MTN withdrawals';
  end if;

  -- An HTTP retry of the same request must not count as another withdrawal.
  if p_idempotency_key is not null and exists (
    select 1 from public.withdrawals
     where user_id = p_user_id and idempotency_key = p_idempotency_key
  ) then
    return;
  end if;

  select count(*), coalesce(sum(amount), 0)
    into v_recent_count, v_recent_total
    from public.withdrawals
   where user_id = p_user_id
     and method = 'mtn'
     and created_at >= now() - interval '24 hours'
     and workflow_status <> 'refunded';
  if v_recent_count >= 3 or v_recent_total + p_amount > 5000000 then
    raise exception 'MTN withdrawal limit reached; try again after 24 hours';
  end if;

  select count(distinct user_id)
    into v_shared_device_users
    from public.withdrawals
   where method = 'mtn'
     and created_at >= now() - interval '24 hours'
     and metadata ->> 'device_fingerprint' = p_device_fingerprint;
  if v_shared_device_users >= 3 then
    raise exception 'This device requires manual review before another withdrawal';
  end if;
end;
$$;

revoke all on function public.reserve_mtn_withdrawal(uuid, bigint, text, numeric, boolean, text)
  from public, anon, authenticated;
grant execute on function public.reserve_mtn_withdrawal(uuid, bigint, text, numeric, boolean, text)
  to service_role;

create or replace function public.claim_mtn_disbursement(p_withdrawal_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public as $$
declare
  v_withdrawal public.withdrawals;
begin
  select * into v_withdrawal from public.withdrawals where id = p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal not found'; end if;
  if v_withdrawal.method <> 'mtn' then raise exception 'Withdrawal is not an MTN withdrawal'; end if;
  if v_withdrawal.workflow_status <> 'initiated' then return false; end if;

  update public.withdrawals
     set status = 'pending', workflow_status = 'pending', updated_at = now()
   where id = p_withdrawal_id;
  insert into public.withdrawal_status_events(
    withdrawal_id, previous_status, new_status, operator_id, note
  ) values (
    p_withdrawal_id, 'initiated', 'pending', 'mtn-disbursement', 'Claimed for MTN submission'
  );
  return true;
end;
$$;

revoke all on function public.claim_mtn_disbursement(uuid) from public, anon, authenticated;
grant execute on function public.claim_mtn_disbursement(uuid) to service_role;
