-- Complete the seller action that originally failed because the lifecycle RPC
-- was absent. Refuse to mutate an order that has moved to any other state.
do $$
declare
  v_order_id constant uuid := '2b6dc0ff-5695-4000-9cb5-7a4262e3951d'::uuid;
  v_seller_id constant uuid := '794b17b3-ca7e-4d63-8b57-23d2d64f6cda'::uuid;
  v_delivery_status text;
begin
  if to_regprocedure(
    'public.transition_commerce_order(uuid,uuid,text,text,uuid,jsonb)'
  ) is null then
    raise exception 'Canonical commerce transition RPC is unavailable.';
  end if;

  if not exists (
    select 1 from public.commerce_escrows
    where order_id = v_order_id and status in ('funded', 'held')
  ) then
    raise exception 'Verified order escrow was not funded.';
  end if;

  select status into v_delivery_status
  from public.commerce_delivery_jobs
  where order_id = v_order_id
  for update;

  if v_delivery_status is null then
    raise exception 'Verified order delivery job was not created.';
  elsif v_delivery_status = 'awaiting_seller' then
    perform public.transition_commerce_order(
      v_order_id,
      v_seller_id,
      'seller',
      'seller_ready',
      null,
      jsonb_build_object('source', 'recovered_vendor_request')
    );
  elsif v_delivery_status <> 'ready_for_pickup' then
    raise exception 'Order is already in unexpected delivery state: %', v_delivery_status;
  end if;
end;
$$;
