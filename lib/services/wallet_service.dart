import 'package:flutter/foundation.dart';

import 'finance_backend.dart';
import 'finance_initializer.dart';

class WalletService {
  WalletService();

  Future<Map<String, dynamic>> _invoke(
    String action, {
    Map<String, dynamic> body = const {},
  }) async {
    await FinanceInitializer.instance.ensureInitialized();
    return FinanceBackend.instance.invoke(action, body: body);
  }

  Future<Map<String, dynamic>> getWalletDetails() async {
    try {
      final result = await _invoke('get_wallet');
      return Map<String, dynamic>.from(result['wallet'] as Map? ?? const {});
    } catch (error) {
      debugPrint('Finance wallet read failed: $error');
      return {'fiat_balance': 0, 'coin_balance': 0, 'escrow_balance': 0};
    }
  }

  Future<PurchaseResult> purchaseCoins({
    required String method,
    required String packId,
  }) async {
    try {
      final result = await _invoke(
        'purchase_coins',
        body: {
          'method': method,
          'packId': packId,
          'idempotencyKey': _idempotencyKey('coin-purchase'),
        },
      );
      return PurchaseResult.success(
        message: result['message']?.toString() ?? 'Purchase initiated.',
        redirectUrl: result['redirectUrl']?.toString(),
      );
    } catch (error) {
      return PurchaseResult.failure(error.toString());
    }
  }

  Future<GiftResult> sendGift({
    required String receiverId,
    required String postId,
    required String giftItemId,
    required int ncxAmount,
    String? contextNote,
    bool isAnonymous = false,
  }) async {
    try {
      final result = await _invoke(
        'send_gift',
        body: {
          'receiverId': receiverId,
          'contextId': postId,
          'contextType': 'creator_post',
          'giftItemId': giftItemId,
          'ncxAmount': ncxAmount,
          'contextNote': contextNote,
          'isAnonymous': isAnonymous,
          'idempotencyKey': _idempotencyKey('gift'),
        },
      );
      return GiftResult.success(
        result['message']?.toString() ?? 'Gift sent successfully.',
      );
    } on FinanceBackendException catch (error) {
      if (error.code == 'insufficient_funds') {
        return GiftResult.insufficientFunds(error.message);
      }
      return GiftResult.failure(error.message);
    } catch (error) {
      return GiftResult.failure(error.toString());
    }
  }

  Future<LiquidationResult> liquidateCoins({
    required int ncxAmount,
    required Map<String, dynamic> securityMetadata,
  }) async {
    if (ncxAmount <= 0) {
      return LiquidationResult.failure('Amount must be greater than zero.');
    }
    try {
      final result = await _invoke(
        'liquidate',
        body: {
          'ncxAmount': ncxAmount,
          'securityMetadata': securityMetadata,
          'idempotencyKey': _idempotencyKey('liquidation'),
        },
      );
      final wallet = Map<String, dynamic>.from(
        result['wallet'] as Map? ?? const {},
      );
      return LiquidationResult.success(
        message: result['message']?.toString() ?? 'Liquidation successful.',
        ugxReceived: (result['ugxReceived'] as num?)?.toDouble() ?? 0,
        ncxBurned: (result['ncxBurned'] as num?)?.toDouble() ?? 0,
        wallet: wallet,
      );
    } catch (error) {
      return LiquidationResult.failure(error.toString());
    }
  }

  String _idempotencyKey(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';
}

class PurchaseResult {
  final bool isSuccess;
  final String message;
  final String? redirectUrl;
  PurchaseResult.success({required this.message, this.redirectUrl})
    : isSuccess = true;
  PurchaseResult.failure(this.message) : isSuccess = false, redirectUrl = null;
}

class GiftResult {
  final bool isSuccess;
  final String message;
  final bool needsTopUp;
  GiftResult.success(this.message) : isSuccess = true, needsTopUp = false;
  GiftResult.failure(this.message) : isSuccess = false, needsTopUp = false;
  GiftResult.insufficientFunds(this.message)
    : isSuccess = false,
      needsTopUp = true;
}

class LiquidationResult {
  final bool isSuccess;
  final String message;
  final double ugxReceived;
  final double ncxBurned;
  final Map<String, dynamic> wallet;
  LiquidationResult.success({
    required this.message,
    this.ugxReceived = 0,
    this.ncxBurned = 0,
    this.wallet = const {},
  }) : isSuccess = true;
  LiquidationResult.failure(this.message)
    : isSuccess = false,
      ugxReceived = 0,
      ncxBurned = 0,
      wallet = const {};
}

class ShopPurchaseResult {
  final bool isSuccess;
  final String message;
  final bool needsTopUp;
  ShopPurchaseResult.success(this.message)
    : isSuccess = true,
      needsTopUp = false;
  ShopPurchaseResult.failure(this.message)
    : isSuccess = false,
      needsTopUp = false;
  ShopPurchaseResult.insufficientFunds(this.message)
    : isSuccess = false,
      needsTopUp = true;
}

extension WalletServiceShop on WalletService {
  Future<ShopPurchaseResult> processShopPurchase({
    required String orderId,
    required String listingId,
    required String vendorId,
    required String sku,
    required int quantity,
    required String deliverySpeed,
    required Map<String, double> customerLocation,
    required String customerNumber,
  }) async {
    try {
      final result = await _invoke(
        'process_shop_purchase',
        body: {
          'orderId': orderId,
          'listingId': listingId,
          'vendorId': vendorId,
          'sku': sku,
          'quantity': quantity,
          'deliverySpeed': deliverySpeed,
          'customerLocation': customerLocation,
          'customerNumber': customerNumber,
          'idempotencyKey': _idempotencyKey('shop-purchase'),
        },
      );
      return ShopPurchaseResult.success(
        result['message']?.toString() ?? 'Purchase successful.',
      );
    } on FinanceBackendException catch (error) {
      if (error.code == 'insufficient_funds') {
        return ShopPurchaseResult.insufficientFunds(error.message);
      }
      return ShopPurchaseResult.failure(error.message);
    } catch (error) {
      return ShopPurchaseResult.failure(error.toString());
    }
  }
}
