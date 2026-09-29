do $$
declare
  v_updated integer;
begin
  update public.share_offers
  set offered_shares = 200,
      external_ownership_bps = 2000,
      price_per_share_ugx = 3000000,
      updated_at = now()
  where id = 'necxa-technology-2026'
    and status = 'draft'
    and reserved_shares = 0
    and paid_shares = 0
    and allotted_shares = 0;

  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    raise exception 'Share offer repricing requires one untouched draft offer';
  end if;
end;
$$;

select pg_notify('pgrst', 'reload schema');
