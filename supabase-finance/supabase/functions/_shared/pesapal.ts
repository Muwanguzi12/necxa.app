const baseUrl = Deno.env.get("PESAPAL_BASE_URL") ?? "https://pay.pesapal.com/v3";

export async function pesapalToken(): Promise<string> {
  const consumerKey = Deno.env.get("PESAPAL_CONSUMER_KEY");
  const consumerSecret = Deno.env.get("PESAPAL_CONSUMER_SECRET");
  if (!consumerKey || !consumerSecret) throw new Error("Pesapal credentials are not configured");
  const response = await fetch(`${baseUrl}/api/Auth/RequestToken`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ consumer_key: consumerKey, consumer_secret: consumerSecret }),
  });
  const data = await response.json();
  if (!response.ok || !data.token) throw new Error(`Pesapal authentication failed: ${JSON.stringify(data)}`);
  return data.token;
}

export async function pesapalIpnId(token: string, callbackUrl: string): Promise<string> {
  const configured = Deno.env.get("PESAPAL_IPN_ID");
  if (configured) return configured;
  const response = await fetch(`${baseUrl}/api/URLSetup/RegisterIPN`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ url: callbackUrl, ipn_notification_type: "POST" }),
  });
  const data = await response.json();
  if (!response.ok || !data.ipn_id) throw new Error(`Pesapal IPN registration failed: ${JSON.stringify(data)}`);
  return data.ipn_id;
}

export async function submitPesapalOrder(token: string, order: Record<string, unknown>) {
  const response = await fetch(`${baseUrl}/api/Transactions/SubmitOrderRequest`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify(order),
  });
  const data = await response.json();
  if (!response.ok || !data.redirect_url || !data.order_tracking_id) {
    throw new Error(`Pesapal order submission failed: ${JSON.stringify(data)}`);
  }
  return data;
}

export async function pesapalStatus(token: string, trackingId: string) {
  const response = await fetch(`${baseUrl}/api/Transactions/GetTransactionStatus?orderTrackingId=${encodeURIComponent(trackingId)}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
  });
  const data = await response.json();
  if (!response.ok) throw new Error(`Pesapal status verification failed: ${JSON.stringify(data)}`);
  return data;
}
