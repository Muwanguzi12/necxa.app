begin;

alter table public.community_gifts
  add column if not exists receiver_ncx bigint,
  add column if not exists platform_fee_ncx bigint,
  add column if not exists creator_ncx_cut bigint,
  add column if not exists necxa_ncx_fee bigint;

update public.community_gifts
set creator_ncx_cut = coalesce(creator_ncx_cut, receiver_ncx, 0),
    necxa_ncx_fee = coalesce(necxa_ncx_fee, platform_fee_ncx, 0);

alter table public.community_gifts
  alter column creator_ncx_cut set default 0,
  alter column creator_ncx_cut set not null,
  alter column necxa_ncx_fee set default 0,
  alter column necxa_ncx_fee set not null;

create index if not exists idx_community_gifts_post_recent
  on public.community_gifts(post_id, created_at desc);

create index if not exists idx_community_gifts_sender
  on public.community_gifts(sender_id, created_at desc);

create index if not exists idx_community_gifts_receiver
  on public.community_gifts(receiver_id, created_at desc);

create or replace function public.sync_community_gift_coin_split()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.creator_ncx_cut := coalesce(new.receiver_ncx, new.creator_ncx_cut, 0);
  new.necxa_ncx_fee := coalesce(new.platform_fee_ncx, new.necxa_ncx_fee, 0);
  return new;
end;
$$;

drop trigger if exists community_gifts_coin_split_sync
  on public.community_gifts;

create trigger community_gifts_coin_split_sync
before insert or update of receiver_ncx, platform_fee_ncx,
  creator_ncx_cut, necxa_ncx_fee
on public.community_gifts
for each row
execute function public.sync_community_gift_coin_split();

update public.community_gifts
set creator_ncx_cut = coalesce(receiver_ncx, creator_ncx_cut, 0),
    necxa_ncx_fee = coalesce(platform_fee_ncx, necxa_ncx_fee, 0)
where creator_ncx_cut is distinct from coalesce(receiver_ncx, creator_ncx_cut, 0)
   or necxa_ncx_fee is distinct from coalesce(platform_fee_ncx, necxa_ncx_fee, 0);

commit;
