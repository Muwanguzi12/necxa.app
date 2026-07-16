import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

    if (action === "list_gift_items") {
      const { data, error } = await admin.from("gift_items").select("*").eq("is_active", true).order("sort_order");
      if (error) throw error;
      return reply({ success: true, giftItems: data });
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
