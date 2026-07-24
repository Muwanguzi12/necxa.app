const functions = require("firebase-functions");
const admin     = require("firebase-admin");
const speakeasy = require("speakeasy");
const qrcode    = require("qrcode");
const nodemailer = require("nodemailer"); // Ensure nodemailer is in your package.json
const axios      = require("axios");

admin.initializeApp();
const db = admin.firestore();

// ── DYNAMIC FOREX CONFIG ───────────────────────────────────────────────────
let FOREX_RATES = {
  USD_TO_UGX: 3800, // Fallback
  last_updated: null
};

// Internal helper to get latest rates from Firestore
async function getCachedRates() {
  try {
    const doc = await db.collection("system_config").doc("forex").get();
    if (doc.exists) {
      FOREX_RATES = doc.data();
      return FOREX_RATES;
    }
  } catch (e) {
    console.error("Forex Cache Error:", e);
  }
  return FOREX_RATES;
}

// Helper for sending emails
async function getMailTransporter() {
  // In production, use environment variables for a real SMTP service like SendGrid, Mailgun, or Resend.
  // These secrets should be stored in Firebase Secret Manager.
  const smtpHost = process.env.SMTP_HOST;
  const smtpUser = process.env.SMTP_USER;
  const smtpPass = process.env.SMTP_PASS;

  if (!smtpHost || !smtpUser || !smtpPass) {
    console.warn("SMTP credentials not configured. Email will not be sent.");
    return null;
  }

  return nodemailer.createTransport({
    host: smtpHost,
    port: 587,
    secure: false, // true for 465, false for other ports
    auth: {
      user: smtpUser,
      pass: smtpPass,
    },
  });
}

/**
 * Helper for sending a transaction receipt email.
 */
async function sendPurchaseReceiptEmail(email, { tx_id, date, description, amount_ncx, amount_fiat, currency, method, new_balance_ncx }) {
  const transporter = await getMailTransporter();
  if (!transporter) return;

  const html = `
    <div style="font-family: sans-serif; padding: 20px; color: #333; max-width: 600px; margin: auto; border: 1px solid #ddd;">
      <h2 style="color: #0052FF;">Transaction Receipt</h2>
      <p>Hello,</p>
      <p>Your recent purchase of Necxa Coins was successful. Here are the details:</p>
      <table style="width: 100%; border-collapse: collapse; margin: 20px 0;">
        <tr style="border-bottom: 1px solid #eee;"><td style="padding: 8px;">Transaction ID:</td><td style="padding: 8px; text-align: right;">${tx_id}</td></tr>
        <tr style="border-bottom: 1px solid #eee;"><td style="padding: 8px;">Date:</td><td style="padding: 8px; text-align: right;">${date}</td></tr>
        <tr style="border-bottom: 1px solid #eee;"><td style="padding: 8px;">Description:</td><td style="padding: 8px; text-align: right;">${description}</td></tr>
        <tr style="border-bottom: 1px solid #eee;"><td style="padding: 8px;">Coins Purchased:</td><td style="padding: 8px; text-align: right; font-weight: bold;">${amount_ncx} NCX</td></tr>
        <tr style="border-bottom: 1px solid #eee;"><td style="padding: 8px;">Amount Paid:</td><td style="padding: 8px; text-align: right;">${amount_fiat.toLocaleString()} ${currency}</td></tr>
        <tr style="border-bottom: 1px solid #eee;"><td style="padding: 8px;">Payment Method:</td><td style="padding: 8px; text-align: right;">${method}</td></tr>
      </table>
      <p style="font-size: 18px;">Your new coin balance is: <strong style="color: #0052FF;">${new_balance_ncx.toLocaleString()} NCX</strong></p>
      <p>Thank you for being a part of the Necxa network.</p>
      <p><em>The Necxa Team</em></p>
    </div>
  `;

  await transporter.sendMail({
    from: '"Necxa Finance" <no-reply@necxa.uk>',
    to: email,
    subject: "Your Necxa Coin Purchase Receipt",
    html: html,
  });
}

// ── Economics ──
const NCX_PRICE_USD = 0.0263; // 1 NCX = ~0.0263 USD (equivalent to ~100 UGX at 3800 rate)
const BURN_RATE     = 0.11;   // 11% liquidation tax
const GIFT_PLATFORM_FEE = 0.20; // 20% platform cut on gifts

// ── Gift Items Catalogue (mirrors SQL seed) ──────────────────────────────────
const GIFT_CATALOGUE = [
  { id: "rose",        name: "Rose",         emoji: "🌹",  ncx_value: 1,     category: "standard",  sort_order: 1  },
  { id: "clap",        name: "Clap",         emoji: "👏",  ncx_value: 2,     category: "standard",  sort_order: 2  },
  { id: "heart",       name: "Heart",        emoji: "❤️",  ncx_value: 3,     category: "standard",  sort_order: 3  },
  { id: "coffee",      name: "Coffee",       emoji: "☕",  ncx_value: 5,     category: "standard",  sort_order: 4  },
  { id: "star",        name: "Star",         emoji: "⭐",  ncx_value: 5,     category: "standard",  sort_order: 5  },
  { id: "fire",        name: "Fire",         emoji: "🔥",  ncx_value: 10,    category: "standard",  sort_order: 6  },
  { id: "rocket",      name: "Rocket",       emoji: "🚀",  ncx_value: 20,    category: "rare",      sort_order: 10 },
  { id: "crown",       name: "Crown",        emoji: "👑",  ncx_value: 25,    category: "rare",      sort_order: 11 },
  { id: "diamond",     name: "Diamond",      emoji: "💎",  ncx_value: 50,    category: "rare",      sort_order: 12 },
  { id: "trophy",      name: "Trophy",       emoji: "🏆",  ncx_value: 50,    category: "rare",      sort_order: 13 },
  { id: "moneybag",    name: "Money Bag",    emoji: "💰",  ncx_value: 100,   category: "rare",      sort_order: 14 },
  { id: "sportscar",   name: "Sports Car",   emoji: "🏎️", ncx_value: 200,   category: "epic",      sort_order: 20 },
  { id: "yacht",       name: "Yacht",        emoji: "⛵",  ncx_value: 300,   category: "epic",      sort_order: 21 },
  { id: "villa",       name: "Villa",        emoji: "🏡",  ncx_value: 500,   category: "epic",      sort_order: 22 },
  { id: "jet",         name: "Private Jet",  emoji: "✈️",  ncx_value: 1000,  category: "legendary", sort_order: 30 },
  { id: "palace",      name: "NECXA Palace", emoji: "🏰",  ncx_value: 5000,  category: "legendary", sort_order: 31 },
  { id: "galaxy",      name: "Galaxy",       emoji: "🌌",  ncx_value: 10000, category: "legendary", sort_order: 32 },
];

// ── Seed gift_items on first call ────────────────────────────────────────────
async function ensureGiftCatalogue() {
  const snap = await db.collection("gift_items").limit(1).get();
  if (!snap.empty) return;
  const batch = db.batch();
  GIFT_CATALOGUE.forEach((item) => {
    const ref = db.collection("gift_items").doc(item.id);
    batch.set(ref, { ...item, ugx_value: item.ncx_value * 100, is_active: true });
  });
  await batch.commit();
}

/**
 * recordLedgerEntry
 * Creates an immutable record of balance changes for independent reconciliation.
 * Synced to both Firestore (legacy/fast read) and Supabase (cryptographic ledger).
 */
