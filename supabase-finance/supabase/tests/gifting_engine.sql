begin;
create extension if not exists pgtap;
select plan(8);

insert into public.finance_users(user_id,email) values
('00000000-0000-4000-8000-000000000010','gift-sender@necxa.invalid'),
('00000000-0000-4000-8000-000000000011','gift-receiver@necxa.invalid');
insert into public.wallets(user_id,coin_balance) values
('00000000-0000-4000-8000-000000000010',100),
('00000000-0000-4000-8000-000000000011',0);
update public.wallets set coin_balance=0 where user_id='00000000-0000-4000-8000-000000000001';

select lives_ok(
  $$select public.process_gift(
    '00000000-0000-4000-8000-000000000010','00000000-0000-4000-8000-000000000011',
    'moneybag','creator_post','post:test',100,2000,false,'gift-test','{}'::jsonb
  )$$,
  'gift transfer completes atomically'
);
select is((select coin_balance from public.wallets where user_id='00000000-0000-4000-8000-000000000010'),0::bigint,'sender is debited');
select is((select coin_balance from public.wallets where user_id='00000000-0000-4000-8000-000000000011'),80::bigint,'receiver is credited net NCX');
select is((select coin_balance from public.wallets where user_id='00000000-0000-4000-8000-000000000001'),20::bigint,'platform fee is credited');
select is((select count(*) from public.ledger_entries where reference_id='post:test'),3::bigint,'all three ledger legs are recorded');
select is((select count(*) from public.gifts where sender_id='00000000-0000-4000-8000-000000000010' and idempotency_key='gift-test'),1::bigint,'one gift record is stored');
select lives_ok(
  $$select public.process_gift(
    '00000000-0000-4000-8000-000000000010','00000000-0000-4000-8000-000000000011',
    'moneybag','creator_post','post:test',100,2000,false,'gift-test','{}'::jsonb
  )$$,
  'duplicate gift request is idempotent'
);
select is((select coin_balance from public.wallets where user_id='00000000-0000-4000-8000-000000000011'),80::bigint,'duplicate does not credit twice');

select * from finish();
rollback;
