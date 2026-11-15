begin;

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  notification_type text,
  type text not null check (
    type in (
      'like',
      'comment',
      'follow',
      'share',
      'save',
      'mention',
      'listing',
      'content',
      'financial',
      'social',
      'system',
      'listing_viewed'
    )
  ),
  title text not null,
  body text not null,
  target_id text,
  target_type text not null default 'post' check (
    target_type in ('post', 'listing', 'profile', 'comment', 'system')
  ),
  metadata jsonb not null default '{}'::jsonb,
  dedupe_key text,
  is_read boolean not null default false,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.notifications
  add column if not exists actor_id uuid,
  add column if not exists notification_type text,
  add column if not exists type text,
  add column if not exists title text,
  add column if not exists body text,
  add column if not exists target_id text,
  add column if not exists target_type text default 'system',
  add column if not exists metadata jsonb default '{}'::jsonb,
  add column if not exists dedupe_key text,
  add column if not exists is_read boolean default false,
  add column if not exists read_at timestamptz,
  add column if not exists created_at timestamptz default now();

update public.notifications
set type = coalesce(type, notification_type, 'system'),
    metadata = coalesce(metadata, '{}'::jsonb),
    is_read = coalesce(is_read, false),
    created_at = coalesce(created_at, now()),
    target_type = coalesce(target_type, 'system');

alter table public.notifications
  alter column notification_type drop not null,
  alter column type set not null,
  alter column metadata set default '{}'::jsonb,
  alter column metadata set not null,
  alter column is_read set default false,
  alter column is_read set not null,
  alter column created_at set default now(),
  alter column created_at set not null,
  alter column target_type set default 'post',
  alter column target_type set not null,
  alter column user_id set not null;

create unique index if not exists notifications_user_dedupe_idx
  on public.notifications (user_id, dedupe_key);

create index if not exists notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

create index if not exists notifications_user_unread_idx
  on public.notifications (user_id, created_at desc)
  where is_read = false;

alter table public.notifications enable row level security;

drop policy if exists "Users read their notifications" on public.notifications;
create policy "Users read their notifications"
  on public.notifications
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Users update their notifications" on public.notifications;
create policy "Users update their notifications"
  on public.notifications
  for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

alter table public.notifications replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.notifications;
exception
  when duplicate_object then null;
end
$$;

commit;
