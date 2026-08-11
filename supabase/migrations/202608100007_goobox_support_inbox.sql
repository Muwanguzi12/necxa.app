begin;

alter table public.direct_chat_rooms
  add column if not exists metadata jsonb not null default '{}'::jsonb;

drop view if exists public.v_my_chats;

create view public.v_my_chats
with (security_invoker = true)
as
select
  r.id as room_id,
  r.updated_at,
  r.last_message,
  r.last_message_at,
  r.status,
  case
    when r.user_a = (select auth.uid()) then r.user_a_unread
    else r.user_b_unread
  end as my_unread,
  case
    when r.user_a = (select auth.uid()) then r.user_b
    else r.user_a
  end as other_user_id,
  op.full_name as other_name,
  op.avatar_url as other_avatar,
  op.is_agent as other_is_agent,
  op.trust_score as other_trust_score,
  r.metadata
from public.direct_chat_rooms r
join public.profiles op
  on op.id = case
    when r.user_a = (select auth.uid()) then r.user_b
    else r.user_a
  end
where (select auth.uid()) in (r.user_a, r.user_b)
  and r.status = 'active';

create or replace view public.v_my_chats_v2
with (security_invoker = true)
as
select
  r.id as room_id,
  r.updated_at,
  r.last_message,
  r.last_message_at,
  r.status,
  r.is_secure,
  r.security_status,
  case
    when r.user_a = (select auth.uid()) then r.user_a_unread
    else r.user_b_unread
  end as my_unread,
  case
    when r.user_a = (select auth.uid()) then r.user_b
    else r.user_a
  end as other_user_id,
  op.full_name as other_name,
  op.avatar_url as other_avatar,
  op.is_agent as other_is_agent,
  op.trust_score as other_trust_score,
  r.metadata
from public.direct_chat_rooms r
join public.profiles op
  on op.id = case
    when r.user_a = (select auth.uid()) then r.user_b
    else r.user_a
  end
where (select auth.uid()) in (r.user_a, r.user_b)
  and r.status = 'active';

revoke all on public.v_my_chats, public.v_my_chats_v2 from public, anon;
grant select on public.v_my_chats, public.v_my_chats_v2
  to authenticated, service_role;

comment on column public.direct_chat_rooms.metadata is
  'Lightweight conversation routing context such as support, social, or vendor.';

commit;
