import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Environment ────────────────────────────────────────────────────────────
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PESAPAL_CONSUMER_KEY = Deno.env.get("PESAPAL_CONSUMER_KEY")?.trim() || "";
const PESAPAL_CONSUMER_SECRET = Deno.env.get("PESAPAL_CONSUMER_SECRET")?.trim() || "";
const PESAPAL_ENV = Deno.env.get("PESAPAL_ENVIRONMENT")?.trim() || "sandbox";
const PESAPAL_IPN_ID = Deno.env.get("PESAPAL_IPN_ID")?.trim() || ""; // set after IPN registration

const PESAPAL_BASE = PESAPAL_ENV === "production"
  ? "https://pay.pesapal.com/v3"
  : "https://cybqa.pesapal.com/pesapalv3";

// Redirect URL after payment — deep links back to the app
const CALLBACK_URL = "https://www.necxa.uk/payment-callback";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
};

// ── Pesapal helpers ─────────────────────────────────────────────────────────
async function getPesapalToken(): Promise<string> {
  const res = await fetch(`${PESAPAL_BASE}/api/Auth/RequestToken`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify({
      consumer_key: PESAPAL_CONSUMER_KEY,
      consumer_secret: PESAPAL_CONSUMER_SECRET,
    }),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(`Pesapal auth failed: ${JSON.stringify(err)}`);
  }
  const data = await res.json();
  if (!data.token) throw new Error("Pesapal returned no token.");
  return data.token;
}

async function submitPesapalOrder(token: string, order: {
  id: string;
  amount: number;
  currency: string;
  description: string;
  firstName: string;
  lastName: string;
  email: string;
  phone?: string;
  branch?: string;
}): Promise<{ redirect_url: string; order_tracking_id: string; merchant_reference: string }> {
  const payload = {
    id: order.id,
    currency: order.currency,
    amount: order.amount,
    description: order.description,
    callback_url: CALLBACK_URL,
    redirect_mode: "",
    notification_id: PESAPAL_IPN_ID,
    branch: order.branch ?? "Necxa - Wallet Deposit",
    billing_address: {
      email_address: order.email,
      phone_number: order.phone ?? "",
      country_code: "UG",
      first_name: order.firstName,
      middle_name: "",
      last_name: order.lastName,
      line_1: "",
      line_2: "",
      city: "",
      state: "",
      postal_code: "",
      zip_code: "",
    },
  };

  const res = await fetch(`${PESAPAL_BASE}/api/Transactions/SubmitOrderRequest`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "Authorization": `Bearer ${token}`,
    },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(`Pesapal order submission failed: ${JSON.stringify(err)}`);
  }
  const data = await res.json();
  if (!data.redirect_url) throw new Error("Pesapal returned no redirect URL.");
  return {
    redirect_url: data.redirect_url,
    order_tracking_id: data.order_tracking_id,
    merchant_reference: data.merchant_reference,
  };
}

async function getPesapalTransactionStatus(token: string, orderTrackingId: string) {
  const res = await fetch(
    `${PESAPAL_BASE}/api/Transactions/GetTransactionStatus?orderTrackingId=${orderTrackingId}`,
    {
      headers: { "Accept": "application/json", "Authorization": `Bearer ${token}` },
    },
  );
  if (!res.ok) throw new Error(`Pesapal status check failed: ${res.status}`);
  return await res.json();
}

