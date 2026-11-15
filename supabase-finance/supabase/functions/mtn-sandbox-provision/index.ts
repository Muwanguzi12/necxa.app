import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const PROVISIONING_SECRET = Deno.env.get("MTN_PROVISIONING_SECRET")?.trim() || "";
const SUBSCRIPTION_KEY = Deno.env.get("MTN_DISBURSEMENT_SUBSCRIPTION_KEY")?.trim() ||
  Deno.env.get("mtn primary key")?.trim() || "";
const CALLBACK_HOST = Deno.env.get("MTN_PROVIDER_CALLBACK_HOST")?.trim() ||
  new URL(Deno.env.get("SUPABASE_URL") ?? "https://ayvescksetiuekoyfqar.supabase.co").hostname;

function response(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

serve(async (request) => {
  if (request.method !== "POST") return response({ error: "Method not allowed" }, 405);
  if (!PROVISIONING_SECRET || request.headers.get("x-mtn-provisioning-secret") !== PROVISIONING_SECRET) {
    return response({ error: "Unauthorized" }, 401);
  }
  if (!SUBSCRIPTION_KEY) return response({ error: "MTN sandbox subscription key is not configured" }, 503);

  const apiUser = crypto.randomUUID();
  const base = "https://sandbox.momodeveloper.mtn.com/v1_0";
  const headers = {
    "Ocp-Apim-Subscription-Key": SUBSCRIPTION_KEY,
    "X-Reference-Id": apiUser,
    "Content-Type": "application/json",
  };
  const createUser = await fetch(`${base}/apiuser`, {
    method: "POST",
    headers,
    body: JSON.stringify({ providerCallbackHost: CALLBACK_HOST }),
  });
  if (!createUser.ok) {
    return response({ error: "MTN API-user provisioning failed", providerStatus: createUser.status }, 502);
  }

  const createKey = await fetch(`${base}/apiuser/${apiUser}/apikey`, {
    method: "POST",
    headers: { "Ocp-Apim-Subscription-Key": SUBSCRIPTION_KEY },
  });
  const keyPayload = await createKey.json().catch(() => ({})) as { apiKey?: string };
  if (!createKey.ok || !keyPayload.apiKey) {
    return response({ error: "MTN API-key provisioning failed", providerStatus: createKey.status }, 502);
  }

  // Returned only once over the provisioning-secret protected request. The
  // caller immediately writes it to Supabase secrets and never logs it.
  return response({ apiUser, apiKey: keyPayload.apiKey, callbackHost: CALLBACK_HOST }, 201);
});
