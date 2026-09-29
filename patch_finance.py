import re

with open('supabase/functions/finance-engine/index.ts', 'r', encoding='utf-8') as f:
    content = f.read()

new_actions = '''
    // ── Action: initiate_property_unlock ─────────────────────────────────────
    if (action === "initiate_property_unlock") {
      const listingId = String(body.listingId ?? "");
      const method = String(body.method ?? "momo").toLowerCase();
      const amountUgx = Math.trunc(Number(body.amountUgx));
      const idempotencyKey = String(body.idempotencyKey ?? crypto.randomUUID());

      if (!listingId || !Number.isFinite(amountUgx) || amountUgx <= 0) {
        return json({ success: false, message: "Invalid property unlock request." }, 400);
      }

      if (method === "ncx_coins") {
        const { data: ncxResult, error: ncxError } = await supabase.rpc("charge_ncx_purpose", {
          p_user_id: user.id,
          p_amount_ncx: amountUgx,
          p_purpose: "feature_unlock",
          p_reference: `unlock_${listingId}`,
          p_idempotency_key: idempotencyKey,
        });

        if (ncxError) return json({ success: false, message: ncxError.message }, 409);

        const primaryAdmin = createClient(PRIMARY_SUPABASE_URL, PRIMARY_SUPABASE_SERVICE_ROLE_KEY);
        const { data: prop } = await primaryAdmin.from("properties").select("lister_id, agent_id").eq("id", listingId).single();
        
        const { error: unlockError } = await primaryAdmin.from("unlocks").upsert({
          property_id: listingId,
          buyer_id: user.id,
          seller_id: prop?.lister_id || null,
          agent_id: prop?.agent_id || null,
          unlock_amount: amountUgx,
          unlock_cost: amountUgx,
          status: "completed",
          address_revealed_at: new Date().toISOString(),
          contact_revealed_at: new Date().toISOString(),
        }, { onConflict: "property_id, buyer_id" });

        if (unlockError) console.error("Unlock sync failed:", unlockError);

        return json({ success: true, paymentId: idempotencyKey });
      }

      if (method === "pesapal" || method === "momo" || method === "card" || method === "mtn" || method === "airtel") {
        const { data: profile } = await supabase.from("profiles").select("full_name, email, phone").eq("id", user.id).maybeSingle();
        const fullName = profile?.full_name || user.user_metadata?.full_name || "Guest";
        const [firstName, ...rest] = fullName.split(" ");
        const lastName = rest.join(" ") || "—";
        const email = profile?.email || user.email || "no-reply@necxa.app";
        const userPhone = profile?.phone || user.phone || "";

        const pesapalToken = await getPesapalToken();
        const orderResult = await submitPesapalOrder(pesapalToken, {
          id: idempotencyKey,
          amount: amountUgx,
          currency: "UGX",
          description: `Necxa Unlock Property ${listingId}`,
          firstName,
          lastName,
          email,
          phone: userPhone,
          branch: "Necxa - Property Unlock",
        });

        const { error: paymentRecordError } = await supabase.from("payments").upsert({
          user_id: user.id,
          provider: "pesapal",
          provider_reference: orderResult.order_tracking_id,
          idempotency_key: idempotencyKey,
          purpose: "property_unlock",
          amount: amountUgx,
          currency: "UGX",
          status: "pending",
          request: { type: "property_unlock", listingId, method },
          response: orderResult,
        }, { onConflict: "idempotency_key" });

        if (paymentRecordError) throw new Error(`PesaPal property unlock record failed: ${paymentRecordError.message}`);

        return json({ success: true, redirectUrl: orderResult.redirect_url, paymentId: idempotencyKey });
      }

      return json({ success: false, message: "Unsupported payment method." }, 400);
    }

    // ── Action: property_unlock_status ───────────────────────────────────────
    if (action === "property_unlock_status") {
      const paymentId = String(body.paymentId ?? "");
      if (!paymentId) return json({ success: false, message: "paymentId required." }, 400);

      const { data: payment } = await supabase.from("payments").select("*").eq("idempotency_key", paymentId).eq("user_id", user.id).single();
      if (!payment) return json({ success: false, message: "Payment not found." }, 404);

      let currentStatus = String(payment.status).toLowerCase();

      if (currentStatus === "pending") {
        const token = await getPesapalToken();
        const statusData = await getPesapalTransactionStatus(token, payment.provider_reference) as Record<string, unknown>;
        currentStatus = await settleVerifiedPesapalPayment(supabase, payment, statusData);
        currentStatus = currentStatus.toLowerCase();
      }

      if (currentStatus === "completed") {
        const listingId = payment.request?.listingId;
        if (listingId) {
          const primaryAdmin = createClient(PRIMARY_SUPABASE_URL, PRIMARY_SUPABASE_SERVICE_ROLE_KEY);
          const { data: prop } = await primaryAdmin.from("properties").select("lister_id, agent_id").eq("id", listingId).maybeSingle();
          await primaryAdmin.from("unlocks").upsert({
            property_id: listingId,
            buyer_id: user.id,
            seller_id: prop?.lister_id || null,
            agent_id: prop?.agent_id || null,
            unlock_amount: payment.amount,
            unlock_cost: payment.amount,
            status: "completed",
            address_revealed_at: new Date().toISOString(),
            contact_revealed_at: new Date().toISOString(),
          }, { onConflict: "property_id, buyer_id" });
        }
      }

      return json({ success: true, status: currentStatus });
    }
'''

content = content.replace('if (action === "coin_purchase_status") {', new_actions + '\n    // ── Action: coin_purchase_status ──────────────────────────────────────────\n    if (action === "coin_purchase_status") {')

with open('supabase/functions/finance-engine/index.ts', 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated finance-engine")
