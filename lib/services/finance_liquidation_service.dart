import 'coin_liquidation_service.dart';
import 'finance_backend.dart';

class FinanceLiquidationService {
  static const double ncxPrice = 100;
  static const double burnRate = 0.11;

  Future<LiquidationQuote> getQuote(double ncxAmount) async {
    final rawUgx = ncxAmount * ncxPrice;
    return LiquidationQuote(
      ncxAmount: ncxAmount,
      ugxReceived: rawUgx * (1 - burnRate),
      ncxBurned: ncxAmount * burnRate,
      burnPercentage: (burnRate * 100).round(),
      effectiveRate: 1 - burnRate,
    );
  }

  Future<LiquidationResult> liquidate({
    required String userId,
    required double ncxAmount,
    required Map<String, dynamic> securityMetadata,
  }) async {
    final response = await FinanceBackend.instance.invoke(
      'liquidate_ncx',
      body: {
        'ncxAmount': ncxAmount.round(),
        'idempotencyKey':
            'liquidation-$userId-${DateTime.now().millisecondsSinceEpoch}',
        'securityMetadata': securityMetadata,
      },
    );
    return LiquidationResult(
      success: response['success'] == true,
      ugxReceived: (response['ugxReceived'] as num?)?.toDouble() ?? 0,
      ncxBurned: (response['ncxBurned'] as num?)?.toDouble() ?? 0,
      newCoinBalance: (response['newCoinBalance'] as num?)?.toDouble() ?? 0,
      newFiatBalance: (response['newFiatBalance'] as num?)?.toDouble() ?? 0,
      txCommitHash: response['transactionId']?.toString() ?? '',
      newNcxPrice: ncxPrice,
      message: response['message']?.toString() ?? 'Liquidation completed.',
    );
  }
}
