-- Run clever-processor's migrate-legacy-engagement action successfully before
-- applying this migration. MongoDB is authoritative after this cutover.

alter table public.community_posts
  add column if not exists listing_id uuid
  references public.listings(id) on delete cascade;

create index if not exists idx_community_posts_listing_id
  on public.community_posts(listing_id)
  where listing_id is not null;

do $$
begin
  if to_regclass('public.community_likes') is not null then
    execute 'drop trigger if exists on_community_like on public.community_likes';
    execute 'drop trigger if exists tr_sync_likes on public.community_likes';
    execute 'drop trigger if exists community_like_count_trigger on public.community_likes';
  end if;

  if to_regclass('public.community_comments') is not null then
    execute 'drop trigger if exists on_community_comment on public.community_comments';
    execute 'drop trigger if exists tr_sync_comments on public.community_comments';
    execute 'drop trigger if exists community_comment_count_trigger on public.community_comments';
  end if;
end
$$;

drop function if exists public.handle_community_like() cascade;
drop function if exists public.handle_community_comment() cascade;
drop function if exists public.fn_sync_post_likes() cascade;
drop function if exists public.fn_sync_post_comments() cascade;
drop function if exists public.sync_community_like_count() cascade;
drop function if exists public.sync_community_comment_count() cascade;
drop function if exists public.fn_notify_post_like() cascade;
drop function if exists public.get_social_feed(uuid, integer, integer) cascade;

drop table if exists public.community_likes cascade;
drop table if exists public.community_comments cascade;

-- These columns remain only as response-shape compatibility fields for older
-- clients and SQL views. Clever Processor overwrites them with MongoDB totals.
update public.community_posts
set likes_count = 0,
    comments_count = 0
where coalesce(likes_count, 0) <> 0
   or coalesce(comments_count, 0) <> 0;

comment on column public.community_posts.likes_count is
  'Deprecated compatibility field. Authoritative value is in MongoDB engagement_totals.';
comment on column public.community_posts.comments_count is
  'Deprecated compatibility field. Authoritative value is in MongoDB engagement_totals.';

notify pgrst, 'reload schema';
