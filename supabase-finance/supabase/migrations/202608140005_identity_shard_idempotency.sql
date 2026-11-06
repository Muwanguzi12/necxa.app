-- SP2 identity submissions are retried by mobile clients. Keep one shard per
-- user/request so a timeout cannot create duplicate PII records or uploads.

alter table public.identity_shards
  add column if not exists idempotency_key text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'identity_shards_user_idempotency_key'
      and conrelid = 'public.identity_shards'::regclass
  ) then
    alter table public.identity_shards
      add constraint identity_shards_user_idempotency_key
      unique (user_id, idempotency_key);
  end if;
end;
$$;

create index if not exists identity_shards_verified_user_idx
  on public.identity_shards (user_id, created_at desc)
  where verified = true;

alter table public.identity_shards enable row level security;
revoke all on table public.identity_shards from anon, authenticated;
grant all on table public.identity_shards to service_role;