async function recordLedgerEntry(userId, { type, amount, currency, direction, metadata, reference_id }, tx = null) {
  const ref = db.collection("ledger_entries").doc();
  const entry = {
    user_id: userId,
    type,
    amount,
    currency, // 'NCX' or 'UGX'
    direction, // 'in' or 'out'
    metadata: metadata || {},
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
    audit_id: ref.id
  };
  
  if (tx) {
    tx.set(ref, entry);
  } else {
    await ref.set(entry);
  }

// dual-write mapper
  const typeMap = {
    "buy_coins": "COIN_PURCHASE",
    "wallet_topup": "WALLET_DEPOSIT",
    "listing_unlock": "LISTING_UNLOCK",
    "feature_unlock": "FEATURE_UNLOCK",
    "feature_unlock_fee": "PLATFORM_FEE",
    "gift_sent": "GIFT_SENT",
    "gift_received": "GIFT_RECEIVED",
    "gift_fee": "PLATFORM_FEE",
    "withdraw_fiat": "WITHDRAWAL",
    "shop_commission": "PLATFORM_FEE",
    "liquidation_out": "COIN_SALE", // More specific than WITHDRAWAL
    "liquidation_in": "FIAT_CREDIT_FROM_SALE", // More specific
    "shop_purchase": "SHOP_PURCHASE", // Corrected: was missing
    "delivery_fee": "DELIVERY_FEE",
    "escrow_deposit": "ESCROW_DEPOSIT",
    "escrow_release": "ESCROW_RELEASE",
    "escrow_refund": "ESCROW_REFUND"
  };
  const supabaseType = typeMap[type] || type.toUpperCase();

  // Dual-Write to Supabase Immutable Ledger
  try {
    const supabaseUrl = process.env.SUPABASE_URL;
    const supabaseKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (supabaseUrl && supabaseKey) {
      axios.post(`${supabaseUrl}/rest/v1/immutable_financial_ledger`, {
        user_id: userId,
        entry_type: supabaseType,
        amount: Math.round(amount), // Ensure integer for bigint
        currency: currency,
        direction: direction,
        balance_after: 0, // Supabase calculates this via trigger in the future, or we just supply 0 for now
        reference_id: reference_id || null,
        metadata: { ...metadata, firestore_audit_id: ref.id }
      }, {
        headers: {
          'apikey': supabaseKey,
          'Authorization': `Bearer ${supabaseKey}`,
          'Content-Type': 'application/json',
          'Prefer': 'return=minimal'
        }
      }).catch(err => {
        console.error("Supabase Ledger Sync Error:", err.response?.data || err.message);
      });
    } else {
      console.warn("SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY missing. Skipping Supabase ledger sync.");
    }
  } catch (e) {
    console.error("Failed to initiate Supabase sync:", e.message);
  }
}

/**
 * ensurePaymentMethod
 * Validates if a payment channel is active and supports the requested operation.
 */
async function ensurePaymentMethod(methodId, amount, type) {
  const ref = db.collection("system_config").doc("payment_methods");
  const doc = await ref.get();
  
  // Default fallback if config doesn't exist
  if (!doc.exists) return true; 

  const methods = doc.data().methods || {};
  const m = methods[methodId];

  if (!m) throw new functions.https.HttpsError("not-found", `Payment method ${methodId} not supported.`);
  if (m.status !== "active") throw new functions.https.HttpsError("unavailable", `Method ${methodId} is currently ${m.status}.`);
  if (m.type !== "both" && m.type !== type) throw new functions.https.HttpsError("permission-denied", `Method ${methodId} does not support ${type}.`);
  if (amount < m.min_amount) throw new functions.https.HttpsError("out-of-range", `Minimum amount for ${methodId} is ${m.min_amount}.`);
  if (amount > m.max_amount) throw new functions.https.HttpsError("out-of-range", `Maximum amount for ${methodId} is ${m.max_amount}.`);
  
  return true;
}

/**
 * initPaymentSystem
 * Seeds the initial payment method configuration.
 */
exports.initPaymentSystem = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "Auth required.");
  
  const initialMethods = {
    methods: {
      mtn: { 
        id: "mtn", name: "MTN Mobile Money", status: "active", 
        type: "both", min_amount: 500, max_amount: 5000000 
      },
      airtel: { 
        id: "airtel", name: "Airtel Money", status: "active", 
        type: "both", min_amount: 500, max_amount: 5000000 
      },
      card: { 
        id: "card", name: "Bank / Card", status: "active", 
        type: "both", min_amount: 50000, max_amount: 20000000 
      }
    }
  };

  await db.collection("system_config").doc("payment_methods").set(initialMethods);
  return { success: true, message: "Payment system initialized with default methods." };
});

// NEW: Transport Index configuration (example structure in Firestore)
/*
  Firestore document at `system_config/transport_index`:
  {
    "base_rate_per_km_ugx": 1500,
    "fuel_surcharge_pct": 0.05, // 5%
    "weight_tiers": [
      { "max_kg": 1, "multiplier": 1.0 },
      { "max_kg": 5, "multiplier": 1.2 },
      { "max_kg": 20, "multiplier": 1.8 },
      { "max_kg": 80, "multiplier": 3.0 }
    ],
    "speed_multipliers": {
      "express": 1.8,
      "standard": 1.0,
      "batch": 0.7
    }
  }
*/

/**
 * NEW: Calculates delivery distance between two geo-points (Haversine formula).
 * @param {object} origin - { lat, lon }
 * @param {object} destination - { lat, lon }
 * @returns {number} Distance in kilometers.
 */
function getDistanceInKm(origin, destination) {
  const R = 6371; // Radius of the Earth in km
  const dLat = (destination.lat - origin.lat) * Math.PI / 180;
  const dLon = (destination.lon - origin.lon) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(origin.lat * Math.PI / 180) * Math.cos(destination.lat * Math.PI / 180) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}


/**
 * NEW: Calculates the delivery fee based on distance, weight, and speed.
 * @param {number} distanceKm - The delivery distance in kilometers.
 * @param {number} weightKg - The weight of the package in kilograms.
 * @param {string} speed - The delivery speed ('express', 'standard', 'batch').
 * @returns {Promise<number>} The calculated delivery fee in UGX.
 */
async function calculateDeliveryFee(distanceKm, weightKg, speed) {
  const configDoc = await db.collection("system_config").doc("transport_index").get();
  if (!configDoc.exists) {
    console.error("Transport Index configuration is missing!");
    return 5000; // Fallback fee
  }
  const config = configDoc.data();

  // 1. Get base rate for distance
  let fee = distanceKm * config.base_rate_per_km_ugx;

  // 2. Apply weight multiplier
  const weightTier = config.weight_tiers.find(tier => weightKg <= tier.max_kg) || config.weight_tiers[config.weight_tiers.length - 1];
  fee *= weightTier.multiplier;

  // 3. Apply speed multiplier
  const speedMultiplier = config.speed_multipliers[speed] || 1.0;
  fee *= speedMultiplier;

  // 4. Add fuel surcharge
  fee *= (1 + config.fuel_surcharge_pct);

  // Return a rounded, sensible integer value (e.g., to the nearest 100 UGX)
  return Math.ceil(fee / 100) * 100;
}

// ═══════════════════════════════════════════════════════════════════════════
// SHOP E-COMMERCE & LOGISTICS PAYMENT (INTERNAL WALLET)
// ═══════════════════════════════════════════════════════════════════════════

