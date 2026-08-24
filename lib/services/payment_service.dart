import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'finance_backend.dart';

class PaymentService {
  String normalizePhone(String phone) {
    final clean = phone.replaceAll(RegExp(r'\D'), '');
    if (clean.startsWith('256')) return clean;
    if (clean.startsWith('0')) return '256${clean.substring(1)}';
    return '256$clean';
  }

  Future<Map<String, dynamic>> initiateUnlock({
    required String listingId,
    required String method,
    required double amount,
    required String buyerId,
    required String buyerEmail,
    String? phone,
  }) async {
    final response = await Supabase.instance.client.functions.invoke(
      'necxa-payment-gateway',
      body: {
        'listing_id': listingId,
        'method': method,
        'amount': amount.round(),
        'buyer_id': buyerId,
        'buyer_email': buyerEmail,
        'buyer_phone': phone == null ? null : normalizePhone(phone),
      },
    );
    if (response.status < 200 || response.status >= 300) {
      throw Exception('Payment initiation failed.');
    }
    final data = Map<String, dynamic>.from(response.data as Map? ?? const {});
    if (data['success'] != true) {
      throw Exception(
        data['message'] ?? data['error'] ?? 'Payment initiation failed.',
      );
    }
    return data;
  }

  Future<Map<String, dynamic>> initiatePesapalUnlock({
    required String listingId,
    required double amount,
    required String buyerId,
    required String buyerEmail,
    String? phone,
  }) => initiateUnlock(
    listingId: listingId,
    method: 'MTN_MOMO',
    amount: amount,
    buyerId: buyerId,
    buyerEmail: buyerEmail,
    phone: phone,
  );

  Future<bool> pollForPaymentCompletion(String paymentId) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      final unlock = await Supabase.instance.client
          .from('listing_unlocks')
          .select('payment_status')
          .eq('id', paymentId)
          .maybeSingle();
      final status = unlock?['payment_status']?.toString().toUpperCase();
      if (status == 'COMPLETED') return true;
      if (status == 'FAILED' || status == 'CANCELLED') {
        throw Exception(
          'Payment was declined. Please check your balance and try again.',
        );
      }
    }
    return false;
  }

  Future<void> chargeArtistDistributionFee(String userId, int amount) async {
    final result = await FinanceBackend.instance.invoke(
      'charge_artist_distribution',
      body: {
        'amountNcx': amount,
        'idempotencyKey':
            'distribution-$userId-${DateTime.now().millisecondsSinceEpoch}',
      },
    );
    if (result['success'] != true) {
      throw Exception(result['message'] ?? 'Distribution fee failed.');
    }
  }
}
