-- Cursor-backed Vendor Dashboard refreshes. Safe on either NECXA Supabase
-- project: each index is created only when its owning table is present.

do $$
begin
  if to_regclass('public.commerce_orders') is not null then
    execute 'create index if not exists commerce_orders_seller_updated_idx
      on public.commerce_orders (seller_id, updated_at desc, id)';
  end if;

  if to_regclass('public.commerce_reviews') is not null then
    if exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'commerce_reviews'
        and column_name = 'updated_at'
    ) and exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'commerce_reviews'
        and column_name = 'seller_id'
    ) and exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'commerce_reviews'
        and column_name = 'status'
    ) then
      execute 'create index if not exists commerce_reviews_seller_updated_idx
        on public.commerce_reviews (seller_id, updated_at desc, id)
        where status = ''published''';
    elsif exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'commerce_reviews'
        and column_name = 'vendor_id'
    ) then
      execute 'create index if not exists commerce_reviews_vendor_created_idx
        on public.commerce_reviews (vendor_id, created_at desc, id)';
    end if;
  end if;

  if to_regclass('public.listings') is not null then
    execute 'create index if not exists listings_user_updated_idx
      on public.listings (user_id, updated_at desc, id)';
    execute 'create index if not exists listings_lister_updated_idx
      on public.listings (lister_id, updated_at desc, id)';
  end if;
end
$$;