exports.processShopPurchase = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "Auth required.");
  const userId = context.auth.uid;
  // CORRECTED: Signature now matches the frontend and includes all required data.
  const { orderId, listingId, vendorId, sku, quantity, deliverySpeed, customerLocation, customerNumber } = data;

  // VALIDATION: Check for new required fields
  if (!orderId || !listingId || !vendorId || !deliverySpeed || !customerLocation?.lat || !customerNumber) {
    throw new functions.https.HttpsError("invalid-argument", "Missing required shop, customer, and delivery parameters.");
  }

  try {
    // --- SERVER-SIDE CALCULATION (as you designed) ---
    const listingDoc = await db.collection("listings").doc(listingId).get();
    if (!listingDoc.exists) {
      throw new functions.https.HttpsError("not-found", "Product listing not found.");
    }
    const listingData = listingDoc.data();
    const productWeightKg = (listingData.weight_kg || 1) * (quantity || 1);
    const vendorLocation = listingData.location;

    if (!vendorLocation?.lat) {
      throw new functions.https.HttpsError("failed-precondition", "Vendor location is not set for this product.");
    }

    const distanceKm = getDistanceInKm(vendorLocation, customerLocation);
    const serverCalculatedDeliveryFeeUgx = await calculateDeliveryFee(distanceKm, productWeightKg, deliverySpeed);
    
    const itemsTotalUgx = (listingData.price_ugx || 0) * (quantity || 1);
    if (itemsTotalUgx <= 0) {
      throw new functions.https.HttpsError("failed-precondition", "Invalid item price.");
    }
    // --- END SERVER-SIDE CALCULATION ---

    const rates = await getCachedRates();
    const ugxPerNcx = NCX_PRICE_USD * rates.USD_TO_UGX;
    const ncxItemsCost = Math.ceil(itemsTotalUgx / ugxPerNcx);
    const ncxDeliveryCost = Math.ceil(serverCalculatedDeliveryFeeUgx / ugxPerNcx);
    const totalNcxCost = ncxItemsCost + ncxDeliveryCost;

    return await db.runTransaction(async (tx) => {
      const walletRef = db.collection("wallets").doc(userId);
      const walletDoc = await tx.get(walletRef);

      if (!walletDoc.exists) throw new functions.https.HttpsError("not-found", "Wallet not found.");
      const currentBalance = walletDoc.data().coin_balance || 0;

      if (currentBalance < totalNcxCost) {
        throw new functions.https.HttpsError("resource-exhausted", "Insufficient NCX balance for shop purchase.");
      }

      // Deduct total balance
      tx.update(walletRef, {
        coin_balance: admin.firestore.FieldValue.increment(-totalNcxCost)
      });

      const vendorPlatformFee = Math.floor(ncxItemsCost * 0.03);
      const vendorNetEarned = ncxItemsCost - vendorPlatformFee;

      // Credit Vendor for the item (minus 3% platform fee)
      const vendorWalletRef = db.collection("wallets").doc(vendorId);
      tx.set(vendorWalletRef, {
        coin_balance: admin.firestore.FieldValue.increment(vendorNetEarned)
      }, { merge: true });

      // Mark Order Paid and save all details
      const orderRef = db.collection("orders").doc(orderId);
      const tripId = `TRIP-${orderId.split('-')[1] || Date.now()}`;
      tx.update(orderRef, {
        status: "paid",
        payment_method: "balance",
        items_ncx: ncxItemsCost,
        delivery_ncx: ncxDeliveryCost,
        trip_id: tripId,
        delivery_details: {
          speed: deliverySpeed,
          distance_km: distanceKm.toFixed(2),
          weight_kg: productWeightKg,
          customer_location: customerLocation,
          customer_number: customerNumber,
          vendor_location: vendorLocation,
          calculated_fee_ugx: serverCalculatedDeliveryFeeUgx
        },
        paid_at: admin.firestore.FieldValue.serverTimestamp()
      });

      // Ledger Entry for Shop Purchase (Goods)
      await recordLedgerEntry(userId, {
        type: "shop_purchase", amount: ncxItemsCost, currency: "NCX", direction: "out", reference_id: orderId,
        metadata: { sku, listing_id: listingId, quantity, ugx_value: itemsTotalUgx }
      }, tx);

      await recordLedgerEntry(vendorId, {
        type: "shop_purchase", amount: vendorNetEarned, currency: "NCX", direction: "in", reference_id: orderId,
        metadata: { sku, listing_id: listingId, quantity, ugx_value: itemsTotalUgx, fee_deducted: vendorPlatformFee }
      }, tx);

      if (vendorPlatformFee > 0) {
        await recordLedgerEntry("platform_revenue", {
          type: "shop_commission", amount: vendorPlatformFee, currency: "NCX", direction: "in", reference_id: orderId,
          metadata: { source: "shop_vendor_commission", sku }
        }, tx);
      }

      // Ledger Entry for Delivery/Logistics Trip
      if (ncxDeliveryCost > 0) {
        await recordLedgerEntry(userId, {
          type: "delivery_fee", amount: ncxDeliveryCost, currency: "NCX", direction: "out", reference_id: orderId,
          metadata: { trip_id: tripId, ugx_value: serverCalculatedDeliveryFeeUgx, speed: deliverySpeed, distance: distanceKm.toFixed(2) }
        }, tx);
      }

      return { success: true, message: "Shop purchase completed successfully." };
    });
  } catch (error) {
    console.error("🔥 processShopPurchase Error:", error);
    if (error instanceof functions.https.HttpsError) throw error;
    throw new functions.https.HttpsError("internal", error.message);
  }
});

