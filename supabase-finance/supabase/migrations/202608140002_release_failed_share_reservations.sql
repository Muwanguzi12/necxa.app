create or replace function public.close_share_subscription(
  p_subscription_id uuid,
  p_status text,
  p_payment_verification jsonb
) returns public.share_subscriptions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subscription public.share_subscriptions;
  v_offer public.share_offers;
begin
  if p_status not in ('failed', 'cancelled') then
    raise exception 'Unsupported share subscription closure status';
  end if;

  select * into v_subscription from public.share_subscriptions
    where id = p_subscription_id for update;
  if not found then raise exception 'Share subscription not found'; end if;
  if v_subscription.status in ('paid_pending_allotment', 'allotted', 'manual_review', 'refunded') then
    return v_subscription;
  end if;
  if v_subscription.status in ('failed', 'cancelled', 'expired') then
    return v_subscription;
  end if;

  select * into v_offer from public.share_offers
    where id = v_subscription.offer_id for update;

  update public.share_offers set
    reserved_shares = greatest(0, reserved_shares - v_subscription.share_count),
    updated_at = now()
  where id = v_offer.id;

  update public.share_subscriptions set
    status = p_status,
    payment_verification = coalesce(p_payment_verification, '{}'::jsonb),
    updated_at = now()
  where id = p_subscription_id
  returning * into v_subscription;
  return v_subscription;
end;
$$;

revoke all on function public.close_share_subscription(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.close_share_subscription(uuid,text,jsonb) to service_role;

select pg_notify('pgrst', 'reload schema');
