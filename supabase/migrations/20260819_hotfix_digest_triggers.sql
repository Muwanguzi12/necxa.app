-- ════════════════════════════════════════════════════════════════════════════
-- HOTFIX: Schema-qualify digest() calls in ledger triggers & fix function overlap
--
-- Problem 1: `pgcrypto` is installed in the `extensions` schema, so `digest()`
-- fails inside `process_gift` because it uses `search_path = public`.
-- Problem 2: The `chain_ledger_entry()` function was accidentally redefined across
-- two different migrations (20260612 and 20260716) for two different ledger tables.
--
-- Solution: Create uniquely named trigger functions for each table and explicitly
-- use `extensions.digest()`.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Fix trigger for immutable_financial_ledger (The active ledger) ──
create or replace function public.chain_immutable_ledger_entry()
returns trigger as $$
declare
  prev_record record;
  prev_hash text;
  raw_payload text;
begin
  -- Fetch the previous ledger entry from immutable_financial_ledger
  select id, hash into prev_record 
  from public.immutable_financial_ledger 
  where user_id = new.user_id
  order by created_at desc, id desc 
  limit 1;

  if found then
    new.previous_id := prev_record.id;
    prev_hash := prev_record.hash;
  else
    new.previous_id := null;
    prev_hash := '0000000000000000000000000000000000000000000000000000000000000000'; -- Genesis seed
  end if;

  -- Construct the raw payload for hashing
  raw_payload := concat_ws('|',
    prev_hash,
    new.user_id::text,
    new.entry_type,
    new.amount::text,
    new.currency,
    new.direction,
    new.balance_after::text,
    to_char(new.created_at, 'YYYY-MM-DD HH24:MI:SS.USTZ')
  );

  -- Calculate SHA-256 hash using schema-qualified extensions.digest
  new.hash := encode(extensions.digest(raw_payload::text, 'sha256'::text), 'hex');

  return new;
end;
$$ language plpgsql;

-- Point the trigger to the new uniquely named function
drop trigger if exists tr_chain_ledger_entry on public.immutable_financial_ledger;
create trigger tr_chain_ledger_entry
  before insert on public.immutable_financial_ledger
  for each row execute function public.chain_immutable_ledger_entry();


-- ── 2. Fix trigger for ledger_entries (Legacy/Secondary ledger) ──
create or replace function public.chain_legacy_ledger_entry()
returns trigger language plpgsql as $$
declare v_previous text;
begin
  select entry_hash into v_previous from public.ledger_entries
  where user_id = new.user_id order by created_at desc, id desc limit 1;
  
  new.previous_hash := coalesce(v_previous, repeat('0', 64));
  new.entry_hash := encode(extensions.digest((concat_ws('|', new.previous_hash, new.user_id::text,
    new.entry_type, new.amount::text, new.currency::text, new.direction::text,
    new.balance_after::text, coalesce(new.reference_id, ''), new.created_at::text))::text, 'sha256'::text), 'hex');
  return new;
end;
$$;

-- Point the trigger to the new uniquely named function
drop trigger if exists ledger_chain on public.ledger_entries;
create trigger ledger_chain 
  before insert on public.ledger_entries
  for each row execute function public.chain_legacy_ledger_entry();
