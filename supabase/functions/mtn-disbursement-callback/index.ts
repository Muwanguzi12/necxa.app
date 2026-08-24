import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CALLBACK_SECRET = Deno.env.get("MTN_DISBURSEMENT_CALLBACK_SECRET")?.trim() || "";
const MTN_DISBURSEMENT_ENV = Deno.env.get("MTN_DISBURSEMENT_ENV")?.trim().toLowerCase() || "sandbox";

function outcome(payload: Record<string, unknown>): "paid" | "failed" | "pending" {
  const status = String(payload.status ?? payload.paymentStatus ?? payload.statusCode ?? "").toUpperCase();
  if (["SUCCESSFUL", "SUCCESS", "COMPLETED"].includes(status)) return "paid";
  if (["FAILED", "REJECTED", "CANCELLED", "EXPIRED"].includes(status)) return "failed";
  return "pending";
}

serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const url = new URL(req.url);
  if (!CALLBACK_SECRET || url.searchParams.get("token") !== CALLBACK_SECRET) {
    return new Response("Unauthorized", { status: 401 });
  }

  const payload = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!payload) return new Response("Bad request", { status: 400 });
  const providerReference = String(
    payload.referenceId ?? payload.reference_id ?? payload.providerReference ?? url.searchParams.get("referenceId") ?? "",
  );
  if (!providerReference) return new Response("Accepted", { status: 202 });

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: withdrawal } = await supabase
    .from("withdrawal_requests")
    .select("id, status")
    .eq("provider_reference", providerReference)
    .maybeSingle();
  if (!withdrawal || ["paid", "reversed", "failed"].includes(String(withdrawal.status))) {
    return new Response("Accepted", { status: 202 });
  }

  const result = outcome(payload);
  if (result === "paid") {
    const completionRpc = MTN_DISBURSEMENT_ENV === "sandbox"
      ? "complete_mtn_sandbox_withdrawal"
      : "complete_mtn_withdrawal";
    await supabase.rpc(completionRpc, {
      p_withdrawal_id: withdrawal.id,
      p_provider_status: payload,
    });
  } else if (result === "failed") {
    await supabase.rpc("reverse_mtn_withdrawal", {
      p_withdrawal_id: withdrawal.id,
      p_failure_reason: "MTN reported the withdrawal as failed.",
      p_provider_status: payload,
    });
  } else {
    await supabase.from("withdrawal_requests")
      .update({ provider_status: payload, updated_at: new Date().toISOString() })
      .eq("id", withdrawal.id);
  }

  return new Response("Accepted", { status: 202 });
});
