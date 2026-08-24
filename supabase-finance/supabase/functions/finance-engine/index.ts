  // Manually triggers a Pesapal status check and wallet credit for a given paymentId.
    // Called from the app after the user returns from the Pesapal browser redirect.
    if (action === "reconcile_deposit") {
      const paymentId = body.paymentId as string;
      if (!paymentId) return json({ success: false, message: "paymentId required." }, 400);

      const { data: payment } = await supabase
        .from("payments")
        .select("*")
        .eq("idempotency_key", paymentId)
        .eq("user_id", user.id)
        .maybeSingle();

      if (!payment) return json({ success: false, message: "Payment record not found." }, 404);

      // Already credited — avoid double-credit
      if (payment.settled_at) {
        return json({ success: true, status: "already_credited", message: "This deposit was already credited to your wallet." });
      }

      // Check current Pesapal status
      const token = await getPesapalToken();
      const statusData = await getPesapalTransactionStatus(
        token,
        payment.provider_reference,
      ) as Record<string, unknown>;
      const reconciledStatus = await settleVerifiedPesapalPayment(supabase, payment, statusData);

      if (reconciledStatus === "COMPLETED") {
        return json({ success: true, status: "completed", message: "Deposit confirmed and wallet credited!" });
      }

      if (reconciledStatus === "FAILED") {
        return json({ success: false, status: "failed", message: "Payment was unsuccessful. Please try again." });
      }

      return json({ success: true, status: "pending", message: "Payment is still processing. Please wait." });
    }

    // ── Action: check_withdrawal_eligibility ──────────────────────────────
    // This is a user-facing preview. The same rule is enforced again by the
    // database trigger when the withdrawal is created.
    if (action === "check_withdrawal_eligibility") {
      const amount = Number(body.amount ?? 0);
      if (!Number.isSafeInteger(amount) || amount <= 0) {
        return json({ success: false, message: "Invalid withdrawal amount." }, 400);
      }
      const { data: assessment, error } = await supabase.rpc("assert_withdrawal_eligible", {
        p_user_id: user.id,
        p_amount: amount,
      });
      if (error) {
        return json({
          success: false,
          code: "withdrawal_not_eligible",
          message: error.message,
        }, 403);
      }
      return json({ success: true, eligibility: assessment });
    }

    // ── Action: send_withdrawal_otp ───────────────────────────────────────
    if (action === "send_withdrawal_otp") {
      const { data: profile } = await supabase
        .from("profiles")
        .select("email")
        .eq("id", user.id)
        .maybeSingle();

      const email = profile?.email || user.email || null;
      if (!email) return json({ success: false, message: "No email available for OTP delivery." }, 400);

      const otp = createWithdrawalOtp();
      const codeHash = await hmacSha256Hex(otp);
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();

      try {
        await queueWithdrawalOtpDelivery(email, otp);
      } catch (deliveryErr) {
        return json({
          success: false,
          message: deliveryErr instanceof Error ? deliveryErr.message : "OTP delivery is unavailable.",
        }, 503);
      }

      const { error: upsertErr } = await supabase.from("withdrawal_otps").upsert({
        user_id: user.id,
        code_hash: codeHash,
        expires_at: expiresAt,
        attempts: 0,
        consumed_at: null,
      }, { onConflict: "user_id" });
      if (upsertErr) throw new Error(upsertErr.message);

      return json({ success: true, sent: true, expiresAt });
    }

    // ── Action: request_withdrawal ────────────────────────────────────────
    if (action === "request_withdrawal") {
      const amount = Number(body.amount ?? 0);
      const method = String(body.method ?? "mtn").trim().toLowerCase();
      const accountNumber = String(body.accountNumber ?? "").trim();
      const recipientName = String(body.recipientName ?? "").trim();
      const idempotencyKey = String(body.idempotencyKey ?? `withdraw-${user.id}-${Date.now()}`).trim();
      const securityMetadata = body.securityMetadata ?? {};
      const emailOtp = String(body.emailOtp ?? "").trim();

      if (!amount || amount <= 0) return json({ success: false, message: "Invalid amount." }, 400);
      if (!idempotencyKey) return json({ success: false, message: "A valid idempotency key is required." }, 400);
      // Airtel and bank rails have no provider implementation yet. Reject them
      // before the wallet is debited rather than leaving a user with a payout
      // that can never be completed.
      if (method !== "mtn") {
        return json({ success: false, message: "Only MTN Mobile Money withdrawals are available right now." }, 400);
      }
      if (!accountNumber || !recipientName) return json({ success: false, message: "Account number and recipient name are required." }, 400);
      if (!isValidWithdrawalOtp(emailOtp)) return json({ success: false, message: "A valid 6-digit OTP is required." }, 400);

      const otpHash = await hmacSha256Hex(emailOtp);
      const destinationCiphertext = await encryptWithdrawalDestination({ accountNumber, recipientName });

      // If MTN method, run conservative device/fraud reservation guard first.
      if (method === 'mtn') {
        const normalizedMsisdn = normalizeUgandanMsisdn(accountNumber);
        if (!normalizedMsisdn) {
          return json({ success: false, message: "Enter a valid Ugandan mobile-money number." }, 400);
        }
        const deviceFingerprint = securityMetadata?.device_fingerprint ?? null;
        const riskScore = securityMetadata && securityMetadata.risk_score != null ? Number(securityMetadata.risk_score) : null;
        const isDeviceTrusted = securityMetadata && securityMetadata.is_device_trusted != null ? Boolean(securityMetadata.is_device_trusted) : null;

        const { error: reserveErr } = await supabase.rpc('reserve_mtn_withdrawal', {
          p_user_id: user.id,
          p_amount: amount,
          p_device_fingerprint: deviceFingerprint,
          p_risk_score: riskScore,
          p_is_device_trusted: isDeviceTrusted,
          p_idempotency_key: idempotencyKey,
        });
        if (reserveErr) {
          // Forward reservation failure (e.g., blocked by risk rules)
          return json({ success: false, message: reserveErr.message }, 403);
        }
      }

      const { data, error: rpcErr } = await supabase.rpc("create_withdrawal_request", {
        p_user_id: user.id,
        p_amount: amount,
        p_method: method,
        p_destination_ciphertext: destinationCiphertext,
        p_recipient_name: recipientName,
        p_otp_hash: otpHash,
        p_idempotency_key: idempotencyKey,
        p_metadata: securityMetadata,
      });
      if (rpcErr) return json({ success: false, message: rpcErr.message }, 400);

      const withdrawal = Array.isArray(data) ? data[0] ?? data : data; // handle rpc single/maybeSingle shapes

      // If MTN, attempt external disbursement and update workflow status accordingly.
      if (method === 'mtn') {
        const withdrawalId = String(withdrawal?.id ?? "");
        if (!withdrawalId) return json({ success: false, message: "Withdrawal could not be created." }, 500);

        // Only one request may submit a particular withdrawal to MTN. This is
        // an atomic database claim, so retried HTTP requests cannot pay twice.
        const { data: claimed, error: claimErr } = await supabase.rpc('claim_mtn_disbursement', {
          p_withdrawal_id: withdrawalId,
        });
        if (claimErr) throw new Error(claimErr.message);
        if (!claimed) {
          return json({
            success: true,
            withdrawal,
            withdrawalId,
            status: withdrawal.workflow_status ?? "processing",
            message: "Withdrawal is already being processed.",
          });
        }

        try {
          const token = await getMtnAccessToken();
          const msisdn = normalizeUgandanMsisdn(accountNumber)!;
          const depositResult = await makeMtnDeposit(token, withdrawal, amount, msisdn);

          // Persist provider response into withdrawals.metadata for audit/debugging
          try {
            const existingMeta = (withdrawal && (withdrawal.metadata ?? {})) || {};
            const newMeta = { ...existingMeta, provider_response: depositResult };
            const { error: metaErr } = await supabase
              .from('withdrawals')
              .update({ metadata: newMeta })
              .eq('id', withdrawalId)
              .select()
              .single();
            if (metaErr) console.error('Failed to persist withdrawal metadata:', metaErr.message || metaErr);
          } catch (mErr) {
            console.error('Exception while persisting metadata:', mErr);
          }

          const providerRef = depositResult.referenceId;
          await supabase.rpc('transition_withdrawal_status', {
            p_withdrawal_id: withdrawalId,
            p_new_status: 'processing',
            p_operator_id: 'mtn-disbursement',
            p_provider_reference: providerRef,
          });

          return json({
            success: true,
            withdrawal,
            withdrawalId,
            status: 'processing',
            providerReference: providerRef,
          });
        } catch (err) {
          const errMsg = (err as Error).message || String(err);
          try {
            await supabase.rpc('transition_withdrawal_status', {
              p_withdrawal_id: withdrawalId,
              p_new_status: 'failed',
              p_operator_id: 'mtn-disbursement',
              p_note: errMsg,
            });
          } catch (tErr) {
            console.error('Failed to mark withdrawal failed:', tErr);
          }
          try {
            // Save provider error into metadata for later inspection
            const existingMeta = (withdrawal && (withdrawal.metadata ?? {})) || {};
            const newMeta = { ...existingMeta, provider_response: { error: errMsg } };
            const { error: metaErr } = await supabase
              .from('withdrawals')
              .update({ metadata: newMeta })
              .eq('id', withdrawalId)
              .select()
              .single();
            if (metaErr) console.error('Failed to persist failure metadata:', metaErr.message || metaErr);
          } catch (mErr) {
            console.error('Exception while persisting failure metadata:', mErr);
          }
          try {
            await supabase.rpc('refund_failed_withdrawal', { p_withdrawal_id: withdrawalId, p_reason: errMsg });
          } catch (rErr) {
            console.error('Refund failed after MTN error:', rErr);
          }
          return json({ success: false, message: 'Disbursement failed: ' + errMsg }, 500);
        }
      }

      return json({
        success: true,
        withdrawal,
        withdrawalId: withdrawal?.id,
        status: withdrawal?.workflow_status ?? withdrawal?.status,
      });
    }

    // ── Action: withdrawal_status ─────────────────────────────────────────
    if (action === "withdrawal_status") {
      const withdrawalId = String(body.withdrawalId ?? "");
      if (!withdrawalId) return json({ success: false, message: "withdrawalId required." }, 400);
      const { data, error } = await supabase.from("withdrawals")
        .select("*").eq("id", withdrawalId).eq("user_id", user.id).maybeSingle();
      if (error) throw new Error(error.message);
      if (!data) return json({ success: false, message: "Withdrawal not found." }, 404);

      // A callback can be missed, so the status endpoint also reconciles any
      // in-flight MTN request with MTN before reporting its state to the user.
      let withdrawal = data;
      if (data.method === "mtn" && data.workflow_status === "processing" && data.provider_reference) {
        try {
          withdrawal = await reconcileMtnWithdrawal(supabase, data);
        } catch (statusError) {
          console.error("MTN withdrawal reconciliation failed:", statusError);
        }
      }
      return json({
        success: true,
        withdrawal,
        withdrawalId: withdrawal.id,
        status: withdrawal.workflow_status ?? withdrawal.status,
      });
    }

    return json({ success: false, message: `Unknown action: ${action}` }, 400);
  } catch (err) {
    console.error("finance-engine error:", err);
    return json({ success: false, message: (err as Error).message }, 500);
  }
});

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