exports.completeDeliveryTrip = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "Auth required.");
  const driverId = context.auth.uid;
  const { orderId } = data;

  if (!orderId) throw new functions.https.HttpsError("invalid-argument", "Missing orderId.");

  return await db.runTransaction(async (tx) => {
    const orderRef = db.collection("orders").doc(orderId);
    const orderDoc = await tx.get(orderRef);

    if (!orderDoc.exists) throw new functions.https.HttpsError("not-found", "Order not found.");
    const orderData = orderDoc.data();

    if (orderData.driver_id !== driverId) {
      throw new functions.https.HttpsError("permission-denied", "You are not assigned to this trip.");
    }
    if (orderData.driver_paid) {
      throw new functions.https.HttpsError("already-exists", "Driver has already been paid for this trip.");
    }
    if (orderData.status !== "paid" && orderData.status !== "completed") {
      throw new functions.https.HttpsError("failed-precondition", "Order must be paid before trip completion.");
    }

    // Determine the delivery value in NCX
    let ncxDeliveryValue = orderData.delivery_ncx;
    if (!ncxDeliveryValue && orderData.metadata?.delivery_ugx) {
       // Convert UGX to NCX if paying via pesapal
       const rates = await getCachedRates();
       const ugxPerNcx = NCX_PRICE_USD * rates.USD_TO_UGX;
       ncxDeliveryValue = Math.ceil(orderData.metadata.delivery_ugx / ugxPerNcx);
    }
    if (!ncxDeliveryValue) {
       ncxDeliveryValue = 0; // fallback if no fee
    }

    // Calculate 4% Platform Fee
    const platformFee = Math.floor(ncxDeliveryValue * 0.04);
    const driverNetEarned = ncxDeliveryValue - platformFee;

    if (driverNetEarned > 0) {
      // Credit Driver
      const driverWalletRef = db.collection("wallets").doc(driverId);
      tx.set(driverWalletRef, {
        coin_balance: admin.firestore.FieldValue.increment(driverNetEarned)
      }, { merge: true });

      // Record Ledger Entries
      await recordLedgerEntry(driverId, {
        type: "commission_payout", // translates to COMMISSION_PAYOUT
        amount: driverNetEarned,
        currency: "NCX",
        direction: "in",
        reference_id: orderId,
        metadata: { trip_id: orderData.trip_id, source: "delivery", fee_deducted: platformFee }
      }, tx);

      if (platformFee > 0) {
        await recordLedgerEntry("platform_revenue", {
          type: "shop_commission",
          amount: platformFee,
          currency: "NCX",
          direction: "in",
          reference_id: orderId,
          metadata: { trip_id: orderData.trip_id, source: "delivery_driver_commission" }
        }, tx);
      }
    }

    // Update order status
    tx.update(orderRef, {
      status: "completed",
      driver_paid: true,
      delivered_at: admin.firestore.FieldValue.serverTimestamp()
    });

    return { success: true, message: "Delivery completed and driver credited." };
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// FEATURE UNLOCKS
// ═══════════════════════════════════════════════════════════════════════════

exports.unlockFeature = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "Auth required.");
  const userId = context.auth.uid;
  const { featureId, ncxCost } = data;

  if (!featureId || !ncxCost || ncxCost <= 0) {
    throw new functions.https.HttpsError("invalid-argument", "Missing required feature parameters (featureId, ncxCost).");
  }

  return await db.runTransaction(async (tx) => {
    const walletRef = db.collection("wallets").doc(userId);
    const walletDoc = await tx.get(walletRef);

    if (!walletDoc.exists) throw new functions.https.HttpsError("not-found", "Wallet not found.");
    const currentBalance = walletDoc.data().coin_balance || 0;

    if (currentBalance < ncxCost) {
      throw new functions.https.HttpsError("resource-exhausted", `Insufficient NCX balance. Have: ${currentBalance}, Need: ${ncxCost}`);
    }

    // 1. Deduct cost from user wallet
    tx.update(walletRef, {
      coin_balance: admin.firestore.FieldValue.increment(-ncxCost)
    });

    // 2. Record that user unlocked the feature
    const featureUnlockRef = db.collection("user_features").doc(userId).collection("unlocked").doc(featureId);
    tx.set(featureUnlockRef, {
        unlocked_at: admin.firestore.FieldValue.serverTimestamp(),
        cost_ncx: ncxCost,
    });

    // 3. Ledger Entry for user's expense
    await recordLedgerEntry(userId, {
      type: "feature_unlock",
      amount: ncxCost,
      currency: "NCX",
      direction: "out",
      reference_id: featureId,
      metadata: { feature: featureId }
    }, tx);

    // 4. Ledger entry for platform revenue
    await recordLedgerEntry("platform_revenue", {
        type: "feature_unlock_fee", // Maps to PLATFORM_FEE
        amount: ncxCost,
        currency: "NCX",
        direction: "in",
        reference_id: featureId,
        metadata: { source: "feature_unlock", user_id: userId }
    }, tx);

    return { success: true, message: `Feature ${featureId} unlocked successfully!` };
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// VAULT FUNCTIONS (existing)
// ═══════════════════════════════════════════════════════════════════════════

exports.liquidateCoins = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "User must be logged in.");
  const { ncxAmount, securityMetadata } = data;
  const userId = context.auth.uid;
  if (!securityMetadata?.lat || !securityMetadata?.device_id)
    throw new functions.https.HttpsError("failed-precondition", "Missing security metadata.");

  return await db.runTransaction(async (tx) => {
    const walletRef = db.collection("wallets").doc(userId);
    const walletDoc = await tx.get(walletRef);
    if (!walletDoc.exists) throw new functions.https.HttpsError("not-found", "Wallet not found.");
    const { coin_balance: currentNcx, fiat_balance: currentFiat } = walletDoc.data();
    if (currentNcx < ncxAmount) throw new functions.https.HttpsError("failed-precondition", "Insufficient NCX.");
    const rates = await getCachedRates();
    const currentUgxPrice = rates.USD_TO_UGX * NCX_PRICE_USD;
    
    const ugxReceived = (ncxAmount * currentUgxPrice) * (1 - BURN_RATE);
    const ncxBurned   = ncxAmount * BURN_RATE;
    tx.update(walletRef, {
      coin_balance: admin.firestore.FieldValue.increment(-ncxAmount),
      fiat_balance: admin.firestore.FieldValue.increment(ugxReceived),
      last_liquidation_at: admin.firestore.FieldValue.serverTimestamp(),
    });
    const txRef = db.collection("vault_transactions").doc();
    tx.set(txRef, { user_id: userId, type: "liquidation", ncx_sold: ncxAmount,
      ncx_burned: ncxBurned, ugx_added: ugxReceived,
      exchange_rate: rates.USD_TO_UGX,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      status: "completed", security: securityMetadata });

    // Independent Audit (Double Entry)
    await recordLedgerEntry(userId, {
      type: "liquidation_out",
      amount: ncxAmount,
      currency: "NCX",
      direction: "out"
    }, tx);
    await recordLedgerEntry(userId, {
      type: "liquidation_in",
      amount: ugxReceived,
      currency: "UGX",
      direction: "in",
      metadata: { ncx_sold: ncxAmount, rate: rates.USD_TO_UGX }
    }, tx);

    // Record the burned NCX as platform revenue
    if (ncxBurned > 0) {
      await recordLedgerEntry("platform_revenue", {
        type: "liquidation_fee", // Maps to PLATFORM_FEE
        amount: ncxBurned,
        currency: "NCX",
        direction: "in",
        metadata: { source: "coin_liquidation_burn", user_id: userId, original_amount: ncxAmount }
      }, tx);
    }

    return { success: true, ugxReceived, ncxBurned,
      newCoinBalance: currentNcx - ncxAmount, newFiatBalance: currentFiat + ugxReceived,
      txCommitHash: txRef.id, currentExchangeRate: rates.USD_TO_UGX, 
      message: `Liquidation successful at rate 1 USD = ${rates.USD_TO_UGX} UGX.` };
  });
});

// ── AML Limit Config ──────────────────────────────────────────────────────
const AML_MAX_USD  = 1000;

exports.withdrawFiat = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "User must be logged in.");

  const { amount, method, accountNumber, recipientName, totpToken, emailOtp, securityMetadata } = data;
  const userId = context.auth.uid;
  const email  = context.auth.token.email;

  const rates = await getCachedRates();
  const dynamicAmlLimitUgx = AML_MAX_USD * rates.USD_TO_UGX;

  // 1. Security metadata required
  if (!securityMetadata?.lat || !securityMetadata?.device_id)
    throw new functions.https.HttpsError("failed-precondition", "Missing security metadata.");

  // 2. Account number required
  if (!accountNumber || String(accountNumber).trim().length < 5)
    throw new functions.https.HttpsError("invalid-argument", "Valid account number is required.");

  // 3. ── AML Hard Cap ──
  if (!amount || amount <= 0)
    throw new functions.https.HttpsError("invalid-argument", "Invalid withdrawal amount.");
  
  if (amount > dynamicAmlLimitUgx)
    throw new functions.https.HttpsError("failed-precondition",
      `Withdrawal exceeds the maximum allowed limit of $${AML_MAX_USD} (UGX ${dynamicAmlLimitUgx.toLocaleString()}) based on current exchange rates.`);

  // 3.5 Validate Availability & Payout Limits
  await ensurePaymentMethod(method, amount, "disbursement");

  // 4. ── 2FA & Email Verification ──
  const securityRef = db.collection("wallets").doc(userId).collection("security").doc("config");
  const securityDoc = await securityRef.get();

  if (securityDoc.exists && securityDoc.data().is_2fa_enabled) {
    if (!totpToken) throw new functions.https.HttpsError("permission-denied", "2FA token required.");
    
    const verified = speakeasy.totp.verify({
      secret: securityDoc.data().two_factor_secret,
      encoding: "base32",
      token: totpToken,
      window: 1 // allow 30s drift
    });

    if (!verified) throw new functions.https.HttpsError("permission-denied", "Invalid 2FA token.");
  }

  // 5. ── Email OTP Check ──
  if (!emailOtp) throw new functions.https.HttpsError("permission-denied", "Email verification code required.");
  const otpRef = db.collection("internal_otps").doc(`${userId}_withdraw`);
  const otpDoc = await otpRef.get();

  if (!otpDoc.exists || otpDoc.data().code !== emailOtp) {
    throw new functions.https.HttpsError("permission-denied", "Invalid or expired email verification code.");
  }
  
  if (otpDoc.data().expires_at.toDate() < new Date()) {
    throw new functions.https.HttpsError("permission-denied", "Email verification code has expired.");
  }

  // Cleanup OTP after use
  await otpRef.delete();

  return await db.runTransaction(async (tx) => {
    const walletRef = db.collection("wallets").doc(userId);
    const walletDoc = await tx.get(walletRef);
    if (!walletDoc.exists) throw new functions.https.HttpsError("not-found", "Wallet not found.");
    const currentFiat = walletDoc.data().fiat_balance || 0;
    if (currentFiat < amount) throw new functions.https.HttpsError("failed-precondition", "Insufficient fiat balance.");
    tx.update(walletRef, {
      fiat_balance: admin.firestore.FieldValue.increment(-amount),
      total_withdrawn_fiat: admin.firestore.FieldValue.increment(amount),
      last_withdrawal_at: admin.firestore.FieldValue.serverTimestamp(),
    });
    const txRef = db.collection("vault_transactions").doc();
    tx.set(txRef, { 
      user_id: userId, 
      type: "withdraw_fiat", 
      amount_withdrawn: amount,
      disbursement_method: method, 
      account_number: accountNumber,
      recipient_name: recipientName,
      status: "pending_review",
      bank_processed: false,
      payout_status: "pending_review",
      processed_at: null,
      provider_reference: null,
      error_message: null,
      timestamp: admin.firestore.FieldValue.serverTimestamp(), 
      security: securityMetadata 
    });

    // Independent Audit
    await recordLedgerEntry(userId, {
      type: "withdraw_fiat",
      amount: amount,
      currency: "UGX",
      direction: "out",
      metadata: { method, account: accountNumber, recipient: recipientName }
    }, tx);

    return { success: true, message: `Withdrawal of UGX ${amount.toLocaleString()} via ${method} to ${accountNumber} initiated.`, tx_id: txRef.id };
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// SECURITY & 2FA FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════

exports.request2FASetup = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "User must be logged in.");
  
  const secret = speakeasy.generateSecret({
    name: `Necxa Finance (${context.auth.token.email})`,
    issuer: "Necxa"
  });

  // Store temporary secret (not enabled yet)
  await db.collection("wallets").doc(context.auth.uid).collection("security").doc("config").set({
    temp_two_factor_secret: secret.base32,
    is_2fa_enabled: false
  }, { merge: true });

  const qrCodeData = await qrcode.toDataURL(secret.otpauth_url);
  return { secret: secret.base32, qrCode: qrCodeData };
});

