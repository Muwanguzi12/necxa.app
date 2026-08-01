import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

    // The finance engine is the only settlement authority. It independently
    // verifies the transaction with PesaPal and applies one atomic ledger effect.
    const financeUrl = new URL(`${supabaseUrl}/functions/v1/finance-engine`);
    financeUrl.searchParams.set("OrderTrackingId", orderTrackingId);
    if (orderMerchantReference) {
      financeUrl.searchParams.set("OrderMerchantReference", orderMerchantReference);
    }
    financeUrl.searchParams.set("OrderNotificationType", orderNotificationType);

    const response = await fetch(financeUrl, {
      method: "GET",
      headers: {
        apikey: supabaseServiceKey,
        Authorization: `Bearer ${supabaseServiceKey}`,
        Accept: "application/json",
      },
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
