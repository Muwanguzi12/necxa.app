-- Repair the April community engagement schema without dropping user data.

create table if not exists public.community_likes (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  parent_id uuid references public.community_comments(id) on delete cascade,
  content text not null,
  likes_count integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.community_comments
  add column if not exists user_id uuid,
  add column if not exists parent_id uuid,
  add column if not exists likes_count integer not null default 0,
  add column if not exists metadata jsonb not null default '{}'::jsonb,
  add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'community_comments'
      and column_name = 'author_id'
  ) then
    execute '
      update public.community_comments
      set user_id = author_id
      where user_id is null
    ';
    execute '
      alter table public.community_comments
      alter column author_id drop not null
    ';
  end if;

  if not exists (
    select 1
    from public.community_comments
    where user_id is null
  ) then
    alter table public.community_comments
      alter column user_id set not null;
  end if;
end
$$;

-- Keep one reaction per user/post before enforcing the unique index.
delete from public.community_likes older
using public.community_likes newer
where older.post_id = newer.post_id
  and older.user_id = newer.user_id
  and older.id > newer.id;

create unique index if not exists community_likes_post_user_uidx
  on public.community_likes (post_id, user_id);
create index if not exists community_likes_post_idx
  on public.community_likes (post_id);
create index if not exists community_likes_user_idx
  on public.community_likes (user_id);
create index if not exists community_comments_post_created_idx
  on public.community_comments (post_id, created_at desc);
create index if not exists community_comments_user_idx
  on public.community_comments (user_id);

create or replace function public.sync_community_like_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update public.community_posts
    set likes_count = coalesce(likes_count, 0) + 1
    where id = new.post_id;
  elsif tg_op = 'DELETE' then
    update public.community_posts
    set likes_count = greatest(coalesce(likes_count, 0) - 1, 0)
    where id = old.post_id;
  end if;
  return null;
end
$$;

create or replace function public.sync_community_comment_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update public.community_posts
    set comments_count = coalesce(comments_count, 0) + 1
    where id = new.post_id;
  elsif tg_op = 'DELETE' then
    update public.community_posts
    set comments_count = greatest(coalesce(comments_count, 0) - 1, 0)
    where id = old.post_id;
  end if;
  return null;
end
$$;

drop trigger if exists on_community_like on public.community_likes;
drop trigger if exists tr_sync_likes on public.community_likes;
drop trigger if exists community_like_count_trigger on public.community_likes;
create trigger community_like_count_trigger
after insert or delete on public.community_likes
for each row execute function public.sync_community_like_count();

drop trigger if exists on_community_comment on public.community_comments;
drop trigger if exists tr_sync_comments on public.community_comments;
drop trigger if exists community_comment_count_trigger on public.community_comments;
create trigger community_comment_count_trigger
after insert or delete on public.community_comments
for each row execute function public.sync_community_comment_count();

-- Reconcile counters after removing duplicates and replacing triggers.
update public.community_posts post
set likes_count = (
      select count(*)::integer
      from public.community_likes likes
      where likes.post_id = post.id
    ),
    comments_count = (
      select count(*)::integer
      from public.community_comments comments
      where comments.post_id = post.id
    );

alter table public.community_likes enable row level security;
alter table public.community_comments enable row level security;

drop policy if exists "Anyone can view likes" on public.community_likes;
drop policy if exists "Anyone can see likes" on public.community_likes;
drop policy if exists "Users can like" on public.community_likes;
drop policy if exists "Users can like posts" on public.community_likes;
drop policy if exists "Users can unlike" on public.community_likes;
drop policy if exists "Users can unlike posts" on public.community_likes;

create policy "Anyone can view likes"
on public.community_likes for select
using (true);
create policy "Users can like"
on public.community_likes for insert to authenticated
with check (auth.uid() = user_id);
create policy "Users can unlike"
on public.community_likes for delete to authenticated
using (auth.uid() = user_id);

drop policy if exists "Anyone can view comments" on public.community_comments;
drop policy if exists "Anyone can see comments" on public.community_comments;
drop policy if exists "Users can comment" on public.community_comments;
drop policy if exists "Users can delete own comments" on public.community_comments;

create policy "Anyone can view comments"
on public.community_comments for select
using (true);
create policy "Users can comment"
on public.community_comments for insert to authenticated
with check (auth.uid() = user_id);
create policy "Users can delete own comments"
on public.community_comments for delete to authenticated
using (auth.uid() = user_id);

grant select on public.community_likes, public.community_comments
  to anon, authenticated;
grant insert, delete on public.community_likes, public.community_comments
  to authenticated;

notify pgrst, 'reload schema';
