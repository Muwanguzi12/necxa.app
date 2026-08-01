import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/services/commerce_service.dart';

void main() {
  test('commerce order preserves participants and verification codes', () {
    final order = CommerceOrder.fromJson({
      'id': 'order-1',
      'order_number': 'ORD-1001',
      'buyer_id': 'buyer-1',
      'seller_id': 'seller-1',
      'listing_id': 'listing-1',
      'product_title': 'Camera',
      'quantity': 2,
      'unit_price_ugx': 120000,
      'delivery_fee_ugx': 10000,
      'total_ugx': 250000,
      'status': 'driver_assigned',
      'payment_status': 'COMPLETED',
      'settlement_status': 'funded',
      'delivery_address': 'Kampala',
      'created_at': '2026-08-01T10:00:00Z',
      'buyer': {'full_name': 'Buyer Name'},
      'seller': {'username': 'seller_name'},
      'pickupCode': '123456',
    });

    expect(order.participantName('buyer'), 'Buyer Name');
    expect(order.participantName('seller'), 'seller_name');
    expect(order.pickupCode, '123456');
    expect(order.totalUgx, 250000);
  });

  test('vendor dashboard parses real financial metrics', () {
    final dashboard = CommerceDashboardData.fromJson({
      'activeListings': 4,
      'lowStockListings': 1,
      'totalOrders': 8,
      'openOrders': 3,
      'grossSalesUgx': 900000,
      'releasedEarningsUgx': 600000,
      'heldEarningsUgx': 300000,
      'ratingAverage': 4.5,
      'ratingCount': 6,
      'listings': const [],
      'recentOrders': const [],
    });

    expect(dashboard.openOrders, 3);
    expect(dashboard.releasedEarningsUgx, 600000);
    expect(dashboard.heldEarningsUgx, 300000);
    expect(dashboard.ratingAverage, 4.5);
  });
}
