begin;
create extension if not exists pgtap;
select plan(8);

insert into public.finance_users(user_id, email)
values
  ('00000000-0000-4000-8000-000000000030', 'projection-sender@necxa.invalid'),
  ('00000000-0000-4000-8000-000000000031', 'projection-receiver@necxa.invalid')
on conflict (user_id) do nothing;

insert into public.wallets(user_id, coin_balance)
values
  ('00000000-0000-4000-8000-000000000030', 10),
  ('00000000-0000-4000-8000-000000000031', 0)
on conflict (user_id) do update set coin_balance = excluded.coin_balance;

select lives_ok(
  $$select public.process_gift(
    '00000000-0000-4000-8000-000000000030',
    '00000000-0000-4000-8000-000000000031',
    'rose',
    'creator_post',
    '00000000-0000-4000-8000-000000000099',
    1,
    1100,
    false,
    'projection-test',
    '{}'::jsonb
  )$$,
  'community gift creates a finance record and projection event'
);

select is(
  (select community_sync_status from public.gifts where idempotency_key = 'projection-test'),
  'pending',
  'new community gift starts pending'
);

select is(
  (select count(*)::integer from public.gift_projection_outbox o
   join public.gifts g on g.id = o.finance_gift_id
   where g.idempotency_key = 'projection-test'),
  1,
  'one outbox event is created'
);

select is(
  (select count(*)::integer from public.gift_projection_outbox
   where status = 'processing'
     and finance_gift_id = (select id from public.gifts where idempotency_key = 'projection-test')),
  0,
  'new outbox event is not claimed prematurely'
);

select is(
  (select count(*)::integer from public.claim_gift_projection_batch(10)),
  1,
  'one projection event can be claimed'
);

select lives_ok(
  $$select public.complete_gift_projection(
    (select id from public.gifts where idempotency_key = 'projection-test'),
    true,
    null
  )$$,
  'projection can be marked synced'
);

select is(
  (select community_sync_attempts from public.gifts where idempotency_key = 'projection-test'),
  1,
  'projection attempt count is persisted'
);

select is(
  (select community_sync_status from public.gifts where idempotency_key = 'projection-test'),
  'synced',
  'gift status reflects successful projection'
);

select * from finish();
rollback;
