import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Environment ────────────────────────────────────────────────────────────
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PESAPAL_CONSUMER_KEY = Deno.env.get("PESAPAL_CONSUMER_KEY")?.trim() || "";
const PESAPAL_CONSUMER_SECRET = Deno.env.get("PESAPAL_CONSUMER_SECRET")?.trim() || "";
const PESAPAL_ENV = Deno.env.get("PESAPAL_ENVIRONMENT")?.trim() || "sandbox";
const PESAPAL_IPN_ID = Deno.env.get("PESAPAL_IPN_ID")?.trim() || ""; // set after IPN registration
const COMMERCE_OTP_SECRET = Deno.env.get("COMMERCE_OTP_SECRET")?.trim() || SUPABASE_SERVICE_KEY;
const PRIMARY_SUPABASE_URL = Deno.env.get("PRIMARY_SUPABASE_URL")?.trim() ||
  Deno.env.get("SUPABASE_AUTH_URL")?.trim() || Deno.env.get("AUTH_PROJECT_URL")?.trim() || "";
const PRIMARY_SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("PRIMARY_SUPABASE_SERVICE_ROLE_KEY")?.trim() || "";

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
    const errMsg = err?.error?.code || err?.message || JSON.stringify(err);
    throw new Error(`Pesapal order submission failed: ${errMsg}`);
  }
  const data = await res.json();
  if (data?.error) {
    const errMsg = data?.error?.code || data?.error?.message || JSON.stringify(data.error);
    throw new Error(`Pesapal API error: ${errMsg}`);
  }
  if (!data.redirect_url) throw new Error(data.message || "Pesapal returned no redirect URL.");
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

