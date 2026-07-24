-- Complete the production contract used by clever-processor/create-post.
-- Existing environments created community_posts before the metadata column
-- was introduced inside a CREATE TABLE IF NOT EXISTS migration, so the column
-- was never added to those already-existing tables.

begin;

alter table public.community_posts
  add column if not exists metadata jsonb;

update public.community_posts
set metadata = '{}'::jsonb
where metadata is null;

alter table public.community_posts
  alter column metadata set default '{}'::jsonb,
  alter column metadata set not null;

-- PostgreSQL does not automatically index foreign-key columns. This is used
-- by post hydration and reusable-media joins.
create index if not exists idx_community_posts_media_asset_id
  on public.community_posts (media_asset_id)
  where media_asset_id is not null;

comment on column public.community_posts.metadata is
  'Publishing, editor, gallery, artist, and AI-verification metadata.';

notify pgrst, 'reload schema';

commit;
