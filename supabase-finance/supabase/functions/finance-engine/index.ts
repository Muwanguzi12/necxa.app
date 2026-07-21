import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { pesapalIpnId, pesapalToken, submitPesapalOrder } from "../_shared/pesapal.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function requiredString(value: unknown, name: string): string {
  if (typeof value !== "string" || value.trim() === "") throw new Error(`${name} is required`);
  return value.trim();
}

function positiveInteger(value: unknown, name: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`${name} must be a positive integer`);
  return parsed;
}

function finiteNumber(value: unknown, name: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) throw new Error(`${name} must be a number`);
  return parsed;
}

function distanceKm(aLat: number, aLng: number, bLat: number, bLng: number) {
  const radians = (degrees: number) => degrees * Math.PI / 180;
  const dLat = radians(bLat - aLat);
  const dLng = radians(bLng - aLng);
  const value = Math.sin(dLat / 2) ** 2 + Math.cos(radians(aLat)) * Math.cos(radians(bLat)) * Math.sin(dLng / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

function deliveryQuote(input: { distance: number; quantity: number; weight: number; length: number; width: number; height: number; method: string; speed: string }) {
  const bases: Record<string, number> = { bike: 3000, van: 15000, truck: 45000 };
  const included: Record<string, number> = { bike: 5, van: 50, truck: 500 };
  const speedMultiplier: Record<string, number> = { batch: 0.6, standard: 1, express: 1.8 };
  if (!(input.method in bases) || !(input.speed in speedMultiplier)) throw new Error("Unsupported delivery method or speed");
  const actual = input.weight * input.quantity;
  const volumetric = input.length * input.width * input.height / 5000 * input.quantity;
  const chargeable = Math.max(actual, volumetric);
  const fare = (bases[input.method] + Math.max(1, input.distance) * 2500 +
    Math.max(0, chargeable - included[input.method]) * 500 + Math.max(0, input.quantity - 1) * 500) * speedMultiplier[input.speed];
  return Math.ceil(fare);
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function encryptDestination(value: string) {
  const secret = Deno.env.get("FINANCE_ENCRYPTION_KEY");
  if (!secret) throw new Error("Finance encryption is not configured");
  const keyBytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(value));
  return btoa(String.fromCharCode(...iv, ...new Uint8Array(encrypted)));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ success: false, code: "method_not_allowed" }, 405);

  try {
    const financeUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const primaryUrl = Deno.env.get("PRIMARY_SUPABASE_URL")!;
    const primaryPublishableKey = Deno.env.get("PRIMARY_SUPABASE_PUBLISHABLE_KEY")!;
    const primaryServiceRoleKey = Deno.env.get("PRIMARY_SUPABASE_SERVICE_ROLE_KEY")!;
    if (!financeUrl || !serviceRoleKey || !primaryUrl || !primaryPublishableKey || !primaryServiceRoleKey) {
      return reply({ success: false, code: "server_misconfigured", message: "Finance authentication is not configured." }, 500);
    }

    const authorization = req.headers.get("Authorization") ?? "";
    const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
    if (!token) return reply({ success: false, code: "unauthenticated", message: "Authentication required." }, 401);

    // Validate the session against the primary Necxa identity project. Supabase 2
    // is deliberately an isolated finance database and does not issue app logins.
    const identity = createClient(primaryUrl, primaryPublishableKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: userData, error: userError } = await identity.auth.getUser(token);
    if (userError || !userData.user) {
      return reply({ success: false, code: "invalid_session", message: "Your session is invalid or expired." }, 401);
    }

    const user = userData.user;
    const admin = createClient(financeUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const primaryAdmin = createClient(primaryUrl, primaryServiceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const body = await req.json() as Record<string, unknown>;
    const action = requiredString(body.action, "action");

    if (action === "health") {
      return reply({ success: true, project: "necxa-finance-supabase-2", userId: user.id });
    }

    const { error: ensureError } = await admin.rpc("ensure_finance_wallet", {
      p_user_id: user.id,
      p_email: user.email ?? null,
      p_display_name: user.user_metadata?.display_name ?? user.user_metadata?.full_name ?? null,
    });
    if (ensureError) throw ensureError;

    if (action === "get_wallet") {
      const { data, error } = await admin.from("wallets").select("*").eq("user_id", user.id).single();
      if (error) throw error;
      return reply({ success: true, wallet: data });
    }

    if (action === "process_shop_purchase") {
      const listingId = requiredString(body.listingId, "listingId");
      const quantity = positiveInteger(body.quantity, "quantity");
      const deliveryMethod = requiredString(body.deliveryMethod, "deliveryMethod").toLowerCase();
      const deliverySpeed = requiredString(body.deliverySpeed, "deliverySpeed").toLowerCase();
      const location = body.customerLocation as Record<string, unknown> | undefined;
      const dropoffLat = finiteNumber(location?.lat, "customerLocation.lat");
      const dropoffLng = finiteNumber(location?.lng, "customerLocation.lng");
      const deliveryAddress = requiredString(body.deliveryAddress, "deliveryAddress");
      const customerNumber = requiredString(body.customerNumber, "customerNumber");
      const idempotencyKey = requiredString(body.idempotencyKey, "idempotencyKey");

      const { data: listing, error: listingError } = await primaryAdmin.from("listings")
        .select("id,user_id,lister_id,title,thumbnail_url,image_url,media_url,price_ugx,price,sku,stock_count,status,weight_kg,length_cm,width_cm,height_cm,latitude,longitude")
        .eq("id", listingId).eq("status", "active").single();
      if (listingError || !listing) return reply({ success: false, code: "listing_unavailable", message: "This product is no longer available." }, 404);
      const vendorId = String(listing.user_id ?? listing.lister_id ?? "");
      if (!vendorId) throw new Error("Listing vendor is missing");
      if (vendorId === user.id) return reply({ success: false, code: "self_purchase", message: "You cannot purchase your own product." }, 409);
      const stock = Number(listing.stock_count ?? 0);
      if (!Number.isSafeInteger(stock) || stock < quantity) return reply({ success: false, code: "insufficient_stock", message: "The requested quantity is unavailable." }, 409);
      const unitPrice = Math.round(Number(listing.price_ugx ?? listing.price));
      const unitWeight = finiteNumber(listing.weight_kg, "listing weight");
      const length = finiteNumber(listing.length_cm, "listing length");
      const width = finiteNumber(listing.width_cm, "listing width");
      const height = finiteNumber(listing.height_cm, "listing height");
      const pickupLat = finiteNumber(listing.latitude, "vendor latitude");
      const pickupLng = finiteNumber(listing.longitude, "vendor longitude");
      const distance = distanceKm(pickupLat, pickupLng, dropoffLat, dropoffLng);
      const deliveryFee = deliveryQuote({ distance, quantity, weight: unitWeight, length, width, height, method: deliveryMethod, speed: deliverySpeed });
      const estimateHours = deliverySpeed === "express" ? 1 : deliverySpeed === "standard" ? 6 : 24;

      const { error: reservationError } = await primaryAdmin.rpc("reserve_commerce_inventory", {
        p_listing_id: listingId, p_customer_id: user.id, p_quantity: quantity, p_idempotency_key: idempotencyKey,
      });
      if (reservationError) throw reservationError;
      await admin.rpc("ensure_finance_wallet", { p_user_id: vendorId });
      const { data: order, error } = await admin.rpc("create_commerce_order", {
        p_customer_id: user.id, p_vendor_id: vendorId, p_listing_id: listing.id,
        p_sku: listing.sku, p_product_title: listing.title,
        p_product_thumbnail: listing.thumbnail_url ?? listing.image_url ?? listing.media_url,
        p_quantity: quantity, p_unit_price_ugx: unitPrice, p_delivery_fee_ugx: deliveryFee,
        p_delivery_method: deliveryMethod, p_delivery_speed: deliverySpeed,
        p_delivery_address: deliveryAddress, p_delivery_phone: customerNumber,
        p_pickup_lat: pickupLat, p_pickup_lng: pickupLng, p_dropoff_lat: dropoffLat, p_dropoff_lng: dropoffLng,
        p_distance_km: distance, p_weight_kg: unitWeight * quantity,
        p_package_dimensions: { length_cm: length, width_cm: width, height_cm: height },
        p_estimated_delivery_at: new Date(Date.now() + estimateHours * 3600000).toISOString(),
        p_idempotency_key: idempotencyKey, p_metadata: body.metadata ?? {},
      });
      if (error) {
        await primaryAdmin.rpc("finalize_commerce_inventory", {
          p_idempotency_key: idempotencyKey, p_finance_order_id: null, p_commit: false,
        });
        throw error;
      }
      const { error: commitError } = await primaryAdmin.rpc("finalize_commerce_inventory", {
        p_idempotency_key: idempotencyKey, p_finance_order_id: order.id, p_commit: true,
      });
      if (commitError) {
        console.error("Inventory reservation commit requires reconciliation", { orderId: order.id, error: commitError.message });
      }
      return reply({ success: true, order, orderId: order.id, orderNumber: order.order_number, status: order.status, deliveryFeeUgx: deliveryFee, totalUgx: order.total_ugx, message: "Order paid and secured in escrow." });
    }

    if (action === "list_shop_orders") {
      const role = typeof body.role === "string" ? body.role : "customer";
      const column = role === "vendor" ? "vendor_id" : role === "courier" ? "courier_id" : "customer_id";
      const { data, error } = await admin.from("commerce_orders").select("*").eq(column, user.id).order("created_at", { ascending: false }).limit(100);
      if (error) throw error;
      return reply({ success: true, orders: data ?? [] });
    }

    if (action === "get_shop_order") {
      const orderId = requiredString(body.orderId, "orderId");
      const { data: order, error } = await admin.from("commerce_orders").select("*,commerce_order_events(*)").eq("id", orderId).single();
      if (error || !order || ![order.customer_id, order.vendor_id, order.courier_id].includes(user.id)) return reply({ success: false, code: "order_not_found", message: "Order not found." }, 404);
      return reply({ success: true, order });
    }

    if (action === "update_shop_order") {
      const { data, error } = await admin.rpc("transition_commerce_order", {
        p_order_id: requiredString(body.orderId, "orderId"), p_actor_id: user.id,
        p_next_status: requiredString(body.status, "status"), p_message: body.message ?? null,
        p_courier_id: body.courierId ?? null, p_metadata: body.metadata ?? {},
      });
      if (error) throw error;
      return reply({ success: true, order: data, status: data.status });
    }

    if (action === "approve_shop_delivery") {
      const { data, error } = await admin.rpc("release_commerce_escrow", {
        p_order_id: requiredString(body.orderId, "orderId"), p_customer_id: user.id,
      });
      if (error) throw error;
      return reply({ success: true, order: data, status: data.status, message: "Delivery approved and escrow released." });
    }

    if (action === "open_shop_dispute") {
      const orderId = requiredString(body.orderId, "orderId");
      const reason = requiredString(body.reason, "reason");
      const { data: order } = await admin.from("commerce_orders").select("*").eq("id", orderId).single();
      if (!order || ![order.customer_id, order.vendor_id, order.courier_id].includes(user.id)) return reply({ success: false, code: "order_not_found" }, 404);
      const { data, error } = await admin.from("commerce_disputes").insert({ order_id: orderId, opened_by: user.id, reason, evidence: body.evidence ?? [] }).select().single();
      if (error) throw error;
      await admin.from("commerce_orders").update({ status: "disputed", updated_at: new Date().toISOString() }).eq("id", orderId);
      await admin.from("escrows").update({ status: "disputed", updated_at: new Date().toISOString() }).eq("context_type", "commerce_order").eq("context_id", orderId).eq("status", "held");
      return reply({ success: true, dispute: data, status: "disputed" });
    }

    if (action === "submit_shop_review") {
      const orderId = requiredString(body.orderId, "orderId");
      const rating = positiveInteger(body.rating, "rating");
      if (rating > 5) throw new Error("rating must be between 1 and 5");
      const { data: order } = await admin.from("commerce_orders").select("*").eq("id", orderId).eq("customer_id", user.id).eq("status", "completed").single();
      if (!order) return reply({ success: false, code: "review_not_allowed", message: "Only a completed purchase can be reviewed." }, 409);
      const { data, error } = await admin.from("commerce_reviews").insert({ order_id: orderId, listing_id: order.listing_id, customer_id: user.id, vendor_id: order.vendor_id, rating, comment: body.comment ?? null }).select().single();
      if (error) throw error;
      return reply({ success: true, review: data });
    }

    if (action === "send_shop_message") {
      const orderId = requiredString(body.orderId, "orderId");
      const { data: order } = await admin.from("commerce_orders").select("customer_id,vendor_id,courier_id").eq("id", orderId).single();
      if (!order || ![order.customer_id, order.vendor_id, order.courier_id].includes(user.id)) return reply({ success: false, code: "order_not_found" }, 404);
      const messageType = typeof body.messageType === "string" ? body.messageType : "text";
      const content = typeof body.content === "string" ? body.content.trim() : null;
      const attachmentUrl = typeof body.attachmentUrl === "string" ? body.attachmentUrl.trim() : null;
      if (!content && !attachmentUrl) throw new Error("Message content or attachment is required");
      const { data, error } = await admin.from("commerce_order_messages").insert({
        order_id: orderId, sender_id: user.id, message_type: messageType,
        content, attachment_url: attachmentUrl, metadata: body.metadata ?? {},
      }).select().single();
      if (error) throw error;
      return reply({ success: true, message: data });
    }

    if (action === "list_shop_messages") {
      const orderId = requiredString(body.orderId, "orderId");
      const { data: order } = await admin.from("commerce_orders").select("customer_id,vendor_id,courier_id").eq("id", orderId).single();
      if (!order || ![order.customer_id, order.vendor_id, order.courier_id].includes(user.id)) return reply({ success: false, code: "order_not_found" }, 404);
      const { data, error } = await admin.from("commerce_order_messages").select("*").eq("order_id", orderId).order("created_at", { ascending: false }).limit(100);
      if (error) throw error;
      return reply({ success: true, messages: data ?? [] });
    }

    if (action === "list_coin_packs") {
      const { data, error } = await admin.from("coin_packs").select("*").eq("is_active", true).order("sort_order");
      if (error) throw error;
      return reply({ success: true, coinPacks: data });
    }

    if (action === "purchase_coins") {
      const packId = requiredString(body.packId, "packId");
      const method = requiredString(body.method, "method").toLowerCase();
      const idempotencyKey = requiredString(body.idempotencyKey, "idempotencyKey");
      const { data: pack, error: packError } = await admin.from("coin_packs").select("*").eq("id", packId).eq("is_active", true).single();
      if (packError || !pack) return reply({ success: false, code: "pack_not_found", message: "Coin pack is unavailable." }, 404);
      if (method === "fiat_balance") {
        const { data, error } = await admin.rpc("purchase_coins_from_wallet", {
          p_user_id: user.id, p_pack_id: packId, p_idempotency_key: idempotencyKey,
          p_metadata: body.securityMetadata ?? {},
        });
        if (error) throw error;
        return reply({ success: true, paymentId: data.id, status: data.status, ncxAmount: pack.ncx_amount, message: `${pack.ncx_amount} NCX added to your wallet.` });
      }
      if (!["pesapal", "card", "mtn", "airtel"].includes(method)) {
        return reply({ success: false, code: "unsupported_payment_method", message: "Choose wallet balance, card, MTN or Airtel through Pesapal." }, 400);
      }
      const { data: existing } = await admin.from("payments").select("*").eq("user_id", user.id).eq("idempotency_key", idempotencyKey).eq("purpose", "coin_purchase").maybeSingle();
      if (existing) {
        if (existing.status === "completed") {
          return reply({ success: true, paymentId: existing.id, status: "completed", ncxAmount: existing.request?.ncx_amount, message: "Coins are already credited." });
        }
        if (["failed", "cancelled", "refunded"].includes(existing.status)) {
          return reply({ success: false, code: "payment_final", message: "The previous payment attempt ended. Try again to create a new checkout." }, 409);
        }
        if (existing.response?.redirect_url) {
          return reply({ success: true, paymentId: existing.id, status: existing.status, redirectUrl: existing.response.redirect_url, redirect_url: existing.response.redirect_url });
        }
        return reply({ success: false, code: "payment_pending", message: "This payment is still being prepared. Please try again shortly." }, 409);
      }
      const { data: payment, error: paymentError } = await admin.from("payments").insert({
        user_id: user.id, provider: "pesapal", purpose: "coin_purchase",
        amount: pack.fiat_price, currency: pack.fiat_currency, status: "pending",
        idempotency_key: idempotencyKey,
        request: { pack_id: pack.id, ncx_amount: pack.ncx_amount, method, security_metadata: body.securityMetadata ?? {} },
      }).select("*").single();
      if (paymentError) throw paymentError;
      let providerToken: string;
      let notificationId: string;
      try {
        providerToken = await pesapalToken();
        const webhookUrl = `${financeUrl}/functions/v1/finance-payment-webhook`;
        notificationId = await pesapalIpnId(providerToken, webhookUrl);
      } catch (error) {
        await admin.from("payments").update({ status: "failed", response: { initialization_error: error instanceof Error ? error.message : String(error), order_created: false }, updated_at: new Date().toISOString() }).eq("id", payment.id);
        return reply({ success: false, code: "payment_initialization_failed", message: "Pesapal checkout could not be started. Try again." }, 502);
      }

      const callbackBase = Deno.env.get("PESAPAL_CALLBACK_URL") ?? "https://necxa.uk/payment-callback";
      let order: Record<string, any>;
      try {
        order = await submitPesapalOrder(providerToken, {
          id: payment.id, currency: String(pack.fiat_currency), amount: Number(pack.fiat_price).toFixed(2),
          description: `Necxa ${pack.label}`,
          callback_url: `${callbackBase}?paymentId=${payment.id}&purpose=coin_purchase`, notification_id: notificationId,
          billing_address: { email_address: user.email ?? "no-reply@necxa.uk", phone_number: "", country_code: "UG", first_name: user.user_metadata?.first_name ?? "Necxa", last_name: user.user_metadata?.last_name ?? "User", line_1: "Kampala", city: "Kampala" },
        });
      } catch (error) {
        // A SubmitOrder network failure is ambiguous: Pesapal may have created
        // the order before the response was lost. Keep the payment recoverable.
        await admin.from("payments").update({ status: "pending", response: { initialization_error: error instanceof Error ? error.message : String(error), order_state: "unknown" }, updated_at: new Date().toISOString() }).eq("id", payment.id);
        return reply({ success: false, code: "payment_pending", message: "Pesapal may still be preparing this payment. Retry shortly with the same purchase." }, 409);
      }
      const { data: updatedPayment, error: updateError } = await admin.from("payments").update({ status: "processing", provider_reference: order.order_tracking_id, response: order, updated_at: new Date().toISOString() }).eq("id", payment.id).neq("status", "completed").select("status").maybeSingle();
      // The merchant reference is the Supabase payment UUID, so the verified
      // webhook can still recover and complete even if this write fails.
      let persistedStatus = updatedPayment?.status;
      if (!persistedStatus) {
        const { data: current } = await admin.from("payments").select("status").eq("id",payment.id).single();
        persistedStatus=current?.status??"pending";
      }
      return reply({ success: true, paymentId: payment.id, status: persistedStatus, redirectUrl: order.redirect_url, redirect_url: order.redirect_url, ncxAmount: pack.ncx_amount, recoveryPending: Boolean(updateError) });
    }

    if (action === "coin_purchase_status") {
      const paymentId = requiredString(body.paymentId, "paymentId");
      const { data, error } = await admin.from("payments").select("id,status,amount,currency,request,updated_at").eq("id", paymentId).eq("user_id", user.id).eq("purpose", "coin_purchase").single();
      if (error) throw error;
      return reply({ success: true, payment: data, status: data.status });
    }

    if (action === "list_gift_items") {
      const { data, error } = await admin.from("gift_items").select("*").eq("is_active", true).order("sort_order");
      if (error) throw error;
      return reply({ success: true, giftItems: data });
    }

    if (action === "list_live_gifts") {
      const contextId = requiredString(body.contextId, "contextId");
      const { data, error } = await admin.from("gifts")
        .select("id,sender_id,receiver_id,ncx_amount,receiver_ncx,platform_fee_ncx,is_anonymous,metadata,created_at,gift_items(name,emoji,ugx_value)")
        .eq("context_type", "live_stream")
        .eq("context_id", contextId)
        .order("created_at", { ascending: false })
        .limit(30);
      if (error) throw error;
      return reply({ success: true, gifts: (data ?? []).map((gift: Record<string, any>) => ({
        id: gift.id,
        senderId: gift.is_anonymous ? null : gift.sender_id,
        receiverId: gift.receiver_id,
        userName: gift.is_anonymous ? "Anonymous" : (gift.metadata?.sender_name ?? "Viewer"),
        name: gift.gift_items?.name ?? "Gift",
        emoji: gift.gift_items?.emoji ?? "\u{1F381}",
        ncxAmount: gift.ncx_amount,
        receiverNcx: gift.receiver_ncx,
        platformFeeNcx: gift.platform_fee_ncx,
        ugxEquivalent: gift.gift_items?.ugx_value ?? 0,
        createdAt: gift.created_at,
      })) });
    }

    if (action === "initiate_deposit") {
      const amount = positiveInteger(body.amount, "amount");
      if (amount < 500 || amount > 5_000_000) {
        return reply({ success: false, code: "invalid_amount", message: "Deposit must be between UGX 500 and UGX 5,000,000." }, 400);
      }
      const idempotencyKey = requiredString(body.idempotencyKey, "idempotencyKey");
      const phone = typeof body.phone === "string" ? body.phone.replace(/\D/g, "") : "";
      const { data: existing } = await admin.from("payments").select("*").eq("idempotency_key", idempotencyKey).maybeSingle();
      if (existing?.response?.redirect_url) {
        return reply({ success: true, paymentId: existing.id, order_id: existing.id, redirectUrl: existing.response.redirect_url, redirect_url: existing.response.redirect_url, status: existing.status });
      }

      const { data: payment, error: paymentError } = await admin.from("payments").insert({
        user_id: user.id,
        provider: "pesapal",
        purpose: "wallet_deposit",
        amount,
        currency: "UGX",
        status: "pending",
        idempotency_key: idempotencyKey,
        request: { phone, email: user.email ?? null },
      }).select("*").single();
      if (paymentError) throw paymentError;

      try {
        const token = await pesapalToken();
        const webhookUrl = `${financeUrl}/functions/v1/finance-payment-webhook`;
        const notificationId = await pesapalIpnId(token, webhookUrl);
        const callbackBase = Deno.env.get("PESAPAL_CALLBACK_URL") ?? "https://necxa.uk/payment-callback";
        const order = await submitPesapalOrder(token, {
          id: payment.id,
          currency: "UGX",
          amount: amount.toFixed(2),
          description: "Necxa Wallet Deposit",
          callback_url: `${callbackBase}?paymentId=${payment.id}`,
          notification_id: notificationId,
          billing_address: {
            email_address: user.email ?? "no-reply@necxa.uk",
            phone_number: phone,
            country_code: "UG",
            first_name: user.user_metadata?.first_name ?? "Necxa",
            last_name: user.user_metadata?.last_name ?? "User",
            line_1: "Kampala",
            city: "Kampala",
          },
        });
        const { error: updateError } = await admin.from("payments").update({
          status: "processing",
          provider_reference: order.order_tracking_id,
          response: order,
          updated_at: new Date().toISOString(),
        }).eq("id", payment.id);
        if (updateError) throw updateError;
        return reply({ success: true, paymentId: payment.id, order_id: payment.id, orderTrackingId: order.order_tracking_id, redirectUrl: order.redirect_url, redirect_url: order.redirect_url, status: "processing" });
      } catch (error) {
        await admin.from("payments").update({ status: "failed", response: { error: error instanceof Error ? error.message : String(error) }, updated_at: new Date().toISOString() }).eq("id", payment.id);
        throw error;
      }
    }

    if (action === "deposit_status") {
      const paymentId = requiredString(body.paymentId, "paymentId");
      const { data, error } = await admin.from("payments").select("id,status,amount,currency,updated_at").eq("id", paymentId).eq("user_id", user.id).eq("purpose", "wallet_deposit").single();
      if (error) throw error;
      return reply({ success: true, payment: data, status: data.status });
    }

    if (action === "send_withdrawal_otp") {
      if (!user.email) return reply({ success: false, code: "email_required", message: "Add a verified email before withdrawing." }, 400);
      const resendKey = Deno.env.get("RESEND_API_KEY");
      const otpPepper = Deno.env.get("WITHDRAWAL_OTP_PEPPER");
      if (!resendKey || !otpPepper) throw new Error("Withdrawal verification is not configured");
      const code = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
      const padded = code.toString().padStart(6, "0");
      const codeHash = await sha256(`${user.id}:${padded}:${otpPepper}`);
      const { error } = await admin.from("withdrawal_otps").upsert({
        user_id: user.id, code_hash: codeHash,
        expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
        attempts: 0, consumed_at: null, created_at: new Date().toISOString(),
      });
      if (error) throw error;
      const emailResponse = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: "Necxa Finance <no-reply@necxa.uk>", to: [user.email], subject: "Your Necxa withdrawal code", text: `Your withdrawal verification code is ${padded}. It expires in 10 minutes.` }),
      });
      if (!emailResponse.ok) {
        await admin.from("withdrawal_otps").delete().eq("user_id", user.id);
        throw new Error("Unable to send withdrawal verification email");
      }
      return reply({ success: true, message: "Verification code sent." });
    }

    if (action === "request_withdrawal") {
      const amount = positiveInteger(body.amount, "amount");
      const method = requiredString(body.method, "method").toLowerCase();
      const destination = requiredString(body.accountNumber, "accountNumber");
      const recipientName = requiredString(body.recipientName, "recipientName");
      const emailOtp = requiredString(body.emailOtp, "emailOtp");
      const securityMetadata = body.securityMetadata as Record<string, unknown> | undefined;
      if (!securityMetadata?.device_id || securityMetadata.lat == null) {
        throw new Error("Device and location verification are required");
      }
      const otpPepper = Deno.env.get("WITHDRAWAL_OTP_PEPPER");
      if (!otpPepper) throw new Error("Withdrawal verification is not configured");
      if (destination.replace(/\D/g, "").length < 9) throw new Error("A valid payout account is required");
      const otpHash = await sha256(`${user.id}:${emailOtp}:${otpPepper}`);
      const { data: otp, error: otpError } = await admin.from("withdrawal_otps").select("*").eq("user_id", user.id).single();
      if (otpError || !otp || otp.consumed_at || new Date(otp.expires_at) < new Date() || otp.attempts >= 5) {
        throw new Error("Withdrawal code is invalid or expired");
      }
      if (otp.code_hash !== otpHash) {
        await admin.from("withdrawal_otps").update({ attempts: otp.attempts + 1 }).eq("user_id", user.id);
        throw new Error("Withdrawal code is invalid or expired");
      }
      const ciphertext = await encryptDestination(destination);
      const { data, error } = await admin.rpc("create_withdrawal_request", {
        p_user_id: user.id, p_amount: amount, p_method: method,
        p_destination_ciphertext: ciphertext, p_recipient_name: recipientName,
        p_otp_hash: otpHash, p_idempotency_key: requiredString(body.idempotencyKey, "idempotencyKey"),
        p_metadata: securityMetadata,
      });
      if (error) throw error;
      return reply({ success: true, withdrawal: data, withdrawalId: data.id, status: data.workflow_status, message: "Withdrawal initiated and awaiting team review." });
    }

    if (action === "withdrawal_status") {
      const withdrawalId = requiredString(body.withdrawalId, "withdrawalId");
      const { data, error } = await admin.from("withdrawals").select("id,amount,currency,method,workflow_status,provider_reference,created_at,updated_at").eq("id", withdrawalId).eq("user_id", user.id).single();
      if (error) throw error;
      return reply({ success: true, withdrawal: data, status: data.workflow_status });
    }

    if (action === "send_gift") {
      const receiverId = requiredString(body.receiverId, "receiverId");
      const contextType = requiredString(body.contextType, "contextType");
      const contextId = requiredString(body.contextId, "contextId");
      const idempotencyKey = requiredString(body.idempotencyKey, "idempotencyKey");
      const giftItemId=requiredString(body.giftItemId,"giftItemId");
      const { data: giftItem, error: itemError }=await admin.from("gift_items").select("*").eq("id",giftItemId).eq("is_active",true).single();
      if(itemError||!giftItem)return reply({success:false,code:"gift_unavailable",message:"Gift item is unavailable."},404);
      const { data, error } = await admin.rpc("process_gift", {
        p_sender_id: user.id,
        p_receiver_id: receiverId,
        p_gift_item_id: giftItemId,
        p_context_type: contextType,
        p_context_id: contextId,
        p_ncx_amount: positiveInteger(body.ncxAmount, "ncxAmount"),
        p_fee_basis_points: 2000,
        p_is_anonymous: body.isAnonymous === true,
        p_idempotency_key: idempotencyKey,
        p_metadata: {
          ...((body.metadata && typeof body.metadata === "object") ? body.metadata as Record<string, unknown> : {}),
          sender_name: user.user_metadata?.display_name ?? user.user_metadata?.full_name ?? "Viewer",
        },
      });
      if (error) throw error;
      return reply({success:true,gift:data,giftId:data.id,giftEmoji:giftItem.emoji,giftName:giftItem.name,
        ncxAmount:data.ncx_amount,receiverNcx:data.receiver_ncx,platformFeeNcx:data.platform_fee_ncx,
        ugxEquivalent:giftItem.ugx_value,isHighlighted:data.ncx_amount>=100,
        message:`${giftItem.name} sent successfully.`});
    }

    if (action === "liquidate") {
      const { data, error } = await admin.rpc("liquidate_ncx", {
        p_user_id: user.id,
        p_ncx_amount: positiveInteger(body.ncxAmount, "ncxAmount"),
        p_ugx_per_ncx: 100,
        p_burn_basis_points: 1100,
        p_idempotency_key: requiredString(body.idempotencyKey, "idempotencyKey"),
        p_metadata: body.securityMetadata ?? {},
      });
      if (error) throw error;
      return reply({ success: true, wallet: data });
    }

    if (action === "get_config") {
      const keys = Array.isArray(body.keys) ? body.keys.filter((v): v is string => typeof v === "string") : [];
      const { data, error } = await admin.from("finance_config").select("key,value").in("key", keys);
      if (error) throw error;
      return reply({ success: true, config: Object.fromEntries((data ?? []).map((row) => [row.key, row.value])) });
    }

    return reply({ success: false, code: "unknown_action", message: `Unsupported finance action: ${action}` }, 400);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const insufficient = message.toLowerCase().includes("insufficient");
    return reply({
      success: false,
      code: insufficient ? "insufficient_funds" : "finance_error",
      message,
    }, insufficient ? 409 : 400);
  }
});
