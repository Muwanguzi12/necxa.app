-- Supabase 1: guarantee one mirrored deposit ledger entry per Finance 2 payment.
create unique index if not exists immutable_ledger_reference_type_unique
  on public.immutable_financial_ledger(reference_id, entry_type)
  where reference_id is not null;
