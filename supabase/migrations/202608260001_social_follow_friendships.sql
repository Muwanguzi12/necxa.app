-- Persistent social graph: a follow is directional; reciprocal follows form a friendship.

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  user_one_id uuid not null references public.profiles(id) on delete cascade,
  user_two_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint friendships_distinct_users check (user_one_id <> user_two_id),
  constraint friendships_canonical_pair check (user_one_id < user_two_id),
  constraint friendships_unique_pair unique (user_one_id, user_two_id)
);

create index if not exists friendships_user_one_idx on public.friendships(user_one_id);
create index if not exists friendships_user_two_idx on public.friendships(user_two_id);

alter table public.friendships enable row level security;

drop policy if exists "Friends can view their friendships" on public.friendships;
create policy "Friends can view their friendships"
  on public.friendships for select
  using (auth.uid() in (user_one_id, user_two_id));

-- Existing reciprocal follows are friends too; do not wait for either person
-- to tap the button again after this migration ships.
insert into public.friendships (user_one_id, user_two_id)
select
  least(a.follower_id, a.creator_id),
  greatest(a.follower_id, a.creator_id)
from public.creator_followers a
join public.creator_followers b
  on b.follower_id = a.creator_id
 and b.creator_id = a.follower_id
where a.follower_id < a.creator_id
on conflict (user_one_id, user_two_id) do nothing;

-- Older migrations registered two creator-count trigger pairs. Keep the
-- current sync trigger and remove only the legacy duplicate pair.
drop trigger if exists on_new_follower on public.creator_followers;
drop trigger if exists on_unfollow on public.creator_followers;

create or replace function public.toggle_follow_relationship(p_target_user_id uuid)
returns table (following boolean, is_friend boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  if p_target_user_id is null or p_target_user_id = v_user_id then
    raise exception 'You cannot follow yourself';
  end if;
  if not exists (select 1 from public.profiles where id = p_target_user_id) then
    raise exception 'Profile not found';
  end if;

  -- creator_followers predates universal profiles. Ensure either participant
  -- can be followed without requiring a separate creator-onboarding flow.
  insert into public.creators (id, display_name)
  select p.id, coalesce(p.full_name, p.username)
  from public.profiles p
  where p.id in (v_user_id, p_target_user_id)
  on conflict (id) do nothing;

  perform pg_advisory_xact_lock(hashtext(least(v_user_id::text, p_target_user_id::text)));
  perform pg_advisory_xact_lock(hashtext(greatest(v_user_id::text, p_target_user_id::text)));

  if exists (
    select 1 from public.creator_followers
    where follower_id = v_user_id and creator_id = p_target_user_id
  ) then
    delete from public.creator_followers
    where follower_id = v_user_id and creator_id = p_target_user_id;

    delete from public.friendships
    where user_one_id = least(v_user_id, p_target_user_id)
      and user_two_id = greatest(v_user_id, p_target_user_id);

    following := false;
    is_friend := false;
  else
    insert into public.creator_followers (creator_id, follower_id)
    values (p_target_user_id, v_user_id)
    on conflict (creator_id, follower_id) do nothing;

    following := true;
    if exists (
      select 1 from public.creator_followers
      where follower_id = p_target_user_id and creator_id = v_user_id
    ) then
      insert into public.friendships (user_one_id, user_two_id)
      values (
        least(v_user_id, p_target_user_id),
        greatest(v_user_id, p_target_user_id)
      )
      on conflict (user_one_id, user_two_id) do nothing;
      is_friend := true;
    else
      is_friend := false;
    end if;
  end if;

  return next;
end;
$$;

revoke all on function public.toggle_follow_relationship(uuid) from public, anon;
grant execute on function public.toggle_follow_relationship(uuid) to authenticated;

create or replace function public.my_follow_relationships()
returns table (user_id uuid, is_friend boolean)
language sql
security definer
set search_path = public
stable
as $$
  select
    cf.creator_id as user_id,
    exists (
      select 1 from public.friendships f
      where (f.user_one_id = auth.uid() and f.user_two_id = cf.creator_id)
         or (f.user_two_id = auth.uid() and f.user_one_id = cf.creator_id)
    ) as is_friend
  from public.creator_followers cf
  where cf.follower_id = auth.uid();
$$;

revoke all on function public.my_follow_relationships() from public, anon;
grant execute on function public.my_follow_relationships() to authenticated;
