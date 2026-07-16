import 'dart:async';

import 'finance_backend.dart';
import 'finance_initializer.dart';

class FinanceDepositService {
  Future<Map<String, dynamic>> initiate({
    required int amountUgx,
    String? phone,
  }) async {
    await FinanceInitializer.instance.ensureInitialized();
    return FinanceBackend.instance.invoke(
      'initiate_deposit',
      body: {
        'amount': amountUgx,
        'phone': phone,
        'idempotencyKey': 'deposit-${DateTime.now().microsecondsSinceEpoch}',
      },
    );
  }

  Future<String> status(String paymentId) async {
    final result = await FinanceBackend.instance.invoke(
      'deposit_status',
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
      if (current == 'failed' ||
          current == 'cancelled' ||
          current == 'refunded') {
        return false;
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return false;
  }
}
