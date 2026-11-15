import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const FINANCE_ENGINE_URL = Deno.env.get("FINANCE_ENGINE_URL")?.trim() ||
  "https://ayvescksetiuekoyfqar.supabase.co/functions/v1/finance-engine";

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  try {
    const url = new URL(req.url);
    let body: Record<string, unknown> = {};
    if (req.method === "POST") {
      body = await req.json().catch(() => ({}));
    }

    const orderTrackingId = url.searchParams.get("OrderTrackingId") ||
      url.searchParams.get("orderTrackingId") ||
      String(body.OrderTrackingId ?? body.orderTrackingId ?? "");
    const orderMerchantReference = url.searchParams.get("OrderMerchantReference") ||
      url.searchParams.get("orderMerchantReference") ||
      String(body.OrderMerchantReference ?? body.orderMerchantReference ?? "");
    const orderNotificationType = url.searchParams.get("OrderNotificationType") ||
      String(body.OrderNotificationType ?? body.orderNotificationType ?? "IPNCHANGE");

    if (!orderTrackingId) {
      return json({
        orderNotificationType,
        orderTrackingId: "",
        orderMerchantReference,
        status: 500,
      }, 400);
    }

    // The finance project is the only settlement authority. It independently
    // verifies the transaction with PesaPal, then applies an idempotent order,
    // reservation and payment update. The primary project never mutates its
    // own shadow payment tables from a provider callback.
    const financeUrl = new URL(FINANCE_ENGINE_URL);
    financeUrl.searchParams.set("OrderTrackingId", orderTrackingId);
    if (orderMerchantReference) {
      financeUrl.searchParams.set("OrderMerchantReference", orderMerchantReference);
    }
    financeUrl.searchParams.set("OrderNotificationType", orderNotificationType);

    const response = await fetch(financeUrl, {
      method: "GET",
      headers: { Accept: "application/json" },
    });
    const responseBody = await response.text();
    return new Response(responseBody, {
      status: response.status,
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("PesaPal IPN forwarding error:", error);
    return json({
      orderNotificationType: "IPNCHANGE",
      orderTrackingId: "",
      orderMerchantReference: "",
      status: 500,
    }, 500);
  }
});
