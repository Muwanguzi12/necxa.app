alter table public.share_investors
  add column if not exists kyc_reference text,
  add column if not exists aml_reference text,
  add column if not exists source_of_funds_reference text,
  add column if not exists investment_limit_ugx bigint check (investment_limit_ugx is null or investment_limit_ugx > 0),
  add column if not exists application_submitted_at timestamptz;

alter table public.share_investors
  add constraint share_investors_verified_kyc_reference_check
    check (kyc_status <> 'verified' or nullif(trim(kyc_reference), '') is not null) not valid,
  add constraint share_investors_cleared_aml_reference_check
    check (aml_status <> 'cleared' or nullif(trim(aml_reference), '') is not null) not valid,
  add constraint share_investors_cleared_source_reference_check
    check (source_of_funds_status <> 'cleared' or nullif(trim(source_of_funds_reference), '') is not null) not valid;

alter table public.share_investors validate constraint share_investors_verified_kyc_reference_check;
alter table public.share_investors validate constraint share_investors_cleared_aml_reference_check;
alter table public.share_investors validate constraint share_investors_cleared_source_reference_check;

create or replace function public.enforce_open_share_offer_approvals()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_required_document_keys text[] := array[
    'prospectus_url',
    'subscription_agreement_url',
    'risk_notice_url',
    'cma_approval_reference',
    'board_resolution_reference',
    'shareholder_resolution_reference',
    'pesapal_approval_reference'
  ];
  v_key text;
begin
  if new.status = 'open' then
    if not (
      new.board_approved and
      new.shareholder_approved and
      new.cma_approved and
      new.kyc_aml_program_ready and
      new.pesapal_merchant_approved
    ) then
      raise exception 'Share offer cannot open until every approval gate is satisfied';
    end if;

    foreach v_key in array v_required_document_keys loop
      if nullif(trim(new.legal_document_refs ->> v_key), '') is null then
        raise exception 'Share offer cannot open without legal document reference: %', v_key;
      end if;
    end loop;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

select pg_notify('pgrst', 'reload schema');
