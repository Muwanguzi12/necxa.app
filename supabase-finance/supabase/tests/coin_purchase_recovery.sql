begin;
create extension if not exists pgtap;
select plan(6);

insert into public.finance_users(user_id, email)
values('00000000-0000-4000-8000-000000000008', 'coin-recovery-test@necxa.invalid');
insert into public.wallets(user_id, coin_balance, fiat_balance)
values('00000000-0000-4000-8000-000000000008', 0, 0);
insert into public.payments(
  id, user_id, provider, provider_reference, purpose, amount, currency,
  status, idempotency_key, request
) values(
  '00000000-0000-4000-8000-000000000009',
  '00000000-0000-4000-8000-000000000008',
  'pesapal', 'recovery-tracking-reference', 'coin_purchase', 10000, 'UGX',
  'failed', 'coin-recovery-test', '{"pack_id":"starter","ncx_amount":100}'::jsonb
);

select lives_ok(
  $$select public.complete_coin_purchase(
    '00000000-0000-4000-8000-000000000009',
    'recovery-tracking-reference',
    '{"payment_status_description":"COMPLETED"}'::jsonb
  )$$,
  'verified completion recovers a locally failed payment'
);
select is((select coin_balance from public.wallets where user_id = '00000000-0000-4000-8000-000000000008'), 100::bigint, 'NCX is credited');
select is((select status::text from public.payments where id = '00000000-0000-4000-8000-000000000009'), 'completed', 'payment becomes completed');
select is((select count(*) from public.ledger_entries where idempotency_key = 'coin-purchase-ncx:00000000-0000-4000-8000-000000000009'), 1::bigint, 'one ledger credit is recorded');
select lives_ok(
  $$select public.complete_coin_purchase(
    '00000000-0000-4000-8000-000000000009',
    'recovery-tracking-reference',
    '{"payment_status_description":"COMPLETED"}'::jsonb
  )$$,
  'duplicate completion is idempotent'
);
select is((select coin_balance from public.wallets where user_id = '00000000-0000-4000-8000-000000000008'), 100::bigint, 'duplicate completion does not credit twice');

select * from finish();
rollback;
