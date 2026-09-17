import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Environment ────────────────────────────────────────────────────────────
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PESAPAL_CONSUMER_KEY = Deno.env.get("PESAPAL_CONSUMER_KEY")?.trim() || "";
const PESAPAL_CONSUMER_SECRET = Deno.env.get("PESAPAL_CONSUMER_SECRET")?.trim() || "";
const PESAPAL_ENV = Deno.env.get("PESAPAL_ENVIRONMENT")?.trim() || "sandbox";
const PESAPAL_IPN_ID = Deno.env.get("PESAPAL_IPN_ID")?.trim() || ""; // set after IPN registration
// This must be a dedicated secret. A service-role key must never double as an
// OTP signing key because rotating either secret would invalidate the other.
const COMMERCE_OTP_SECRET = Deno.env.get("COMMERCE_OTP_SECRET")?.trim() || "";
const PRIMARY_SUPABASE_URL = Deno.env.get("PRIMARY_SUPABASE_URL")?.trim() ||
  Deno.env.get("SUPABASE_AUTH_URL")?.trim() || Deno.env.get("AUTH_PROJECT_URL")?.trim() || "";
const PRIMARY_SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("PRIMARY_SUPABASE_SERVICE_ROLE_KEY")?.trim() || "";
const GIFT_PROJECTION_RECONCILIATION_SECRET =
  Deno.env.get("GIFT_PROJECTION_RECONCILIATION_SECRET")?.trim() || "";

const PESAPAL_BASE = PESAPAL_ENV === "production"
  ? "https://pay.pesapal.com/v3"
  : "https://cybqa.pesapal.com/pesapalv3";

// MTN Disbursement config
const MTN_DISBURSEMENT_ENV = Deno.env.get("MTN_DISBURSEMENT_ENV")?.trim() || "sandbox";
const MTN_BASE = MTN_DISBURSEMENT_ENV === "production"
  ? "https://momodeveloper.mtn.com/disbursement"
  : "https://sandbox.momodeveloper.mtn.com/disbursement";
// MTN calls these an API user and API key. The older CLIENT_ID/CLIENT_SECRET
// names remain as a temporary compatibility fallback during credential rollout.
const MTN_API_USER = Deno.env.get("MTN_DISBURSEMENT_API_USER")?.trim() ||
  Deno.env.get("MTN_DISBURSEMENT_CLIENT_ID")?.trim() || "";
const MTN_API_KEY = Deno.env.get("MTN_DISBURSEMENT_API_KEY")?.trim() ||
  Deno.env.get("MTN_DISBURSEMENT_CLIENT_SECRET")?.trim() || "";
const MTN_SUBSCRIPTION_KEY = Deno.env.get("MTN_DISBURSEMENT_SUBSCRIPTION_KEY")?.trim() ||
  Deno.env.get("mtn primary key")?.trim() || Deno.env.get("mtn secondary key")?.trim() || "";
const MTN_TARGET_ENV = Deno.env.get("MTN_DISBURSEMENT_TARGET_ENV")?.trim() || (MTN_DISBURSEMENT_ENV === 'production' ? 'production' : 'sandbox');
const MTN_RECONCILIATION_SECRET = Deno.env.get("MTN_RECONCILIATION_SECRET")?.trim() || "";
const WITHDRAWAL_DESTINATION_ENCRYPTION_KEY = Deno.env.get("WITHDRAWAL_DESTINATION_ENCRYPTION_KEY")?.trim() || "";

async function getMtnAccessToken(): Promise<string> {
  if (!MTN_API_USER || !MTN_API_KEY || !MTN_SUBSCRIPTION_KEY) {
    throw new Error('MTN disbursement credentials are not configured');
  }
  const tokenUrl = `${MTN_BASE}/token/`;
  const body = new URLSearchParams({ grant_type: 'client_credentials' });
  const basic = btoa(`${MTN_API_USER}:${MTN_API_KEY}`);
  const res = await fetch(tokenUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Authorization': `Basic ${basic}`,
      'Ocp-Apim-Subscription-Key': MTN_SUBSCRIPTION_KEY,
    },
    body: body.toString(),
  });
  if (!res.ok) {
    const txt = await res.text().catch(() => '');
    throw new Error(`MTN token fetch failed: ${res.status} ${txt}`);
  }
  const data = await res.json().catch(() => ({}));
  if (!data.access_token) throw new Error('MTN token response missing access_token');
  return String(data.access_token);
}

