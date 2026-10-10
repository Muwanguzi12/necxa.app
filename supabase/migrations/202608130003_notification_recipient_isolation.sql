begin;

-- Notifications are private recipient records. Remove every legacy policy so
-- an older permissive policy cannot combine with the recipient-only policies
-- below (Postgres policies are ORed together).
alter table public.notifications enable row level security;

delete from public.notifications
where user_id is null;

alter table public.notifications
  alter column user_id set not null;

do $$
declare
  policy_record record;
begin
  for policy_record in
    select policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = 'notifications'
  loop
    execute format(
      'drop policy if exists %I on public.notifications',
      policy_record.policyname
    );
  end loop;
end;
$$;

create policy notifications_recipient_select
  on public.notifications
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy notifications_recipient_update
  on public.notifications
  for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

revoke insert, delete on table public.notifications from anon, authenticated;
grant select, update on table public.notifications to authenticated;

create index if not exists notifications_recipient_created_idx
  on public.notifications (user_id, created_at desc);

commit;
