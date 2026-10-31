import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/models/wallet.dart';

void main() {
  group('Wallet.fromJson', () {
    test('preserves canonical balances returned as numeric strings', () {
      final wallet = Wallet.fromJson({
        'id': 'wallet-1',
        'user_id': 'user-1',
        'fiat_balance': '125000',
        'coin_balance': '42',
        'escrow_balance': '7500',
        'daily_withdrawal_limit': '5000000',
        'monthly_withdrawal_limit': '50000000',
        'created_at': '2026-08-13T10:00:00Z',
        'updated_at': '2026-08-13T10:05:00Z',
      });

      expect(wallet.userId, 'user-1');
      expect(wallet.fiatBalance, 125000);
      expect(wallet.coinBalance, 42);
      expect(wallet.escrowBalance, 7500);
      expect(wallet.dailyWithdrawalLimit, 5000000);
      expect(wallet.monthlyWithdrawalLimit, 50000000);
    });

    test('keeps a genuine zero-balance wallet as zero', () {
      final wallet = Wallet.fromJson({
        'id': 'wallet-2',
        'user_id': 'user-2',
        'fiat_balance': 0,
        'coin_balance': 0,
        'escrow_balance': 0,
      });

      expect(wallet.fiatBalance, 0);
      expect(wallet.coinBalance, 0);
      expect(wallet.escrowBalance, 0);
    });
  });
}
