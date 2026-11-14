-- Aggregator RPC to produce a withdrawal-proof JSON payload
-- Returns a JSON object containing the withdrawal record, ledger entries
-- specifically tied to the withdrawal, recent incoming ledger entries
-- (source-of-funds candidates), payments, and commerce orders for audit.

create or replace function public.withdrawal_proof(
  p_user_id uuid,
  p_withdrawal_id uuid
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_withdrawal public.withdrawals%rowtype;
  v_withdrawal_json jsonb;
  v_withdrawal_ledger jsonb;
  v_recent_incoming jsonb;
  v_payments jsonb;
  v_orders jsonb;
begin
  select * into v_withdrawal from public.withdrawals where id = p_withdrawal_id and user_id = p_user_id;
  if not found then
    raise exception 'Withdrawal not found or access denied';
  end if;

  v_withdrawal_json := to_jsonb(v_withdrawal);

  -- Ledger entries that reference this withdrawal explicitly
  select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at), '[]'::jsonb)
    into v_withdrawal_ledger
    from public.ledger_entries l
    where l.reference_id = ('withdrawal:' || p_withdrawal_id::text);

  -- Recent incoming ledger entries for the user up to the withdrawal time
  select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at desc), '[]'::jsonb)
    into v_recent_incoming
    from (
      select * from public.ledger_entries
      where user_id = p_user_id and direction = 'in' and created_at <= v_withdrawal.created_at
      order by created_at desc
      limit 50
    ) l;

  -- Relevant completed payments for the user up to the withdrawal time
  select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at desc), '[]'::jsonb)
    into v_payments
    from (
      select * from public.payments
      where user_id = p_user_id and created_at <= v_withdrawal.created_at
      and status = 'completed'
      order by created_at desc
      limit 50
    ) p;

  -- Commerce orders involving the user near the withdrawal time (seller or buyer)
  select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc), '[]'::jsonb)
    into v_orders
    from (
      select * from public.commerce_orders
      where (seller_id = p_user_id or buyer_id = p_user_id) and created_at <= v_withdrawal.created_at
      order by created_at desc
      limit 50
    ) o;

  return jsonb_build_object(
    'withdrawal', v_withdrawal_json,
    'withdrawal_ledger_entries', v_withdrawal_ledger,
    'recent_incoming_ledger_entries', v_recent_incoming,
    'payments', v_payments,
    'commerce_orders', v_orders
  );
end;
$$;

-- Restrict direct public/anon access; only service_role may execute.
revoke all on function public.withdrawal_proof(uuid,uuid) from public, anon, authenticated;
grant execute on function public.withdrawal_proof(uuid,uuid) to service_role;
