import 'dart:async';

import 'finance_backend.dart';
import 'finance_initializer.dart';

class FinanceCoinPurchaseService {
  static const supportedMethods = {'fiat_balance', 'pesapal', 'card', 'mtn', 'airtel'};

  static String packIdForUgx(num ugx) {
    if (ugx >= 500000) return 'whale';
    if (ugx >= 100000) return 'elite';
    if (ugx >= 50000) return 'pro';
    return 'starter';
  }

  static bool isSupportedMethod(String method) =>
      supportedMethods.contains(method.toLowerCase());

  Future<List<Map<String, dynamic>>> packs() async {
    await FinanceInitializer.instance.ensureInitialized();
    final result = await FinanceBackend.instance.invoke('list_coin_packs');
    return (result['coinPacks'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Future<Map<String, dynamic>> purchase({
    required String packId,
    required String method,
    required String idempotencyKey,
    Map<String, dynamic> securityMetadata = const {},
  }) async {
    await FinanceInitializer.instance.ensureInitialized();
    return FinanceBackend.instance.invoke('purchase_coins', body: {
      'packId': packId,
      'method': method,
      'idempotencyKey': idempotencyKey,
      'securityMetadata': securityMetadata,
    });
  }

  Future<String> status(String paymentId) async {
    final result = await FinanceBackend.instance.invoke(
      'coin_purchase_status',
      body: {'paymentId': paymentId},
    );
    return result['status']?.toString() ?? 'processing';
  }

  Future<bool> waitForCompletion(
    String paymentId, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final current = await status(paymentId);
      if (current == 'completed') return true;
      if (current == 'failed' || current == 'cancelled' || current == 'refunded') return false;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return false;
  }
}
