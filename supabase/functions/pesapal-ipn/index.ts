import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const pesapalConsumerKey = Deno.env.get("PESAPAL_CONSUMER_KEY")?.trim() || "";
const pesapalConsumerSecret = Deno.env.get("PESAPAL_CONSUMER_SECRET")?.trim() || "";
const pesapalEnv = Deno.env.get("PESAPAL_ENVIRONMENT")?.trim() || "sandbox"; // "sandbox" or "production"

const baseUrl = pesapalEnv === "production" 
  ? "https://pay.pesapal.com/v3" 
  : "https://cybqa.pesapal.com/pesapalv3";

const supabase = createClient(supabaseUrl, supabaseServiceKey);

async function getPesapalToken() {
  console.log("Diagnostic Check:", {
    keyLoaded: Boolean(pesapalConsumerKey),
    secretLoaded: Boolean(pesapalConsumerSecret),
    env: pesapalEnv,
    keyLength: pesapalConsumerKey.length,
    secretLength: pesapalConsumerSecret.length,
    keyStart: pesapalConsumerKey.substring(0, 4),
  });

  const response = await fetch(`${baseUrl}/api/Auth/RequestToken`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
    },
    body: JSON.stringify({
      consumer_key: pesapalConsumerKey,
      consumer_secret: pesapalConsumerSecret,
    }),
  });
  
  if (!response.ok) {
    throw new Error(`Failed to get Pesapal token: ${response.status}`);
  }
  
  const data = await response.json();
  return data.token;
}

async function getTransactionStatus(orderTrackingId: string, token: string) {
  const response = await fetch(`${baseUrl}/api/Transactions/GetTransactionStatus?orderTrackingId=${orderTrackingId}`, {
    method: "GET",
    headers: {
      "Accept": "application/json",
      "Authorization": `Bearer ${token}`,
    },
  });
  
  if (!response.ok) {
    throw new Error(`Failed to get transaction status: ${response.status}`);
  }
  
  return await response.json();
}

serve(async (req) => {
  try {
    // Pesapal sends a GET or POST with query params or JSON body depending on webhook setup.
    // Generally IPN sends OrderNotificationType, OrderTrackingId, OrderMerchantReference.
    let orderTrackingId = "";
    let orderMerchantReference = "";

    const url = new URL(req.url);
    if (req.method === "GET") {
      orderTrackingId = url.searchParams.get("OrderTrackingId") || "";
      orderMerchantReference = url.searchParams.get("OrderMerchantReference") || "";
    } else {
      const body = await req.json();
      orderTrackingId = body.OrderTrackingId;
      orderMerchantReference = body.OrderMerchantReference;
    }

    if (!orderTrackingId) {
      return new Response(JSON.stringify({ error: "Missing OrderTrackingId" }), { status: 400 });
    }

    console.log(`Processing IPN for OrderTrackingId: ${orderTrackingId}`);

    // 1. Authenticate with Pesapal
    const token = await getPesapalToken();

    // 2. Fetch the actual transaction status from Pesapal
    const statusData = await getTransactionStatus(orderTrackingId, token);
    console.log("Pesapal status response:", statusData);

    const paymentStatus = statusData.payment_status_description; // "COMPLETED", "FAILED", "INVALID", etc
    
    // Map Pesapal status to our standard status
    let mappedStatus = "PENDING";
    if (paymentStatus === "COMPLETED") mappedStatus = "COMPLETED";
    else if (paymentStatus === "FAILED" || paymentStatus === "INVALID") mappedStatus = "FAILED";
    
    // 3. Update Supabase
    // Using orderMerchantReference if valid, else fallback to tracking ID mapping
    const merchantRef = statusData.merchant_reference || orderMerchantReference;

    // Check if already processed to prevent duplicate execution
    const { data: currentPayment } = await supabase
      .from('payments')
      .select('status')
      .eq('idempotency_key', merchantRef)
      .single();

    if (currentPayment?.status === 'COMPLETED') {
      console.log('Payment already marked as completed. Skipping duplicate processing.');
      // Proceed directly to returning 200 OK
    } else {
      // Update payments table
      const { error: paymentError } = await supabase
        .from('payments')
        .update({ 
          status: mappedStatus,
          provider_reference: orderTrackingId,
          updated_at: new Date().toISOString()
        })
        .eq('idempotency_key', merchantRef);

      if (paymentError) {
        console.error("Error updating payment:", paymentError);
      }

      // Update orders table optionally
      if (merchantRef) {
        const { error: orderError } = await supabase
          .from('commerce_orders')
          .update({ status: mappedStatus })
          .eq('order_number', merchantRef);
          
        if (orderError) {
           console.error("Error updating order:", orderError);
        }
      }
    }

    // 4. Return successful response to Pesapal
    return new Response(JSON.stringify({
      orderNotificationType: url.searchParams.get("OrderNotificationType") || "IPNCHANGE",
      orderTrackingId: orderTrackingId,
      orderMerchantReference: merchantRef,
      status: 200
    }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });

  } catch (error) {
    console.error("IPN Processing Error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
