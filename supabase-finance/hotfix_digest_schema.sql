-- ════════════════════════════════════════════════════════════════════════════
-- HOTFIX: Schema-qualify digest() calls in ledger triggers
--
-- Since pgcrypto is installed in the `extensions` schema, any trigger executing
-- under a strict `search_path = public` (like `process_gift`) will fail to resolve
-- the unqualified `digest()` function.
--
-- This script updates the ledger triggers to explicitly use `extensions.digest()`.
-- ════════════════════════════════════════════════════════════════════════════

-- 1. Update the immutable_financial_ledger trigger (from 20260612_financial_identity_ledger.sql)
create or replace function public.chain_ledger_entry()
returns trigger as $$
declare
  prev_record record;
  prev_hash text;
  raw_payload text;
begin
  -- 1. Fetch the previous ledger entry
  select id, hash into prev_record 
  from public.immutable_financial_ledger 
  order by created_at desc, id desc 
  limit 1;

  if found then
    new.previous_id := prev_record.id;
    prev_hash := prev_record.hash;
  else
    new.previous_id := null;
    prev_hash := '0000000000000000000000000000000000000000000000000000000000000000'; -- Genesis seed
  end if;

  -- 2. Construct the raw payload for hashing
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

  -- 3. Calculate SHA-256 hash using extensions.digest
  new.hash := encode(extensions.digest(raw_payload::text, 'sha256'::text), 'hex');

  return new;
end;
$$ language plpgsql;


-- 2. Update the old ledger_entries trigger (from 202607160001_finance_core.sql)
-- (Just in case the system is still writing to both or this table is still active)
create or replace function public.chain_ledger_entry()
returns trigger language plpgsql as $$
declare v_previous text;
begin
  select entry_hash into v_previous from public.ledger_entries
  where user_id = new.user_id order by created_at desc, id desc limit 1;
  new.previous_hash := coalesce(v_previous, repeat('0', 64));
  new.entry_hash := encode(extensions.digest(concat_ws('|', new.previous_hash, new.user_id::text,
    new.entry_type, new.amount::text, new.currency::text, new.direction::text,
    new.balance_after::text, coalesce(new.reference_id, ''), new.created_at::text)::text, 'sha256'::text), 'hex');
  return new;
end;
$$;
