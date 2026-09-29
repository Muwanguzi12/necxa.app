import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { pesapalIpnId, pesapalStatus, pesapalToken, submitPesapalOrder } from "../_shared/pesapal.ts";

const OFFER_ID = "necxa-technology-2026";
const PUBLIC_ORIGINS = new Set([
  "https://invest.necxa.uk",
  "https://necxa-investors.neatgriti.chatgpt.site",
  "http://localhost:3000",
]);

function cors(req: Request) {
  const origin = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": PUBLIC_ORIGINS.has(origin) ? origin : "https://invest.necxa.uk",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, idempotency-key",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Vary": "Origin",
  };
}

function json(req: Request, body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(req), "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function paymentState(data: Record<string, unknown>) {
  const description = String(data.payment_status_description ?? "").toUpperCase();
  const code = Number(data.payment_status_code ?? data.status_code);
  if (description === "COMPLETED" || code === 1) return "completed";
  if (["FAILED", "INVALID", "CANCELLED", "REVERSED"].includes(description) || code === 2) return "failed";
  return "processing";
}

function checkoutEnabled() {
  return Deno.env.get("SHARE_OFFER_ENABLED") === "true" &&
    Deno.env.get("PESAPAL_SHARE_SALES_APPROVED") === "true";
}

function pesapalEnvironment() {
  return Deno.env.get("PESAPAL_ENVIRONMENT")?.trim().toLowerCase() ?? "sandbox";
}

