-- Supabase 1 is the identity authority; Supabase 2 stores finance projections.
-- Apply only to the isolated NECXA Finance project.

do $$
declare
  constraint_record record;
begin
  for constraint_record in
    select constraint_name.conname
    from pg_constraint constraint_name
    join pg_class source_table on source_table.oid = constraint_name.conrelid
    join pg_namespace source_schema on source_schema.oid = source_table.relnamespace
    join pg_class target_table on target_table.oid = constraint_name.confrelid
    join pg_namespace target_schema on target_schema.oid = target_table.relnamespace
    where constraint_name.contype = 'f'
      and source_schema.nspname = 'public'
      and source_table.relname = 'profiles'
      and target_schema.nspname = 'auth'
      and target_table.relname = 'users'
  loop
    execute format(
      'alter table public.profiles drop constraint %I',
      constraint_record.conname
    );
  end loop;
end;
$$;

alter table public.profiles
  add column if not exists email text,
  add column if not exists phone text,
  add column if not exists full_name text,
  add column if not exists avatar_url text,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;

comment on table public.profiles is
  'Finance identity projection. IDs and permitted profile fields originate in NECXA Supabase 1.';