// ── Main handler ────────────────────────────────────────────────────────────
serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }

  // ── Authentication (Cross-Project Support) ────────────────────────────────
  // Authenticate the user against Supabase 1 (Auth Project) if configured, 
  // otherwise default to local Supabase 2
  const authHeader = req.headers.get("Authorization") ?? "";
  const SUPABASE_AUTH_URL = Deno.env.get("SUPABASE_AUTH_URL") || SUPABASE_URL;
  const SUPABASE_AUTH_ANON_KEY = Deno.env.get("SUPABASE_AUTH_ANON_KEY") || SUPABASE_SERVICE_KEY;

  const userSupabase = createClient(SUPABASE_AUTH_URL, SUPABASE_AUTH_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: { user }, error: userError } = await userSupabase.auth.getUser();
  if (userError || !user) {
    return new Response(
      JSON.stringify({ success: false, code: "unauthenticated", message: "Sign in first." }),
      { status: 401, headers: { ...cors, "Content-Type": "application/json" } },
    );
  }

  // Local Supabase 2 client for all financial operations
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  // Sync stub profile to satisfy foreign key constraints on Supabase 2 (wallets -> profiles)
  await supabase.from("profiles").upsert(
    { id: user.id, email: user.email, updated_at: new Date().toISOString() },
    { onConflict: "id", ignoreDuplicates: true }
  );

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch (_) { /* no body */ }

  const action = (body.action as string) ?? "";

  try {
    // ── Action: initiate_deposit ──────────────────────────────────────────
    if (action === "initiate_deposit") {
      const amountUgx = Number(body.amount);
      const phone = (body.phone as string | undefined)?.trim();
      const idempotencyKey = (body.idempotencyKey as string) || `deposit-${user.id}-${Date.now()}`;

      if (!amountUgx || amountUgx < 500) {
        return json({ success: false, message: "Minimum deposit is UGX 500." }, 400);
      }

      // Fetch user profile for name & email
      const { data: profile, error: profileErr } = await supabase
        .from("profiles")
        .select("full_name, email, phone")
        .eq("id", user.id)
        .single();

      if (profileErr || !profile) {
        return json({ success: false, message: "User profile not found." }, 400);
      }

      const [firstName, ...rest] = (profile.full_name ?? "").split(" ");
      const lastName = rest.join(" ") || "—";
      const email = profile.email ?? user.email ?? "";
      const userPhone = phone ?? profile.phone ?? "";

      // Prevent duplicate initiation via idempotency key
      const { data: existingPayment } = await supabase
        .from("payments")
        .select("id, status, response")
        .eq("idempotency_key", idempotencyKey)
        .maybeSingle();

      if (existingPayment && existingPayment.status === "COMPLETED") {
        return json({ success: false, message: "This deposit was already completed." }, 409);
      }

      // Get Pesapal token & submit order
      const token = await getPesapalToken();
      const orderId = idempotencyKey; // Use as Pesapal order ID too

      const orderResult = await submitPesapalOrder(token, {
        id: orderId,
        amount: amountUgx,
        currency: "UGX",
        description: `Necxa Wallet Deposit - ${user.id.substring(0, 8)}`,
        firstName,
        lastName,
        email,
        phone: userPhone,
      });

      // Upsert a payments record in PENDING state
      await supabase.from("payments").upsert({
        user_id: user.id,
        provider: "pesapal",
        provider_reference: orderResult.order_tracking_id,
        idempotency_key: idempotencyKey,
        status: "PENDING",
        request: {
          amount: amountUgx,
          currency: "UGX",
          phone: userPhone,
          orderId,
        },
        response: orderResult,
      }, { onConflict: "idempotency_key" });

      return json({
        success: true,
        redirectUrl: orderResult.redirect_url,
        paymentId: idempotencyKey,
        orderTrackingId: orderResult.order_tracking_id,
      });
    }

    // ── Action: deposit_status ────────────────────────────────────────────
    if (action === "deposit_status") {
      const paymentId = body.paymentId as string;
      if (!paymentId) return json({ success: false, message: "paymentId required." }, 400);

      const { data: payment, error: payErr } = await supabase
        .from("payments")
        .select("status, provider_reference, user_id")
        .eq("idempotency_key", paymentId)
        .eq("user_id", user.id)
        .single();

      if (payErr || !payment) {
        return json({ success: false, message: "Payment not found." }, 404);
      }

      // If already completed or failed, return stored status
      if (payment.status === "COMPLETED" || payment.status === "FAILED") {
        return json({ success: true, status: payment.status.toLowerCase() });
      }

      // Otherwise query Pesapal for real-time status
      const token = await getPesapalToken();
      const statusData = await getPesapalTransactionStatus(token, payment.provider_reference);
      const pesapalStatus = statusData.payment_status_description as string;

      let mappedStatus = "PENDING";
      if (pesapalStatus === "COMPLETED") mappedStatus = "COMPLETED";
      else if (pesapalStatus === "FAILED" || pesapalStatus === "INVALID") mappedStatus = "FAILED";

      // Update the DB if status has changed
      if (mappedStatus !== "PENDING") {
        await supabase
          .from("payments")
          .update({ status: mappedStatus, updated_at: new Date().toISOString() })
          .eq("idempotency_key", paymentId);

        // Credit wallet if completed
        if (mappedStatus === "COMPLETED") {
          const { data: payFull } = await supabase
            .from("payments")
            .select("request")
            .eq("idempotency_key", paymentId)
            .single();
          const amountUgx = (payFull?.request as Record<string, number>)?.amount ?? 0;
          if (amountUgx > 0) {
            await supabase.rpc("credit_wallet_fiat", {
              p_user_id: user.id,
              p_amount_ugx: amountUgx,
              p_reference: paymentId,
            }).throwOnError();
          }
        }
      }

      return json({ success: true, status: mappedStatus.toLowerCase() });
    }


    // ── Action: process_shop_purchase (Pay with wallet balance) ─────────────
    if (action === "process_shop_purchase") {
      const listingId = body.listingId as string;
      const quantity = Number(body.quantity) || 1;
      const deliveryFeeUgx = Number(body.deliveryFeeUgx) || 0;
      const deliveryAddress = (body.deliveryAddress as string) ?? "";
      const deliveryPhone = (body.customerNumber as string) ?? "";
      const deliverySpeed = (body.deliverySpeed as string) ?? "standard";
      const deliveryMethod = (body.deliveryMethod as string) ?? "bike";
      const customerLocation = (body.customerLocation as Record<string, number>) ?? {};
      const idempotencyKey = (body.idempotencyKey as string) || `shop-${user.id}-${Date.now()}`;

      if (!listingId) return json({ success: false, message: "listingId required." }, 400);

      // Call the atomic SQL function — validates balance, deducts, creates order & ledger entries
      const { data, error } = await supabase.rpc("process_shop_purchase_with_balance", {
        p_buyer_id: user.id,
        p_listing_id: listingId,
        p_quantity: quantity,
        p_delivery_fee_ugx: deliveryFeeUgx,
        p_delivery_address: deliveryAddress,
        p_delivery_phone: deliveryPhone,
        p_delivery_speed: deliverySpeed,
        p_delivery_method: deliveryMethod,
        p_customer_location: customerLocation,
        p_idempotency_key: idempotencyKey,
      });

      if (error) {
        // Surface insufficient_funds as a specific error code
        const isInsufficientFunds =
          error.message?.toLowerCase().includes("insufficient funds") ||
          error.hint === "insufficient_funds";
        return json(
          {
            success: false,
            code: isInsufficientFunds ? "insufficient_funds" : "shop_purchase_failed",
            message: error.message ?? "Shop purchase failed.",
          },
          isInsufficientFunds ? 402 : 500,
        );
      }

      const result = data as Record<string, unknown>;
      return json({
        success: true,
        orderId: result.orderId,
        orderNumber: result.orderNumber,
        deliveryFeeUgx: result.deliveryFeeUgx,
        message: result.message ?? "Purchase successful.",
      });
    }

    // ── Action: initiate_shop_payment (Pesapal momo / card) ──────────────────
    if (action === "initiate_shop_payment") {
      const listingId = body.listingId as string;
      const quantity = Number(body.quantity) || 1;
      const deliveryFeeUgx = Number(body.deliveryFeeUgx) || 0;
      const deliveryAddress = (body.deliveryAddress as string) ?? "";
      const deliveryPhone = (body.customerNumber as string) ?? "";
      const deliverySpeed = (body.deliverySpeed as string) ?? "standard";
      const deliveryMethod = (body.deliveryMethod as string) ?? "bike";
      const customerLocation = (body.customerLocation as Record<string, number>) ?? {};
      const idempotencyKey = (body.idempotencyKey as string) || `shop-pesapal-${user.id}-${Date.now()}`;

      if (!listingId) return json({ success: false, message: "listingId required." }, 400);

      // Prevent double-initiation
      const { data: existingOrder } = await supabase
        .from("commerce_orders")
        .select("id, order_number, payment_status")
        .eq("idempotency_key", idempotencyKey)
        .maybeSingle();

      if (existingOrder && existingOrder.payment_status === "COMPLETED") {
        return json({ success: false, message: "This order was already paid." }, 409);
      }

      // Fetch listing details
      const { data: listing, error: listingErr } = await supabase
        .from("listings")
        .select("id, price, title, stock_count, user_id, lister_id, status")
        .eq("id", listingId)
        .single();

      if (listingErr || !listing) return json({ success: false, message: "Listing not found." }, 404);
      if (listing.status !== "active") return json({ success: false, message: "Listing is not active." }, 400);
      if ((listing.user_id === user.id) || (listing.lister_id === user.id)) {
        return json({ success: false, message: "Cannot purchase your own listing." }, 400);
      }
      if ((listing.stock_count ?? 0) < quantity) {
        return json({ success: false, message: "Insufficient stock." }, 400);
      }

      const unitPriceUgx = Number(listing.price);
      const itemsUgx = unitPriceUgx * quantity;
      const totalUgx = itemsUgx + deliveryFeeUgx;

      // Fetch user profile for billing address
      const { data: profile } = await supabase
        .from("profiles")
        .select("full_name, email, phone")
        .eq("id", user.id)
        .single();

      const [firstName, ...rest] = (profile?.full_name ?? "").split(" ");
      const lastName = rest.join(" ") || "—";
      const email = profile?.email ?? user.email ?? "";
      const phone = deliveryPhone || profile?.phone || "";

      // Reserve inventory (prevents overselling during Pesapal redirect window)
      const { error: reserveErr } = await supabase.rpc("reserve_commerce_inventory", {
        p_listing_id: listingId,
        p_customer_id: user.id,
        p_quantity: quantity,
        p_idempotency_key: idempotencyKey + "-inv",
      });
      if (reserveErr) {
        return json({ success: false, message: reserveErr.message ?? "Could not reserve stock." }, 409);
      }

      // Submit Pesapal order
      const pesapalToken = await getPesapalToken();
      const orderResult = await submitPesapalOrder(pesapalToken, {
        id: idempotencyKey,
        amount: totalUgx,
        currency: "UGX",
        description: `Necxa Shop: ${listing.title ?? listingId} x${quantity}`,
        firstName,
        lastName,
        email,
        phone,
        branch: "Necxa - Shop Checkout",
      });

      // Create a PENDING commerce_order
      const { data: order, error: orderErr } = await supabase
        .from("commerce_orders")
        .upsert({
          buyer_id: user.id,
          listing_id: listingId,
          seller_id: listing.user_id ?? listing.lister_id,
          quantity,
          unit_price_ugx: unitPriceUgx,
          delivery_fee_ugx: deliveryFeeUgx,
          total_ugx: totalUgx,
          delivery_address: deliveryAddress,
          delivery_phone: deliveryPhone,
          delivery_speed: deliverySpeed,
          delivery_method: deliveryMethod,
          customer_location: customerLocation,
          payment_method: "momo",
          payment_id: idempotencyKey,
          payment_status: "PENDING",
          status: "pending",
          idempotency_key: idempotencyKey,
          metadata: { order_tracking_id: orderResult.order_tracking_id },
        }, { onConflict: "idempotency_key" })
        .select("id, order_number")
        .single();

      if (orderErr) throw new Error(orderErr.message);

      // Also upsert a payments row for the pesapal-ipn webhook to find
      await supabase.from("payments").upsert({
        user_id: user.id,
        provider: "pesapal",
        provider_reference: orderResult.order_tracking_id,
        idempotency_key: idempotencyKey,
        status: "PENDING",
        request: { amount: totalUgx, currency: "UGX", type: "shop_purchase", listingId, quantity },
        response: orderResult,
      }, { onConflict: "idempotency_key" });

      return json({
        success: true,
        redirectUrl: orderResult.redirect_url,
        paymentId: idempotencyKey,
        orderId: order!.id,
        orderNumber: order!.order_number,
        orderTrackingId: orderResult.order_tracking_id,
      });
    }

    // ── Action: shop_payment_status (poll after Pesapal redirect) ────────────
    if (action === "shop_payment_status") {
      const paymentId = body.paymentId as string;
      if (!paymentId) return json({ success: false, message: "paymentId required." }, 400);

      const { data: payment } = await supabase
        .from("payments")
        .select("status, provider_reference")
        .eq("idempotency_key", paymentId)
        .eq("user_id", user.id)
        .single();

      if (!payment) return json({ success: false, message: "Payment not found." }, 404);

      if (payment.status === "COMPLETED" || payment.status === "FAILED") {
        // Sync the commerce_order payment_status if needed
        await supabase.from("commerce_orders")
          .update({ payment_status: payment.status, status: payment.status === "COMPLETED" ? "confirmed" : "cancelled", updated_at: new Date().toISOString() })
          .eq("payment_id", paymentId);
        return json({ success: true, status: payment.status.toLowerCase() });
      }

      // Ask Pesapal directly
      const token = await getPesapalToken();
      const statusData = await getPesapalTransactionStatus(token, payment.provider_reference);
      const pesapalStatus = statusData.payment_status_description as string;

      let mappedStatus = "PENDING";
      if (pesapalStatus === "COMPLETED") mappedStatus = "COMPLETED";
      else if (pesapalStatus === "FAILED" || pesapalStatus === "INVALID") mappedStatus = "FAILED";

      if (mappedStatus !== "PENDING") {
        await supabase.from("payments")
          .update({ status: mappedStatus, updated_at: new Date().toISOString() })
          .eq("idempotency_key", paymentId);
        await supabase.from("commerce_orders")
          .update({ payment_status: mappedStatus, status: mappedStatus === "COMPLETED" ? "confirmed" : "cancelled", updated_at: new Date().toISOString() })
          .eq("payment_id", paymentId);

        // Release inventory if failed
        if (mappedStatus === "FAILED") {
          await supabase.rpc("finalize_commerce_inventory", {
            p_idempotency_key: paymentId + "-inv",
            p_finance_order_id: null,
            p_commit: false,
          }).throwOnError();
        }
      }

      return json({ success: true, status: mappedStatus.toLowerCase() });
    }

    // ── Action: list_coin_packs ──────────────────────────────────────────────
    if (action === "list_coin_packs") {
      return json({
        success: true,
        coinPacks: [
          { id: "starter", ncx_amount: 50, fiat_price: 5000, color_hex: "#00E5FF", description: "Starter Pack" },
          { id: "pro", ncx_amount: 150, fiat_price: 15000, color_hex: "#2979FF", description: "Pro Pack" },
          { id: "elite", ncx_amount: 500, fiat_price: 50000, color_hex: "#D500F9", description: "Elite Pack" },
          { id: "whale", ncx_amount: 1200, fiat_price: 100000, color_hex: "#FFC400", description: "Whale Pack" },
        ],
      });
    }

    // ── Action: purchase_coins ──────────────────────────────────────────────
    if (action === "purchase_coins") {
      const packId = body.packId as string;
      const method = body.method as string;
      const idempotencyKey = (body.idempotencyKey as string) || `coin-purchase-${user.id}-${Date.now()}`;

      // Prevent double purchase
      const { data: existingPayment } = await supabase
        .from("payments")
        .select("id, status")
        .eq("idempotency_key", idempotencyKey)
        .maybeSingle();

      if (existingPayment && existingPayment.status === "COMPLETED") {
        return json({ success: false, message: "Purchase already processed." }, 409);
      }

      // Hardcoded mapping matching list_coin_packs
      const packDetails: Record<string, { ncx: number, fiat: number }> = {
        starter: { ncx: 50, fiat: 5000 },
        pro: { ncx: 150, fiat: 15000 },
        elite: { ncx: 500, fiat: 50000 },
        whale: { ncx: 1200, fiat: 100000 },
      };

      const pack = packDetails[packId];
      if (!pack) return json({ success: false, message: "Invalid pack selected." }, 400);

      // If fiat_balance, atomically deduct and credit NCX
      if (method === "fiat_balance") {
        const { error } = await supabase.rpc("buy_coins_with_fiat_balance", {
          p_user_auth_id: user.id,
          p_fiat_amount_to_spend: pack.fiat,
          p_ncx_to_receive: pack.ncx,
          p_fiat_currency: "UGX",
        });

        if (error) {
          const isInsufficient = error.message?.toLowerCase().includes("insufficient");
          return json(
            { success: false, code: isInsufficient ? "payment_initialization_failed" : "failed", message: error.message },
            isInsufficient ? 402 : 500
          );
        }

        // Record a completed payment for idempotency tracking
        await supabase.from("payments").upsert({
          user_id: user.id,
          provider: "wallet_balance",
          provider_reference: idempotencyKey,
          idempotency_key: idempotencyKey,
          status: "COMPLETED",
          request: { type: "coin_purchase", packId, method },
          response: { success: true },
        }, { onConflict: "idempotency_key" });

        return json({ success: true });
      }

      // If pesapal (momo/card)
      if (method === "pesapal" || method === "momo" || method === "card" || method === "mtn" || method === "airtel") {
        const { data: profile } = await supabase
          .from("profiles")
          .select("full_name, email, phone")
          .eq("id", user.id)
          .single();

        const [firstName, ...rest] = (profile?.full_name ?? "").split(" ");
        const lastName = rest.join(" ") || "—";
        const email = profile?.email ?? user.email ?? "";
        const phone = profile?.phone || "";

        const pesapalToken = await getPesapalToken();
        const orderResult = await submitPesapalOrder(pesapalToken, {
          id: idempotencyKey,
          amount: pack.fiat,
          currency: "UGX",
          description: `Necxa Coin Purchase: ${pack.ncx} NCX`,
          firstName,
          lastName,
          email,
          phone,
          branch: "Necxa - Coin Purchase",
        });

        await supabase.from("payments").upsert({
          user_id: user.id,
          provider: "pesapal",
          provider_reference: orderResult.order_tracking_id,
          idempotency_key: idempotencyKey,
          status: "PENDING",
          request: { type: "coin_purchase", packId, method, ncxAmount: pack.ncx, fiatAmount: pack.fiat },
          response: orderResult,
        }, { onConflict: "idempotency_key" });

        return json({
          success: true,
          redirectUrl: orderResult.redirect_url,
          paymentId: idempotencyKey,
        });
      }

      return json({ success: false, message: "Unsupported payment method." }, 400);
    }

    // ── Action: coin_purchase_status ──────────────────────────────────────────
    if (action === "coin_purchase_status") {
      const paymentId = body.paymentId as string;
      if (!paymentId) return json({ success: false, message: "paymentId required." }, 400);

      const { data: payment } = await supabase
        .from("payments")
        .select("status, provider_reference, request")
        .eq("idempotency_key", paymentId)
        .eq("user_id", user.id)
        .single();

      if (!payment) return json({ success: false, message: "Payment not found." }, 404);

      if (payment.status === "COMPLETED" || payment.status === "FAILED") {
        return json({ success: true, status: payment.status.toLowerCase() });
      }

      const token = await getPesapalToken();
      const statusData = await getPesapalTransactionStatus(token, payment.provider_reference);
      const pesapalStatus = statusData.payment_status_description as string;

      let mappedStatus = "PENDING";
      if (pesapalStatus === "COMPLETED") mappedStatus = "COMPLETED";
      else if (pesapalStatus === "FAILED" || pesapalStatus === "INVALID") mappedStatus = "FAILED";

      if (mappedStatus !== "PENDING") {
        await supabase.from("payments")
          .update({ status: mappedStatus, updated_at: new Date().toISOString() })
          .eq("idempotency_key", paymentId);

        if (mappedStatus === "COMPLETED") {
          // Credit the coins!
          const reqData = payment.request as Record<string, any>;
          await supabase.rpc("credit_ncx", {
            p_user_auth_id: user.id,
            p_amount_ncx: reqData.ncxAmount,
            p_transaction_type: "COIN_PURCHASE",
            p_fiat_amount: reqData.fiatAmount,
            p_fiat_currency: "UGX",
            p_reference_id: paymentId,
            p_reference_type: "pesapal",
            p_metadata: {},
          });
        }
      }

      return json({ success: true, status: mappedStatus.toLowerCase() });
    }

    // ── Action: list_gift_items ──────────────────────────────────────────────
    if (action === "list_gift_items") {
      return json({
        success: true,
        giftItems: [
          { id: "rose", name: "Rose", emoji: "🌹", ncx_value: 1, ugx_value: 100, category: "standard", sort_order: 1, is_active: true },
          { id: "coffee", name: "Coffee", emoji: "☕", ncx_value: 5, ugx_value: 500, category: "standard", sort_order: 2, is_active: true },
          { id: "heart", name: "Heart", emoji: "💖", ncx_value: 10, ugx_value: 1000, category: "standard", sort_order: 3, is_active: true },
          { id: "diamond", name: "Diamond", emoji: "💎", ncx_value: 50, ugx_value: 5000, category: "premium", sort_order: 4, is_active: true },
          { id: "crown", name: "Crown", emoji: "👑", ncx_value: 100, ugx_value: 10000, category: "premium", sort_order: 5, is_active: true },
          { id: "rocket", name: "Rocket", emoji: "🚀", ncx_value: 500, ugx_value: 50000, category: "epic", sort_order: 6, is_active: true },
        ],
      });
    }

    // ── Action: send_gift ────────────────────────────────────────────────────
    if (action === "send_gift") {
      const receiverId = body.receiverId as string;
      const giftItemId = body.giftItemId as string;
      const ncxAmount = Number(body.ncxAmount) || 0;
      const contextType = body.contextType as string; // e.g. "feed", "live", "shop"
      const contextId = body.contextId as string; // The post ID or live stream ID
      const contextNote = body.contextNote as string;
      const isAnonymous = Boolean(body.isAnonymous);
      const idempotencyKey = (body.idempotencyKey as string) || `gift-${user.id}-${Date.now()}`;

      // For gifts we map to post ID, if there's no context ID we fake one or rely on the RPC handling it
      const postId = contextId && contextId.startsWith("direct") ? "00000000-0000-0000-0000-000000000000" : (contextId || "00000000-0000-0000-0000-000000000000");

      const { data, error } = await supabase.rpc("process_gift_ncx", {
        p_sender_auth_id: user.id,
        p_receiver_auth_id: receiverId,
        p_post_id: postId,
        p_ncx_amount: ncxAmount,
        p_gift_platform_fee_rate: 0.11, // 11% platform fee (89% to creator)
        p_gift_details: {
          gift_item_id: giftItemId,
          context_type: contextType,
          context_note: contextNote,
          is_anonymous: isAnonymous,
          idempotency_key: idempotencyKey,
        },
      });

      if (error) {
        return json({ success: false, message: error.message }, 500);
      }

      // The RPC returns { success, message, platform_fee_paid, receiver_amount_credited }
      // Due to how Supabase returns tabular RPCs it's an array of length 1
      const resData = Array.isArray(data) ? data[0] : data;
      if (resData && resData.success === false) {
        return json({ success: false, message: resData.message }, 400);
      }

      // Fetch gift details to enrich response
      const giftItems = [
        { id: "rose", name: "Rose", emoji: "🌹" },
        { id: "coffee", name: "Coffee", emoji: "☕" },
        { id: "heart", name: "Heart", emoji: "💖" },
        { id: "diamond", name: "Diamond", emoji: "💎" },
        { id: "crown", name: "Crown", emoji: "👑" },
        { id: "rocket", name: "Rocket", emoji: "🚀" },
      ];
      const giftDef = giftItems.find(g => g.id === giftItemId) || { name: "Gift", emoji: "🎁" };

      return json({
        success: true,
        giftId: idempotencyKey,
        giftEmoji: giftDef.emoji,
        giftName: giftDef.name,
        ncxAmount: ncxAmount,
        receiverNcx: resData?.receiver_amount_credited || (ncxAmount * 0.89),
        platformFeeNcx: resData?.platform_fee_paid || (ncxAmount * 0.11),
        ugxEquivalent: ncxAmount * 100, // standard conversion
        isHighlighted: ncxAmount >= 50,
        message: "Gift sent successfully.",
      });
    }

    // ── Action: list_live_gifts ──────────────────────────────────────────────
    if (action === "list_live_gifts") {
      const contextId = body.contextId as string;
      if (!contextId) return json({ success: false, message: "contextId required." }, 400);

      // Query recent gifts from the ledger / community_gifts table
      const { data: gifts, error } = await supabase
        .from("community_gifts")
        .select(`
          id, gift_type, coin_amount, created_at,
          sender:profiles!community_gifts_sender_id_fkey(full_name, avatar_url)
        `)
        .eq("post_id", contextId) // Assuming post_id is being reused for live streams
        .order("created_at", { ascending: false })
        .limit(20);

      if (error) {
        // Fallback for missing table relations or schemas (just so it doesn't break streaming)
        return json({ success: true, gifts: [] });
      }

      const formatted = (gifts || []).map(g => ({
        id: g.id,
        senderName: g.sender?.full_name || "Anonymous",
        senderAvatar: g.sender?.avatar_url || "",
        giftEmoji: g.gift_type === "rose" ? "🌹" : (g.gift_type === "diamond" ? "💎" : "🎁"),
        giftName: g.gift_type,
        amount: g.coin_amount,
        timestamp: g.created_at,
      }));

      return json({ success: true, gifts: formatted });
    }

    return json({ success: false, message: `Unknown action: ${action}` }, 400);
  } catch (err) {
    console.error("finance-engine error:", err);
    return json({ success: false, message: (err as Error).message }, 500);
  }
});

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