exports.confirm2FASetup = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "User must be logged in.");
  const { token } = data;

  const securityRef = db.collection("wallets").doc(context.auth.uid).collection("security").doc("config");
  const securityDoc = await securityRef.get();

  if (!securityDoc.exists || !securityDoc.data().temp_two_factor_secret) {
    throw new functions.https.HttpsError("failed-precondition", "2FA setup not initiated.");
  }

  const verified = speakeasy.totp.verify({
    secret: securityDoc.data().temp_two_factor_secret,
    encoding: "base32",
    token: token
  });

  if (verified) {
    await securityRef.update({
      two_factor_secret: securityDoc.data().temp_two_factor_secret,
      temp_two_factor_secret: admin.firestore.FieldValue.delete(),
      is_2fa_enabled: true,
      enabled_at: admin.firestore.FieldValue.serverTimestamp()
    });
    return { success: true, message: "2FA successfully enabled." };
  } else {
    throw new functions.https.HttpsError("permission-denied", "Invalid verification token.");
  }
});

exports.sendWithdrawalOTP = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "User must be logged in.");
  const email = context.auth.token.email;
  if (!email) throw new functions.https.HttpsError("failed-precondition", "No email associated with account.");

  const otp = Math.floor(100000 + Math.random() * 900000).toString();
  
  await db.collection("internal_otps").doc(`${context.auth.uid}_withdraw`).set({
    code: otp,
    expires_at: admin.firestore.Timestamp.fromDate(new Date(Date.now() + 10 * 60 * 1000)), // 10 mins
    created_at: admin.firestore.FieldValue.serverTimestamp()
  });

  // --- FIX: Integrate with real SMTP ---
  const transporter = await getMailTransporter();
  if (transporter) {
    try {
      await transporter.sendMail({
        from: '"Necxa Finance" <no-reply@necxa.uk>',
        to: email,
        subject: "Your Necxa Withdrawal Verification Code",
        text: `Your withdrawal verification code is: ${otp}. It is valid for 10 minutes.`,
        html: `
          <div style="font-family: sans-serif; padding: 20px; color: #333;">
            <h2>Necxa Withdrawal Verification</h2>
            <p>Your one-time verification code is:</p>
            <p style="font-size: 24px; font-weight: bold; letter-spacing: 2px; background: #f0f0f0; padding: 10px 20px; border-radius: 8px; display: inline-block;">${otp}</p>
            <p>This code is valid for 10 minutes. Do not share it with anyone.</p>
            <p>If you did not request this withdrawal, please secure your account immediately.</p>
            <br/>
            <p><em>The Necxa Team</em></p>
          </div>
        `,
      });
    } catch (emailError) {
      console.error("Failed to send withdrawal OTP email:", emailError);
      // We don't throw here, as the OTP is still saved. But we should log this failure.
    }
  } else {
    // Fallback for local dev without SMTP config
    console.log(`[AUTH] Withdrawal OTP for ${email}: ${otp}`);
  }
  
  return { success: true, message: "Verification code sent to your email." };
});

// ═══════════════════════════════════════════════════════════════════════════
// FOREX & SYSTEM CONFIG
// ═══════════════════════════════════════════════════════════════════════════

