import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { pesapalStatus, pesapalToken } from "../_shared/pesapal.ts";
import { mirrorDepositLedger } from "../_shared/primary-ledger.ts";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method !== "POST" && req.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  try {
    const url = new URL(req.url);
    let body: Record<string, unknown> = {};
    if (req.method === "POST") {
      const contentType = req.headers.get("content-type") ?? "";
      if (contentType.includes("application/json")) body = await req.json();
      else body = Object.fromEntries((await req.formData()).entries());
    }
    const trackingId = String(url.searchParams.get("OrderTrackingId") ?? body.OrderTrackingId ?? "");
    const merchantReference = String(url.searchParams.get("OrderMerchantReference") ?? body.OrderMerchantReference ?? "");
    if (!trackingId || !merchantReference) return json({ error: "missing_payment_reference" }, 400);

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const admin = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });
    const { data: payment, error: paymentError } = await admin.from("payments").select("*").eq("id", merchantReference).eq("purpose", "wallet_deposit").single();
    if (paymentError || !payment) return json({ error: "unknown_payment" }, 404);
    if (payment.provider_reference && payment.provider_reference !== trackingId) {
      return json({ error: "provider_reference_mismatch" }, 409);
    }
    if (payment.status === "completed") {
      await mirrorDepositLedger(admin, payment.id);
      return json({ status: "success", message: "Already completed and ledger synchronized" });
    }

    // The callback is never trusted by itself. Query Pesapal server-to-server
    // and use that verified result as the payment authority.
    const token = await pesapalToken();
    const verified = await pesapalStatus(token, trackingId);
    const verifiedMerchantReference = String(verified.merchant_reference ?? verified.order_merchant_reference ?? merchantReference);
    if (verifiedMerchantReference !== payment.id) {
      return json({ error: "verified_merchant_reference_mismatch" }, 409);
    }
    if (verified.amount != null && Number(verified.amount) !== Number(payment.amount)) {
      return json({ error: "verified_amount_mismatch" }, 409);
    }
    if (verified.currency && String(verified.currency).toUpperCase() !== String(payment.currency).toUpperCase()) {
      return json({ error: "verified_currency_mismatch" }, 409);
    }
    const description = String(verified.payment_status_description ?? "").toUpperCase();
    const completed = description === "COMPLETED" || Number(verified.payment_status_code ?? verified.status_code) === 1;
    const failed = ["FAILED", "INVALID", "CANCELLED", "REVERSED"].includes(description);

    if (completed) {
      const { error } = await admin.rpc("complete_deposit", {
        p_payment_id: payment.id,
        p_provider_reference: trackingId,
        p_provider_response: verified,
      });
      if (error) throw error;
      await mirrorDepositLedger(admin, payment.id);
    } else if (failed) {
      const { error } = await admin.from("payments").update({
        status: description === "CANCELLED" ? "cancelled" : "failed",
        response: verified,
        updated_at: new Date().toISOString(),
      }).eq("id", payment.id).neq("status", "completed");
      if (error) throw error;
    } else {
      await admin.from("payments").update({ response: verified, updated_at: new Date().toISOString() }).eq("id", payment.id).neq("status", "completed");
    }

    return json({ status: "success", payment_status: completed ? "completed" : failed ? "failed" : "processing" });
  } catch (error) {
    console.error("finance-payment-webhook", error);
    return json({ error: "webhook_processing_failed" }, 500);
  }
});
