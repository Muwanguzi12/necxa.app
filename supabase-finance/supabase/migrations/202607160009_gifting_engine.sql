insert into public.gift_items(id,name,emoji,ncx_value,ugx_value,category,sort_order,is_active) values
('rose','Rose',U&'\+01F339',1,100,'standard',1,true),
('clap','Clap',U&'\+01F44F',2,200,'standard',2,true),
('heart','Heart',U&'\2764',3,300,'standard',3,true),
('coffee','Coffee',U&'\2615',5,500,'standard',4,true),
('star','Star',U&'\2B50',5,500,'standard',5,true),
('fire','Fire',U&'\+01F525',10,1000,'standard',6,true),
('rocket','Rocket',U&'\+01F680',20,2000,'rare',10,true),
('crown','Crown',U&'\+01F451',25,2500,'rare',11,true),
('diamond','Diamond',U&'\+01F48E',50,5000,'rare',12,true),
('trophy','Trophy',U&'\+01F3C6',50,5000,'rare',13,true),
('moneybag','Money Bag',U&'\+01F4B0',100,10000,'rare',14,true),
('sportscar','Sports Car',U&'\+01F3CE',200,20000,'epic',20,true),
('yacht','Yacht',U&'\26F5',300,30000,'epic',21,true),
('villa','Villa',U&'\+01F3E1',500,50000,'epic',22,true),
('jet','Private Jet',U&'\2708',1000,100000,'legendary',30,true),
('palace','NECXA Palace',U&'\+01F3F0',5000,500000,'legendary',31,true),
('galaxy','Galaxy',U&'\+01F30C',10000,1000000,'legendary',32,true)
on conflict(id) do update set name=excluded.name,emoji=excluded.emoji,ncx_value=excluded.ncx_value,
ugx_value=excluded.ugx_value,category=excluded.category,sort_order=excluded.sort_order,is_active=excluded.is_active;

insert into public.finance_users(user_id,display_name,source_project)
values('00000000-0000-4000-8000-000000000001','Necxa Platform','necxa-finance')
on conflict(user_id) do nothing;
insert into public.wallets(user_id)
values('00000000-0000-4000-8000-000000000001') on conflict(user_id) do nothing;

alter table public.gifts drop constraint if exists gifts_idempotency_key_key;
alter table public.gifts add constraint gifts_sender_idempotency_key unique(sender_id,idempotency_key);

create or replace function public.process_gift(
  p_sender_id uuid, p_receiver_id uuid, p_gift_item_id text, p_context_type text,
  p_context_id text, p_ncx_amount bigint, p_fee_basis_points integer,
  p_is_anonymous boolean, p_idempotency_key text, p_metadata jsonb default '{}'::jsonb
) returns public.gifts
language plpgsql security definer set search_path = public as $$
declare
  v_item public.gift_items; v_fee bigint; v_receiver_amount bigint; v_gift public.gifts;
  v_platform_id constant uuid := '00000000-0000-4000-8000-000000000001';
begin
  if p_sender_id = p_receiver_id then raise exception 'Cannot gift yourself'; end if;
  select * into v_gift from public.gifts
    where sender_id = p_sender_id and idempotency_key = p_idempotency_key;
  if found then return v_gift; end if;

  select * into v_item from public.gift_items where id = p_gift_item_id and is_active for share;
  if not found then raise exception 'Gift item is unavailable'; end if;
  if p_ncx_amount <> v_item.ncx_value then raise exception 'Gift price does not match the catalogue'; end if;

  perform public.ensure_finance_wallet(p_sender_id);
  perform public.ensure_finance_wallet(p_receiver_id);
  perform public.ensure_finance_wallet(v_platform_id, null, 'Necxa Platform');
  perform 1 from public.wallets
    where user_id in (p_sender_id,p_receiver_id,v_platform_id) order by user_id for update;

  v_fee := floor(v_item.ncx_value * greatest(0,least(p_fee_basis_points,10000)) / 10000.0);
  v_receiver_amount := v_item.ncx_value - v_fee;
  perform public.debit_wallet(p_sender_id,v_item.ncx_value,'NCX','GIFT_SENT',p_context_id,
    p_idempotency_key || ':sender',p_metadata || jsonb_build_object('gift_item_id',v_item.id));
  perform public.credit_wallet(p_receiver_id,v_receiver_amount,'NCX','GIFT_RECEIVED',p_context_id,
    p_idempotency_key || ':receiver',p_metadata || jsonb_build_object('gift_item_id',v_item.id));
  if v_fee > 0 then
    perform public.credit_wallet(v_platform_id,v_fee,'NCX','GIFT_PLATFORM_FEE',p_context_id,
      p_idempotency_key || ':platform',jsonb_build_object('gift_item_id',v_item.id,'sender_id',p_sender_id,'receiver_id',p_receiver_id));
  end if;
  insert into public.gifts(sender_id,receiver_id,gift_item_id,context_type,context_id,ncx_amount,
    receiver_ncx,platform_fee_ncx,is_anonymous,idempotency_key,metadata)
  values(p_sender_id,p_receiver_id,v_item.id,p_context_type,p_context_id,v_item.ncx_value,
    v_receiver_amount,v_fee,p_is_anonymous,p_idempotency_key,p_metadata)
  returning * into v_gift;
  return v_gift;
end;
$$;

revoke all on function public.process_gift(uuid,uuid,text,text,text,bigint,integer,boolean,text,jsonb) from public,anon,authenticated;
grant execute on function public.process_gift(uuid,uuid,text,text,text,bigint,integer,boolean,text,jsonb) to service_role;
