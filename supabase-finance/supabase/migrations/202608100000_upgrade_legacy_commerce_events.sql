-- Upgrade the original commerce event stream without removing the columns
-- still read by older application builds.
alter table public.commerce_order_events
  add column if not exists actor_role text,
  add column if not exists event_type text,
  add column if not exists order_status text;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'commerce_order_events'
      and column_name = 'to_status'
  ) then
    execute 'update public.commerce_order_events
      set order_status = to_status::text
      where order_status is null';
  end if;
end;
$$;

update public.commerce_order_events
set actor_role = coalesce(actor_role, 'system'),
    event_type = coalesce(event_type, 'legacy_transition')
where actor_role is null or event_type is null;

alter table public.commerce_order_events
  alter column actor_role set not null,
  alter column event_type set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'commerce_order_events_actor_role_check'
      and conrelid = 'public.commerce_order_events'::regclass
  ) then
    alter table public.commerce_order_events
      add constraint commerce_order_events_actor_role_check
      check (actor_role in ('system', 'buyer', 'seller', 'driver', 'support')) not valid;
  end if;
end;
$$;

alter table public.commerce_order_events
  validate constraint commerce_order_events_actor_role_check;
