-- Move the verified vintage order from the legacy payment-only recovery path
-- into the authoritative escrow and delivery lifecycle. The funding RPC is
-- replay-safe and returns without crediting balances twice when rerun.
select public.fund_commerce_order_from_external_payment(
  '2b6dc0ff-5695-4000-9cb5-7a4262e3951d'::uuid,
  'checkout-7e42a5a7-a6f4-4492-9e35-5053fc9ae4a7-1786343361286020-pesapal',
  'pesapal'
);
