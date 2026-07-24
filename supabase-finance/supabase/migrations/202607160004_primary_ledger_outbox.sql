create table public.primary_ledger_outbox (
  payment_id uuid primary key references public.payments(id) on delete restrict,
  ledger_entry_id uuid not null references public.ledger_entries(id) on delete restrict,
  user_id uuid not null references public.finance_users(user_id) on delete restrict,
  amount bigint not null check (amount > 0),
  currency public.finance_currency not null,
  balance_after bigint not null check (balance_after >= 0),
  status text not null default 'pending' check (status in ('pending', 'syncing', 'synced', 'failed')),
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  synced_at timestamptz
);

create index primary_ledger_outbox_retry_idx
  on public.primary_ledger_outbox(status, updated_at)
  where status in ('pending', 'failed');

alter table public.primary_ledger_outbox enable row level security;
revoke all on public.primary_ledger_outbox from anon, authenticated;

create or replace function public.queue_primary_deposit_ledger(p_payment_id uuid)
returns public.primary_ledger_outbox
language plpgsql security definer set search_path = public as $$
declare v_payment public.payments; v_ledger public.ledger_entries; v_outbox public.primary_ledger_outbox;
begin
  select * into v_payment from public.payments where id = p_payment_id and status = 'completed';
  if not found then raise exception 'Completed deposit payment not found'; end if;
  select * into v_ledger from public.ledger_entries
    where user_id = v_payment.user_id and idempotency_key = 'deposit:' || v_payment.id::text;
  if not found then raise exception 'Deposit ledger entry not found'; end if;
  insert into public.primary_ledger_outbox(payment_id, ledger_entry_id, user_id, amount, currency, balance_after)
  values(v_payment.id, v_ledger.id, v_payment.user_id, v_payment.amount, v_payment.currency, v_ledger.balance_after)
  on conflict (payment_id) do nothing;
  select * into v_outbox from public.primary_ledger_outbox where payment_id = p_payment_id;
  return v_outbox;
end;
$$;

revoke all on function public.queue_primary_deposit_ledger(uuid) from public, anon, authenticated;
grant execute on function public.queue_primary_deposit_ledger(uuid) to service_role;