async function authenticatedUser(req: Request) {
  const authHeader = req.headers.get("authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) return null;
  const authUrl = Deno.env.get("SUPABASE_AUTH_URL") ?? Deno.env.get("AUTH_PROJECT_URL") ?? Deno.env.get("SUPABASE_URL")!;
  const authKey = Deno.env.get("SUPABASE_AUTH_ANON_KEY") ?? Deno.env.get("AUTH_PROJECT_ANON_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY")!;
  const client = createClient(authUrl, authKey, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
  const { data: { user } } = await client.auth.getUser();
  return user;
}

async function reconcile(admin: any, trackingId: string, merchantReference: string) {
  const query = admin.from("share_subscriptions").select("*");
  const { data: rawSubscription, error } = merchantReference
    ? await query.eq("merchant_reference", merchantReference).maybeSingle()
    : await query.eq("provider_tracking_id", trackingId).maybeSingle();
  const subscription = rawSubscription as Record<string, any> | null;
  if (error || !subscription) throw new Error("Unknown share payment");
  if (subscription.provider_tracking_id && subscription.provider_tracking_id !== trackingId) {
    throw new Error("Provider reference mismatch");
  }

  const token = await pesapalToken();
  const verified = await pesapalStatus(token, trackingId) as Record<string, unknown>;
  const verifiedReference = String(verified.merchant_reference ?? verified.order_merchant_reference ?? "");
  if (verifiedReference && verifiedReference !== subscription.merchant_reference) throw new Error("Merchant reference mismatch");
  if (verified.amount != null && Number(verified.amount) !== Number(subscription.amount_ugx)) throw new Error("Payment amount mismatch");
  if (verified.currency && String(verified.currency).toUpperCase() !== "UGX") throw new Error("Payment currency mismatch");

  const state = paymentState(verified);
  if (state === "completed") {
    const { data: rawCompleted, error: completionError } = await admin.rpc("complete_share_subscription", {
      p_subscription_id: subscription.id,
      p_provider_tracking_id: trackingId,
      p_payment_verification: verified,
    });
    if (completionError) throw completionError;
    const completed = rawCompleted as Record<string, any>;
    return { state: completed.status === "manual_review" ? "manual_review" : "paid_pending_allotment", subscription: completed };
  }
  if (state === "failed") {
    const description = String(verified.payment_status_description ?? "").toUpperCase();
    const closureStatus = description === "CANCELLED" ? "cancelled" : "failed";
    const { error: closureError } = await admin.rpc("close_share_subscription", {
      p_subscription_id: subscription.id,
      p_status: closureStatus,
      p_payment_verification: verified,
    });
    if (closureError) throw closureError;
  }
  return { state, subscription };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const url = new URL(req.url);

  try {
    let requestBody: Record<string, unknown> = {};
    if (req.method === "POST") {
      const contentType = req.headers.get("content-type") ?? "";
      if (contentType.includes("application/json")) requestBody = await req.clone().json().catch(() => ({}));
      else if (contentType.includes("form")) requestBody = Object.fromEntries((await req.clone().formData()).entries());
    }
    const trackingId = String(url.searchParams.get("OrderTrackingId") ?? requestBody.OrderTrackingId ?? "");
    const callbackMerchantReference = String(url.searchParams.get("OrderMerchantReference") ?? requestBody.OrderMerchantReference ?? "");
    if (trackingId) {
      const result = await reconcile(admin, trackingId, callbackMerchantReference);
      return json(req, {
        orderNotificationType: url.searchParams.get("OrderNotificationType") ?? requestBody.OrderNotificationType ?? "IPNCHANGE",
        orderTrackingId: trackingId,
        orderMerchantReference: callbackMerchantReference,
        status: 200,
        paymentState: result.state,
      });
    }

    if (req.method === "GET") {
      const { data: offer, error } = await admin.from("share_offers").select(
        "id,company_legal_name,total_shares,offered_shares,external_ownership_bps,price_per_share_ugx,reserved_shares,paid_shares,status,opens_at,closes_at,legal_document_refs",
      ).eq("id", OFFER_ID).single();
      if (error) throw error;
      const enabled = checkoutEnabled() && offer.status === "open";
      return json(req, {
        offer: {
          ...offer,
          legal_document_refs: undefined,
          available_shares: Math.max(0, offer.offered_shares - offer.reserved_shares - offer.paid_shares),
          gross_offer_value_ugx: offer.offered_shares * offer.price_per_share_ugx,
        },
        documents: enabled ? offer.legal_document_refs : null,
        checkout_enabled: enabled,
        checkout_status: enabled ? "open" : "awaiting_approvals",
      });
    }

    if (req.method !== "POST") return json(req, { error: "method_not_allowed" }, 405);
    const body = requestBody;
    const action = String(body.action ?? "checkout");
    if (action === "health") return json(req, {
      success: true,
      service: "share-offer",
      checkout_enabled: checkoutEnabled(),
      payment_environment: pesapalEnvironment(),
      launch_gates_configured: {
        share_offer_enabled: Deno.env.get("SHARE_OFFER_ENABLED") === "true",
        pesapal_share_sales_approved: Deno.env.get("PESAPAL_SHARE_SALES_APPROVED") === "true",
      },
    });

    const user = await authenticatedUser(req);
    if (!user) return json(req, { error: "sign_in_required" }, 401);

    const loadInvestor = async () => {
      const { data, error } = await admin.from("share_investors").select("*").eq("auth_user_id", user.id).maybeSingle();
      if (error) throw error;
      return data as Record<string, any> | null;
    };

    const eligibility = (investor: Record<string, any> | null) => ({
      application_submitted: Boolean(investor?.application_submitted_at),
      kyc_verified: investor?.kyc_status === "verified",
      aml_cleared: investor?.aml_status === "cleared",
      source_of_funds_cleared: investor?.source_of_funds_status === "cleared",
      terms_accepted: Boolean(investor?.terms_accepted_at),
      risk_acknowledged: Boolean(investor?.risk_acknowledged_at),
      approved: Boolean(investor?.approved_at),
      eligible_to_pay: Boolean(
        investor?.kyc_status === "verified" && investor?.aml_status === "cleared" &&
        investor?.source_of_funds_status === "cleared" && investor?.approved_at
      ),
      investment_limit_ugx: investor?.investment_limit_ugx ?? null,
    });

    if (action === "eligibility") {
      return json(req, { success: true, eligibility: eligibility(await loadInvestor()) });
    }

    if (action === "apply") {
      const fullName = String(body.fullName ?? "").trim();
      const phone = String(body.phone ?? "").trim();
      const countryCode = String(body.countryCode ?? "UG").trim().toUpperCase();
      if (fullName.length < 2 || fullName.length > 120) return json(req, { error: "valid_full_name_required" }, 400);
      if (phone.length > 32 || !/^[+0-9 ()-]*$/.test(phone)) return json(req, { error: "invalid_phone" }, 400);
      if (!/^[A-Z]{2}$/.test(countryCode)) return json(req, { error: "invalid_country_code" }, 400);

      const primaryUrl = Deno.env.get("PRIMARY_SUPABASE_URL") ?? Deno.env.get("SUPABASE_AUTH_URL") ?? Deno.env.get("AUTH_PROJECT_URL") ?? "";
      const primaryServiceKey = Deno.env.get("PRIMARY_SUPABASE_SERVICE_ROLE_KEY") ?? "";
      let identityShard: Record<string, any> | null = null;
      let financialIdentity: Record<string, any> | null = null;
      if (primaryUrl && primaryServiceKey) {
        const primaryAdmin = createClient(primaryUrl, primaryServiceKey, { auth: { persistSession: false } });
        const [identityResult, financeIdentityResult] = await Promise.all([
          primaryAdmin.from("identity_shards").select("*").eq("user_id", user.id).order("created_at", { ascending: false }).limit(1).maybeSingle(),
          primaryAdmin.from("financial_identities").select("*").eq("user_id", user.id).maybeSingle(),
        ]);
        identityShard = identityResult.data as Record<string, any> | null;
        financialIdentity = financeIdentityResult.data as Record<string, any> | null;
      }

      const existing = await loadInvestor();
      const kycVerified = existing?.kyc_status === "verified" || identityShard?.status === "verified" || identityShard?.verified === true;
      const amlCleared = existing?.aml_status === "cleared" || (
        financialIdentity?.aml_checked === true && String(financialIdentity?.aml_status).toUpperCase() === "PASSED"
      );
      const record = {
        auth_user_id: user.id,
        full_name: fullName,
        email: user.email ?? existing?.email,
        phone: phone || null,
        country_code: countryCode,
        kyc_status: kycVerified ? "verified" : (existing?.kyc_status === "rejected" ? "rejected" : "pending"),
        kyc_reference: kycVerified ? (existing?.kyc_reference ?? String(identityShard?.id ?? "")) : existing?.kyc_reference,
        aml_status: amlCleared ? "cleared" : (existing?.aml_status === "rejected" ? "rejected" : "pending"),
        aml_reference: amlCleared ? (existing?.aml_reference ?? String(financialIdentity?.id ?? "")) : existing?.aml_reference,
        source_of_funds_status: existing?.source_of_funds_status ?? "pending",
        source_of_funds_reference: existing?.source_of_funds_reference,
        investment_limit_ugx: existing?.investment_limit_ugx ?? financialIdentity?.aml_limit_ugx ?? null,
        application_submitted_at: existing?.application_submitted_at ?? new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      if (!record.email) return json(req, { error: "verified_email_required" }, 400);
      const { data: saved, error: saveError } = await admin.from("share_investors").upsert(record, { onConflict: "auth_user_id" }).select("*").single();
      if (saveError) throw saveError;
      return json(req, { success: true, eligibility: eligibility(saved) });
    }

    if (action === "status") {
      const reference = String(body.merchantReference ?? "");
      if (!reference) return json(req, { error: "merchant_reference_required" }, 400);
      const { data: investor } = await admin.from("share_investors").select("id").eq("auth_user_id", user.id).maybeSingle();
      if (!investor) return json(req, { error: "investor_not_found" }, 404);
      const { data: subscription } = await admin.from("share_subscriptions").select("provider_tracking_id,merchant_reference,status")
        .eq("merchant_reference", reference).eq("investor_id", investor.id).maybeSingle();
      if (!subscription) return json(req, { error: "subscription_not_found" }, 404);
      if (!subscription.provider_tracking_id || ["paid_pending_allotment", "allotted", "manual_review"].includes(subscription.status)) {
        return json(req, { state: subscription.status });
      }
      const result = await reconcile(admin, subscription.provider_tracking_id, subscription.merchant_reference);
      return json(req, { state: result.state });
    }

    if (action !== "checkout") return json(req, { error: "unknown_action" }, 400);
    if (!checkoutEnabled()) return json(req, { error: "checkout_awaiting_approvals" }, 503);

    const shareCount = Number(body.shareCount);
    if (!Number.isInteger(shareCount) || shareCount < 1 || shareCount > 1000) return json(req, { error: "invalid_share_count" }, 400);
    if (body.acceptApprovedDocuments !== true || body.acknowledgeRisk !== true) {
      return json(req, { error: "offer_documents_and_risk_acknowledgement_required" }, 400);
    }
    const currentInvestor = await loadInvestor();
    if (!currentInvestor) return json(req, { error: "investor_application_required" }, 403);
    const acknowledgementTime = new Date().toISOString();
    const { data: investor, error: investorError } = await admin.from("share_investors").update({
      terms_accepted_at: currentInvestor.terms_accepted_at ?? acknowledgementTime,
      risk_acknowledged_at: currentInvestor.risk_acknowledged_at ?? acknowledgementTime,
      updated_at: acknowledgementTime,
    }).eq("id", currentInvestor.id).select("*").single();
    if (investorError) throw investorError;
    if (!investor || investor.kyc_status !== "verified" || investor.aml_status !== "cleared" ||
      investor.source_of_funds_status !== "cleared" || !investor.terms_accepted_at || !investor.risk_acknowledged_at || !investor.approved_at) {
      return json(req, { error: "investor_verification_required" }, 403);
    }

    const suppliedKey = req.headers.get("idempotency-key")?.trim() ?? "";
    if (!/^[A-Za-z0-9_-]{16,50}$/.test(suppliedKey)) return json(req, { error: "valid_idempotency_key_required" }, 400);
    const merchantReference = `share-${suppliedKey}`.slice(0, 50);
    const { data: subscription, error: reservationError } = await admin.rpc("reserve_share_subscription", {
      p_offer_id: OFFER_ID,
      p_investor_id: investor.id,
      p_share_count: shareCount,
      p_idempotency_key: merchantReference,
    });
    if (reservationError) return json(req, { error: "reservation_failed", message: reservationError.message }, 409);
    if (investor.investment_limit_ugx != null && Number(subscription.amount_ugx) > Number(investor.investment_limit_ugx)) {
      const { error: releaseError } = await admin.rpc("close_share_subscription", {
        p_subscription_id: subscription.id,
        p_status: "cancelled",
        p_payment_verification: { reason: "investment_limit_exceeded" },
      });
      if (releaseError) throw releaseError;
      return json(req, { error: "investment_limit_exceeded" }, 403);
    }
    if (subscription.provider_tracking_id) {
      return json(req, {
        error: "checkout_already_initialized",
        merchant_reference: subscription.merchant_reference,
        state: subscription.status,
      }, 409);
    }

    const token = await pesapalToken();
    const callbackUrl = `https://invest.necxa.uk/payment-return?reference=${encodeURIComponent(merchantReference)}`;
    const ipnUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/share-offer`;
    const ipnId = await pesapalIpnId(token, ipnUrl);
    const nameParts = String(investor.full_name).trim().split(/\s+/);
    const result = await submitPesapalOrder(token, {
      id: merchantReference,
      currency: "UGX",
      amount: Number(subscription.amount_ugx),
      description: `${shareCount} Necxa Technology Ltd share${shareCount === 1 ? "" : "s"} - payment pending allotment`,
      callback_url: callbackUrl,
      notification_id: ipnId,
      branch: "Necxa Technology Ltd Share Subscription",
      billing_address: {
        email_address: investor.email,
        phone_number: investor.phone ?? "",
        country_code: investor.country_code,
        first_name: nameParts.shift() ?? investor.full_name,
        last_name: nameParts.join(" ") || "Investor",
      },
    });

    const { error: updateError } = await admin.from("share_subscriptions").update({
      status: "payment_pending",
      provider_tracking_id: result.order_tracking_id,
      payment_request: { share_count: shareCount, amount_ugx: subscription.amount_ugx },
      updated_at: new Date().toISOString(),
    }).eq("id", subscription.id).eq("status", "reserved");
    if (updateError) throw updateError;
    return json(req, { redirect_url: result.redirect_url, merchant_reference: merchantReference, expires_at: subscription.expires_at }, 201);
  } catch (error) {
    console.error("share-offer", error);
    return json(req, { error: "share_offer_request_failed" }, 500);
  }
});
