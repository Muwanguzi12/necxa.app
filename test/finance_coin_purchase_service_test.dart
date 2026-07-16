import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/services/finance_coin_purchase_service.dart';

void main() {
  group('Buy Coins routing', () {
    test('maps recharge amounts to Supabase 2 pack IDs', () {
      expect(FinanceCoinPurchaseService.packIdForUgx(5000), 'starter');
      expect(FinanceCoinPurchaseService.packIdForUgx(50000), 'pro');
      expect(FinanceCoinPurchaseService.packIdForUgx(100000), 'elite');
      expect(FinanceCoinPurchaseService.packIdForUgx(500000), 'whale');
    });

    test('accepts only implemented payment methods', () {
      for (final method in ['fiat_balance', 'pesapal', 'card', 'mtn', 'airtel']) {
        expect(FinanceCoinPurchaseService.isSupportedMethod(method), isTrue);
      }
      for (final method in ['mobile_money', 'visa', 'usdt']) {
        expect(FinanceCoinPurchaseService.isSupportedMethod(method), isFalse);
      }
    });
  });
}
