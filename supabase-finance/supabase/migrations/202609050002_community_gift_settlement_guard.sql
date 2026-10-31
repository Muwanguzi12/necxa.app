begin;

create or replace function public.process_gift_ncx(
  p_sender_auth_id uuid,
  p_receiver_auth_id uuid,
  p_post_id text,
  p_ncx_amount bigint,
  p_gift_platform_fee_rate numeric,
  p_gift_details jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.gifts;
  v_item public.gift_items;
  v_gift public.gifts;
begin
  select * into v_existing
  from public.gifts
  where sender_id = p_sender_auth_id
    and idempotency_key = p_gift_details->>'idempotency_key';

  if found then
    return jsonb_build_object(
      'success', true,
      'gift_id', v_existing.id,
      'platform_fee_paid', v_existing.platform_fee_ncx,
      'receiver_amount_credited', v_existing.receiver_ncx
    );
  end if;

  select * into v_item
  from public.gift_items
  where id = p_gift_details->>'gift_item_id'
    and is_active
  for share;

  if not found then
    raise exception 'Gift item is unavailable';
  end if;

  if p_ncx_amount <> v_item.ncx_value then
    raise exception 'Gift price does not match the catalogue';
  end if;

  v_gift := public.process_gift(
    p_sender_auth_id,
    p_receiver_auth_id,
    v_item.id,
    p_gift_details->>'context_type',
    p_post_id,
    v_item.ncx_value,
    round(p_gift_platform_fee_rate * 10000)::integer,
    coalesce((p_gift_details->>'is_anonymous')::boolean, false),
    p_gift_details->>'idempotency_key',
    p_gift_details
  );

  return jsonb_build_object(
    'success', true,
    'gift_id', v_gift.id,
    'platform_fee_paid', v_gift.platform_fee_ncx,
    'receiver_amount_credited', v_gift.receiver_ncx
  );
end;
$$;

revoke all on function public.process_gift_ncx(uuid, uuid, text, bigint, numeric, jsonb)
  from public, anon, authenticated;
grant execute on function public.process_gift_ncx(uuid, uuid, text, bigint, numeric, jsonb)
  to service_role;

commit;
