import 'dart:async';

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
    final result = await FinanceBackend.instance.invoke(
      'initiate_property_unlock',
      body: {
        'listingId': listingId,
        'method': method.toLowerCase(),
        'amountUgx': amount.round(),
        'buyerEmail': buyerEmail,
        'buyerPhone': phone == null ? null : normalizePhone(phone),
      },
    );
    if (result['success'] != true) {
      throw Exception(result['message'] ?? 'Payment initiation failed.');
    }
    return result;
  }

  Future<Map<String, dynamic>> initiatePesapalUnlock({
    required String listingId,
    required double amount,
    required String buyerId,
    required String buyerEmail,
    String? phone,
  }) => initiateUnlock(
    listingId: listingId,
    method: 'pesapal',
    amount: amount,
    buyerId: buyerId,
    buyerEmail: buyerEmail,
    phone: phone,
  );

  Future<bool> pollForPaymentCompletion(String paymentId) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      try {
        final result = await FinanceBackend.instance.invoke(
          'property_unlock_status',
          body: {'paymentId': paymentId},
        );
        final status = result['status']?.toString().toUpperCase();
        if (status == 'COMPLETED') return true;
        if (status == 'FAILED' || status == 'CANCELLED') {
          throw Exception(
            'Payment was declined. Please check your balance and try again.',
          );
        }
      } catch (e) {
        // If it throws an exception that isn't the final fail, maybe log it and keep polling
        if (e.toString().contains('declined')) rethrow;
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

  /// Initiates the FCFS escrow deposit payment via the Finance Engine.
  /// Returns the Pesapal redirectUrl and a paymentId for polling.
  Future<Map<String, dynamic>> initiateEscrowPayment({
    required String listingId,
    required String escrowReservationId,
    required double depositAmount,
    required String buyerId,
    required String buyerEmail,
  }) async {
    final idempotencyKey =
        'escrow-$listingId-$buyerId-${DateTime.now().millisecondsSinceEpoch}';
    final result = await FinanceBackend.instance.invoke(
      'initiate_escrow_payment',
      body: {
        'listingId': listingId,
        'escrowReservationId': escrowReservationId,
        'depositAmount': depositAmount.round(),
        'buyerEmail': buyerEmail,
        'idempotencyKey': idempotencyKey,
      },
    );
    if (result['already_sold'] == true) {
      throw Exception(
        'This property was just secured by another buyer. You were this close!',
      );
    }
    if (result['success'] != true) {
      throw Exception(result['message'] ?? 'Escrow initiation failed.');
    }
    return result;
  }

  /// Polls Finance Engine for escrow payment completion.
  /// Returns true if this buyer WON the FCFS race.
  /// Throws if the payment failed or the buyer was outbid.
  Future<bool> pollForEscrowCompletion(String paymentId) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      try {
        final result = await FinanceBackend.instance.invoke(
          'escrow_payment_status',
          body: {'paymentId': paymentId},
        );
        final status = result['status']?.toString().toUpperCase();
        if (status == 'COMPLETED') return true;
        if (result['refunded'] == true) {
          throw Exception(
            'Another buyer completed their payment first. Your funds will be refunded.',
          );
        }
        if (status == 'FAILED' || status == 'CANCELLED') {
          throw Exception('Payment was declined. Please try again.');
        }
      } catch (e) {
        if (e.toString().contains('faster') || e.toString().contains('declined')) {
          rethrow;
        }
      }
    }
    return false;
  }
}
