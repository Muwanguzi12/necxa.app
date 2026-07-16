import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export async function mirrorDepositLedger(admin: SupabaseClient, paymentId: string) {
  const primaryUrl = Deno.env.get("PRIMARY_SUPABASE_URL");
  const primaryServiceKey = Deno.env.get("PRIMARY_SUPABASE_SERVICE_ROLE_KEY");
  if (!primaryUrl || !primaryServiceKey) throw new Error("Primary ledger service credentials are not configured");

  const { data: outbox, error: queueError } = await admin.rpc("queue_primary_deposit_ledger", { p_payment_id: paymentId });
  if (queueError) throw queueError;
  if (outbox.status === "synced") return;

  await admin.from("primary_ledger_outbox").update({ status: "syncing", attempts: outbox.attempts + 1, updated_at: new Date().toISOString() }).eq("payment_id", paymentId);
  const response = await fetch(`${primaryUrl}/rest/v1/immutable_financial_ledger?on_conflict=reference_id,entry_type`, {
    method: "POST",
    headers: {
      apikey: primaryServiceKey,
      Authorization: `Bearer ${primaryServiceKey}`,
      "Content-Type": "application/json",
      Prefer: "resolution=ignore-duplicates,return=minimal",
    },
    body: JSON.stringify({
      user_id: outbox.user_id,
      entry_type: "WALLET_DEPOSIT",
      amount: outbox.amount,
      currency: outbox.currency,
      direction: "in",
      balance_after: outbox.balance_after,
      reference_id: paymentId,
      metadata: { source: "supabase_2", finance2_payment_id: paymentId, finance2_ledger_id: outbox.ledger_entry_id },
    }),
  });
  if (!response.ok) {
    const error = await response.text();
    await admin.from("primary_ledger_outbox").update({ status: "failed", last_error: error.slice(0, 1000), updated_at: new Date().toISOString() }).eq("payment_id", paymentId);
    throw new Error(`Primary ledger mirror failed: ${response.status}`);
  }
  await admin.from("primary_ledger_outbox").update({ status: "synced", last_error: null, synced_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("payment_id", paymentId);
}
