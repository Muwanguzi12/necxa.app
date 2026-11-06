begin;

alter table public.support_tickets
  add column if not exists necxa_user_id uuid,
  add column if not exists verified boolean not null default false;

create index if not exists support_tickets_necxa_user_idx
  on public.support_tickets (necxa_user_id)
  where necxa_user_id is not null;

-- The browser dashboard may continue editing normal ticket fields, but only a
-- service-role Edge Function can assign or change a trusted Necxa identity.
create or replace function public.protect_support_ticket_necxa_identity()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  request_role text := coalesce(current_setting('request.jwt.claim.role', true), '');
begin
  if request_role = 'service_role' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.verified or new.necxa_user_id is not null then
      raise exception 'Necxa support identity must be assigned by the verification service';
    end if;
  elsif new.verified is distinct from old.verified
     or new.necxa_user_id is distinct from old.necxa_user_id then
    raise exception 'Necxa support identity cannot be changed from the browser';
  end if;

  return new;
end;
$$;

drop trigger if exists protect_support_ticket_necxa_identity
  on public.support_tickets;
create trigger protect_support_ticket_necxa_identity
before insert or update on public.support_tickets
for each row execute function public.protect_support_ticket_necxa_identity();

commit;
