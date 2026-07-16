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
    if (!financeUrl || !serviceRoleKey || !primaryUrl || !primaryPublishableKey) {
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
      try {
        const providerToken = await pesapalToken();
        const webhookUrl = `${financeUrl}/functions/v1/finance-payment-webhook`;
        const notificationId = await pesapalIpnId(providerToken, webhookUrl);
        const callbackBase = Deno.env.get("PESAPAL_CALLBACK_URL") ?? "https://necxa.uk/payment-callback";
        const order = await submitPesapalOrder(providerToken, {
          id: payment.id, currency: String(pack.fiat_currency), amount: Number(pack.fiat_price).toFixed(2),
          description: `Necxa ${pack.label}`,
          callback_url: `${callbackBase}?paymentId=${payment.id}&purpose=coin_purchase`, notification_id: notificationId,
          billing_address: { email_address: user.email ?? "no-reply@necxa.uk", phone_number: "", country_code: "UG", first_name: user.user_metadata?.first_name ?? "Necxa", last_name: user.user_metadata?.last_name ?? "User", line_1: "Kampala", city: "Kampala" },
        });
        const { error: updateError } = await admin.from("payments").update({ status: "processing", provider_reference: order.order_tracking_id, response: order, updated_at: new Date().toISOString() }).eq("id", payment.id);
        if (updateError) throw updateError;
        return reply({ success: true, paymentId: payment.id, status: "processing", redirectUrl: order.redirect_url, redirect_url: order.redirect_url, ncxAmount: pack.ncx_amount });
      } catch (error) {
        await admin.from("payments").update({ status: "failed", response: { error: error instanceof Error ? error.message : String(error) }, updated_at: new Date().toISOString() }).eq("id", payment.id);
        return reply({ success: false, code: "payment_initialization_failed", message: "Pesapal checkout could not be started. Try again." }, 502);
      }
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
      const { data, error } = await admin.rpc("process_gift", {
        p_sender_id: user.id,
        p_receiver_id: receiverId,
        p_gift_item_id: body.giftItemId ?? null,
        p_context_type: contextType,
        p_context_id: contextId,
        p_ncx_amount: positiveInteger(body.ncxAmount, "ncxAmount"),
        p_fee_basis_points: 2000,
        p_is_anonymous: body.isAnonymous === true,
        p_idempotency_key: idempotencyKey,
        p_metadata: body.metadata ?? {},
      });
      if (error) throw error;
      return reply({ success: true, gift: data });
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