function asFiniteNumber(value: unknown): number | null {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const radians = (degrees: number) => degrees * Math.PI / 180;
  const dLat = radians(lat2 - lat1);
  const dLon = radians(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(radians(lat1)) * Math.cos(radians(lat2)) * Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function calculateDeliveryFeeUgx(
  listing: Record<string, unknown>,
  customerLocation: Record<string, unknown>,
  deliveryMethod: string,
  deliverySpeed: string,
  quantity: number,
): number {
  const method = ["bike", "van", "truck"].includes(deliveryMethod) ? deliveryMethod : "bike";
  const baseRates: Record<string, number> = { bike: 3000, van: 15000, truck: 45000 };
  const includedWeights: Record<string, number> = { bike: 5, van: 50, truck: 500 };
  const speedMultipliers: Record<string, number> = { standard: 1, express: 1.8, batch: 0.6 };

  const pickupLat = asFiniteNumber(listing.latitude);
  const pickupLng = asFiniteNumber(listing.longitude);
  const dropoffLat = asFiniteNumber(customerLocation.latitude ?? customerLocation.lat);
  const dropoffLng = asFiniteNumber(customerLocation.longitude ?? customerLocation.lng);
  const distanceKm = pickupLat !== null && pickupLng !== null && dropoffLat !== null && dropoffLng !== null
    ? Math.max(1, haversineKm(pickupLat, pickupLng, dropoffLat, dropoffLng))
    : 5;

  const safeQuantity = Math.max(1, Math.min(99, Math.trunc(quantity)));
  const actualWeight = Math.max(0, asFiniteNumber(listing.weight_kg) ?? 0) * safeQuantity;
  const volumetricWeight = (
    Math.max(0, asFiniteNumber(listing.length_cm) ?? 0) *
    Math.max(0, asFiniteNumber(listing.width_cm) ?? 0) *
    Math.max(0, asFiniteNumber(listing.height_cm) ?? 0) / 5000
  ) * safeQuantity;
  const chargeableWeight = Math.max(actualWeight, volumetricWeight);
  const excessWeightCharge = Math.max(0, chargeableWeight - includedWeights[method]) * 500;
  const handlingCharge = Math.max(0, safeQuantity - 1) * 500;
  const multiplier = speedMultipliers[deliverySpeed] ?? 1;

  return Math.ceil((baseRates[method] + distanceKm * 2500 + excessWeightCharge + handlingCharge) * multiplier);
}

async function commerceVerificationCode(orderId: string, purpose: "pickup" | "delivery"): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(COMMERCE_OTP_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${purpose}:${orderId}`),
  ));
  const number = signature.slice(0, 4).reduce((value, byte) => (value * 256 + byte) >>> 0, 0);
  return String(number % 1000000).padStart(6, "0");
}

async function mirrorFinanceInventoryToPrimary(
  financeClient: ReturnType<typeof createClient>,
  listingId: string,
): Promise<void> {
  if (!PRIMARY_SUPABASE_URL || !PRIMARY_SUPABASE_SERVICE_ROLE_KEY || !listingId) return;
  const { data: listing, error: listingError } = await financeClient
    .from("listings")
    .select("stock_count, status")
    .eq("id", listingId)
    .single();
  if (listingError || !listing) throw new Error(listingError?.message ?? "Finance listing not found.");

  const primaryAdmin = createClient(PRIMARY_SUPABASE_URL, PRIMARY_SUPABASE_SERVICE_ROLE_KEY);
  const { error: updateError } = await primaryAdmin
    .from("listings")
    .update({
      stock_count: listing.stock_count,
      status: Number(listing.stock_count) <= 0 ? "sold" : listing.status,
      updated_at: new Date().toISOString(),
    })
    .eq("id", listingId);
  if (updateError) throw new Error(`Primary inventory sync failed: ${updateError.message}`);
}

// ── Main handler ────────────────────────────────────────────────────────────
serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
  const urlObj = new URL(req.url);
  const orderTrackingId = urlObj.searchParams.get("OrderTrackingId") || urlObj.searchParams.get("orderTrackingId");
  const orderMerchantRef = urlObj.searchParams.get("OrderMerchantReference") ||
    urlObj.searchParams.get("orderMerchantReference") || urlObj.searchParams.get("paymentId");

  // Provider callbacks do not carry a NECXA user session. Pesapal is queried
  // directly before one replay-safe financial effect is applied.
  if (req.method === "GET" && orderTrackingId && orderMerchantRef) {
    try {
      const { data: payment } = await supabase
        .from("payments")
        .select("*")
        .eq("idempotency_key", orderMerchantRef)
        .maybeSingle();

      if (payment && payment.status !== "COMPLETED") {
        const token = await getPesapalToken();
        const statusData = await getPesapalTransactionStatus(token, orderTrackingId);
        const pesapalStatus = String(statusData.payment_status_description || statusData.status_code || "").toUpperCase();

        if (pesapalStatus.includes("COMPLETED") || statusData.status_code === 1) {
          const paymentRequest = (payment.request ?? {}) as Record<string, unknown>;
          const paymentType = String(paymentRequest.type ?? "wallet_deposit");
          const amountUgx = Number(paymentRequest.amount) || 0;

          if (paymentType === "shop_purchase") {
            const { data: order, error: orderError } = await supabase
              .from("commerce_orders")
              .select("id, listing_id, payment_method")
              .eq("payment_id", orderMerchantRef)
              .single();
            if (orderError || !order) throw new Error(orderError?.message ?? "Shop order not found.");
            const { error: fundingError } = await supabase.rpc("fund_commerce_order_from_external_payment", {
              p_order_id: order.id,
              p_payment_id: orderMerchantRef,
              p_funding_source: order.payment_method === "card" ? "card" : "pesapal",
            });
            if (fundingError) throw new Error(fundingError.message);
            await mirrorFinanceInventoryToPrimary(supabase, String(order.listing_id));
          } else if (paymentType === "wallet_deposit" && amountUgx > 0 && payment.user_id) {
            const { error: creditError } = await supabase.rpc("credit_wallet_fiat", {
              p_user_id: payment.user_id,
              p_amount_ugx: amountUgx,
              p_reference: orderMerchantRef,
            });
            if (creditError) throw new Error(creditError.message);
          } else {
            return json({ success: true, orderNotificationType: "IPNCHANGE", orderTrackingId, status: "202" });
          }

          await supabase.from("payments")
            .update({ status: "COMPLETED", updated_at: new Date().toISOString() })
            .eq("idempotency_key", orderMerchantRef);
        }
      }
      return json({ success: true, orderNotificationType: "IPNCHANGE", orderTrackingId, status: "200" });
    } catch (ipnErr) {
      console.error("IPN handler error:", ipnErr);
      return json({ success: false, error: String(ipnErr) }, 500);
    }
  }

  // ── Authentication (Cross-Project Support) ────────────────────────────────
  // Authenticate the user against Supabase 1 (Auth Project) if configured,
  // otherwise default to local Supabase 2
  const authHeader = req.headers.get("Authorization") ?? "";
  const AUTH_PROJECT_URL = Deno.env.get("SUPABASE_AUTH_URL") ||
    Deno.env.get("AUTH_PROJECT_URL") || PRIMARY_SUPABASE_URL || SUPABASE_URL;
  const AUTH_PROJECT_ANON_KEY = Deno.env.get("SUPABASE_AUTH_ANON_KEY") || Deno.env.get("AUTH_PROJECT_ANON_KEY") || SUPABASE_SERVICE_KEY;

  const userSupabase = createClient(AUTH_PROJECT_URL, AUTH_PROJECT_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: { user }, error: userError } = await userSupabase.auth.getUser();
  if (userError || !user) {
    return new Response(
      JSON.stringify({ success: false, code: "unauthenticated", message: "Sign in first." }),
      { status: 401, headers: { ...cors, "Content-Type": "application/json" } },
    );
  }

  // Sync stub profile to satisfy foreign key constraints on Supabase 2 (wallets -> profiles)
  await supabase.from("profiles").upsert(
    { id: user.id, email: user.email, updated_at: new Date().toISOString() },
    { onConflict: "id", ignoreDuplicates: true }
  );

  const syncCommerceListing = async (listingId: string, forceStock = false) => {
    const fields = "id, title, price, stock_count, status, user_id, lister_id, category, media_url, weight_kg, length_cm, width_cm, height_cm, latitude, longitude, pickup_address";
    let { data: sourceListing } = await userSupabase
      .from("listings")
      .select(fields)
      .eq("id", listingId)
      .maybeSingle();

    if (!sourceListing) {
      const authAnonClient = createClient(AUTH_PROJECT_URL, AUTH_PROJECT_ANON_KEY);
      const { data: publicListing } = await authAnonClient
        .from("listings")
        .select(fields)
        .eq("id", listingId)
        .maybeSingle();
      sourceListing = publicListing;
    }

    if (!sourceListing) return null;
    const sellerId = sourceListing.user_id ?? sourceListing.lister_id;
    if (sellerId) {
      await supabase.from("profiles").upsert(
        { id: sellerId, updated_at: new Date().toISOString() },
        { onConflict: "id", ignoreDuplicates: true },
      );
    }
    const { data: existingFinanceListing } = await supabase
      .from("listings")
      .select("stock_count")
      .eq("id", listingId)
      .maybeSingle();
    const financeListing = {
      ...sourceListing,
      stock_count: forceStock || !existingFinanceListing
        ? sourceListing.stock_count
        : existingFinanceListing.stock_count,
    };
    const { error: syncError } = await supabase.from("listings").upsert(financeListing, { onConflict: "id" });
    if (syncError) throw new Error(`Could not synchronize listing: ${syncError.message}`);
    return financeListing as Record<string, unknown>;
  };

  const attachCommerceDetails = async (orders: Record<string, unknown>[]) => {
    if (orders.length === 0) return [];
    const orderIds = orders.map((order) => String(order.id));
    const participantIds = new Set<string>();
    for (const order of orders) {
      participantIds.add(String(order.buyer_id));
      participantIds.add(String(order.seller_id));
    }

    const [{ data: deliveries }, { data: escrows }, { data: settlements }] = await Promise.all([
      supabase.from("commerce_delivery_jobs").select("*").in("order_id", orderIds),
      supabase.from("commerce_escrows").select("*").in("order_id", orderIds),
      supabase.from("commerce_settlements").select("*").in("order_id", orderIds),
    ]);
    for (const delivery of deliveries ?? []) {
      if (delivery.driver_id) participantIds.add(String(delivery.driver_id));
    }

    const { data: profiles } = await userSupabase
      .from("profiles")
      .select("id, full_name, username, avatar_url, phone")
      .in("id", [...participantIds]);
    const profileById = new Map((profiles ?? []).map((profile) => [String(profile.id), profile]));
    const deliveryByOrder = new Map((deliveries ?? []).map((delivery) => [String(delivery.order_id), delivery]));
    const escrowByOrder = new Map((escrows ?? []).map((escrow) => [String(escrow.order_id), escrow]));

    return orders.map((order) => ({
      ...order,
      delivery: deliveryByOrder.get(String(order.id)) ?? null,
      escrow: escrowByOrder.get(String(order.id)) ?? null,
      settlements: (settlements ?? []).filter((settlement) => String(settlement.order_id) === String(order.id)),
      buyer: profileById.get(String(order.buyer_id)) ?? null,
      seller: profileById.get(String(order.seller_id)) ?? null,
      driver: deliveryByOrder.get(String(order.id))?.driver_id
        ? profileById.get(String(deliveryByOrder.get(String(order.id))!.driver_id)) ?? null
        : null,
    }));
  };

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    // some requests might be empty
  }

  const action = body.action as string;

  if (action === "health") {
    return json({ success: true, status: "online", timestamp: new Date().toISOString() });
  }

  try {
    // ── Action: initiate_deposit ──────────────────────────────────────────
    if (action === "initiate_deposit") {
      const amountUgx = Number(body.amount);
      const phone = (body.phone as string | undefined)?.trim();
      const idempotencyKey = (body.idempotencyKey as string) || `deposit-${user.id}-${Date.now()}`;

      if (!amountUgx || amountUgx < 500) {
        return json({ success: false, message: "Minimum deposit is UGX 500." }, 400);
      }

      // Fetch user profile for name & email, but don't fail if missing
      const { data: profile } = await supabase
        .from("profiles")
        .select("full_name, email, phone")
        .eq("id", user.id)
        .maybeSingle();

      const fullName = profile?.full_name || user.user_metadata?.full_name || "";
      const [firstName, ...rest] = fullName.split(" ");
      const lastName = rest.join(" ") || "—";
      const email = profile?.email || user.email || "no-reply@necxa.app";
      const userPhone = phone || profile?.phone || user.phone || "";

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
          type: "wallet_deposit",
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
      const pesapalStatus = String(statusData.payment_status_description || statusData.status_code || "").toUpperCase();

      let mappedStatus = "PENDING";
      if (pesapalStatus.includes("COMPLETED") || statusData.status_code === 1) mappedStatus = "COMPLETED";
      else if (pesapalStatus.includes("FAILED") || pesapalStatus.includes("INVALID") || statusData.status_code === 2) mappedStatus = "FAILED";

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
      const deliveryAddress = (body.deliveryAddress as string) ?? "";
      const deliveryPhone = (body.customerNumber as string) ?? "";
      const requestedSpeed = (body.deliverySpeed as string) ?? "standard";
      const requestedMethod = (body.deliveryMethod as string) ?? "bike";
      const deliverySpeed = ["standard", "express", "batch"].includes(requestedSpeed) ? requestedSpeed : "standard";
      const deliveryMethod = ["bike", "van", "truck"].includes(requestedMethod) ? requestedMethod : "bike";
      const customerLocation = (body.customerLocation as Record<string, unknown>) ?? {};
      const idempotencyKey = (body.idempotencyKey as string) || `shop-${user.id}-${Date.now()}`;

      if (!listingId) return json({ success: false, message: "listingId required." }, 400);
      const sourceListing = await syncCommerceListing(listingId);
      if (!sourceListing) return json({ success: false, message: "Listing not found." }, 404);
      const deliveryFeeUgx = calculateDeliveryFeeUgx(
        sourceListing,
        customerLocation,
        deliveryMethod,
        deliverySpeed,
        quantity,
      );

      // 🔄 CROSS-PROJECT SYNC: Ensure listing exists on Supabase 2 before atomic SQL
      const { data: localListing } = await supabase.from('listings').select('id').eq('id', listingId).maybeSingle();
      if (!localListing) {
        let { data: sourceListing } = await userSupabase
          .from('listings')
          .select('id, title, price, stock_count, status, user_id, lister_id, category, media_url')
          .eq('id', listingId)
          .maybeSingle();

        if (!sourceListing) {
          const authAnonClient = createClient(AUTH_PROJECT_URL, AUTH_PROJECT_ANON_KEY);
          const { data: publicListing } = await authAnonClient
            .from('listings')
            .select('id, title, price, stock_count, status, user_id, lister_id, category, media_url')
            .eq('id', listingId)
            .maybeSingle();
          sourceListing = publicListing;
        }

        console.log("Cross-Project Listing Sync result for process_shop_purchase:", sourceListing);

        if (sourceListing) {
          if (sourceListing.user_id) await supabase.from("profiles").upsert({ id: sourceListing.user_id, updated_at: new Date().toISOString() }, { onConflict: "id", ignoreDuplicates: true });
          if (sourceListing.lister_id) await supabase.from("profiles").upsert({ id: sourceListing.lister_id, updated_at: new Date().toISOString() }, { onConflict: "id", ignoreDuplicates: true });
          const { error: upsertErr } = await supabase.from("listings").upsert(sourceListing);
          if (upsertErr) console.error("Error upserting listing to Supabase 2:", upsertErr);
        }
      }

      // 💳 WALLET AUTO-PROVISION: Ensure wallet row exists on Supabase 2
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
      await mirrorFinanceInventoryToPrimary(supabase, listingId);
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
      const deliveryAddress = (body.deliveryAddress as string) ?? "";
      const deliveryPhone = (body.customerNumber as string) ?? "";
      const requestedSpeed = (body.deliverySpeed as string) ?? "standard";
      const requestedMethod = (body.deliveryMethod as string) ?? "bike";
      const deliverySpeed = ["standard", "express", "batch"].includes(requestedSpeed) ? requestedSpeed : "standard";
      const deliveryMethod = ["bike", "van", "truck"].includes(requestedMethod) ? requestedMethod : "bike";
      const customerLocation = (body.customerLocation as Record<string, unknown>) ?? {};
      const idempotencyKey = (body.idempotencyKey as string) || `shop-pesapal-${user.id}-${Date.now()}`;

      if (!listingId) return json({ success: false, message: "listingId required." }, 400);
      const sourceListing = await syncCommerceListing(listingId);
      if (!sourceListing) return json({ success: false, message: "Listing not found." }, 404);
      const deliveryFeeUgx = calculateDeliveryFeeUgx(
        sourceListing,
        customerLocation,
        deliveryMethod,
        deliverySpeed,
        quantity,
      );

      // Prevent double-initiation
      const { data: existingOrder } = await supabase
        .from("commerce_orders")
        .select("id, order_number, payment_status, payment_id")
        .eq("idempotency_key", idempotencyKey)
        .maybeSingle();

      if (existingOrder) {
        const { data: existingPayment } = await supabase
          .from("payments")
          .select("provider_reference, response")
          .eq("idempotency_key", idempotencyKey)
          .maybeSingle();
        const previousResponse = (existingPayment?.response ?? {}) as Record<string, unknown>;
        return json({
          success: true,
          status: String(existingOrder.payment_status).toLowerCase(),
          redirectUrl: previousResponse.redirect_url ?? null,
          paymentId: existingOrder.payment_id ?? idempotencyKey,
          orderId: existingOrder.id,
          orderNumber: existingOrder.order_number,
          orderTrackingId: existingPayment?.provider_reference ?? null,
          alreadyInitiated: true,
        });
      }

      // 🔄 CROSS-PROJECT SYNC: Ensure listing exists on Supabase 2
      const { data: localListing } = await supabase.from('listings').select('id').eq('id', listingId).maybeSingle();
      if (!localListing) {
        let { data: sourceListing } = await userSupabase
          .from('listings')
          .select('id, title, price, stock_count, status, user_id, lister_id, category, media_url')
          .eq('id', listingId)
          .maybeSingle();

        if (!sourceListing) {
          const authAnonClient = createClient(AUTH_PROJECT_URL, AUTH_PROJECT_ANON_KEY);
          const { data: publicListing } = await authAnonClient
            .from('listings')
            .select('id, title, price, stock_count, status, user_id, lister_id, category, media_url')
            .eq('id', listingId)
            .maybeSingle();
          sourceListing = publicListing;
        }

        console.log("Cross-Project Listing Sync result for initiate_shop_payment:", sourceListing);

        if (sourceListing) {
          if (sourceListing.user_id) await supabase.from("profiles").upsert({ id: sourceListing.user_id, updated_at: new Date().toISOString() }, { onConflict: "id", ignoreDuplicates: true });
          if (sourceListing.lister_id) await supabase.from("profiles").upsert({ id: sourceListing.lister_id, updated_at: new Date().toISOString() }, { onConflict: "id", ignoreDuplicates: true });
          const { error: upsertErr } = await supabase.from("listings").upsert(sourceListing);
          if (upsertErr) console.error("Error upserting listing to Supabase 2:", upsertErr);
        }
      }

      // Fetch listing details
      const { data: listing, error: listingErr } = await supabase
        .from("listings")
        .select("id, price, title, media_url, stock_count, user_id, lister_id, status")
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
        .maybeSingle();

      const fullName = profile?.full_name || user.user_metadata?.full_name || "";
      const [firstName, ...rest] = fullName.split(" ");
      const lastName = rest.join(" ") || "—";
      const email = profile?.email || user.email || "no-reply@necxa.app";
      const phone = deliveryPhone || profile?.phone || user.phone || "";

      // Reserve inventory (prevents overselling during Pesapal redirect window)
      const { data: reservation, error: reserveErr } = await supabase.rpc("reserve_commerce_inventory", {
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
      let orderResult: Awaited<ReturnType<typeof submitPesapalOrder>>;
      try {
        orderResult = await submitPesapalOrder(pesapalToken, {
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
      } catch (providerError) {
        await supabase.rpc("finalize_commerce_inventory", {
          p_idempotency_key: idempotencyKey + "-inv",
          p_finance_order_id: null,
          p_commit: false,
        });
        throw providerError;
      }

      // Create a PENDING commerce_order
      const { data: order, error: orderErr } = await supabase
        .from("commerce_orders")
        .upsert({
          buyer_id: user.id,
          listing_id: listingId,
          seller_id: listing.user_id ?? listing.lister_id,
          product_title: listing.title,
          product_media_url: listing.media_url,
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
          status: "pending_payment",
          idempotency_key: idempotencyKey,
          reservation_id: reservation?.id ?? null,
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

      const { data: shopOrder } = await supabase
        .from("commerce_orders")
        .select("id, listing_id, payment_method")
        .eq("payment_id", paymentId)
        .eq("buyer_id", user.id)
        .single();
      if (!shopOrder) return json({ success: false, message: "Shop order not found." }, 404);

      if (payment.status === "COMPLETED" || payment.status === "FAILED") {
        if (payment.status === "COMPLETED") {
          const { error: fundingError } = await supabase.rpc("fund_commerce_order_from_external_payment", {
            p_order_id: shopOrder.id,
            p_payment_id: paymentId,
            p_funding_source: shopOrder.payment_method === "card" ? "card" : "pesapal",
          });
          if (fundingError) throw new Error(fundingError.message);
          await mirrorFinanceInventoryToPrimary(supabase, String(shopOrder.listing_id));
        }
        return json({ success: true, status: payment.status.toLowerCase() });
      }

      // Ask Pesapal directly
      const token = await getPesapalToken();
      const statusData = await getPesapalTransactionStatus(token, payment.provider_reference);
      const pesapalStatus = String(statusData.payment_status_description || statusData.status_code || "").toUpperCase();

      let mappedStatus = "PENDING";
      if (pesapalStatus.includes("COMPLETED") || statusData.status_code === 1) mappedStatus = "COMPLETED";
      else if (pesapalStatus.includes("FAILED") || pesapalStatus.includes("INVALID") || statusData.status_code === 2) mappedStatus = "FAILED";

      if (mappedStatus !== "PENDING") {
        if (mappedStatus === "COMPLETED") {
          const { error: fundingError } = await supabase.rpc("fund_commerce_order_from_external_payment", {
            p_order_id: shopOrder.id,
            p_payment_id: paymentId,
            p_funding_source: shopOrder.payment_method === "card" ? "card" : "pesapal",
          });
          if (fundingError) throw new Error(fundingError.message);
          await mirrorFinanceInventoryToPrimary(supabase, String(shopOrder.listing_id));
        } else {
          await supabase.from("commerce_orders")
            .update({ payment_status: "FAILED", status: "cancelled", cancelled_at: new Date().toISOString(), updated_at: new Date().toISOString() })
            .eq("id", shopOrder.id);
          await supabase.rpc("finalize_commerce_inventory", {
            p_idempotency_key: paymentId + "-inv",
            p_finance_order_id: null,
            p_commit: false,
          }).throwOnError();
          await mirrorFinanceInventoryToPrimary(supabase, String(shopOrder.listing_id));
        }

        await supabase.from("payments")
          .update({ status: mappedStatus, updated_at: new Date().toISOString() })
          .eq("idempotency_key", paymentId);
      }

      return json({ success: true, status: mappedStatus.toLowerCase() });
    }

    // ── Action: list_coin_packs ──────────────────────────────────────────────
    if (action === "liquidate_ncx") {
      const ncxAmount = Math.trunc(Number(body.ncxAmount));
      const idempotencyKey = String(body.idempotencyKey ?? "");
      if (!Number.isFinite(ncxAmount) || ncxAmount <= 0 || !idempotencyKey) {
        return json({ success: false, message: "A positive NCX amount and idempotency key are required." }, 400);
      }
      const { data, error } = await supabase.rpc("liquidate_ncx", {
        p_user_id: user.id,
        p_ncx_amount: ncxAmount,
        p_idempotency_key: idempotencyKey,
        p_metadata: (body.securityMetadata ?? {}) as Record<string, unknown>,
      });
      if (error) return json({ success: false, message: error.message }, 409);
      return json(data as Record<string, unknown>);
    }

    if (action === "unlock_feature" || action === "charge_artist_distribution") {
      const isFeature = action === "unlock_feature";
      const reference = isFeature ? String(body.featureId ?? "") : String(body.reference ?? "artist_distribution");
      const amountNcx = Math.trunc(Number(body.costNcx ?? body.amountNcx));
      const idempotencyKey = String(body.idempotencyKey ?? "");
      if (!reference || !Number.isFinite(amountNcx) || amountNcx <= 0 || !idempotencyKey) {
        return json({ success: false, message: "A reference, NCX amount and idempotency key are required." }, 400);
      }
      if (isFeature) {
        const { data: existing } = await supabase
          .from("finance_feature_unlocks")
          .select("id")
          .eq("user_id", user.id)
          .eq("feature_id", reference)
          .maybeSingle();
        if (existing) return json({ success: true, alreadyUnlocked: true });
      }
      const { data, error } = await supabase.rpc("charge_ncx_purpose", {
        p_user_id: user.id,
        p_amount_ncx: amountNcx,
        p_purpose: isFeature ? "feature_unlock" : "distribution_charge",
        p_reference: reference,
        p_idempotency_key: idempotencyKey,
      });
      if (error) return json({ success: false, message: error.message }, 409);
      return json(data as Record<string, unknown>);
    }

    if (action === "create_transport_booking") {
      const orderId = String(body.orderId ?? "");
      const driverId = String(body.driverId ?? "");
      const pickup = String(body.pickup ?? "").trim();
      const dropoff = String(body.dropoff ?? "").trim();
      const amountUgx = Math.trunc(Number(body.amountUgx));
      const idempotencyKey = String(body.idempotencyKey ?? "");
      if (!orderId || !driverId || !pickup || !dropoff || !idempotencyKey || amountUgx < 1000 || amountUgx > 10000000) {
        return json({ success: false, message: "Invalid transport booking." }, 400);
      }
      const { data: driver } = await userSupabase
        .from("transport_drivers")
        .select("id, is_verified, is_available")
        .eq("id", driverId)
        .maybeSingle();
      if (!driver?.is_verified || !driver.is_available) {
        return json({ success: false, message: "The selected driver is not available and verified." }, 409);
      }
      const { data, error } = await supabase.rpc("create_transport_booking_hold", {
        p_order_id: orderId,
        p_customer_id: user.id,
        p_driver_id: driverId,
        p_pickup: pickup,
        p_dropoff: dropoff,
        p_amount_ugx: amountUgx,
        p_idempotency_key: idempotencyKey,
      });
      if (error) return json({ success: false, message: error.message }, 409);
      return json(data as Record<string, unknown>);
    }

    if (action === "settle_transport_booking") {
      const orderId = String(body.orderId ?? "");
      if (!orderId) return json({ success: false, message: "orderId required." }, 400);
      const { data: order } = await userSupabase
        .from("transport_orders")
        .select("id, user_id, driver_id, status")
        .eq("id", orderId)
        .maybeSingle();
      if (!order || order.user_id !== user.id) {
        return json({ success: false, message: "Only the customer can release transport escrow." }, 403);
      }
      if (!["delivered", "completed"].includes(order.status)) {
        return json({ success: false, message: "The driver must mark the trip delivered before escrow release." }, 409);
      }
      const { data, error } = await supabase.rpc("settle_transport_booking", { p_order_id: orderId });
      if (error) return json({ success: false, message: error.message }, 409);
      return json(data as Record<string, unknown>);
    }

    if (action === "refund_transport_booking") {
      const orderId = String(body.orderId ?? "");
      const reason = String(body.reason ?? "booking_creation_failed").slice(0, 500);
      if (!orderId) return json({ success: false, message: "orderId required." }, 400);

      const { data: booking } = await supabase
        .from("finance_transport_bookings")
        .select("customer_id, status")
        .eq("order_id", orderId)
        .maybeSingle();
      if (!booking) return json({ success: false, message: "Transport booking not found." }, 404);
      if (booking.customer_id !== user.id) {
        return json({ success: false, message: "Only the customer can cancel this booking." }, 403);
      }

      const { data, error } = await supabase.rpc("refund_transport_booking", {
        p_order_id: orderId,
        p_reason: reason,
      });
      if (error) return json({ success: false, message: error.message }, 409);
      return json(data as Record<string, unknown>);
    }

    if (action === "dispute_transport_booking") {
      const orderId = String(body.orderId ?? "");
      const reason = String(body.reason ?? "").trim().slice(0, 500);
      if (!orderId || reason.length < 5) {
        return json({ success: false, message: "An order and dispute reason are required." }, 400);
      }
      const { data: order } = await userSupabase
        .from("transport_orders")
        .select("id, user_id, driver_id, status")
        .eq("id", orderId)
        .maybeSingle();
      if (!order || (order.user_id !== user.id && order.driver_id !== user.id)) {
        return json({ success: false, message: "Transport order access denied." }, 403);
      }
      if (["completed", "cancelled"].includes(order.status)) {
        return json({ success: false, message: "This trip can no longer be disputed." }, 409);
      }
      const { data, error } = await supabase.rpc("dispute_transport_booking", {
        p_order_id: orderId,
        p_reason: reason,
      });
      if (error) return json({ success: false, message: error.message }, 409);
      return json(data as Record<string, unknown>);
    }

    if (action === "commerce_dashboard") {
      const { data: sourceListings, error: listingsError } = await userSupabase
        .from("listings")
        .select("id, title, media_url, price, stock_count, status, created_at")
        .or(`user_id.eq.${user.id},lister_id.eq.${user.id}`)
        .order("created_at", { ascending: false });
      if (listingsError) throw new Error(listingsError.message);
      const inventoryListings = (await Promise.all(
        (sourceListings ?? []).map((listing) => syncCommerceListing(String(listing.id))),
      )).filter((listing): listing is Record<string, unknown> => listing !== null);

      const { data: orders, error: ordersError } = await supabase
        .from("commerce_orders")
        .select("*")
        .eq("seller_id", user.id)
        .order("created_at", { ascending: false });
      if (ordersError) throw new Error(ordersError.message);

      const { data: settlements, error: settlementsError } = await supabase
        .from("commerce_settlements")
        .select("net_amount_ugx, status, created_at")
        .eq("beneficiary_id", user.id)
        .eq("beneficiary_type", "seller");
      if (settlementsError) throw new Error(settlementsError.message);

      const { data: reviews } = await supabase
        .from("commerce_reviews")
        .select("rating")
        .eq("seller_id", user.id)
        .eq("status", "published");

      const sellerOrders = orders ?? [];
      const paidOrders = sellerOrders.filter((order) => order.payment_status === "COMPLETED");
      const grossSalesUgx = paidOrders.reduce(
        (total, order) => total + Number(order.unit_price_ugx) * Number(order.quantity),
        0,
      );
      const releasedEarningsUgx = (settlements ?? []).reduce(
        (total, settlement) => total + Number(settlement.net_amount_ugx),
        0,
      );
      const heldEarningsUgx = paidOrders
        .filter((order) => order.settlement_status !== "released" && order.settlement_status !== "refunded")
        .reduce((total, order) => total + Number(order.unit_price_ugx) * Number(order.quantity), 0);
      const ratingCount = reviews?.length ?? 0;
      const ratingAverage = ratingCount === 0
        ? 0
        : reviews!.reduce((total, review) => total + Number(review.rating), 0) / ratingCount;

      return json({
        success: true,
        dashboard: {
          activeListings: inventoryListings.filter((listing) => listing.status === "active").length,
          lowStockListings: inventoryListings.filter((listing) => Number(listing.stock_count) <= 5).length,
          totalOrders: sellerOrders.length,
          openOrders: sellerOrders.filter((order) => !["completed", "cancelled", "refunded"].includes(order.status)).length,
          grossSalesUgx,
          releasedEarningsUgx,
          heldEarningsUgx,
          ratingAverage,
          ratingCount,
          listings: inventoryListings,
          recentOrders: await attachCommerceDetails(sellerOrders.slice(0, 10)),
        },
      });
    }

    if (action === "list_commerce_orders") {
      const role = String(body.role ?? "buyer");
      const limit = Math.max(1, Math.min(50, Number(body.limit) || 20));
      const cursor = body.cursor ? String(body.cursor) : null;
      if (!["buyer", "seller", "driver"].includes(role)) {
        return json({ success: false, message: "Invalid order role." }, 400);
      }

      let orders: Record<string, unknown>[] = [];
      if (role === "driver") {
        const { data: jobs, error: jobsError } = await supabase
          .from("commerce_delivery_jobs")
          .select("order_id")
          .eq("driver_id", user.id)
          .order("updated_at", { ascending: false })
          .limit(limit);
        if (jobsError) throw new Error(jobsError.message);
        const orderIds = (jobs ?? []).map((job) => job.order_id);
        if (orderIds.length > 0) {
          const { data, error } = await supabase.from("commerce_orders").select("*").in("id", orderIds);
          if (error) throw new Error(error.message);
          orders = (data ?? []) as Record<string, unknown>[];
        }
      } else {
        let query = supabase
          .from("commerce_orders")
          .select("*")
          .eq(role === "seller" ? "seller_id" : "buyer_id", user.id)
          .order("created_at", { ascending: false })
          .limit(limit + 1);
        if (cursor) query = query.lt("created_at", cursor);
        const { data, error } = await query;
        if (error) throw new Error(error.message);
        orders = (data ?? []) as Record<string, unknown>[];
      }

      orders.sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
      const hasMore = orders.length > limit;
      const page = orders.slice(0, limit);
      const detailedOrders = await attachCommerceDetails(page);
      const roleSafeOrders = await Promise.all(detailedOrders.map(async (order) => ({
        ...order,
        pickupCode: role === "seller" ? await commerceVerificationCode(String(order.id), "pickup") : null,
        deliveryCode: role === "buyer" ? await commerceVerificationCode(String(order.id), "delivery") : null,
      })));

      return json({
        success: true,
        orders: roleSafeOrders,
        nextCursor: hasMore ? page[page.length - 1]?.created_at ?? null : null,
      });
    }

    if (action === "get_commerce_order") {
      const orderId = String(body.orderId ?? "");
      const eventCursor = Math.max(0, Number(body.eventCursor) || 0);
      if (!orderId) return json({ success: false, message: "orderId required." }, 400);

      const { data: order, error: orderError } = await supabase
        .from("commerce_orders")
        .select("*")
        .eq("id", orderId)
        .single();
      if (orderError || !order) return json({ success: false, message: "Order not found." }, 404);
      const { data: delivery } = await supabase
        .from("commerce_delivery_jobs")
        .select("driver_id")
        .eq("order_id", orderId)
        .single();

      const role = order.buyer_id === user.id
        ? "buyer"
        : order.seller_id === user.id
        ? "seller"
        : delivery?.driver_id === user.id
        ? "driver"
        : null;
      if (!role) return json({ success: false, message: "Order access denied." }, 403);

      const { data: events, error: eventsError } = await supabase
        .from("commerce_order_events")
        .select("*")
        .eq("order_id", orderId)
        .gt("id", eventCursor)
        .order("id", { ascending: true })
        .limit(100);
      if (eventsError) throw new Error(eventsError.message);

      const [detailedOrder] = await attachCommerceDetails([order]);
      return json({
        success: true,
        role,
        order: {
          ...detailedOrder,
          pickupCode: role === "seller" ? await commerceVerificationCode(orderId, "pickup") : null,
          deliveryCode: role === "buyer" ? await commerceVerificationCode(orderId, "delivery") : null,
        },
        events: events ?? [],
        nextEventCursor: events?.length ? events[events.length - 1].id : eventCursor,
      });
    }

    if (action === "list_available_deliveries") {
      const { data: driver } = await userSupabase
        .from("transport_drivers")
        .select("id, is_verified, is_available, vehicle_type")
        .eq("id", user.id)
        .maybeSingle();
      if (!driver?.is_verified) return json({ success: false, message: "Driver verification is required." }, 403);
      if (!driver.is_available) return json({ success: true, deliveries: [] });

      const { data: jobs, error: jobsError } = await supabase
        .from("commerce_delivery_jobs")
        .select("order_id")
        .eq("status", "ready_for_pickup")
        .is("driver_id", null)
        .order("created_at", { ascending: true })
        .limit(50);
      if (jobsError) throw new Error(jobsError.message);
      const orderIds = (jobs ?? []).map((job) => job.order_id);
      if (orderIds.length === 0) return json({ success: true, deliveries: [] });
      const { data: orders, error: ordersError } = await supabase
        .from("commerce_orders")
        .select("*")
        .in("id", orderIds);
      if (ordersError) throw new Error(ordersError.message);
      const detailed = await attachCommerceDetails((orders ?? []) as Record<string, unknown>[]);
      detailed.sort((a, b) => orderIds.indexOf(String(a.id)) - orderIds.indexOf(String(b.id)));
      const privacySafeDeliveries = detailed.map((order) => {
        const {
          buyer: _buyer,
          seller: _seller,
          driver: _driver,
          buyer_id: _buyerId,
          seller_id: _sellerId,
          delivery_phone: _deliveryPhone,
          ...safeOrder
        } = order;
        return safeOrder;
      });
      return json({ success: true, deliveries: privacySafeDeliveries });
    }

    if (action === "transition_commerce_order") {
      const orderId = String(body.orderId ?? "");
      const transition = String(body.transition ?? "");
      const verificationCode = String(body.verificationCode ?? "").trim();
      if (!orderId || !transition) return json({ success: false, message: "orderId and transition are required." }, 400);

      const { data: order } = await supabase
        .from("commerce_orders")
        .select("buyer_id, seller_id")
        .eq("id", orderId)
        .single();
      if (!order) return json({ success: false, message: "Order not found." }, 404);
      const { data: delivery } = await supabase
        .from("commerce_delivery_jobs")
        .select("driver_id")
        .eq("order_id", orderId)
        .single();

      let actorRole: "buyer" | "seller" | "driver" | null = null;
      if (order.buyer_id === user.id) actorRole = "buyer";
      else if (order.seller_id === user.id) actorRole = "seller";
      else if (delivery?.driver_id === user.id || transition === "driver_accept") actorRole = "driver";
      if (!actorRole) return json({ success: false, message: "Order access denied." }, 403);

      if (actorRole === "driver") {
        const { data: driver } = await userSupabase
          .from("transport_drivers")
          .select("id, is_verified, is_available")
          .eq("id", user.id)
          .maybeSingle();
        if (!driver?.is_verified || !driver.is_available) {
          return json({ success: false, message: "An available, verified driver account is required." }, 403);
        }
      }

      if (transition === "driver_pickup") {
        const expected = await commerceVerificationCode(orderId, "pickup");
        if (verificationCode !== expected) return json({ success: false, message: "The pickup code is incorrect." }, 400);
      }
      if (transition === "driver_delivered") {
        const expected = await commerceVerificationCode(orderId, "delivery");
        if (verificationCode !== expected) return json({ success: false, message: "The delivery code is incorrect." }, 400);
      }

      const transitionMetadata = (body.metadata ?? {}) as Record<string, unknown>;
      if (
        transition === "driver_delivered" &&
        (asFiniteNumber(transitionMetadata.latitude) === null ||
          asFiniteNumber(transitionMetadata.longitude) === null)
      ) {
        return json({ success: false, message: "Delivery GPS proof is required." }, 400);
      }
      const { data: result, error: transitionError } = await supabase.rpc("transition_commerce_order", {
        p_order_id: orderId,
        p_actor_id: user.id,
        p_actor_role: actorRole,
        p_action: transition,
        p_driver_id: actorRole === "driver" ? user.id : null,
        p_metadata: transitionMetadata,
      });
      if (transitionError) return json({ success: false, message: transitionError.message }, 409);
      return json({ success: true, result });
    }

    if (action === "update_commerce_inventory") {
      const listingId = String(body.listingId ?? "");
      const stockCount = Number(body.stockCount);
      const status = body.status == null ? null : String(body.status);
      if (!listingId || !Number.isInteger(stockCount) || stockCount < 0) {
        return json({ success: false, message: "A valid listingId and stockCount are required." }, 400);
      }
      if (status !== null && !["active", "paused", "sold", "draft"].includes(status)) {
        return json({ success: false, message: "Invalid listing status." }, 400);
      }

      const { data: ownedListing } = await userSupabase
        .from("listings")
        .select("id, user_id, lister_id")
        .eq("id", listingId)
        .maybeSingle();
      if (!ownedListing || (ownedListing.user_id !== user.id && ownedListing.lister_id !== user.id)) {
        return json({ success: false, message: "Only the listing owner can change inventory." }, 403);
      }

      const updates: Record<string, unknown> = { stock_count: stockCount, updated_at: new Date().toISOString() };
      if (status !== null) updates.status = status;
      const { error: sourceUpdateError } = await userSupabase.from("listings").update(updates).eq("id", listingId);
      if (sourceUpdateError) throw new Error(sourceUpdateError.message);
      const syncedListing = await syncCommerceListing(listingId, true);
      return json({ success: true, listing: syncedListing });
    }

    if (action === "review_eligibility") {
      const listingId = String(body.listingId ?? "");
      const { data: order } = await supabase
        .from("commerce_orders")
        .select("id, completed_at")
        .eq("buyer_id", user.id)
        .eq("listing_id", listingId)
        .eq("status", "completed")
        .order("completed_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (!order) return json({ success: true, eligible: false, reason: "Complete a verified purchase before reviewing." });
      const { data: review } = await supabase
        .from("commerce_reviews")
        .select("id")
        .eq("order_id", order.id)
        .eq("buyer_id", user.id)
        .maybeSingle();
      return json({ success: true, eligible: !review, orderId: order.id, reason: review ? "This purchase was already reviewed." : null });
    }

    if (action === "submit_commerce_review") {
      const orderId = String(body.orderId ?? "");
      const rating = Number(body.rating);
      const comment = String(body.comment ?? "").trim();
      const mediaUrls = Array.isArray(body.mediaUrls) ? body.mediaUrls.map(String).slice(0, 5) : [];
      if (!orderId || !Number.isInteger(rating) || rating < 1 || rating > 5 || comment.length < 3 || comment.length > 2000) {
        return json({ success: false, message: "Rating and a comment between 3 and 2000 characters are required." }, 400);
      }

      const { data: order } = await supabase
        .from("commerce_orders")
        .select("id, buyer_id, seller_id, listing_id, status")
        .eq("id", orderId)
        .single();
      if (!order || order.buyer_id !== user.id || order.status !== "completed") {
        return json({ success: false, message: "Only the buyer of a completed order can review it." }, 403);
      }
      const { data: review, error: reviewError } = await supabase
        .from("commerce_reviews")
        .insert({
          order_id: order.id,
          listing_id: order.listing_id,
          buyer_id: user.id,
          seller_id: order.seller_id,
          rating,
          comment,
          media_urls: mediaUrls,
        })
        .select("*")
        .single();
      if (reviewError) {
        const duplicate = reviewError.code === "23505";
        return json({ success: false, message: duplicate ? "This purchase was already reviewed." : reviewError.message }, duplicate ? 409 : 500);
      }
      return json({ success: true, review });
    }

    if (action === "list_commerce_reviews") {
      const listingId = String(body.listingId ?? "");
      const limit = Math.max(1, Math.min(50, Number(body.limit) || 20));
      const cursor = body.cursor ? String(body.cursor) : null;
      if (!listingId) return json({ success: false, message: "listingId required." }, 400);

      let query = supabase
        .from("commerce_reviews")
        .select("id, listing_id, buyer_id, rating, comment, media_urls, seller_response, seller_responded_at, created_at")
        .eq("listing_id", listingId)
        .eq("status", "published")
        .order("created_at", { ascending: false })
        .limit(limit + 1);
      if (cursor) query = query.lt("created_at", cursor);
      const { data: reviews, error: reviewsError } = await query;
      if (reviewsError) throw new Error(reviewsError.message);
      const page = (reviews ?? []).slice(0, limit);
      const buyerIds = [...new Set(page.map((review) => review.buyer_id))];
      const { data: buyers } = buyerIds.length === 0
        ? { data: [] }
        : await userSupabase.from("profiles").select("id, full_name, username, avatar_url").in("id", buyerIds);
      const buyerById = new Map((buyers ?? []).map((buyer) => [buyer.id, buyer]));
      const allRatings = await supabase.from("commerce_reviews").select("rating").eq("listing_id", listingId).eq("status", "published");
      const ratingCount = allRatings.data?.length ?? 0;
      const ratingAverage = ratingCount === 0 ? 0 : allRatings.data!.reduce((sum, review) => sum + Number(review.rating), 0) / ratingCount;

      return json({
        success: true,
        reviews: page.map((review) => ({ ...review, buyer: buyerById.get(review.buyer_id) ?? null, verifiedPurchase: true })),
        summary: { ratingAverage, ratingCount },
        nextCursor: (reviews?.length ?? 0) > limit ? page[page.length - 1]?.created_at ?? null : null,
      });
    }

    if (action === "list_vendor_reviews") {
      const limit = Math.max(1, Math.min(50, Number(body.limit) || 20));
      const cursor = body.cursor ? String(body.cursor) : null;
      let query = supabase
        .from("commerce_reviews")
        .select("id, listing_id, buyer_id, rating, comment, media_urls, seller_response, seller_responded_at, created_at")
        .eq("seller_id", user.id)
        .eq("status", "published")
        .order("created_at", { ascending: false })
        .limit(limit + 1);
      if (cursor) query = query.lt("created_at", cursor);
      const { data: reviews, error: reviewsError } = await query;
      if (reviewsError) throw new Error(reviewsError.message);
      const page = (reviews ?? []).slice(0, limit);
      const buyerIds = [...new Set(page.map((review) => review.buyer_id))];
      const listingIds = [...new Set(page.map((review) => review.listing_id))];
      const [{ data: buyers }, { data: listings }] = await Promise.all([
        buyerIds.length === 0
          ? Promise.resolve({ data: [] })
          : userSupabase.from("profiles").select("id, full_name, username, avatar_url").in("id", buyerIds),
        listingIds.length === 0
          ? Promise.resolve({ data: [] })
          : userSupabase.from("listings").select("id, title, media_url").in("id", listingIds),
      ]);
      const buyerById = new Map((buyers ?? []).map((buyer) => [buyer.id, buyer]));
      const listingById = new Map((listings ?? []).map((listing) => [listing.id, listing]));
      return json({
        success: true,
        reviews: page.map((review) => ({
          ...review,
          buyer: buyerById.get(review.buyer_id) ?? null,
          listing: listingById.get(review.listing_id) ?? null,
          verifiedPurchase: true,
        })),
        nextCursor: (reviews?.length ?? 0) > limit ? page[page.length - 1]?.created_at ?? null : null,
      });
    }

    if (action === "respond_to_commerce_review") {
      const reviewId = String(body.reviewId ?? "");
      const response = String(body.response ?? "").trim();
      if (!reviewId || response.length < 2 || response.length > 1000) {
        return json({ success: false, message: "A response between 2 and 1000 characters is required." }, 400);
      }
      const { data: review } = await supabase.from("commerce_reviews").select("id, seller_id").eq("id", reviewId).single();
      if (!review || review.seller_id !== user.id) return json({ success: false, message: "Only the seller can respond." }, 403);
      const { data: updated, error } = await supabase.from("commerce_reviews")
        .update({ seller_response: response, seller_responded_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq("id", reviewId)
        .select("*")
        .single();
      if (error) throw new Error(error.message);
      return json({ success: true, review: updated });
    }

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
          .maybeSingle();

        const fullName = profile?.full_name || user.user_metadata?.full_name || "";
        const [firstName, ...rest] = fullName.split(" ");
        const lastName = rest.join(" ") || "—";
        const email = profile?.email || user.email || "no-reply@necxa.app";
        const userPhone = profile?.phone || user.phone || "";

        const pesapalToken = await getPesapalToken();
        const orderResult = await submitPesapalOrder(pesapalToken, {
          id: idempotencyKey,
          amount: pack.fiat,
          currency: "UGX",
          description: `Necxa Coin Purchase: ${pack.ncx} NCX`,
          firstName,
          lastName,
          email,
          phone: userPhone,
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
      const pesapalStatus = String(statusData.payment_status_description || statusData.status_code || "").toUpperCase();

      let mappedStatus = "PENDING";
      if (pesapalStatus.includes("COMPLETED") || statusData.status_code === 1) mappedStatus = "COMPLETED";
      else if (pesapalStatus.includes("FAILED") || pesapalStatus.includes("INVALID") || statusData.status_code === 2) mappedStatus = "FAILED";

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
      const metadata = (body.metadata ?? {}) as Record<string, unknown>;

      const isLiveGift = contextType === "live_stream" || contextType === "live";
      const rpcName = isLiveGift ? "process_live_gift_ncx" : "process_gift_ncx";
      const rpcPayload = isLiveGift
        ? {
            p_sender_auth_id: user.id,
            p_receiver_auth_id: receiverId,
            p_channel_id: contextId,
            p_ncx_amount: ncxAmount,
            p_gift_platform_fee_rate: 0.11,
            p_gift_details: {
              gift_item_id: giftItemId,
              context_type: contextType,
              context_note: contextNote,
              is_anonymous: isAnonymous,
              idempotency_key: idempotencyKey,
              sender_name: isAnonymous ? "Anonymous" : (metadata.sender_name || user.email || "Viewer"),
              sender_avatar: isAnonymous ? "" : (metadata.sender_avatar || ""),
            },
          }
        : {
            p_sender_auth_id: user.id,
            p_receiver_auth_id: receiverId,
            p_post_id: contextId && !contextId.startsWith("direct")
              ? contextId
              : "00000000-0000-0000-0000-000000000000",
            p_ncx_amount: ncxAmount,
            p_gift_platform_fee_rate: 0.11,
            p_gift_details: {
              gift_item_id: giftItemId,
              context_type: contextType,
              context_note: contextNote,
              is_anonymous: isAnonymous,
              idempotency_key: idempotencyKey,
            },
          };

      const { data, error } = await supabase.rpc(rpcName, rpcPayload);

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
        giftId: resData?.gift_id || idempotencyKey,
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

      // Live channels are text identifiers and have their own finance table.
      const { data: gifts, error } = await supabase
        .from("live_gifts")
        .select("id, sender_id, sender_name, sender_avatar, gift_type, coin_amount, created_at")
        .eq("channel_id", contextId)
        .order("created_at", { ascending: false })
        .limit(1000);

      if (error) {
        return json({ success: false, message: error.message }, 503);
      }

      const formatted = (gifts || []).slice(0, 20).map(g => ({
        id: g.id,
        senderId: g.sender_id,
        senderName: g.sender_name || "Anonymous",
        senderAvatar: g.sender_avatar || "",
        giftEmoji: g.gift_type === "rose" ? "🌹" : (g.gift_type === "diamond" ? "💎" : "🎁"),
        giftName: g.gift_type,
        amount: g.coin_amount,
        timestamp: g.created_at,
      }));

      const totalsBySender = new Map<string, {
        senderId: string;
        senderName: string;
        senderAvatar: string;
        amount: number;
      }>();
      let totalAmount = 0;
      for (const gift of gifts || []) {
        const amount = Number(gift.coin_amount) || 0;
        totalAmount += amount;
        const senderId = gift.sender_id || gift.sender_name || "anonymous";
        const current = totalsBySender.get(senderId) ?? {
          senderId,
          senderName: gift.sender_name || "Anonymous",
          senderAvatar: gift.sender_avatar || "",
          amount: 0,
        };
        current.amount += amount;
        totalsBySender.set(senderId, current);
      }
      const topGifter = [...totalsBySender.values()]
        .sort((a, b) => b.amount - a.amount)[0] ?? null;
      const milestones = [100, 500, 1000, 5000, 10000, 25000, 50000, 100000];
      const goalTarget = milestones.find(value => value > totalAmount)
        ?? Math.ceil((totalAmount + 1) / 100000) * 100000;

      return json({
        success: true,
        gifts: formatted,
        summary: { totalAmount, goalTarget, topGifter },
      });
    }

    // ── Action: get_wallet ───────────────────────────────────────────────────
    // Returns the current wallet for the authenticated user.
    // Called by Flutter _syncVault() every time the UI needs to refresh balances.
    if (action === "get_wallet") {
      // Ensure wallet row exists (0 balance if first request)
      await supabase.from("wallets").upsert(
        { user_id: user.id, fiat_balance: 0, coin_balance: 0, escrow_balance: 0 },
        { onConflict: "user_id", ignoreDuplicates: true }
      );

      const { data: wallet, error: walletErr } = await supabase
        .from("wallets")
        .select("*")
        .eq("user_id", user.id)
        .single();

      if (walletErr || !wallet) {
        return json({ success: false, message: "Wallet not found." }, 404);
      }

      // Also fetch recent ledger entries for the transaction history
      const { data: ledger } = await supabase
        .from("immutable_financial_ledger")
        .select("id, entry_type, amount, currency, direction, balance_after, metadata, created_at")
        .eq("user_id", user.id)
        .order("created_at", { ascending: false })
        .limit(20);

      return json({
        success: true,
        wallet: {
          id: wallet.id,
          user_id: wallet.user_id,
          fiat_balance: wallet.fiat_balance,
          coin_balance: wallet.coin_balance,
          escrow_balance: wallet.escrow_balance,
          total_earned: wallet.total_earned ?? 0,
          total_spent: wallet.total_spent ?? 0,
          total_commission_earned: 0,
          daily_withdrawal_limit: 5000000,
          monthly_withdrawal_limit: 50000000,
          is_frozen: wallet.is_frozen ?? false,
          freeze_reason: wallet.freeze_reason ?? null,
          created_at: wallet.created_at,
          updated_at: wallet.updated_at,
        },
        recentTransactions: (ledger || []).map(e => ({
          id: e.id,
          type: e.entry_type,
          amount: e.amount,
          currency: e.currency,
          direction: e.direction,
          balanceAfter: e.balance_after,
          metadata: e.metadata,
          createdAt: e.created_at,
        })),
      });
    }

    // ── Action: get_transaction_history ──────────────────────────────────────
    if (action === "get_transaction_history") {
      const limit = Number(body.limit) || 50;
      const offset = Number(body.offset) || 0;

      const { data: ledger, error: ledgerErr } = await supabase
        .from("immutable_financial_ledger")
        .select("id, entry_type, amount, currency, direction, balance_after, metadata, created_at")
        .eq("user_id", user.id)
        .order("created_at", { ascending: false })
        .range(offset, offset + limit - 1);

      if (ledgerErr) throw new Error(ledgerErr.message);

      return json({
        success: true,
        transactions: (ledger || []).map(e => ({
          id: e.id,
          type: e.entry_type,
          amount: e.amount,
          currency: e.currency,
          direction: e.direction,
          balanceAfter: e.balance_after,
          metadata: e.metadata,
          createdAt: e.created_at,
        })),
      });
    }

    // ── Action: reconcile_deposit ─────────────────────────────────────────────
    // Manually triggers a Pesapal status check and wallet credit for a given paymentId.
    // Called from the app after the user returns from the Pesapal browser redirect.
    if (action === "reconcile_deposit") {
      const paymentId = body.paymentId as string;
      if (!paymentId) return json({ success: false, message: "paymentId required." }, 400);

      const { data: payment } = await supabase
        .from("payments")
        .select("*")
        .eq("idempotency_key", paymentId)
        .eq("user_id", user.id)
        .maybeSingle();

      if (!payment) return json({ success: false, message: "Payment record not found." }, 404);

      // Already credited — avoid double-credit
      if (payment.status === "COMPLETED") {
        return json({ success: true, status: "already_credited", message: "This deposit was already credited to your wallet." });
      }

      // Check current Pesapal status
      const token = await getPesapalToken();
      const statusData = await getPesapalTransactionStatus(token, payment.provider_reference);
      const pesapalStatus = String(statusData.payment_status_description || statusData.status_code || "").toUpperCase();

      console.log(`Reconcile deposit ${paymentId}: Pesapal says "${pesapalStatus}", status_code=${statusData.status_code}`);

      let reconciledStatus = "PENDING";
      if (pesapalStatus.includes("COMPLETED") || statusData.status_code === 1) reconciledStatus = "COMPLETED";
      else if (pesapalStatus.includes("FAILED") || pesapalStatus.includes("INVALID") || statusData.status_code === 2) reconciledStatus = "FAILED";

      // Update payment record
      await supabase.from("payments")
        .update({ status: reconciledStatus, updated_at: new Date().toISOString() })
        .eq("idempotency_key", paymentId);

      if (reconciledStatus === "COMPLETED") {
        const amountUgx = (payment.request as Record<string, number>)?.amount ?? 0;
        if (amountUgx > 0) {
          const { error: creditErr } = await supabase.rpc("credit_wallet_fiat", {
            p_user_id: user.id,
            p_amount_ugx: amountUgx,
            p_reference: paymentId,
          });
          if (creditErr) {
            console.error("credit_wallet_fiat error:", creditErr);
            // Don't fail — update was successful, just log
          }
        }

        // Insert reconciliation record
        await supabase.from("payment_reconciliations").upsert({
          payment_id: payment.id,
          idempotency_key: paymentId,
          user_id: user.id,
          provider: "pesapal",
          amount_ugx: (payment.request as Record<string, number>)?.amount ?? 0,
          pesapal_status: pesapalStatus,
          reconciled_status: "RECONCILED",
          reconciled_at: new Date().toISOString(),
          pesapal_response: statusData,
        }, { onConflict: "idempotency_key" });

        return json({ success: true, status: "completed", message: "Deposit confirmed and wallet credited!" });
      }

      if (reconciledStatus === "FAILED") {
        await supabase.from("payment_reconciliations").upsert({
          payment_id: payment.id,
          idempotency_key: paymentId,
          user_id: user.id,
          provider: "pesapal",
          amount_ugx: (payment.request as Record<string, number>)?.amount ?? 0,
          pesapal_status: pesapalStatus,
          reconciled_status: "FAILED",
          reconciled_at: new Date().toISOString(),
          pesapal_response: statusData,
        }, { onConflict: "idempotency_key" });
        return json({ success: false, status: "failed", message: "Payment was unsuccessful. Please try again." });
      }

      return json({ success: true, status: "pending", message: "Payment is still processing. Please wait." });
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
