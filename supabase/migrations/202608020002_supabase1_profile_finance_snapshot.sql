-- Private Supabase 1 projection of the authoritative Supabase 2 wallet.
-- Apply only to the primary NECXA Supabase project.

create table if not exists public.profile_finance_snapshots (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  finance_wallet_id uuid not null,
  fiat_balance bigint not null default 0 check (fiat_balance >= 0),
  coin_balance bigint not null default 0 check (coin_balance >= 0),
  escrow_balance bigint not null default 0 check (escrow_balance >= 0),
  total_earned bigint not null default 0 check (total_earned >= 0),
  total_spent bigint not null default 0 check (total_spent >= 0),
  finance_updated_at timestamptz,
  synced_at timestamptz not null default now(),
  source_project text not null default 'supabase2'
    check (source_project = 'supabase2')
);

alter table public.profile_finance_snapshots enable row level security;

drop policy if exists "Users can view own finance snapshot"
  on public.profile_finance_snapshots;
create policy "Users can view own finance snapshot"
  on public.profile_finance_snapshots
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

revoke all on public.profile_finance_snapshots from anon;
revoke insert, update, delete, truncate, references, trigger
  on public.profile_finance_snapshots from authenticated;
grant select on public.profile_finance_snapshots to authenticated;
grant all on public.profile_finance_snapshots to service_role;

comment on table public.profile_finance_snapshots is
  'Private read-only profile balance snapshot mirrored from the Supabase 2 finance ledger.';
