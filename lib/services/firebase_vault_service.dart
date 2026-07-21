import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:necxa_flutter/firebase_options.dart';

class FirebaseVaultService {
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  FirebaseFunctions get _functions => FirebaseFunctions.instance;

  Future<void> _ensureFirebaseAuth() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    }

    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
  }

  /// Atomic transaction for eCommerce purchases using wallet balance
  Future<Map<String, dynamic>> processShopPurchase({
    required String orderId,
    required String listingId,
    required String vendorId,
    required String sku,
    required double itemsTotalUgx,
    required double deliveryFeeUgx,
    required int quantity,
  }) async {
    try {
      await _ensureFirebaseAuth();
      final HttpsCallable callable = _functions.httpsCallable('processShopPurchase');
      final result = await callable.call({
        'orderId': orderId,
        'listingId': listingId,
        'vendorId': vendorId,
        'sku': sku,
        'itemsTotalUgx': itemsTotalUgx,
        'deliveryFeeUgx': deliveryFeeUgx,
        'quantity': quantity,
      });
      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      debugPrint('🔥 Firebase Vault: Shop Purchase Failure: $e');
      return {'success': false, 'message': e.toString()};
    }
  }

  Future<void> logListingMint({
    required String userId,
    required String listingId,
    required String mintEventId,
    required String title,
    required int priceUgx,
    int listingFeeNcx = 0,
  }) async {
    await _firestore
        .collection('audit_logs')
        .doc(userId)
        .collection('listing_mints')
        .doc(mintEventId)
        .set({
      'user_id': userId,
      'listing_id': listingId,
      'mint_event_id': mintEventId,
      'title': title,
      'price_ugx': priceUgx,
      'listing_fee_ncx': listingFeeNcx,
      'event_type': 'listing_minted',
      'created_at': FieldValue.serverTimestamp(),
    });
  }

  /// Initiates a Pesapal Checkout Session
  Future<Map<String, dynamic>> initiatePesapalPayment({
    required double amount,
    required String currency,
    required String description,
    required String type, // e.g. 'wallet_topup', 'buy_coins', 'unlock_listing'
    String? packId,
    String? listingId,
    String? email,
    String? phone,
  }) async {
    try {
      await _ensureFirebaseAuth();
      final HttpsCallable callable = _functions.httpsCallable('initiatePesapalPayment');
      final result = await callable.call({
        'amount': amount,
        'currency': currency,
        'description': description,
        'type': type,
        'packId': packId,
        'listingId': listingId,
        'email': email,
        'phone': phone,
      });
      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      debugPrint('🔥 Firebase Vault: Pesapal Init Failure: $e');
      return {'success': false, 'message': e.toString()};
    }
  }

  /// Atomic transaction for withdrawing fiat to mobile money or bank via Cloud Functions
  Future<Map<String, dynamic>> withdrawFiat({
    required String userId,
    required double amount,
    required String method, // 'mtn', 'airtel', 'card'
    required String accountNumber,
    required String recipientName,
    required String? totpToken,
    required String emailOtp,
    required Map<String, dynamic> securityMetadata,
  }) async {
    try {
      await _ensureFirebaseAuth();
      final HttpsCallable callable = _functions.httpsCallable('withdrawFiat');
      final result = await callable.call({
        'amount': amount,
        'method': method,
        'accountNumber': accountNumber,
        'recipientName': recipientName,
        'totpToken': totpToken,
        'emailOtp': emailOtp,
        'securityMetadata': securityMetadata,
      });
      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      debugPrint('🔥 Firebase Vault: Withdrawal Failure: $e');
      return {'success': false, 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> request2FASetup() async {
    try {
      await _ensureFirebaseAuth();
      final HttpsCallable callable = _functions.httpsCallable('request2FASetup');
      final result = await callable.call();
      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  // ── Escrow Transactions ──────────────────────────────────────────────────────

  /// Holds funds in escrow for a specific transaction (e.g., transport, marketplace)
  Future<Map<String, dynamic>> holdInEscrow({
    required String userId,
    required double amount,
    required String transactionId,
    required String contextType, // 'transport', 'marketplace'
  }) async {
    try {
      await _ensureFirebaseAuth();
      final HttpsCallable callable = _functions.httpsCallable('holdInEscrow');
      final result = await callable.call({
        'userId': userId,
        'amount': amount,
        'transactionId': transactionId,
        'contextType': contextType,
      });
      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      debugPrint('🔥 Firebase Vault: Escrow Hold Failure: $e');
      return {'success': false, 'message': e.toString()};
    }
  }

  /// Releases funds from escrow to the recipient
  Future<Map<String, dynamic>> releaseEscrow({
    required String transactionId,
    required String recipientId,
    required double amount,
  }) async {
    try {
      await _ensureFirebaseAuth();
      final HttpsCallable callable = _functions.httpsCallable('releaseEscrow');
      final result = await callable.call({
        'transactionId': transactionId,
        'recipientId': recipientId,
        'amount': amount,
      });
      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      debugPrint('🔥 Firebase Vault: Escrow Release Failure: $e');
      return {'success': false, 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> confirm2FASetup(String token) async {
    try {
      await _ensureFirebaseAuth();
      final HttpsCallable callable = _functions.httpsCallable('confirm2FASetup');
      final result = await callable.call({'token': token});
      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> sendWithdrawalOTP() async {
    try {
      await _ensureFirebaseAuth();
      final HttpsCallable callable = _functions.httpsCallable('sendWithdrawalOTP');
      final result = await callable.call();
      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> refreshForexRates() async {
    try {
      await _ensureFirebaseAuth();
      final HttpsCallable callable = _functions.httpsCallable('refreshForexRates');
      final result = await callable.call();
      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }


}
