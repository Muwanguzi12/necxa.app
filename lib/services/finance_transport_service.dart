import 'finance_backend.dart';

class FinanceTransportService {
  FinanceTransportService({FinanceBackend? backend})
    : _backend = backend ?? FinanceBackend.instance;

  final FinanceBackend _backend;

  Future<Map<String, dynamic>> createTransportBooking({
    required String orderId,
    required String driverId,
    required String pickup,
    required String dropoff,
    required int amountUgx,
    required String idempotencyKey,
  }) async {
    final response = await _backend.invoke(
      'create_transport_booking',
      body: {
        'orderId': orderId,
        'driverId': driverId,
        'pickup': pickup,
        'dropoff': dropoff,
        'amountUgx': amountUgx,
        'idempotencyKey': idempotencyKey,
      },
    );
    return _map(response) ?? {};
  }

  Future<Map<String, dynamic>> settleTransportBooking(String orderId) async {
    final response = await _backend.invoke(
      'settle_transport_booking',
      body: {'orderId': orderId},
    );
    return _map(response) ?? {};
  }

  Future<Map<String, dynamic>> refundTransportBooking({
    required String orderId,
    required String reason,
  }) async {
    final response = await _backend.invoke(
      'refund_transport_booking',
      body: {'orderId': orderId, 'reason': reason},
    );
    return _map(response) ?? {};
  }

  Future<Map<String, dynamic>> disputeTransportBooking({
    required String orderId,
    required String reason,
  }) async {
    final response = await _backend.invoke(
      'dispute_transport_booking',
      body: {'orderId': orderId, 'reason': reason},
    );
    return _map(response) ?? {};
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }
}
