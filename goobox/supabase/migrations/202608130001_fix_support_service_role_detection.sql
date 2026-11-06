begin;

-- PostgREST now exposes verified JWT claims through request.jwt.claims. The
-- legacy request.jwt.claim.role setting can be empty even for a service-role
-- request, which caused the trusted create-support-ticket Edge Function to be
-- rejected by this trigger. auth.role() reads the authenticated request role;
-- the explicit claim lookups keep this compatible with older PostgREST builds.
create or replace function public.protect_support_ticket_necxa_identity()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  request_role text := coalesce(
    auth.role(),
    nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    ''
  );
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

commit;