async function makeMtnDeposit(token: string, withdrawal: Record<string, any>, amount: number, msisdn: string) {
  const url = `${MTN_BASE}/v2_0/deposit`;
  const externalId = withdrawal.id ?? `wd-${Date.now()}`;
  const referenceId = crypto.randomUUID();
  const payload = {
    amount: String(amount),
    currency: 'UGX',
    externalId,
    payee: { partyIdType: 'MSISDN', partyId: msisdn },
    payerMessage: 'Necxa withdrawal',
    payeeNote: 'Necxa payout',
  };
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`,
      'Ocp-Apim-Subscription-Key': MTN_SUBSCRIPTION_KEY,
      'X-Target-Environment': MTN_TARGET_ENV,
      'X-Reference-Id': referenceId,
    },
    body: JSON.stringify(payload),
  });
  const responseText = await res.text();
  const response = responseText ? JSON.parse(responseText) : {};
  // MTN disbursements are asynchronous. 202 means only that the request was
  // accepted, not that the recipient has received the funds.
  if (res.status !== 202) {
    throw new Error(`MTN deposit failed: ${res.status} ${JSON.stringify(response)}`);
  }
  return { accepted: true, referenceId, statusCode: res.status, response };
}

async function getMtnDepositStatus(token: string, referenceId: string) {
  const url = `${MTN_BASE}/v1_0/deposit/${encodeURIComponent(referenceId)}`;
  const res = await fetch(url, {
    headers: {
      'Authorization': `Bearer ${token}`,
      'Ocp-Apim-Subscription-Key': MTN_SUBSCRIPTION_KEY,
      'X-Target-Environment': MTN_TARGET_ENV,
    },
  });
  const responseText = await res.text();
  const response = responseText ? JSON.parse(responseText) : {};
  if (!res.ok) throw new Error(`MTN deposit status failed: ${res.status} ${JSON.stringify(response)}`);
  return response as Record<string, unknown>;
}

function base64UrlToBytes(value: string): Uint8Array {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function bytesToBase64Url(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function encryptWithdrawalDestination(destination: Record<string, string>): Promise<string> {
  if (!WITHDRAWAL_DESTINATION_ENCRYPTION_KEY) {
    throw new Error("WITHDRAWAL_DESTINATION_ENCRYPTION_KEY is not configured.");
  }
  const rawKey = base64UrlToBytes(WITHDRAWAL_DESTINATION_ENCRYPTION_KEY);
  if (rawKey.length !== 32) {
    throw new Error("WITHDRAWAL_DESTINATION_ENCRYPTION_KEY must be a base64url-encoded 32-byte key.");
  }
  const key = await crypto.subtle.importKey("raw", rawKey, { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    new TextEncoder().encode(JSON.stringify(destination)),
  ));
  return `v1.${bytesToBase64Url(iv)}.${bytesToBase64Url(encrypted)}`;
}

// Redirect URL after payment — deep links back to the app
const CALLBACK_URL = "https://www.necxa.uk/payment-callback";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-mtn-reconciliation-secret, x-gift-projection-reconciliation-secret",
};

const GIFT_CATALOGUE = [
  { id: "rose", name: "Rose", emoji: "🌹", ncx_value: 1, ugx_value: 100, category: "standard", sort_order: 1, is_active: true },
  { id: "clap", name: "Clap", emoji: "👏", ncx_value: 2, ugx_value: 200, category: "standard", sort_order: 2, is_active: true },
  { id: "heart", name: "Heart", emoji: "❤️", ncx_value: 3, ugx_value: 300, category: "standard", sort_order: 3, is_active: true },
  { id: "coffee", name: "Coffee", emoji: "☕", ncx_value: 5, ugx_value: 500, category: "standard", sort_order: 4, is_active: true },
  { id: "star", name: "Star", emoji: "⭐", ncx_value: 5, ugx_value: 500, category: "standard", sort_order: 5, is_active: true },
  { id: "fire", name: "Fire", emoji: "🔥", ncx_value: 10, ugx_value: 1000, category: "standard", sort_order: 6, is_active: true },
  { id: "rocket", name: "Rocket", emoji: "🚀", ncx_value: 20, ugx_value: 2000, category: "standard", sort_order: 7, is_active: true },
  { id: "crown", name: "Crown", emoji: "👑", ncx_value: 25, ugx_value: 2500, category: "standard", sort_order: 8, is_active: true },
  { id: "diamond", name: "Diamond", emoji: "💎", ncx_value: 50, ugx_value: 5000, category: "premium", sort_order: 9, is_active: true },
  { id: "trophy", name: "Trophy", emoji: "🏆", ncx_value: 50, ugx_value: 5000, category: "premium", sort_order: 10, is_active: true },
  { id: "money_bag", name: "Money Bag", emoji: "💰", ncx_value: 100, ugx_value: 10000, category: "premium", sort_order: 11, is_active: true },
  { id: "sports_car", name: "Sports Car", emoji: "🏎️", ncx_value: 200, ugx_value: 20000, category: "premium", sort_order: 12, is_active: true },
  { id: "yacht", name: "Yacht", emoji: "🛥️", ncx_value: 500, ugx_value: 50000, category: "premium", sort_order: 13, is_active: true },
  { id: "mansion", name: "Mansion", emoji: "🏰", ncx_value: 1000, ugx_value: 100000, category: "premium", sort_order: 14, is_active: true },
  { id: "jet", name: "Private Jet", emoji: "✈️", ncx_value: 1500, ugx_value: 150000, category: "premium", sort_order: 15, is_active: true },
  { id: "globe", name: "Globe", emoji: "🌍", ncx_value: 5000, ugx_value: 500000, category: "epic", sort_order: 16, is_active: true },
  { id: "stadium", name: "Stadium", emoji: "🏟️", ncx_value: 10000, ugx_value: 1000000, category: "epic", sort_order: 17, is_active: true },
  { id: "ressort", name: "Ressort", emoji: "🎢", ncx_value: 50000, ugx_value: 5000000, category: "legendary", sort_order: 18, is_active: true },
] as const;

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

type PesapalStatus = "PENDING" | "COMPLETED" | "FAILED";

function mapPesapalStatus(statusData: Record<string, unknown>): PesapalStatus {
  const description = String(
    statusData.payment_status_description ?? statusData.status_code ?? "",
  ).toUpperCase();
  if (description.includes("COMPLETED") || statusData.status_code === 1) return "COMPLETED";
  if (
    description.includes("FAILED") ||
    description.includes("INVALID") ||
    statusData.status_code === 2
  ) return "FAILED";
  return "PENDING";
}

function commerceLifecycleUnavailable(message: string): boolean {
  const value = message.toLowerCase();
  return value.includes("fund_commerce_order_from_external_payment") ||
    value.includes("commerce_escrows") ||
    value.includes("commerce_delivery_jobs") ||
    value.includes("settlement_status") ||
    value.includes("schema cache");
}

async function confirmExternallyHeldCommerceOrder(
  financeClient: ReturnType<typeof createClient>,
  order: Record<string, any>,
  payment: Record<string, any>,
  statusData: Record<string, unknown>,
) {
  const { error: inventoryError } = await financeClient.rpc("finalize_commerce_inventory", {
    p_idempotency_key: `${payment.idempotency_key}-inv`,
    p_finance_order_id: order.id,
    p_commit: true,
  });
  if (inventoryError) {
    throw new Error(`Inventory confirmation failed: ${inventoryError.message}`);
  }

  const metadata = (order.metadata ?? {}) as Record<string, unknown>;
  const { error: orderUpdateError } = await financeClient.from("commerce_orders").update({
    payment_status: "COMPLETED",
    status: "confirmed",
    metadata: {
      ...metadata,
      payment_verified_at: new Date().toISOString(),
      payment_provider: "pesapal",
      payment_provider_reference: payment.provider_reference,
      payment_verification: statusData,
      funds_state: "external_held_pending_lifecycle",
    },
    updated_at: new Date().toISOString(),
  }).eq("id", order.id);
  if (orderUpdateError) {
    throw new Error(`Order confirmation failed: ${orderUpdateError.message}`);
  }
}

async function settleVerifiedPesapalPayment(
  financeClient: ReturnType<typeof createClient>,
  payment: Record<string, any>,
  statusData: Record<string, unknown>,
): Promise<PesapalStatus> {
  const mappedStatus = mapPesapalStatus(statusData);
  const providerStatus = String(
    statusData.payment_status_description ?? statusData.status_code ?? mappedStatus,
  ).toUpperCase();

  if (mappedStatus === "PENDING") {
    const { error } = await financeClient.from("payments").update({
      provider_status: providerStatus,
      provider_response: statusData,
      last_checked_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", payment.id);
    if (error) throw new Error(`Payment status update failed: ${error.message}`);
    return mappedStatus;
  }

  if (mappedStatus === "FAILED") {
    const paymentRequest = (payment.request ?? {}) as Record<string, unknown>;
    if (String(paymentRequest.type ?? "") === "shop_purchase") {
      const { data: order } = await financeClient
        .from("commerce_orders")
        .select("id, listing_id")
        .eq("payment_id", payment.idempotency_key)
        .maybeSingle();
      if (order) {
        await financeClient.from("commerce_orders").update({
          payment_status: "FAILED",
          status: "cancelled",
          cancelled_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        }).eq("id", order.id);
        const { error: inventoryError } = await financeClient.rpc("finalize_commerce_inventory", {
          p_idempotency_key: `${payment.idempotency_key}-inv`,
          p_finance_order_id: null,
          p_commit: false,
        });
        if (inventoryError) throw new Error(inventoryError.message);
        await mirrorFinanceInventoryToPrimary(financeClient, String(order.listing_id));
      }
    }
    const { error: failedPaymentError } = await financeClient.from("payments").update({
      status: "failed",
      provider_status: providerStatus,
      provider_response: statusData,
      last_checked_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", payment.id).is("settled_at", null);
    if (failedPaymentError) {
      throw new Error(`Failed payment update failed: ${failedPaymentError.message}`);
    }
    return mappedStatus;
  }

  const paymentRequest = (payment.request ?? {}) as Record<string, unknown>;
  const paymentType = String(paymentRequest.type ?? "wallet_deposit");

  if (paymentType === "wallet_deposit" || paymentType === "coin_purchase") {
    const { error } = await financeClient.rpc("settle_pesapal_wallet_payment", {
      p_payment_id: payment.id,
      p_provider_status: providerStatus,
      p_provider_response: statusData,
    });
    if (error) throw new Error(`Wallet settlement failed: ${error.message}`);
    try {
      await mirrorUserWalletSnapshotToPrimary(financeClient, String(payment.user_id));
    } catch (snapshotError) {
      console.error("Post-settlement profile finance sync failed:", snapshotError);
    }
    return mappedStatus;
  }

  if (paymentType === "shop_purchase") {
    const { data: order, error: orderError } = await financeClient
      .from("commerce_orders")
      .select("id, listing_id, payment_method, metadata")
      .eq("payment_id", payment.idempotency_key)
      .single();
    if (orderError || !order) throw new Error(orderError?.message ?? "Shop order not found.");
    const { error: fundingError } = await financeClient.rpc("fund_commerce_order_from_external_payment", {
      p_order_id: order.id,
      p_payment_id: payment.idempotency_key,
      p_funding_source: order.payment_method === "card" ? "card" : "pesapal",
    });
    if (fundingError) {
      if (!commerceLifecycleUnavailable(fundingError.message)) {
        throw new Error(fundingError.message);
      }
      // Compatibility path for the currently deployed legacy commerce schema.
      // PesaPal is verified server-to-server, stock is committed, and the order
      // becomes visible, but no vendor payout is released without escrow tables.
      await confirmExternallyHeldCommerceOrder(financeClient, order, payment, statusData);
    }
    await mirrorFinanceInventoryToPrimary(financeClient, String(order.listing_id));
    const { error: completedPaymentError } = await financeClient.from("payments").update({
      status: "completed",
      provider_status: providerStatus,
      provider_response: statusData,
      last_checked_at: new Date().toISOString(),
      settled_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", payment.id);
    if (completedPaymentError) {
      throw new Error(`Completed payment update failed: ${completedPaymentError.message}`);
    }
    return mappedStatus;
  }

  throw new Error(`Unsupported PesaPal payment type: ${paymentType}`);
}

async function findPesapalPayment(
  financeClient: ReturnType<typeof createClient>,
  orderTrackingId: string,
  merchantReference?: string | null,
) {
  if (merchantReference) {
    const { data, error } = await financeClient
      .from("payments")
      .select("*")
      .eq("idempotency_key", merchantReference)
      .maybeSingle();
    if (error) throw new Error(error.message);
    if (data) return data;
  }

  const { data, error } = await financeClient
    .from("payments")
    .select("*")
    .eq("provider", "pesapal")
    .eq("provider_reference", orderTrackingId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data;
}

async function reconcilePesapalReference(
  financeClient: ReturnType<typeof createClient>,
  orderTrackingId: string,
  merchantReference?: string | null,
) {
  const token = await getPesapalToken();
  const statusData = await getPesapalTransactionStatus(token, orderTrackingId) as Record<string, unknown>;
  const verifiedReference = String(statusData.merchant_reference ?? merchantReference ?? "");
  const payment = await findPesapalPayment(financeClient, orderTrackingId, verifiedReference);
  if (!payment) throw new Error("Payment record not found for PesaPal transaction.");
  const status = await settleVerifiedPesapalPayment(financeClient, payment, statusData);
  return { payment, status, statusData };
}

async function reconcileUserPesapalPayments(
  financeClient: ReturnType<typeof createClient>,
  userId: string,
) {
  const { data: payments, error } = await financeClient
    .from("payments")
    .select("*")
    .eq("user_id", userId)
    .eq("provider", "pesapal")
    .not("provider_reference", "is", null)
    .is("settled_at", null)
    .in("status", ["pending", "completed"])
    .order("created_at", { ascending: false })
    .limit(10);
  if (error) throw new Error(error.message);
  if (!payments?.length) return { checked: 0, settled: 0 };

  const token = await getPesapalToken();
  let settled = 0;
  for (const payment of payments) {
    try {
      const statusData = await getPesapalTransactionStatus(
        token,
        String(payment.provider_reference),
      ) as Record<string, unknown>;
      const status = await settleVerifiedPesapalPayment(financeClient, payment, statusData);
      if (status === "COMPLETED") settled += 1;
    } catch (error) {
      console.error(`PesaPal recovery failed for payment ${payment.id}:`, error);
    }
  }
  return { checked: payments.length, settled };
}

async function reconcileSellerPesapalPayments(
  financeClient: ReturnType<typeof createClient>,
  sellerId: string,
) {
  const { data: orders, error: ordersError } = await financeClient
    .from("commerce_orders")
    .select("payment_id")
    .eq("seller_id", sellerId)
    .eq("payment_status", "PENDING")
    .not("payment_id", "is", null)
    .order("created_at", { ascending: false })
    .limit(10);
  if (ordersError) throw new Error(ordersError.message);

  const paymentIds = [...new Set((orders ?? []).map((order) => String(order.payment_id)).filter(Boolean))];
  if (paymentIds.length === 0) return { checked: 0, settled: 0 };

  const { data: payments, error: paymentsError } = await financeClient
    .from("payments")
    .select("*")
    .eq("provider", "pesapal")
    .in("idempotency_key", paymentIds)
    .not("provider_reference", "is", null);
  if (paymentsError) throw new Error(paymentsError.message);
  if (!payments?.length) return { checked: 0, settled: 0 };

  const token = await getPesapalToken();
  let settled = 0;
  for (const payment of payments) {
    try {
      const statusData = await getPesapalTransactionStatus(
        token,
        String(payment.provider_reference),
      ) as Record<string, unknown>;
      const status = await settleVerifiedPesapalPayment(financeClient, payment, statusData);
      if (status === "COMPLETED") settled += 1;
    } catch (error) {
      console.error(`Seller PesaPal recovery failed for payment ${payment.id}:`, error);
    }
  }
  return { checked: payments.length, settled };
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
  if (!COMMERCE_OTP_SECRET) throw new Error("COMMERCE_OTP_SECRET is not configured.");
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

async function hmacSha256Hex(message: string): Promise<string> {
  if (!COMMERCE_OTP_SECRET) throw new Error("COMMERCE_OTP_SECRET is not configured.");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(COMMERCE_OTP_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message)));
  return Array.from(signature).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function createWithdrawalOtp(): string {
  const bytes = new Uint32Array(1);
  crypto.getRandomValues(bytes);
  return String(bytes[0] % 1000000).padStart(6, "0");
}

function normalizeUgandanMsisdn(value: string): string | null {
  let digits = value.replace(/[^0-9+]/g, "");
  if (digits.startsWith("+")) digits = digits.slice(1);
  if (digits.startsWith("0")) digits = `256${digits.slice(1)}`;
  return /^256\d{9}$/.test(digits) ? digits : null;
}

function mtnProviderOutcome(response: Record<string, unknown>): "paid" | "failed" | "pending" {
  const status = String(
    response.status ?? response.financialTransactionStatus ?? response.statusCode ?? "",
  ).toUpperCase();
  if (["SUCCESSFUL", "SUCCESS", "COMPLETED"].includes(status)) return "paid";
  if (["FAILED", "FAILURE", "REJECTED", "CANCELLED"].includes(status)) return "failed";
  return "pending";
}

async function reconcileMtnWithdrawal(
  financeClient: ReturnType<typeof createClient>,
  withdrawal: Record<string, any>,
  accessToken?: string,
): Promise<Record<string, any>> {
  if (withdrawal.method !== "mtn" || withdrawal.workflow_status !== "processing" || !withdrawal.provider_reference) {
    return withdrawal;
  }

  const providerResponse = await getMtnDepositStatus(
    accessToken ?? await getMtnAccessToken(),
    String(withdrawal.provider_reference),
  );
  const metadata = { ...(withdrawal.metadata ?? {}), provider_status_response: providerResponse };
  const { error: metadataError } = await financeClient
    .from("withdrawals")
    .update({ metadata })
    .eq("id", withdrawal.id);
  if (metadataError) throw new Error(`Could not record MTN status: ${metadataError.message}`);

  const outcome = mtnProviderOutcome(providerResponse);
  if (outcome === "paid") {
    const { error } = await financeClient.rpc("transition_withdrawal_status", {
      p_withdrawal_id: withdrawal.id,
      p_new_status: "paid",
      p_operator_id: "mtn-status-reconciliation",
      p_provider_reference: withdrawal.provider_reference,
    });
    if (error) throw new Error(error.message);
  } else if (outcome === "failed") {
    const { error: transitionError } = await financeClient.rpc("transition_withdrawal_status", {
      p_withdrawal_id: withdrawal.id,
      p_new_status: "failed",
      p_operator_id: "mtn-status-reconciliation",
      p_note: JSON.stringify(providerResponse),
    });
    if (transitionError) throw new Error(transitionError.message);
    const { error: refundError } = await financeClient.rpc("refund_failed_withdrawal", {
      p_withdrawal_id: withdrawal.id,
      p_reason: "MTN marked the disbursement as failed.",
    });
    if (refundError) throw new Error(refundError.message);
  }

  const { data: refreshed, error: refreshError } = await financeClient
    .from("withdrawals")
    .select("*")
    .eq("id", withdrawal.id)
    .single();
  if (refreshError) throw new Error(refreshError.message);
  return refreshed ?? withdrawal;
}

async function reconcilePendingMtnWithdrawals(financeClient: ReturnType<typeof createClient>) {
  const { data: withdrawals, error } = await financeClient
    .from("withdrawals")
    .select("*")
    .eq("method", "mtn")
    .eq("workflow_status", "processing")
    .not("provider_reference", "is", null)
    .order("updated_at", { ascending: true })
    .limit(50);
  if (error) throw new Error(error.message);
  if (!withdrawals?.length) return { checked: 0, reconciled: 0, errors: 0 };

  const accessToken = await getMtnAccessToken();
  let reconciled = 0;
  let errors = 0;
  for (const withdrawal of withdrawals) {
    try {
      await reconcileMtnWithdrawal(financeClient, withdrawal, accessToken);
      reconciled += 1;
    } catch (error) {
      errors += 1;
      console.error(`MTN reconciliation failed for withdrawal ${withdrawal.id}:`, error);
    }
  }
  return { checked: withdrawals.length, reconciled, errors };
}

function isValidWithdrawalOtp(value: string): boolean {
  return /^\d{6}$/.test(String(value ?? "").trim());
}

async function queueWithdrawalOtpDelivery(userEmail: string, otp: string): Promise<void> {
  const deliveryProvider = Deno.env.get("OTP_DELIVERY_PROVIDER")?.trim().toLowerCase();
  const resendApiKey = Deno.env.get("RESEND_API_KEY")?.trim();
  const fromEmail = Deno.env.get("OTP_FROM_EMAIL")?.trim();
  if (deliveryProvider !== "resend" || !resendApiKey || !fromEmail) {
    throw new Error("Withdrawal OTP delivery requires OTP_DELIVERY_PROVIDER=resend, RESEND_API_KEY, and OTP_FROM_EMAIL.");
  }

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: fromEmail,
      to: [userEmail],
      subject: "Your Necxa withdrawal code",
      text: `Your Necxa withdrawal code is ${otp}. It expires in 10 minutes. Do not share this code.`,
    }),
  });
  if (!response.ok) {
    throw new Error(`Withdrawal OTP email could not be sent: ${response.status} ${await response.text()}`);
  }
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
async function mirrorWalletSnapshotToPrimary(wallet: Record<string, unknown>) {
  if (!PRIMARY_SUPABASE_URL || !PRIMARY_SUPABASE_SERVICE_ROLE_KEY) {
    return { synced: false, reason: "primary_finance_sync_not_configured" };
  }

  const primaryAdmin = createClient(
    PRIMARY_SUPABASE_URL,
    PRIMARY_SUPABASE_SERVICE_ROLE_KEY,
  );
  const syncedAt = new Date().toISOString();
  const { error } = await primaryAdmin.from("profile_finance_snapshots").upsert({
    user_id: wallet.user_id,
    finance_wallet_id: wallet.id,
    fiat_balance: wallet.fiat_balance ?? 0,
    coin_balance: wallet.coin_balance ?? 0,
    escrow_balance: wallet.escrow_balance ?? 0,
    total_earned: wallet.total_earned ?? 0,
    total_spent: wallet.total_spent ?? 0,
    finance_updated_at: wallet.updated_at ?? null,
    synced_at: syncedAt,
    source_project: "supabase2",
  }, { onConflict: "user_id" });
  if (error) {
    throw new Error(`Primary finance snapshot sync failed: ${error.message}`);
  }
  return { synced: true, syncedAt };
}

async function mirrorUserWalletSnapshotToPrimary(
  financeClient: ReturnType<typeof createClient>,
  userId: string,
) {
  const { data: wallet, error } = await financeClient
    .from("wallets")
    .select("id, user_id, fiat_balance, coin_balance, escrow_balance, total_earned, total_spent, updated_at")
    .eq("user_id", userId)
    .single();
  if (error || !wallet) {
    throw new Error(error?.message ?? "Finance wallet not found for profile sync.");
  }
  return await mirrorWalletSnapshotToPrimary(wallet);
}

async function syncCommunityGiftToPrimary(
  financeGiftId: string,
  senderId: string,
  receiverId: string,
  postId: string,
  giftItemId: string,
  ncxAmount: number,
  receiverNcx: number,
  platformFeeNcx: number,
  idempotencyKey: string,
  metadata: Record<string, unknown>,
) {
  if (!PRIMARY_SUPABASE_URL || !PRIMARY_SUPABASE_SERVICE_ROLE_KEY) {
    return { synced: false, reason: "primary_community_sync_not_configured" };
  }
  const primaryAdmin = createClient(
    PRIMARY_SUPABASE_URL,
    PRIMARY_SUPABASE_SERVICE_ROLE_KEY,
  );
  const { data, error } = await primaryAdmin.rpc("record_community_gift", {
    p_finance_gift_id: financeGiftId,
    p_post_id: postId,
    p_sender_id: senderId,
    p_receiver_id: receiverId,
    p_gift_item_id: giftItemId,
    p_ncx_amount: ncxAmount,
    p_receiver_ncx: receiverNcx,
    p_platform_fee_ncx: platformFeeNcx,
    p_idempotency_key: idempotencyKey,
    p_metadata: metadata,
    p_context_type: metadata.context_type || "creator_post",
  });
  if (error) throw new Error(`Primary community gift sync failed: ${error.message}`);
  return { synced: true, result: data };
}

async function completeGiftProjection(
  financeClient: ReturnType<typeof createClient>,
  financeGiftId: string,
  success: boolean,
  errorMessage?: string,
) {
  const { error } = await financeClient.rpc("complete_gift_projection", {
    p_finance_gift_id: financeGiftId,
    p_success: success,
    p_error: errorMessage ?? null,
  });
  if (error) throw new Error(`Gift projection status update failed: ${error.message}`);
}

async function reconcileGiftProjections(
  financeClient: ReturnType<typeof createClient>,
  limit = 50,
) {
  const { data: projections, error } = await financeClient.rpc(
    "claim_gift_projection_batch",
    { p_limit: limit },
  );
  if (error) throw new Error(`Gift projection claim failed: ${error.message}`);

  let synced = 0;
  let failed = 0;
  for (const projection of (projections ?? []) as Record<string, unknown>[]) {
    const financeGiftId = String(projection.finance_gift_id ?? "");
    try {
      const metadata = {
        ...((projection.metadata ?? {}) as Record<string, unknown>),
        ugx_value: Number(projection.ugx_value ?? 0),
        context_type: String(projection.context_type ?? ""),
      };
      const syncResult = await syncCommunityGiftToPrimary(
        financeGiftId,
        String(projection.sender_id),
        String(projection.receiver_id),
        String(projection.context_id),
        String(projection.gift_item_id),
        Number(projection.ncx_amount),
        Number(projection.receiver_ncx),
        Number(projection.platform_fee_ncx),
        String(projection.idempotency_key),
        metadata,
      );
      if (!syncResult.synced) {
        throw new Error(String(syncResult.reason ?? "Community sync is not configured."));
      }
      await completeGiftProjection(financeClient, financeGiftId, true);
      synced += 1;
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : "Gift projection failed.";
      console.error(`Gift projection ${financeGiftId} failed:`, error);
      try {
        await completeGiftProjection(financeClient, financeGiftId, false, message);
      } catch (statusError) {
        console.error(`Unable to persist gift projection failure ${financeGiftId}:`, statusError);
      }
    }
  }
  return { claimed: (projections ?? []).length, synced, failed };
}

type PrimaryAuthUser = {
  id: string;
  email?: string | null;
  phone?: string | null;
  user_metadata?: Record<string, unknown>;
};

async function syncPrimaryIdentityToFinance(
  primaryClient: ReturnType<typeof createClient>,
  financeClient: ReturnType<typeof createClient>,
  user: PrimaryAuthUser,
) {
  // Auth is the identity authority. The public profile is optional enrichment:
  // a missing profile row or a temporarily stale profile schema must never
  // make an authenticated user's canonical finance wallet unavailable.
  const { data: primaryProfile, error: profileError } = await primaryClient
    .from("profiles")
    .select("id, email, phone, full_name, avatar_url")
    .eq("id", user.id)
    .maybeSingle();
  if (profileError) {
    console.error("Deferred primary profile enrichment:", profileError.message);
  }

  const metadata = user.user_metadata ?? {};
  const syncedAt = new Date().toISOString();
  const email = primaryProfile?.email ?? user.email ?? null;
  const displayName = primaryProfile?.full_name ?? metadata.full_name ?? metadata.name ?? null;

  // This SECURITY DEFINER function performs an idempotent finance-user and
  // wallet upsert in one short transaction. It preserves every existing
  // balance and closes the first-login race between simultaneous clients.
  const { error: walletProvisionError } = await financeClient.rpc(
    "ensure_finance_wallet",
    {
      p_user_id: user.id,
      p_email: email,
      p_display_name: displayName,
    },
  );
  if (walletProvisionError) {
    throw new Error(`Finance wallet provisioning failed: ${walletProvisionError.message}`);
  }

  // Some commerce tables still use the legacy profile projection. Keep it in
  // sync when available, but do not couple a wallet read to this projection.
  const financeProfile = {
    id: user.id,
    email,
    phone: primaryProfile?.phone ?? user.phone ?? null,
    full_name: displayName,
    avatar_url: primaryProfile?.avatar_url ?? metadata.avatar_url ?? null,
    updated_at: syncedAt,
  };
  const { error: financeProfileError } = await financeClient
    .from("profiles")
    .upsert(financeProfile, { onConflict: "id" });
  if (financeProfileError) {
    console.error("Deferred legacy finance profile projection:", financeProfileError.message);
  }

  return {
    source: "supabase1",
    target: "supabase2",
    userId: user.id,
    syncedAt,
    profileEnriched: !profileError,
    legacyProfileProjected: !financeProfileError,
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
  const urlObj = new URL(req.url);
  let providerPayload: Record<string, unknown> = {};
  if (req.method === "POST" && req.headers.get("content-type")?.includes("application/json")) {
    providerPayload = await req.clone().json().catch(() => ({}));
  }
  const orderTrackingId = urlObj.searchParams.get("OrderTrackingId") ||
    urlObj.searchParams.get("orderTrackingId") ||
    String(providerPayload.OrderTrackingId ?? providerPayload.orderTrackingId ?? "");
  const orderMerchantRef = urlObj.searchParams.get("OrderMerchantReference") ||
    urlObj.searchParams.get("orderMerchantReference") ||
    urlObj.searchParams.get("paymentId") ||
    String(providerPayload.OrderMerchantReference ?? providerPayload.orderMerchantReference ?? "");
  const notificationType = urlObj.searchParams.get("OrderNotificationType") ||
    String(providerPayload.OrderNotificationType ?? providerPayload.orderNotificationType ?? "IPNCHANGE");

  // Provider callbacks do not carry a NECXA user session. Pesapal is queried
  // directly before one replay-safe financial effect is applied.
  if (orderTrackingId) {
    try {
      const result = await reconcilePesapalReference(supabase, orderTrackingId, orderMerchantRef);
      return json({
        orderNotificationType: notificationType || "IPNCHANGE",
        orderTrackingId,
        orderMerchantReference: result.payment.idempotency_key,
        status: 200,
      });
    } catch (ipnErr) {
      console.error("IPN handler error:", ipnErr);
      return json({
        orderNotificationType: notificationType || "IPNCHANGE",
        orderTrackingId,
        orderMerchantReference: orderMerchantRef,
        status: 500,
      }, 500);
    }
  }

  // Called by a protected scheduler every few minutes. MTN sends transaction
  // results asynchronously, so user-driven polling alone is not sufficient to
  // settle or refund every payout.
  if (
    req.method === "POST" &&
    MTN_RECONCILIATION_SECRET &&
    req.headers.get("x-mtn-reconciliation-secret") === MTN_RECONCILIATION_SECRET
  ) {
    try {
      return json({ success: true, ...(await reconcilePendingMtnWithdrawals(supabase)) });
    } catch (reconciliationError) {
      console.error("Scheduled MTN reconciliation failed:", reconciliationError);
      return json({
        success: false,
        message: reconciliationError instanceof Error ? reconciliationError.message : "MTN reconciliation failed.",
      }, 500);
    }
  }

  if (
    req.method === "POST" &&
    GIFT_PROJECTION_RECONCILIATION_SECRET &&
    req.headers.get("x-gift-projection-reconciliation-secret") ===
      GIFT_PROJECTION_RECONCILIATION_SECRET
  ) {
    try {
      const limit = Number(urlObj.searchParams.get("limit") ?? "50");
      return json({
        success: true,
        ...(await reconcileGiftProjections(supabase, limit)),
      });
    } catch (reconciliationError) {
      console.error("Scheduled gift projection reconciliation failed:", reconciliationError);
      return json({
        success: false,
        message: reconciliationError instanceof Error
          ? reconciliationError.message
          : "Gift projection reconciliation failed.",
      }, 500);
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

  let identitySync: Record<string, unknown>;
  try {
    identitySync = await syncPrimaryIdentityToFinance(
      userSupabase,
      supabase,
      user,
    );
  } catch (error) {
    console.error("Cross-project identity sync failed:", error);
    return json({
      success: false,
      code: "identity_sync_failed",
      message: "Your finance account could not be synchronized.",
    }, 503);
  }

  const syncCommerceListing = async (listingId: string, forceStock = false) => {
    // SP1 owns listings. Checkout only requires the columns shared by both
    // projects. Selecting one optional shipping column that is absent from a
    // live SP1 schema makes PostgREST reject the whole row and used to be
    // misreported below as "Listing not found".
    const commerceListingFields =
      "id,title,price,stock_count,status,user_id,lister_id,category,media_url";
    const { data: userListing, error: userListingError } = await userSupabase
      .from("listings")
      .select(commerceListingFields)
      .eq("id", listingId)
      .maybeSingle();
    let sourceListing = userListing as Record<string, unknown> | null;

    if (!sourceListing) {
      const authAnonClient = createClient(AUTH_PROJECT_URL, AUTH_PROJECT_ANON_KEY);
      const { data: publicListing, error: publicListingError } = await authAnonClient
        .from("listings")
        .select(commerceListingFields)
        .eq("id", listingId)
        .maybeSingle();
      sourceListing = publicListing as Record<string, unknown> | null;
      if (!sourceListing && userListingError && publicListingError) {
        throw new Error(`Could not load listing: ${userListingError.message}`);
      }
    }

    if (!sourceListing) return null;
    const sellerId = (sourceListing.user_id ?? sourceListing.lister_id) as string | null | undefined;
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
    // SP2 needs a stable minimal projection for checkout. Keeping optional SP1
    // shipping/display fields out also supports an older SP2 schema safely.
    const financeListing = {
      id: sourceListing.id,
      title: sourceListing.title ?? null,
      price: sourceListing.price ?? 0,
      status: sourceListing.status ?? "active",
      user_id: sourceListing.user_id ?? null,
      lister_id: sourceListing.lister_id ?? null,
      category: sourceListing.category ?? null,
      media_url: sourceListing.media_url ?? null,
      stock_count: forceStock || !existingFinanceListing
        ? Number(sourceListing.stock_count ?? 0)
        : existingFinanceListing.stock_count,
    };
    const { error: syncError } = await supabase.from("listings").upsert(financeListing, { onConflict: "id" });
    if (syncError) throw new Error(`Could not synchronize listing: ${syncError.message}`);
    return financeListing as Record<string, unknown>;
  };

  const attachCommerceDetails = async (
    orders: Record<string, unknown>[],
    includeParticipantContact = false,
  ) => {
    if (orders.length === 0) return [];
    const orderIds = orders.map((order) => String(order.id));
    const participantIds = new Set<string>();
    const listingIds = new Set<string>();
    for (const order of orders) {
      participantIds.add(String(order.buyer_id));
      participantIds.add(String(order.seller_id));
      listingIds.add(String(order.listing_id));
    }

    const [{ data: deliveries }, { data: escrows }, { data: settlements }, { data: listings }] = await Promise.all([
      supabase.from("commerce_delivery_jobs").select("*").in("order_id", orderIds),
      supabase.from("commerce_escrows").select("*").in("order_id", orderIds),
      supabase.from("commerce_settlements").select("*").in("order_id", orderIds),
      supabase.from("listings").select("id,title,media_url").in("id", [...listingIds]),
    ]);
    for (const delivery of deliveries ?? []) {
      if (delivery.driver_id) participantIds.add(String(delivery.driver_id));
    }

    const { data: profiles } = await userSupabase
      .from("profiles")
      .select(includeParticipantContact
        ? "id, full_name, username, avatar_url, phone"
        : "id, full_name, username, avatar_url")
      .in("id", [...participantIds]);
    const profileById = new Map((profiles ?? []).map((profile) => [String(profile.id), profile]));
    const deliveryByOrder = new Map((deliveries ?? []).map((delivery) => [String(delivery.order_id), delivery]));
    const escrowByOrder = new Map((escrows ?? []).map((escrow) => [String(escrow.order_id), escrow]));
    const listingById = new Map((listings ?? []).map((listing) => [String(listing.id), listing]));

    return orders.map((order) => {
      const metadata = (order.metadata ?? {}) as Record<string, unknown>;
      const listing = listingById.get(String(order.listing_id));
      return {
        ...order,
        product_title: order.product_title ?? metadata.product_title ?? listing?.title ?? "Product",
        product_media_url: order.product_media_url ?? metadata.product_media_url ?? listing?.media_url ?? null,
        delivery: deliveryByOrder.get(String(order.id)) ?? null,
        escrow: escrowByOrder.get(String(order.id)) ?? null,
        settlements: (settlements ?? []).filter((settlement) => String(settlement.order_id) === String(order.id)),
        buyer: profileById.get(String(order.buyer_id)) ?? null,
        seller: profileById.get(String(order.seller_id)) ?? null,
        driver: deliveryByOrder.get(String(order.id))?.driver_id
          ? profileById.get(String(deliveryByOrder.get(String(order.id))!.driver_id)) ?? null
          : null,
      };
    });
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

      if (existingPayment && String(existingPayment.status).toLowerCase() === "completed") {
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
      const { error: paymentRecordError } = await supabase.from("payments").upsert({
        user_id: user.id,
        provider: "pesapal",
        provider_reference: orderResult.order_tracking_id,
        idempotency_key: idempotencyKey,
        purpose: "wallet_deposit",
        amount: amountUgx,
        currency: "UGX",
        status: "pending",
        request: {
          amount: amountUgx,
          currency: "UGX",
          type: "wallet_deposit",
          phone: userPhone,
          orderId,
        },
        response: orderResult,
      }, { onConflict: "idempotency_key" });
      if (paymentRecordError) {
        throw new Error(`Deposit payment record failed: ${paymentRecordError.message}`);
      }

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
        .select("*")
        .eq("idempotency_key", paymentId)
        .eq("user_id", user.id)
        .single();

      if (payErr || !payment) {
        return json({ success: false, message: "Payment not found." }, 404);
      }

      // Completion is final only after the atomic settlement marker exists.
      if (payment.settled_at) {
        return json({ success: true, status: "completed" });
      }
      if (String(payment.status).toLowerCase() === "failed") {
        return json({ success: true, status: payment.status.toLowerCase() });
      }

      const token = await getPesapalToken();
      const statusData = await getPesapalTransactionStatus(
        token,
        payment.provider_reference,
      ) as Record<string, unknown>;
      const mappedStatus = await settleVerifiedPesapalPayment(supabase, payment, statusData);
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
          metadata: {
            order_tracking_id: orderResult.order_tracking_id,
            product_title: listing.title,
            product_media_url: listing.media_url,
          },
        }, { onConflict: "idempotency_key" })
        .select("id, order_number")
        .single();

      if (orderErr) {
        await supabase.rpc("finalize_commerce_inventory", {
          p_idempotency_key: idempotencyKey + "-inv",
          p_finance_order_id: null,
          p_commit: false,
        });
        throw new Error(orderErr.message);
      }

      // Also upsert a payments row for the pesapal-ipn webhook to find
      const { error: paymentRecordError } = await supabase.from("payments").upsert({
        user_id: user.id,
        provider: "pesapal",
        provider_reference: orderResult.order_tracking_id,
        idempotency_key: idempotencyKey,
        purpose: "shop_purchase",
        amount: totalUgx,
        currency: "UGX",
        status: "pending",
        request: { amount: totalUgx, currency: "UGX", type: "shop_purchase", listingId, quantity },
        response: orderResult,
      }, { onConflict: "idempotency_key" });
      if (paymentRecordError) {
        throw new Error(`Shop payment record failed: ${paymentRecordError.message}`);
      }

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
        .select("*")
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

      if (payment.settled_at) {
        return json({ success: true, status: "completed" });
      }
      if (String(payment.status).toLowerCase() === "failed") {
        return json({ success: true, status: "failed" });
      }

      const token = await getPesapalToken();
      const statusData = await getPesapalTransactionStatus(
        token,
        payment.provider_reference,
      ) as Record<string, unknown>;
      const mappedStatus = await settleVerifiedPesapalPayment(supabase, payment, statusData);

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
      try {
        await reconcileSellerPesapalPayments(supabase, user.id);
      } catch (reconciliationError) {
        console.error("Vendor payment reconciliation failed:", reconciliationError);
      }

      const syncCursor = new Date().toISOString();
      const requestedCursor = body.updatedSince ? String(body.updatedSince) : null;
      const updatedSince = requestedCursor && !Number.isNaN(Date.parse(requestedCursor))
        ? requestedCursor
        : null;
      const listingOwnerFilter = `user_id.eq.${user.id},lister_id.eq.${user.id}`;
      let listingsQuery = userSupabase
        .from("listings")
        .select("id, title, media_url, price, stock_count, status, created_at, updated_at")
        .or(listingOwnerFilter)
        .order(updatedSince ? "updated_at" : "created_at", { ascending: false })
        .limit(300);
      if (updatedSince) {
        listingsQuery = listingsQuery.gt("updated_at", updatedSince).lte("updated_at", syncCursor);
      }

      const [listingsResult, activeListingsResult, lowStockResult] = await Promise.all([
        listingsQuery,
        userSupabase
          .from("listings")
          .select("id", { count: "exact", head: true })
          .or(listingOwnerFilter)
          .eq("status", "active"),
        userSupabase
          .from("listings")
          .select("id", { count: "exact", head: true })
          .or(listingOwnerFilter)
          .lte("stock_count", 5),
      ]);
      if (listingsResult.error) throw new Error(listingsResult.error.message);
      if (activeListingsResult.error) throw new Error(activeListingsResult.error.message);
      if (lowStockResult.error) throw new Error(lowStockResult.error.message);
      const inventoryListings = (listingsResult.data ?? []) as Record<string, unknown>[];

      const { data: orders, error: ordersError } = await supabase
        .from("commerce_orders")
        .select("id, status, payment_status, unit_price_ugx, quantity, created_at, updated_at")
        .eq("seller_id", user.id)
        .order("created_at", { ascending: false });
      if (ordersError) throw new Error(ordersError.message);

      const { data: recentOrders, error: recentOrdersError } = await supabase
        .from("commerce_orders")
        .select("*")
        .eq("seller_id", user.id)
        .order("created_at", { ascending: false })
        .limit(10);
      if (recentOrdersError) throw new Error(recentOrdersError.message);

      const { data: settlementRows, error: settlementsError } = await supabase
        .from("commerce_settlements")
        .select("net_amount_ugx, status, created_at")
        .eq("beneficiary_id", user.id)
        .eq("beneficiary_type", "seller");
      let settlements = settlementRows ?? [];
      if (settlementsError) {
        if (!commerceLifecycleUnavailable(settlementsError.message)) {
          throw new Error(settlementsError.message);
        }
        console.warn("Commerce settlement table is not installed; showing orders without payout totals.");
        settlements = [];
      }

      const { data: lifecycleReviews, error: reviewsError } = await supabase
        .from("commerce_reviews")
        .select("rating")
        .eq("seller_id", user.id)
        .eq("status", "published");
      let reviews = lifecycleReviews ?? [];
      if (reviewsError && commerceLifecycleUnavailable(reviewsError.message)) {
        const compatibilityReviews = await supabase
          .from("commerce_reviews")
          .select("rating")
          .eq("vendor_id", user.id);
        if (compatibilityReviews.error) throw new Error(compatibilityReviews.error.message);
        reviews = compatibilityReviews.data ?? [];
      } else if (reviewsError) {
        throw new Error(reviewsError.message);
      }

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
      const ratingCount = reviews.length;
      const ratingAverage = ratingCount === 0
        ? 0
        : reviews.reduce((total, review) => total + Number(review.rating), 0) / ratingCount;

      return json({
        success: true,
        isDelta: updatedSince !== null,
        syncCursor,
        dashboard: {
          activeListings: activeListingsResult.count ?? 0,
          lowStockListings: lowStockResult.count ?? 0,
          totalOrders: sellerOrders.length,
          openOrders: sellerOrders.filter((order) => !["completed", "cancelled", "refunded"].includes(order.status)).length,
          grossSalesUgx,
          releasedEarningsUgx,
          heldEarningsUgx,
          ratingAverage,
          ratingCount,
          listings: inventoryListings,
          recentOrders: await attachCommerceDetails((recentOrders ?? []) as Record<string, unknown>[]),
        },
      });
    }

    if (action === "list_commerce_orders") {
      const role = String(body.role ?? "buyer");
      const limit = Math.max(1, Math.min(50, Number(body.limit) || 20));
      const cursor = body.cursor ? String(body.cursor) : null;
      const syncCursor = new Date().toISOString();
      const requestedUpdateCursor = body.updatedSince ? String(body.updatedSince) : null;
      const updatedSince = requestedUpdateCursor && !Number.isNaN(Date.parse(requestedUpdateCursor))
        ? requestedUpdateCursor
        : null;
      if (!["buyer", "seller", "driver"].includes(role)) {
        return json({ success: false, message: "Invalid order role." }, 400);
      }

      if (role === "seller") {
        try {
          await reconcileSellerPesapalPayments(supabase, user.id);
        } catch (reconciliationError) {
          console.error("Seller order reconciliation failed:", reconciliationError);
        }
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
          .order(updatedSince ? "updated_at" : "created_at", { ascending: false })
          .limit(updatedSince ? 200 : limit + 1);
        if (updatedSince) {
          query = query.gt("updated_at", updatedSince).lte("updated_at", syncCursor);
        } else if (cursor) {
          query = query.lt("created_at", cursor);
        }
        const { data, error } = await query;
        if (error) throw new Error(error.message);
        orders = (data ?? []) as Record<string, unknown>[];
      }

      orders.sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
      const hasMore = updatedSince === null && orders.length > limit;
      const page = updatedSince ? orders : orders.slice(0, limit);
      const detailedOrders = await attachCommerceDetails(page);
      const roleSafeOrders = await Promise.all(detailedOrders.map(async (order) => ({
        ...order,
        pickupCode: role === "seller" ? await commerceVerificationCode(String(order.id), "pickup") : null,
        deliveryCode: role === "buyer" ? await commerceVerificationCode(String(order.id), "delivery") : null,
      })));

      return json({
        success: true,
        orders: roleSafeOrders,
        syncCursor,
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

      const [detailedOrder] = await attachCommerceDetails([order], true);
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
      const syncCursor = new Date().toISOString();
      const requestedUpdateCursor = body.updatedSince ? String(body.updatedSince) : null;
      const updatedSince = requestedUpdateCursor && !Number.isNaN(Date.parse(requestedUpdateCursor))
        ? requestedUpdateCursor
        : null;
      let query = supabase
        .from("commerce_reviews")
        .select("id, listing_id, buyer_id, rating, comment, media_urls, seller_response, seller_responded_at, created_at, updated_at")
        .eq("seller_id", user.id)
        .eq("status", "published")
        .order(updatedSince ? "updated_at" : "created_at", { ascending: false })
        .limit(updatedSince ? 100 : limit + 1);
      if (updatedSince) {
        query = query.gt("updated_at", updatedSince).lte("updated_at", syncCursor);
      } else if (cursor) {
        query = query.lt("created_at", cursor);
      }
      const { data: lifecycleReviews, error: reviewsError } = await query;
      let reviews = (lifecycleReviews ?? []) as Record<string, unknown>[];
      let compatibilitySchema = false;
      if (reviewsError) {
        if (!commerceLifecycleUnavailable(reviewsError.message)) {
          throw new Error(reviewsError.message);
        }
        compatibilitySchema = true;
        let compatibilityQuery = supabase
          .from("commerce_reviews")
          .select("id, listing_id, customer_id, vendor_id, rating, comment, created_at")
          .eq("vendor_id", user.id)
          .order("created_at", { ascending: false })
          .limit(updatedSince ? 100 : limit + 1);
        if (updatedSince) {
          compatibilityQuery = compatibilityQuery.gt("created_at", updatedSince).lte("created_at", syncCursor);
        } else if (cursor) {
          compatibilityQuery = compatibilityQuery.lt("created_at", cursor);
        }
        const { data: compatibilityReviews, error: compatibilityError } = await compatibilityQuery;
        if (compatibilityError) throw new Error(compatibilityError.message);
        reviews = (compatibilityReviews ?? []).map((review) => ({
          ...review,
          buyer_id: review.customer_id,
          seller_id: review.vendor_id,
          media_urls: [],
          seller_response: null,
          seller_responded_at: null,
          updated_at: review.created_at,
        }));
      }
      const page = updatedSince ? reviews : reviews.slice(0, limit);
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
        syncCursor,
        compatibilitySchema,
        nextCursor: updatedSince === null && reviews.length > limit
          ? page[page.length - 1]?.created_at ?? null
          : null,
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
      const { data: coinPacks, error } = await supabase
        .from("coin_packs")
        .select("*")
        .eq("is_active", true)
        .order("sort_order", { ascending: true });
      if (error) {
        // Fallback to hardcoded list if table doesn't exist yet
        return json({
          success: true,
          coinPacks: [
            { id: "spark",   ncx_amount: 10,   fiat_price: 1000,   fiat_currency: "UGX", color_hex: "#64FFDA", emoji: "⚡", name: "Spark Pack",   tagline: "Try it out" },
            { id: "starter", ncx_amount: 50,   fiat_price: 5000,   fiat_currency: "UGX", color_hex: "#00E5FF", emoji: "🌟", name: "Starter Pack", tagline: "Get started" },
            { id: "pro",     ncx_amount: 150,  fiat_price: 15000,  fiat_currency: "UGX", color_hex: "#2979FF", emoji: "🔵", name: "Pro Pack",     tagline: "Most popular" },
            { id: "elite",   ncx_amount: 500,  fiat_price: 50000,  fiat_currency: "UGX", color_hex: "#D500F9", emoji: "💜", name: "Elite Pack",   tagline: "Power user" },
            { id: "whale",   ncx_amount: 1200, fiat_price: 100000, fiat_currency: "UGX", color_hex: "#FFC400", emoji: "🐋", name: "Whale Pack",   tagline: "Go all in" },
          ],
        });
      }
      return json({ success: true, coinPacks });
    }

    // ── Action: purchase_coins ──────────────────────────────────────────────
    if (action === "purchase_coins") {
      const packId = body.packId as string;
      const { data: packRecord, error: packError } = await supabase
        .from("coin_packs")
        .select("ncx_amount, fiat_price")
        .eq("id", packId)
        .single();
      if (packError || !packRecord) {
        return json({ success: false, message: "Invalid pack ID." }, 400);
      }
      const pack = { ncx: Number(packRecord.ncx_amount), fiat: Number(packRecord.fiat_price) };
      const method = body.method as string;
      const idempotencyKey = (body.idempotencyKey as string) || `coin-purchase-${user.id}-${Date.now()}`;

      // Prevent double purchase
      const { data: existingPayment } = await supabase
        .from("payments")
        .select("id, status")
        .eq("idempotency_key", idempotencyKey)
        .maybeSingle();

      if (existingPayment && String(existingPayment.status).toLowerCase() === "completed") {
        return json({ success: false, message: "Purchase already processed." }, 409);
      }

      if (!pack) return json({ success: false, message: "Invalid pack selected." }, 400);

      // If fiat_balance, atomically deduct and credit NCX
      if (method === "fiat_balance") {
        const { data: rpcResult, error } = await supabase.rpc("buy_coins_with_fiat_balance", {
          p_user_auth_id:    user.id,
          p_fiat_amount:     pack.fiat,
          p_ncx_to_receive:  pack.ncx,
          p_fiat_currency:   "UGX",
          p_idempotency_key: idempotencyKey,
          p_payment_id:      null,
          p_issuance_type:   "WALLET_PURCHASE",
          p_metadata:        { pack_id: packId, method },
        });

        if (error) {
          const isInsufficient = error.message?.toLowerCase().includes("insufficient");
          return json(
            { success: false, code: isInsufficient ? "insufficient_balance" : "failed", message: error.message },
            isInsufficient ? 402 : 500
          );
        }

        // Record a completed payment for idempotency tracking
        const { error: paymentRecordError } = await supabase.from("payments").upsert({
          user_id:            user.id,
          provider:           "wallet_balance",
          provider_reference: idempotencyKey,
          idempotency_key:    idempotencyKey,
          purpose:            "coin_purchase",
          amount:             pack.fiat,
          currency:           "UGX",
          status:             "completed",
          settled_at:         new Date().toISOString(),
          request:            { type: "coin_purchase", packId, method },
          response:           rpcResult ?? { success: true },
        }, { onConflict: "idempotency_key" });
        if (paymentRecordError) {
          throw new Error(`Wallet coin payment record failed: ${paymentRecordError.message}`);
        }

        return json({
          success:          true,
          issuanceId:       rpcResult?.issuance_id        ?? null,
          originHash:       rpcResult?.origin_hash        ?? null,
          coinBalanceAfter: rpcResult?.coin_balance_after ?? null,
          fiatBalanceAfter: rpcResult?.fiat_balance_after ?? null,
        });
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

        const { error: paymentRecordError } = await supabase.from("payments").upsert({
          user_id: user.id,
          provider: "pesapal",
          provider_reference: orderResult.order_tracking_id,
          idempotency_key: idempotencyKey,
          purpose: "coin_purchase",
          amount: pack.fiat,
          currency: "UGX",
          status: "pending",
          request: { type: "coin_purchase", packId, method, ncxAmount: pack.ncx, fiatAmount: pack.fiat },
          response: orderResult,
        }, { onConflict: "idempotency_key" });
        if (paymentRecordError) {
          throw new Error(`PesaPal coin payment record failed: ${paymentRecordError.message}`);
        }

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
        .select("*")
        .eq("idempotency_key", paymentId)
        .eq("user_id", user.id)
        .single();

      if (!payment) return json({ success: false, message: "Payment not found." }, 404);

      if (payment.settled_at) {
        return json({ success: true, status: "completed" });
      }
      if (String(payment.status).toLowerCase() === "failed") {
        return json({ success: true, status: payment.status.toLowerCase() });
      }

      const token = await getPesapalToken();
      const statusData = await getPesapalTransactionStatus(
        token,
        payment.provider_reference,
      ) as Record<string, unknown>;
      const mappedStatus = await settleVerifiedPesapalPayment(supabase, payment, statusData);
      return json({ success: true, status: mappedStatus.toLowerCase() });
    }

    // ── Action: list_gift_items ──────────────────────────────────────────────
    if (action === "list_gift_items") {
      const { data: giftItems, error } = await supabase
        .from("gift_items")
        .select("*")
        .eq("is_active", true)
        .order("sort_order", { ascending: true });
      if (error) throw new Error(error.message);
      return json({ success: true, giftItems });
    }

    // ── Action: send_gift ────────────────────────────────────────────────────
    if (action === "send_gift") {
      const receiverId = body.receiverId as string;
      const giftItemId = body.giftItemId as string;
      const ncxAmount = Number(body.ncxAmount) || 0;
      const contextType = body.contextType as string;
      const contextId = body.contextId as string; // The post ID or live stream ID
      const contextNote = body.contextNote as string;
      const isAnonymous = Boolean(body.isAnonymous);
      const idempotencyKey = (body.idempotencyKey as string) || `gift-${user.id}-${Date.now()}`;
      const metadata = (body.metadata ?? {}) as Record<string, unknown>;
      const supportedContextTypes = new Set([
        "direct",
        "creator_post",
        "listing",
        "live_stream",
        "live",
      ]);
      if (!supportedContextTypes.has(contextType)) {
        return json({ success: false, message: "Unsupported gift context." }, 400);
      }
      if (!receiverId || !giftItemId || !contextId || ncxAmount <= 0) {
        return json({ success: false, message: "Gift recipient, item, context, and amount are required." }, 400);
      }
      const isLiveGift = contextType === "live_stream" || contextType === "live";
      const { data: feeConfig } = await supabase
        .from("finance_config")
        .select("value")
        .eq("key", "gift_platform_fee_basis_points")
        .maybeSingle();
      const configuredFeeBasisPoints = Number(
        (feeConfig?.value as Record<string, unknown> | null)?.basis_points ?? 1100,
      );
      const giftFeeBasisPoints = Number.isInteger(configuredFeeBasisPoints) &&
          configuredFeeBasisPoints >= 0 &&
          configuredFeeBasisPoints <= 10000
        ? configuredFeeBasisPoints
        : 1100;
      const giftFeeRate = giftFeeBasisPoints / 10000;
      const effectiveGiftFeeRate = isLiveGift ? 0.11 : giftFeeRate;
      const rpcName = isLiveGift ? "process_live_gift_ncx" : "process_gift_ncx";
      const rpcPayload = isLiveGift
        ? {
            p_sender_auth_id: user.id,
            p_receiver_auth_id: receiverId,
            p_channel_id: contextId,
            p_ncx_amount: ncxAmount,
            p_gift_platform_fee_rate: effectiveGiftFeeRate,
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
            p_gift_platform_fee_rate: effectiveGiftFeeRate,
            p_gift_details: {
              gift_item_id: giftItemId,
              context_type: contextType,
              context_note: contextNote,
              is_anonymous: isAnonymous,
              idempotency_key: idempotencyKey,
              sender_name: isAnonymous ? "Anonymous" : (metadata.sender_name || user.email || "Viewer"),
              sender_avatar: isAnonymous ? "" : (metadata.sender_avatar || ""),
            },
          };

      const { data, error } = await supabase.rpc(rpcName, rpcPayload);

      if (error) {
        const message = error.message || "Gift transaction failed.";
        const normalizedMessage = message.toLowerCase();
        if (normalizedMessage.includes("insufficient ncx") ||
            normalizedMessage.includes("insufficient balance")) {
          return json({
            success: false,
            code: "insufficient_funds",
            message: "Insufficient NCX balance.",
          }, 402);
        }
        return json({ success: false, code: "gift_failed", message }, 400);
      }

      // The RPC returns { success, message, platform_fee_paid, receiver_amount_credited }
      // Due to how Supabase returns tabular RPCs it's an array of length 1
      const resData = Array.isArray(data) ? data[0] : data;
      if (resData && resData.success === false) {
        return json({ success: false, message: resData.message }, 400);
      }

      const { data: giftDef } = await supabase
        .from("gift_items")
        .select("name, emoji, ugx_value")
        .eq("id", giftItemId)
        .maybeSingle();
      const receiverNcx = Number(resData?.receiver_amount_credited);
      const platformFeeNcx = Number(resData?.platform_fee_paid);
      if (!giftDef || !Number.isFinite(receiverNcx) || !Number.isFinite(platformFeeNcx)) {
        return json({ success: false, message: "Finance returned an incomplete gift settlement." }, 502);
      }
      const financeGiftId = resData?.gift_id?.toString();
      let communitySync: Record<string, unknown> = { synced: false, reason: "not_supported_context" };
      if ((contextType === "creator_post" || contextType === "listing") && contextId && financeGiftId && !contextId.startsWith("direct")) {
        try {
          communitySync = await syncCommunityGiftToPrimary(
            financeGiftId,
            user.id,
            receiverId,
            contextId,
            giftItemId,
            ncxAmount,
            receiverNcx,
            platformFeeNcx,
            idempotencyKey,
            { ...metadata, context_type: contextType, ugx_value: Number(giftDef.ugx_value) },
          );
          if (!communitySync.synced) {
            throw new Error(String(communitySync.reason ?? "Community sync is not configured."));
          }
          try {
            await completeGiftProjection(supabase, financeGiftId, true);
          } catch (statusError) {
            // Projection success must remain visible even while the optional
            // finance-side status migration is rolling out.
            console.error("Unable to persist community sync success:", statusError);
          }
        } catch (syncError) {
          // Finance remains authoritative; a failed social projection must be
          // observable without turning a completed debit into a false failure.
          console.error(syncError);
          if (financeGiftId) {
            try {
              await completeGiftProjection(
                supabase,
                financeGiftId,
                false,
                syncError instanceof Error ? syncError.message : "Community sync failed.",
              );
            } catch (statusError) {
              console.error("Unable to persist community sync failure:", statusError);
            }
          }
          communitySync = { synced: false, reason: "sync_failed" };
        }
      }

      return json({
        success: true,
        giftId: resData?.gift_id || idempotencyKey,
        giftEmoji: giftDef?.emoji || "🎁",
        giftName: giftDef?.name || "Gift",
        ncxAmount: ncxAmount,
        receiverNcx,
        platformFeeNcx,
        ugxEquivalent: Number(giftDef.ugx_value),
        isHighlighted: ncxAmount >= 50,
        communitySynced: communitySync.synced,
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
      const leaderboard = [...totalsBySender.values()]
        .sort((a, b) => b.amount - a.amount)
        .slice(0, 10)
        .map((entry, index) => ({ ...entry, rank: index + 1 }));
      const topGifter = leaderboard[0] ?? null;
      const milestones = [100, 500, 1000, 5000, 10000, 25000, 50000, 100000];
      const goalTarget = milestones.find(value => value > totalAmount)
        ?? Math.ceil((totalAmount + 1) / 100000) * 100000;

      return json({
        success: true,
        gifts: formatted,
        summary: { totalAmount, goalTarget, topGifter, leaderboard },
      });
    }

    // ── Action: get_wallet ───────────────────────────────────────────────────
    // Returns the current wallet for the authenticated user.
    // Called by Flutter _syncVault() every time the UI needs to refresh balances.
    if (action === "get_wallet") {
      // Recover delayed IPNs and payments completed while the app was closed.
      // Reconciliation is a recovery enhancement. Provider or legacy-schema
      // trouble must not suppress a valid locally committed wallet balance.
      let reconciliation: Record<string, unknown>;
      try {
        reconciliation = await reconcileUserPesapalPayments(supabase, user.id);
      } catch (reconciliationError) {
        console.error("Deferred wallet payment reconciliation:", reconciliationError);
        reconciliation = { checked: 0, settled: 0, deferred: true };
      }

      const { data: wallet, error: walletErr } = await supabase
        .from("wallets")
        .select("*")
        .eq("user_id", user.id)
        .single();

      if (walletErr || !wallet) {
        return json({ success: false, message: "Wallet not found." }, 404);
      }

      let profileFinanceSync: Record<string, unknown>;
      try {
        profileFinanceSync = await mirrorWalletSnapshotToPrimary(wallet);
      } catch (snapshotError) {
        console.error("Profile finance snapshot sync failed:", snapshotError);
        profileFinanceSync = { synced: false, reason: "primary_sync_failed" };
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
        authoritative: true,
        source: "necxa-finance-ledger",
        syncedAt: new Date().toISOString(),
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
        identitySync,
        profileFinanceSync,
        reconciliation,
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
      if (payment.settled_at) {
        return json({ success: true, status: "already_credited", message: "This deposit was already credited to your wallet." });
      }

      // Check current Pesapal status
      const token = await getPesapalToken();
      const statusData = await getPesapalTransactionStatus(
        token,
        payment.provider_reference,
      ) as Record<string, unknown>;
      const reconciledStatus = await settleVerifiedPesapalPayment(supabase, payment, statusData);

      if (reconciledStatus === "COMPLETED") {
        return json({ success: true, status: "completed", message: "Deposit confirmed and wallet credited!" });
      }

      if (reconciledStatus === "FAILED") {
        return json({ success: false, status: "failed", message: "Payment was unsuccessful. Please try again." });
      }

      return json({ success: true, status: "pending", message: "Payment is still processing. Please wait." });
    }

    // ── Action: check_withdrawal_eligibility ──────────────────────────────
    // This is a user-facing preview. The same rule is enforced again by the
    // database trigger when the withdrawal is created.
    if (action === "check_withdrawal_eligibility") {
      const amount = Number(body.amount ?? 0);
      if (!Number.isSafeInteger(amount) || amount <= 0) {
        return json({ success: false, message: "Invalid withdrawal amount." }, 400);
      }
      const { data: assessment, error } = await supabase.rpc("assert_withdrawal_eligible", {
        p_user_id: user.id,
        p_amount: amount,
      });
      if (error) {
        return json({
          success: false,
          code: "withdrawal_not_eligible",
          message: error.message,
        }, 403);
      }
      return json({ success: true, eligibility: assessment });
    }

    // ── Action: send_withdrawal_otp ───────────────────────────────────────
    if (action === "send_withdrawal_otp") {
      const { data: profile } = await supabase
        .from("profiles")
        .select("email")
        .eq("id", user.id)
        .maybeSingle();

      const email = profile?.email || user.email || null;
      if (!email) return json({ success: false, message: "No email available for OTP delivery." }, 400);

      const otp = createWithdrawalOtp();
      const codeHash = await hmacSha256Hex(otp);
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();

      try {
        await queueWithdrawalOtpDelivery(email, otp);
      } catch (deliveryErr) {
        return json({
          success: false,
          message: deliveryErr instanceof Error ? deliveryErr.message : "OTP delivery is unavailable.",
        }, 503);
      }

      const { error: upsertErr } = await supabase.from("withdrawal_otps").upsert({
        user_id: user.id,
        code_hash: codeHash,
        expires_at: expiresAt,
        attempts: 0,
        consumed_at: null,
      }, { onConflict: "user_id" });
      if (upsertErr) throw new Error(upsertErr.message);

      return json({ success: true, sent: true, expiresAt });
    }

    // ── Action: request_withdrawal ────────────────────────────────────────
    if (action === "request_withdrawal") {
      const amount = Number(body.amount ?? 0);
      const method = String(body.method ?? "mtn").trim().toLowerCase();
      const accountNumber = String(body.accountNumber ?? "").trim();
      const recipientName = String(body.recipientName ?? "").trim();
      const idempotencyKey = String(body.idempotencyKey ?? `withdraw-${user.id}-${Date.now()}`).trim();
      const securityMetadata = body.securityMetadata ?? {};
      const emailOtp = String(body.emailOtp ?? "").trim();

      if (!amount || amount <= 0) return json({ success: false, message: "Invalid amount." }, 400);
      if (!idempotencyKey) return json({ success: false, message: "A valid idempotency key is required." }, 400);
      // Airtel and bank rails have no provider implementation yet. Reject them
      // before the wallet is debited rather than leaving a user with a payout
      // that can never be completed.
      if (method !== "mtn") {
        return json({ success: false, message: "Only MTN Mobile Money withdrawals are available right now." }, 400);
      }
      if (!accountNumber || !recipientName) return json({ success: false, message: "Account number and recipient name are required." }, 400);
      if (!isValidWithdrawalOtp(emailOtp)) return json({ success: false, message: "A valid 6-digit OTP is required." }, 400);

      const otpHash = await hmacSha256Hex(emailOtp);
      const destinationCiphertext = await encryptWithdrawalDestination({ accountNumber, recipientName });

      // If MTN method, run conservative device/fraud reservation guard first.
      if (method === 'mtn') {
        const normalizedMsisdn = normalizeUgandanMsisdn(accountNumber);
        if (!normalizedMsisdn) {
          return json({ success: false, message: "Enter a valid Ugandan mobile-money number." }, 400);
        }
        const deviceFingerprint = securityMetadata?.device_fingerprint ?? null;
        const riskScore = securityMetadata && securityMetadata.risk_score != null ? Number(securityMetadata.risk_score) : null;
        const isDeviceTrusted = securityMetadata && securityMetadata.is_device_trusted != null ? Boolean(securityMetadata.is_device_trusted) : null;

        const { error: reserveErr } = await supabase.rpc('reserve_mtn_withdrawal', {
          p_user_id: user.id,
          p_amount: amount,
          p_device_fingerprint: deviceFingerprint,
          p_risk_score: riskScore,
          p_is_device_trusted: isDeviceTrusted,
          p_idempotency_key: idempotencyKey,
        });
        if (reserveErr) {
          // Forward reservation failure (e.g., blocked by risk rules)
          return json({ success: false, message: reserveErr.message }, 403);
        }
      }

      const { data, error: rpcErr } = await supabase.rpc("create_withdrawal_request", {
        p_user_id: user.id,
        p_amount: amount,
        p_method: method,
        p_destination_ciphertext: destinationCiphertext,
        p_recipient_name: recipientName,
        p_otp_hash: otpHash,
        p_idempotency_key: idempotencyKey,
        p_metadata: securityMetadata,
      });
      if (rpcErr) return json({ success: false, message: rpcErr.message }, 400);

      const withdrawal = Array.isArray(data) ? data[0] ?? data : data; // handle rpc single/maybeSingle shapes

      // If MTN, attempt external disbursement and update workflow status accordingly.
      if (method === 'mtn') {
        const withdrawalId = String(withdrawal?.id ?? "");
        if (!withdrawalId) return json({ success: false, message: "Withdrawal could not be created." }, 500);

        // Only one request may submit a particular withdrawal to MTN. This is
        // an atomic database claim, so retried HTTP requests cannot pay twice.
        const { data: claimed, error: claimErr } = await supabase.rpc('claim_mtn_disbursement', {
          p_withdrawal_id: withdrawalId,
        });
        if (claimErr) throw new Error(claimErr.message);
        if (!claimed) {
          return json({
            success: true,
            withdrawal,
            withdrawalId,
            status: withdrawal.workflow_status ?? "processing",
            message: "Withdrawal is already being processed.",
          });
        }

        try {
          const token = await getMtnAccessToken();
          const msisdn = normalizeUgandanMsisdn(accountNumber)!;
          const depositResult = await makeMtnDeposit(token, withdrawal, amount, msisdn);

          // Persist provider response into withdrawals.metadata for audit/debugging
          try {
            const existingMeta = (withdrawal && (withdrawal.metadata ?? {})) || {};
            const newMeta = { ...existingMeta, provider_response: depositResult };
            const { error: metaErr } = await supabase
              .from('withdrawals')
              .update({ metadata: newMeta })
              .eq('id', withdrawalId)
              .select()
              .single();
            if (metaErr) console.error('Failed to persist withdrawal metadata:', metaErr.message || metaErr);
          } catch (mErr) {
            console.error('Exception while persisting metadata:', mErr);
          }

          const providerRef = depositResult.referenceId;
          await supabase.rpc('transition_withdrawal_status', {
            p_withdrawal_id: withdrawalId,
            p_new_status: 'processing',
            p_operator_id: 'mtn-disbursement',
            p_provider_reference: providerRef,
          });

          return json({
            success: true,
            withdrawal,
            withdrawalId,
            status: 'processing',
            providerReference: providerRef,
          });
        } catch (err) {
          const errMsg = (err as Error).message || String(err);
          try {
            await supabase.rpc('transition_withdrawal_status', {
              p_withdrawal_id: withdrawalId,
              p_new_status: 'failed',
              p_operator_id: 'mtn-disbursement',
              p_note: errMsg,
            });
          } catch (tErr) {
            console.error('Failed to mark withdrawal failed:', tErr);
          }
          try {
            // Save provider error into metadata for later inspection
            const existingMeta = (withdrawal && (withdrawal.metadata ?? {})) || {};
            const newMeta = { ...existingMeta, provider_response: { error: errMsg } };
            const { error: metaErr } = await supabase
              .from('withdrawals')
              .update({ metadata: newMeta })
              .eq('id', withdrawalId)
              .select()
              .single();
            if (metaErr) console.error('Failed to persist failure metadata:', metaErr.message || metaErr);
          } catch (mErr) {
            console.error('Exception while persisting failure metadata:', mErr);
          }
          try {
            await supabase.rpc('refund_failed_withdrawal', { p_withdrawal_id: withdrawalId, p_reason: errMsg });
          } catch (rErr) {
            console.error('Refund failed after MTN error:', rErr);
          }
          return json({ success: false, message: 'Disbursement failed: ' + errMsg }, 500);
        }
      }

      return json({
        success: true,
        withdrawal,
        withdrawalId: withdrawal?.id,
        status: withdrawal?.workflow_status ?? withdrawal?.status,
      });
    }

    // ── Action: withdrawal_status ─────────────────────────────────────────
    if (action === "withdrawal_status") {
      const withdrawalId = String(body.withdrawalId ?? "");
      if (!withdrawalId) return json({ success: false, message: "withdrawalId required." }, 400);
      const { data, error } = await supabase.from("withdrawals")
        .select("*").eq("id", withdrawalId).eq("user_id", user.id).maybeSingle();
      if (error) throw new Error(error.message);
      if (!data) return json({ success: false, message: "Withdrawal not found." }, 404);

      // A callback can be missed, so the status endpoint also reconciles any
      // in-flight MTN request with MTN before reporting its state to the user.
      let withdrawal = data;
      if (data.method === "mtn" && data.workflow_status === "processing" && data.provider_reference) {
        try {
          withdrawal = await reconcileMtnWithdrawal(supabase, data);
        } catch (statusError) {
          console.error("MTN withdrawal reconciliation failed:", statusError);
        }
      }
      return json({
        success: true,
        withdrawal,
        withdrawalId: withdrawal.id,
        status: withdrawal.workflow_status ?? withdrawal.status,
      });
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