exports.refreshForexRates = functions.https.onCall(async (data, context) => {
  // Only allow admins or internal scheduled calls in production
  // For now, we allow any authenticated user to trigger a refresh for testing
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "Auth required.");

  try {
    // Using ExchangeRate-API (Free Tier)
    const response = await axios.get("https://open.er-api.com/v6/latest/USD");
    const ugxRate = response.data.rates.UGX;

    if (!ugxRate) throw new Error("UGX rate not found in response.");

    const newRates = {
      USD_TO_UGX: ugxRate,
      all_rates: response.data.rates,
      last_updated: admin.firestore.FieldValue.serverTimestamp(),
      provider: "open.er-api.com"
    };

    await db.collection("system_config").doc("forex").set(newRates);
    
    return { success: true, newRate: ugxRate, message: `Exchange rates updated. 1 USD = ${ugxRate} UGX.` };
  } catch (e) {
    console.error("Forex Update Failed:", e);
    throw new functions.https.HttpsError("internal", `Failed to fetch rates: ${e.message}`);
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// GIFTING FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════

/**
 * processGift (V2 - Supabase Centric)
 * Calls the atomic Supabase function to process a gift transaction.
 * On success, it handles non-financial side-effects like notifications.
 */
exports.processGift = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "User must be logged in.");

  const {
    receiverId, // This is the auth.uid of the receiver
    postId,
    giftItemId, // e.g., "rose", "diamond"
    ncxAmount,
    contextType, // e.g., "creator_post"
    contextNote,
    isAnonymous,
  } = data;
  const senderId = context.auth.uid;

  // 1. Basic Validation
  if (!receiverId || !ncxAmount || ncxAmount < 1 || !postId) {
    throw new functions.https.HttpsError("invalid-argument", "Invalid gift parameters (receiverId, ncxAmount, postId).");
  }
  if (senderId === receiverId) {
    throw new functions.https.HttpsError("invalid-argument", "Cannot gift yourself.");
  }

  // Initialize Supabase client
  const { createClient } = require('@supabase/supabase-js');
  const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

  try {
    // 2. Call the atomic Supabase RPC function
    const { data: rpcData, error } = await supabase.rpc('process_gift_ncx', {
      p_sender_auth_id: senderId,
      p_receiver_auth_id: receiverId,
      p_post_id: postId,
      p_ncx_amount: ncxAmount,
      p_gift_platform_fee_rate: GIFT_PLATFORM_FEE, // Using the constant from this file
      p_gift_details: {
        gift_item_id: giftItemId,
        is_anonymous: isAnonymous || false,
        context_note: contextNote || null,
        context_type: contextType || 'creator_post'
      }
    });

    if (error) {
      console.error('Supabase RPC error (process_gift_ncx):', error);
      // This is the crucial part for the frontend
      if (error.message.includes('Insufficient NCX balance')) {
        throw new functions.https.HttpsError("resource-exhausted", "Insufficient NCX balance. Please top up your wallet.");
      }
      throw new functions.https.HttpsError("internal", "Failed to process gift transaction.");
    }

    // The RPC returns a single row from the table function
    const result = rpcData[0];

    if (!result || !result.success) {
      throw new functions.https.HttpsError("internal", result?.message || "An unknown error occurred in the database function.");
    }

    // 3. Handle non-financial side-effects (fire and forget)
    try {
      // a. Send notification to receiver
      const giftItem = GIFT_CATALOGUE.find(g => g.id === giftItemId) || { name: 'a Gift', emoji: '🎁' };
      const notifRef = db.collection("notifications").doc();
      await notifRef.set({
        user_id: receiverId,
        type: "gift_received",
        title: `${giftItem.emoji} You received a gift!`,
        body: isAnonymous
          ? `Someone sent you ${giftItem.name} (${result.receiver_amount_credited} NCX)`
          : `A user sent you ${giftItem.emoji} ${giftItem.name} — ${result.receiver_amount_credited} NCX`,
        metadata: {
          gift_id: null, // The gift ID is now in Supabase, not easily available here.
          gift_emoji: giftItem.emoji,
          ncx_amount: result.receiver_amount_credited,
          sender_id: isAnonymous ? null : senderId,
          context_type: contextType,
          context_id: postId,
        },
        is_read: false,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      // b. Update sender's gift streak (best-effort)
      await _updateGiftStreak(senderId, ncxAmount);

    } catch (sideEffectError) {
      console.error("Error during post-gift side-effects (non-critical):", sideEffectError);
    }

    // 4. Return success to the client
    return {
      success: true,
      message: result.message,
      receiverNcx: result.receiver_amount_credited,
      platformFeeNcx: result.platform_fee_paid,
    };

  } catch (error) {
    console.error("🔥 processGift Error:", error);
    if (error instanceof functions.https.HttpsError) throw error;
    throw new functions.https.HttpsError("internal", error.message);
  }
});


/**
 * getContextGifts
 * Returns recent gifts for a given context (post, stream, listing…)
 */
exports.getContextGifts = functions.https.onCall(async (data, _context) => {
  const { contextId, contextType, limit = 20 } = data;
  if (!contextId || !contextType)
    throw new functions.https.HttpsError("invalid-argument", "contextId and contextType required.");

  const snap = await db.collection("ncx_gifts")
    .where("context_id", "==", contextId)
    .where("context_type", "==", contextType)
    .where("status", "==", "completed")
    .orderBy("ncx_amount", "desc")
    .orderBy("created_at", "desc")
    .limit(limit)
    .get();

  return snap.docs.map((doc) => {
    const d = doc.data();
    return {
      gift_id: doc.id,
      sender_id: d.is_anonymous ? null : d.sender_id,
      gift_emoji: d.gift_emoji, gift_name: d.gift_name,
      ncx_amount: d.ncx_amount, ugx_equivalent: d.ugx_equivalent,
      receiver_ncx: d.receiver_ncx,
      is_anonymous: d.is_anonymous, is_highlighted: d.is_highlighted,
      created_at: d.created_at?.toDate()?.toISOString() || null,
    };
  });
});

/**
 * getContextGiftTotals
 * Aggregated gift stats for a context.
 */
exports.getContextGiftTotals = functions.https.onCall(async (data, _context) => {
  const { contextId, contextType } = data;
  if (!contextId || !contextType)
    throw new functions.https.HttpsError("invalid-argument", "contextId and contextType required.");

  const snap = await db.collection("ncx_gifts")
    .where("context_id", "==", contextId)
    .where("context_type", "==", contextType)
    .where("status", "==", "completed")
    .get();

  if (snap.empty) return { total_gifts: 0, total_ncx: 0, total_ugx: 0, unique_gifters: 0, top_emoji: null };

  let totalNcx = 0, totalUgx = 0;
  const gifters = new Set();
  const emojiMap = {};

  snap.docs.forEach((doc) => {
    const d = doc.data();
    totalNcx += d.ncx_amount || 0;
    totalUgx += d.ugx_equivalent || 0;
    gifters.add(d.sender_id);
    emojiMap[d.gift_emoji] = (emojiMap[d.gift_emoji] || 0) + (d.ncx_amount || 0);
  });

  const topEmoji = Object.entries(emojiMap).sort((a, b) => b[1] - a[1])[0]?.[0] || null;

  return {
    total_gifts: snap.size, total_ncx: totalNcx, total_ugx: totalUgx,
    unique_gifters: gifters.size, top_emoji: topEmoji,
  };
});

/**
 * getTopGifters — leaderboard of top NCX senders
 */
exports.getTopGifters = functions.https.onCall(async (data, _context) => {
  const limit = data?.limit || 20;
  const snap = await db.collection("gift_streaks")
    .orderBy("total_ncx_sent", "desc")
    .limit(limit)
    .get();

  return snap.docs.map((doc) => ({
    user_id: doc.id,
    total_ncx_sent: doc.data().total_ncx_sent || 0,
    total_gifts_sent: doc.data().total_gifts_sent || 0,
    current_streak: doc.data().current_streak || 0,
    longest_streak: doc.data().longest_streak || 0,
  }));
});

/**
 * getTopReceivers — leaderboard of top NCX receivers
 */
exports.getTopReceivers = functions.https.onCall(async (data, _context) => {
  const limit = data?.limit || 20;
  const snap = await db.collection("wallets")
    .orderBy("total_gifts_received_ncx", "desc")
    .limit(limit)
    .get();

  return snap.docs.map((doc) => ({
    user_id: doc.id,
    total_ncx_received: doc.data().total_gifts_received_ncx || 0,
  }));
});

// ── Helpers ──────────────────────────────────────────────────────────────────

async function _updateGiftStreak(userId, ncxAmount) {
  try {
    const streakRef = db.collection("gift_streaks").doc(userId);
    const streakDoc = await streakRef.get();
    const today = new Date().toISOString().split("T")[0]; // YYYY-MM-DD

    if (!streakDoc.exists) {
      await streakRef.set({
        user_id: userId, current_streak: 1, longest_streak: 1,
        last_gift_date: today, total_gifts_sent: 1, total_ncx_sent: ncxAmount,
        updated_at: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    const d = streakDoc.data();
    const lastDate = d.last_gift_date;
    const yesterday = new Date(Date.now() - 86400000).toISOString().split("T")[0];
    let newStreak = 1;
    if (lastDate === yesterday) newStreak = (d.current_streak || 0) + 1;
    else if (lastDate === today)  newStreak = d.current_streak || 1;

    await streakRef.update({
      current_streak: newStreak,
      longest_streak: Math.max(d.longest_streak || 0, newStreak),
      last_gift_date: today,
      total_gifts_sent: admin.firestore.FieldValue.increment(1),
      total_ncx_sent: admin.firestore.FieldValue.increment(ncxAmount),
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (e) {
    console.error("Streak update failed (non-critical):", e);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PAYMENT GATEWAY
// ═══════════════════════════════════════════════════════════════════════════

exports.necxaPaymentGateway = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "User must be logged in.");
  
  const { listing_id, method, amount, buyer_id, buyer_email, buyer_phone } = data;
  
  if (!listing_id || !method || !amount) {
    throw new functions.https.HttpsError("invalid-argument", "Missing required payment fields.");
  }

  // Verify buyer_id matches authenticated user
  if (buyer_id !== context.auth.uid) {
    throw new functions.https.HttpsError("permission-denied", "Buyer ID mismatch.");
  }

  const paymentRef = db.collection("listing_unlocks").doc();
  const paymentId = paymentRef.id;

  if (method === 'NCX_COINS') {
    // Process with internal wallet
    return await db.runTransaction(async (tx) => {
      const walletRef = db.collection("wallets").doc(buyer_id);
      const walletDoc = await tx.get(walletRef);
      
      if (!walletDoc.exists) {
        throw new functions.https.HttpsError("not-found", "Wallet not found.");
      }
      
      const currentBalance = walletDoc.data().coin_balance || 0;
      if (currentBalance < amount) {
        throw new functions.https.HttpsError("failed-precondition", "Insufficient NCX Coins.");
      }
      
      // Deduct from wallet
      tx.update(walletRef, {
        coin_balance: admin.firestore.FieldValue.increment(-amount)
      });
      
      // Record payment completion
      tx.set(paymentRef, {
        buyer_id,
        listing_id,
        method,
        amount,
        payment_status: "COMPLETED",
        timestamp: admin.firestore.FieldValue.serverTimestamp()
      });

      // Record vault transaction
      const txRef = db.collection("vault_transactions").doc();
      tx.set(txRef, {
        user_id: buyer_id,
        type: "listing_unlock",
        ncx_paid: amount,
        listing_id,
        status: "completed",
        timestamp: admin.firestore.FieldValue.serverTimestamp()
      });

      // Independent Audit
      await recordLedgerEntry(buyer_id, {
        type: "listing_unlock",
        amount: amount,
        currency: "NCX",
        direction: "out",
        metadata: { listing_id }
      }, tx);

      return { success: true, payment_id: paymentId, status: "COMPLETED" };
    });
  } else {
    // External Mobile Money / Card Payment
    // Simulate initiation and create a PROCESSING record.
    
    await paymentRef.set({
      buyer_id,
      buyer_email,
      buyer_phone,
      listing_id,
      method,
      amount,
      payment_status: "PROCESSING", // A webhook or polling would update this
      timestamp: admin.firestore.FieldValue.serverTimestamp()
    });

    // Simulate webhook completion after a few seconds for testing purposes
    setTimeout(async () => {
      try {
        await paymentRef.update({ payment_status: "COMPLETED" });
      } catch (e) {
        console.error("Mock webhook update failed:", e);
      }
    }, 5000);

    return { success: true, payment_id: paymentId, status: "PROCESSING", message: "Payment initiated" };
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// PESAPAL PAYMENT INTEGRATION (LIVE)
// ═══════════════════════════════════════════════════════════════════════════
const PESAPAL_BASE_URL = "https://pay.pesapal.com/v3";
// To use secrets in v1, we configure runWith:
const pesapalConfig = { secrets: ["PESAPAL_CONSUMER_KEY", "PESAPAL_CONSUMER_SECRET"] };

/**
 * Helper to get Pesapal Bearer Token
 */
async function getPesapalToken() {
  const consumerKey = process.env.PESAPAL_CONSUMER_KEY;
  const consumerSecret = process.env.PESAPAL_CONSUMER_SECRET;
  
  if (!consumerKey || !consumerSecret) {
    throw new Error("Pesapal credentials not found in Secret Manager.");
  }

  const response = await axios.post(`${PESAPAL_BASE_URL}/api/Auth/RequestToken`, {
    consumer_key: consumerKey,
    consumer_secret: consumerSecret
  }, {
    headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' }
  });

  return response.data.token;
}

/**
 * Helper to register IPN if not exists. 
 * We will cache the IPN ID in Firestore to avoid registering it every time.
 */
async function getOrRegisterIPN(token) {
  // Use Firebase hosting or functions URL
  const ipnUrl = `https://us-central1-${process.env.GCLOUD_PROJECT}.cloudfunctions.net/pesapalWebhook`;
  
  const ipnConfigRef = db.collection("system_config").doc("pesapal_ipn");
  const doc = await ipnConfigRef.get();
  if (doc.exists && doc.data().ipn_id) {
    return doc.data().ipn_id;
  }

  // Register IPN
  const response = await axios.post(`${PESAPAL_BASE_URL}/api/URLSetup/RegisterIPN`, {
    url: ipnUrl,
    ipn_notification_type: "POST"
  }, {
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
      'Accept': 'application/json'
    }
  });

  if (response.data && response.data.ipn_id) {
    await ipnConfigRef.set({ ipn_id: response.data.ipn_id, url: ipnUrl });
    return response.data.ipn_id;
  }
  
  throw new Error("Failed to register IPN with Pesapal.");
}

/**
 * initiatePesapalPayment (Callable)
 * Generates an order and returns the redirect URL for checkout.
 */
exports.initiatePesapalPayment = require("firebase-functions/v1").runWith(pesapalConfig).https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "User must be logged in.");

  const { amount, currency = "UGX", description, type, packId, listingId, email, phone } = data;
  const userId = context.auth.uid;
  const userEmail = email || context.auth.token.email || "no-reply@necxa.uk";
  
  if (!amount || amount <= 0) {
    throw new functions.https.HttpsError("invalid-argument", "Invalid amount.");
  }

  try {
    const token = await getPesapalToken();
    const ipnId = await getOrRegisterIPN(token);

    // Create a local order reference
    const orderRef = db.collection("pesapal_orders").doc();
    const orderId = orderRef.id;

    // Submit Order to Pesapal
    const orderData = {
      id: orderId,
      currency: currency,
      amount: parseFloat(amount).toFixed(2),
      description: description || "Necxa Payment",
      callback_url: `https://necxa.uk/payment-callback?orderId=${orderId}`,
      notification_id: ipnId,
      billing_address: {
        email_address: userEmail,
        phone_number: phone || "",
        country_code: "UG",
        first_name: "Necxa",
        last_name: "User",
        line_1: "Kampala",
        city: "Kampala"
      }
    };

    const response = await axios.post(`${PESAPAL_BASE_URL}/api/Transactions/SubmitOrderRequest`, orderData, {
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      }
    });

    if (response.data && response.data.redirect_url) {
      const pesapalOrderTrackingId = response.data.order_tracking_id;

      // Save pending order
      await orderRef.set({
        user_id: userId,
        type: type, // 'buy_coins' or 'unlock_listing'
        amount: amount,
        currency: currency,
        pack_id: packId || null,
        listing_id: listingId || null,
        status: "PENDING",
        pesapal_tracking_id: pesapalOrderTrackingId,
        redirect_url: response.data.redirect_url,
        created_at: admin.firestore.FieldValue.serverTimestamp()
      });

      return {
        success: true,
        redirect_url: response.data.redirect_url,
        order_tracking_id: pesapalOrderTrackingId,
        order_id: orderId
      };
    } else {
      throw new Error("Invalid response from Pesapal SubmitOrderRequest.");
    }
  } catch (error) {
    console.error("Pesapal Initiate Error:", error.response?.data || error.message);
    throw new functions.https.HttpsError("internal", "Failed to initiate payment with Pesapal.");
  }
});

/**
 * pesapalWebhook (HTTP)
 * Receives IPNs from Pesapal, verifies the transaction, and fulfills the order.
 */
exports.pesapalWebhook = require("firebase-functions/v1").runWith(pesapalConfig).https.onRequest(async (req, res) => {
  // Pesapal sends OrderTrackingId and OrderNotificationType in query params or body
  const orderTrackingId = req.query.OrderTrackingId || req.body.OrderTrackingId;
  const orderMerchantReference = req.query.OrderMerchantReference || req.body.OrderMerchantReference;
  
  if (!orderTrackingId) {
    res.status(400).send("Missing OrderTrackingId");
    return;
  }

  try {
    const token = await getPesapalToken();
    
    // Check status with Pesapal
    const statusRes = await axios.get(`${PESAPAL_BASE_URL}/api/Transactions/GetTransactionStatus?orderTrackingId=${orderTrackingId}`, {
      headers: {
        'Authorization': `Bearer ${token}`,
        'Accept': 'application/json'
      }
    });

    const paymentStatus = statusRes.data.payment_status_description; // "COMPLETED", "FAILED", "INVALID"
    
    // Find the order in Firestore
    const orderRef = db.collection("pesapal_orders").doc(orderMerchantReference);
    const orderDoc = await orderRef.get();

    if (!orderDoc.exists) {
      console.warn(`Pesapal IPN for unknown order: ${orderMerchantReference}`);
      res.status(200).send({ status: "success", message: "Order not found locally, ignored." });
      return;
    }

    if (orderDoc.data().status === "COMPLETED") {
      res.status(200).send({ status: "success", message: "Already fulfilled." });
      return;
    }

    // Update order status
    await orderRef.update({
      status: paymentStatus,
      pesapal_status_code: statusRes.data.payment_status_code,
      updated_at: admin.firestore.FieldValue.serverTimestamp()
    });

    // Fulfill if COMPLETED
    if (paymentStatus === "COMPLETED") {
      const orderData = orderDoc.data();
      const userId = orderData.user_id;

      if (orderData.type === "wallet_topup") {
        const ugxAmount = orderData.amount;
        // This part needs a new Supabase function: `credit_fiat`
        // For now, we will log an error as it's not implemented yet.
        console.error(`Webhook Error: 'wallet_topup' fulfillment not yet implemented in Supabase for order ${orderMerchantReference}.`);

      } else if (orderData.type === "unlock_listing" && orderData.listing_id) {
        // Unlock listing logic (similar to necxaPaymentGateway)
        await db.runTransaction(async (tx) => {
          const paymentRef = db.collection("listing_unlocks").doc(orderMerchantReference);
          tx.set(paymentRef, {
            buyer_id: userId,
            listing_id: orderData.listing_id,
            method: "PESAPAL",
            amount: orderData.amount,
            payment_status: "COMPLETED",
            timestamp: admin.firestore.FieldValue.serverTimestamp()
          });

          // Independent Audit
          await recordLedgerEntry(userId, {
            type: "listing_unlock",
            amount: orderData.amount,
            currency: "UGX",
            direction: "out",
            metadata: { listing_id: orderData.listing_id, method: "pesapal", tracking_id: orderTrackingId }
          }, tx);
        });
      } else if (orderData.type === "shop_purchase" && orderData.order_id) {
        // Shop E-commerce fulfillment logic
        await db.runTransaction(async (tx) => {
          const shopOrderRef = db.collection("orders").doc(orderData.order_id);
          const shopOrderDoc = await tx.get(shopOrderRef);

          if (shopOrderDoc.exists) {
            tx.update(shopOrderRef, {
              status: "paid",
              payment_method: "pesapal",
              paid_at: admin.firestore.FieldValue.serverTimestamp()
            });
            
            const { items_ugx = orderData.amount, delivery_ugx = 0, vendor_id, sku, quantity, listing_id } = orderData;

            const vendorPlatformFeeUgx = Math.floor(items_ugx * 0.03);
            const vendorNetUgx = items_ugx - vendorPlatformFeeUgx;

            // Goods Purchase Ledger Entry
            if (items_ugx > 0) {
              await recordLedgerEntry(userId, {
                type: "shop_purchase",
                amount: items_ugx,
                currency: "UGX",
                direction: "out",
                reference_id: orderData.order_id,
                metadata: { sku: sku, listing_id: listing_id, quantity: quantity, method: "pesapal", tracking_id: orderTrackingId }
              }, tx);
              
              if (vendor_id) {
                await recordLedgerEntry(vendor_id, {
                  type: "shop_purchase",
                  amount: vendorNetUgx,
                  currency: "UGX",
                  direction: "in",
                  reference_id: orderData.order_id,
                  metadata: { sku: sku, listing_id: listing_id, quantity: quantity, method: "pesapal", fee_deducted: vendorPlatformFeeUgx }
                }, tx);

                if (vendorPlatformFeeUgx > 0) {
                  await recordLedgerEntry("platform_revenue", {
                    type: "gift_fee", // Maps to PLATFORM_FEE
                    amount: vendorPlatformFeeUgx,
                    currency: "UGX",
                    direction: "in",
                    reference_id: orderData.order_id,
                    metadata: { source: "shop_vendor_commission", sku: sku, method: "pesapal" }
                  }, tx);
                }
              }
            }

            // Logistics Ledger Entry
            if (delivery_ugx > 0) {
              const tripId = `TRIP-${orderData.order_id.split('-')[1] || Date.now()}`;
              tx.update(shopOrderRef, { trip_id: tripId });

              await recordLedgerEntry(userId, {
                type: "delivery_fee",
                amount: delivery_ugx,
                currency: "UGX",
                direction: "out",
                reference_id: orderData.order_id,
                metadata: { trip_id: tripId, method: "pesapal", tracking_id: orderTrackingId }
              }, tx);
            }
          }
        });
      }
    }

    // Acknowledge the IPN
    res.status(200).json({
      orderNotificationType: req.query.OrderNotificationType || req.body.OrderNotificationType,
      orderTrackingId: orderTrackingId,
      orderMerchantReference: orderMerchantReference,
      status: 200
    });

  } catch (error) {
    console.error("Pesapal Webhook Error:", error.message);
    res.status(500).send("Webhook processing failed.");
  }
});

/**
 * Helper to disburse funds via Pesapal.
 * NOTE: This is a hypothetical structure. The actual endpoint and payload may differ.
 */
async function disburseViaPesapal(token, { amount, accountNumber, recipientName, method }) {
  const DISBURSEMENT_URL = "https://pay.pesapal.com/v3/api/Transactions/SendMoney"; // Hypothetical endpoint

  const payload = {
    amount: parseFloat(amount).toFixed(2),
    currency: "UGX",
    destination: {
      type: "MOBILE_MONEY", // Or "BANK_ACCOUNT"
      recipient: {
        msisdn: accountNumber,
        name: recipientName,
      },
      wallet: method.toUpperCase(), // e.g., "MTN", "AIRTEL"
    },
    description: `Necxa Payout to ${recipientName}`,
    reference: `WD-${Date.now()}`, // Unique reference for this disbursement
  };

  const response = await axios.post(DISBURSEMENT_URL, payload, {
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
      'Accept': 'application/json'
    }
  });

  if (response.data && response.data.status === "SUCCESS") {
    return { success: true, provider_reference: response.data.transaction_reference };
  } else {
    throw new Error(response.data.message || "Pesapal disbursement failed.");
  }
}

/**
 * processDisbursement (Callable by Finance Team)
 * Executes the actual payout for a reviewed withdrawal transaction.
 */
exports.processDisbursement = require("firebase-functions/v1").runWith(pesapalConfig).https.onCall(async (data, context) => {
  // --- SECURITY: Add role-based access control ---
  // In a real app, you would check for a custom claim e.g., if (context.auth.token.role !== 'finance')
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Finance team authentication required.");
  }

  const { transactionId } = data;
  if (!transactionId) {
    throw new functions.https.HttpsError("invalid-argument", "Missing transactionId.");
  }

  const txRef = db.collection("vault_transactions").doc(transactionId);
  const txDoc = await txRef.get();

  if (!txDoc.exists) {
    throw new functions.https.HttpsError("not-found", "Withdrawal transaction not found.");
  }

  const txData = txDoc.data();

  if (txData.status !== "pending_review") {
    throw new functions.https.HttpsError("failed-precondition", `Transaction is not pending review. Current status: ${txData.status}`);
  }

  await txRef.update({ status: "processing", payout_status: "processing" });

  try {
    const pesapalToken = await getPesapalToken();
    const disbursementResult = await disburseViaPesapal(pesapalToken, {
      amount: txData.amount_withdrawn,
      accountNumber: txData.account_number,
      recipientName: txData.recipient_name,
      method: txData.disbursement_method,
    });

    await txRef.update({
      status: "completed",
      payout_status: "paid",
      bank_processed: true,
      processed_at: admin.firestore.FieldValue.serverTimestamp(),
      provider_reference: disbursementResult.provider_reference,
    });

    return { success: true, message: `Disbursement of UGX ${txData.amount_withdrawn} to ${txData.account_number} completed successfully.` };
  } catch (error) {
    console.error("Pesapal Disbursement Error:", error.response?.data || error.message);
    await txRef.update({
      status: "review_failed",
      payout_status: "failed",
      error_message: error.message || "An unknown error occurred during disbursement.",
    });
    throw new functions.https.HttpsError("internal", `Failed to disburse funds via Pesapal: ${error.message}`);
  }
});


