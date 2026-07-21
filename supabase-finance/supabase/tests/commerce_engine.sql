begin;
create extension if not exists pgtap;
select plan(12);

insert into public.finance_users(user_id,email) values
('00000000-0000-4000-8000-000000000020','buyer@necxa.invalid'),
('00000000-0000-4000-8000-000000000021','vendor@necxa.invalid'),
('00000000-0000-4000-8000-000000000022','courier@necxa.invalid');
insert into public.wallets(user_id,fiat_balance) values
('00000000-0000-4000-8000-000000000020',200000),
('00000000-0000-4000-8000-000000000021',0),
('00000000-0000-4000-8000-000000000022',0);

select lives_ok($$select public.create_commerce_order(
  '00000000-0000-4000-8000-000000000020','00000000-0000-4000-8000-000000000021',
  '10000000-0000-4000-8000-000000000001','1234ABC','Test product',null,2,50000,10000,
  'bike','standard','Kampala','+256700000000',0.31,32.58,0.33,32.61,5,4,
  '{"length_cm":30,"width_cm":20,"height_cm":10}',now()+interval '6 hours','commerce-test','{}'
)$$,'order and escrow are created atomically');
select is((select fiat_balance from public.wallets where user_id='00000000-0000-4000-8000-000000000020'),90000::bigint,'buyer total is debited');
select is((select status::text from public.escrows where idempotency_key='commerce-test:escrow'),'held','funds remain held');
select is((select status::text from public.commerce_orders where idempotency_key='commerce-test'),'paid','order begins paid');
select is((select count(*) from public.commerce_orders where idempotency_key='commerce-test'),1::bigint,'one order is stored');
select lives_ok($$select public.create_commerce_order(
  '00000000-0000-4000-8000-000000000020','00000000-0000-4000-8000-000000000021',
  '10000000-0000-4000-8000-000000000001','1234ABC','Test product',null,2,50000,10000,
  'bike','standard','Kampala','+256700000000',0.31,32.58,0.33,32.61,5,4,
  '{}',now()+interval '6 hours','commerce-test','{}'
)$$,'duplicate purchase is idempotent');
select is((select fiat_balance from public.wallets where user_id='00000000-0000-4000-8000-000000000020'),90000::bigint,'duplicate does not debit twice');

select lives_ok($$select public.transition_commerce_order((select id from public.commerce_orders where idempotency_key='commerce-test'),'00000000-0000-4000-8000-000000000021','vendor_confirmed','Accepted')$$,'vendor accepts order');
select lives_ok($$select public.transition_commerce_order((select id from public.commerce_orders where idempotency_key='commerce-test'),'00000000-0000-4000-8000-000000000021','preparing','Preparing')$$,'vendor prepares order');
select lives_ok($$select public.transition_commerce_order((select id from public.commerce_orders where idempotency_key='commerce-test'),'00000000-0000-4000-8000-000000000021','ready_for_pickup','Ready')$$,'vendor marks ready');
select lives_ok($$select public.transition_commerce_order((select id from public.commerce_orders where idempotency_key='commerce-test'),'00000000-0000-4000-8000-000000000021','courier_assigned','Assigned','00000000-0000-4000-8000-000000000022')$$,'vendor assigns courier');
select throws_ok($$select public.release_commerce_escrow((select id from public.commerce_orders where idempotency_key='commerce-test'),'00000000-0000-4000-8000-000000000020')$$,'Delivery must be confirmed first','escrow cannot release early');

select * from finish();
rollback;
