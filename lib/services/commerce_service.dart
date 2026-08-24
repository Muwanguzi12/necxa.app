import 'finance_backend.dart';

class CommerceDashboardData {
  const CommerceDashboardData({
    required this.activeListings,
    required this.lowStockListings,
    required this.totalOrders,
    required this.openOrders,
    required this.grossSalesUgx,
    required this.releasedEarningsUgx,
    required this.heldEarningsUgx,
    required this.ratingAverage,
    required this.ratingCount,
    required this.listings,
    required this.recentOrders,
    this.isDelta = false,
    this.syncCursor,
  });

  factory CommerceDashboardData.fromJson(Map<String, dynamic> json) =>
      CommerceDashboardData(
        activeListings: _integer(json['activeListings']),
        lowStockListings: _integer(json['lowStockListings']),
        totalOrders: _integer(json['totalOrders']),
        openOrders: _integer(json['openOrders']),
        grossSalesUgx: _integer(json['grossSalesUgx']),
        releasedEarningsUgx: _integer(json['releasedEarningsUgx']),
        heldEarningsUgx: _integer(json['heldEarningsUgx']),
        ratingAverage: _number(json['ratingAverage']),
        ratingCount: _integer(json['ratingCount']),
        listings: _maps(json['listings']),
        recentOrders: _maps(
          json['recentOrders'],
        ).map(CommerceOrder.fromJson).toList(),
        isDelta: json['isDelta'] == true,
        syncCursor: json['syncCursor']?.toString(),
      );

  final int activeListings;
  final int lowStockListings;
  final int totalOrders;
  final int openOrders;
  final int grossSalesUgx;
  final int releasedEarningsUgx;
  final int heldEarningsUgx;
  final double ratingAverage;
  final int ratingCount;
  final List<Map<String, dynamic>> listings;
  final List<CommerceOrder> recentOrders;
  final bool isDelta;
  final String? syncCursor;

  CommerceDashboardData mergeDelta(CommerceDashboardData update) {
    if (!update.isDelta) return update;
    final listingsById = <String, Map<String, dynamic>>{
      for (final listing in listings)
        if (listing['id'] != null) listing['id'].toString(): listing,
    };
    for (final listing in update.listings) {
      final id = listing['id']?.toString();
      if (id != null && id.isNotEmpty) listingsById[id] = listing;
    }
    final ordersById = {for (final order in recentOrders) order.id: order};
    for (final order in update.recentOrders) {
      ordersById[order.id] = order;
    }
    final mergedOrders = ordersById.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return CommerceDashboardData(
      activeListings: update.activeListings,
      lowStockListings: update.lowStockListings,
      totalOrders: update.totalOrders,
      openOrders: update.openOrders,
      grossSalesUgx: update.grossSalesUgx,
      releasedEarningsUgx: update.releasedEarningsUgx,
      heldEarningsUgx: update.heldEarningsUgx,
      ratingAverage: update.ratingAverage,
      ratingCount: update.ratingCount,
      listings: listingsById.values.toList(),
      recentOrders: mergedOrders.take(10).toList(),
      syncCursor: update.syncCursor,
    );
  }

  Map<String, dynamic> toJson() => {
    'activeListings': activeListings,
    'lowStockListings': lowStockListings,
    'totalOrders': totalOrders,
    'openOrders': openOrders,
    'grossSalesUgx': grossSalesUgx,
    'releasedEarningsUgx': releasedEarningsUgx,
    'heldEarningsUgx': heldEarningsUgx,
    'ratingAverage': ratingAverage,
    'ratingCount': ratingCount,
    'listings': listings,
    'recentOrders': recentOrders.map((order) => order.toJson()).toList(),
    'isDelta': false,
    if (syncCursor != null) 'syncCursor': syncCursor,
  };
}

class CommerceOrder {
  const CommerceOrder({
    required this.id,
    required this.orderNumber,
    required this.buyerId,
    required this.sellerId,
    required this.listingId,
    required this.productTitle,
    required this.productMediaUrl,
    required this.quantity,
    required this.unitPriceUgx,
    required this.deliveryFeeUgx,
    required this.totalUgx,
    required this.status,
    required this.paymentStatus,
    required this.settlementStatus,
    required this.deliveryAddress,
    required this.createdAt,
    required this.delivery,
    required this.buyer,
    required this.seller,
    required this.driver,
    required this.settlements,
    this.pickupCode,
    this.deliveryCode,
    this.updatedAt,
  });

  factory CommerceOrder.fromJson(Map<String, dynamic> json) => CommerceOrder(
    id: json['id']?.toString() ?? '',
    orderNumber: json['order_number']?.toString() ?? 'Order',
    buyerId: json['buyer_id']?.toString() ?? '',
    sellerId: json['seller_id']?.toString() ?? '',
    listingId: json['listing_id']?.toString() ?? '',
    productTitle: json['product_title']?.toString() ?? 'Product',
    productMediaUrl: json['product_media_url']?.toString(),
    quantity: _integer(json['quantity']),
    unitPriceUgx: _integer(json['unit_price_ugx']),
    deliveryFeeUgx: _integer(json['delivery_fee_ugx']),
    totalUgx: _integer(json['total_ugx']),
    status: json['status']?.toString() ?? 'pending',
    paymentStatus: json['payment_status']?.toString() ?? 'PENDING',
    settlementStatus: json['settlement_status']?.toString() ?? 'pending',
    deliveryAddress: json['delivery_address']?.toString() ?? '',
    createdAt:
        DateTime.tryParse(json['created_at']?.toString() ?? '') ??
        DateTime.now(),
    delivery: _map(json['delivery']),
    buyer: _map(json['buyer']),
    seller: _map(json['seller']),
    driver: _map(json['driver']),
    settlements: _maps(json['settlements']),
    pickupCode: json['pickupCode']?.toString(),
    deliveryCode: json['deliveryCode']?.toString(),
    updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
  );

  final String id;
  final String orderNumber;
  final String buyerId;
  final String sellerId;
  final String listingId;
  final String productTitle;
  final String? productMediaUrl;
  final int quantity;
  final int unitPriceUgx;
  final int deliveryFeeUgx;
  final int totalUgx;
  final String status;
  final String paymentStatus;
  final String settlementStatus;
  final String deliveryAddress;
  final DateTime createdAt;
  final Map<String, dynamic>? delivery;
  final Map<String, dynamic>? buyer;
  final Map<String, dynamic>? seller;
  final Map<String, dynamic>? driver;
  final List<Map<String, dynamic>> settlements;
  final String? pickupCode;
  final String? deliveryCode;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'order_number': orderNumber,
    'buyer_id': buyerId,
    'seller_id': sellerId,
    'listing_id': listingId,
    'product_title': productTitle,
    'product_media_url': productMediaUrl,
    'quantity': quantity,
    'unit_price_ugx': unitPriceUgx,
    'delivery_fee_ugx': deliveryFeeUgx,
    'total_ugx': totalUgx,
    'status': status,
    'payment_status': paymentStatus,
    'settlement_status': settlementStatus,
    'delivery_address': deliveryAddress,
    'created_at': createdAt.toUtc().toIso8601String(),
    if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
    'delivery': _cacheDelivery(delivery),
    'buyer': _cacheProfile(buyer),
    'seller': _cacheProfile(seller),
    'driver': _cacheProfile(driver),
    'settlements': settlements,
  };

  String participantName(String role) {
    final profile = switch (role) {
      'buyer' => buyer,
      'seller' => seller,
      'driver' => driver,
      _ => null,
    };
    return profile?['full_name']?.toString().trim().isNotEmpty == true
        ? profile!['full_name'].toString()
        : profile?['username']?.toString() ?? role;
  }
}

class CommerceOrderPage {
  const CommerceOrderPage({
    required this.orders,
    this.nextCursor,
    this.syncCursor,
  });

  final List<CommerceOrder> orders;
  final String? nextCursor;
  final String? syncCursor;
}

class CommerceService {
  CommerceService({FinanceBackend? backend})
    : _backend = backend ?? FinanceBackend.instance;

  final FinanceBackend _backend;

  Future<CommerceDashboardData> fetchVendorDashboard({
    String? updatedSince,
  }) async {
    final response = await _backend.invoke(
      'commerce_dashboard',
      body: {if (updatedSince != null) 'updatedSince': updatedSince},
    );
    final dashboard = _map(response['dashboard']) ?? {};
    dashboard['isDelta'] = response['isDelta'] == true;
    dashboard['syncCursor'] = response['syncCursor'];
    return CommerceDashboardData.fromJson(dashboard);
  }

  Future<CommerceOrderPage> fetchOrders({
    String role = 'buyer',
    String? cursor,
    String? updatedSince,
    int limit = 20,
  }) async {
    final response = await _backend.invoke(
      'list_commerce_orders',
      body: {
        'role': role,
        'cursor': cursor,
        if (updatedSince != null) 'updatedSince': updatedSince,
        'limit': limit,
      },
    );
    return CommerceOrderPage(
      orders: _maps(response['orders']).map(CommerceOrder.fromJson).toList(),
      nextCursor: response['nextCursor']?.toString(),
      syncCursor: response['syncCursor']?.toString(),
    );
  }

  Future<CommerceOrder> fetchOrder(
    String orderId, {
    int eventCursor = 0,
  }) async {
    final response = await _backend.invoke(
      'get_commerce_order',
      body: {'orderId': orderId, 'eventCursor': eventCursor},
    );
    return CommerceOrder.fromJson(_map(response['order']) ?? {});
  }

  Future<List<CommerceOrder>> fetchAvailableDeliveries() async {
    final response = await _backend.invoke('list_available_deliveries');
    return _maps(response['deliveries']).map(CommerceOrder.fromJson).toList();
  }

  Future<void> transitionOrder(
    String orderId,
    String transition, {
    String? verificationCode,
    Map<String, dynamic> metadata = const {},
  }) async {
    await _backend.invoke(
      'transition_commerce_order',
      body: {
        'orderId': orderId,
        'transition': transition,
        if (verificationCode != null) 'verificationCode': verificationCode,
        'metadata': metadata,
      },
    );
  }

  Future<Map<String, dynamic>> updateInventory({
    required String listingId,
    required int stockCount,
    String? status,
  }) async {
    final response = await _backend.invoke(
      'update_commerce_inventory',
      body: {
        'listingId': listingId,
        'stockCount': stockCount,
        if (status != null) 'status': status,
      },
    );
    return _map(response['listing']) ?? {};
  }

  Future<Map<String, dynamic>> reviewEligibility(String listingId) =>
      _backend.invoke('review_eligibility', body: {'listingId': listingId});

  Future<Map<String, dynamic>> submitReview({
    required String orderId,
    required int rating,
    required String comment,
    List<String> mediaUrls = const [],
  }) => _backend.invoke(
    'submit_commerce_review',
    body: {
      'orderId': orderId,
      'rating': rating,
      'comment': comment,
      'mediaUrls': mediaUrls,
    },
  );

  Future<Map<String, dynamic>> fetchReviews({
    required String listingId,
    String? cursor,
    int limit = 20,
  }) => _backend.invoke(
    'list_commerce_reviews',
    body: {'listingId': listingId, 'cursor': cursor, 'limit': limit},
  );

  Future<Map<String, dynamic>> respondToReview({
    required String reviewId,
    required String response,
  }) => _backend.invoke(
    'respond_to_commerce_review',
    body: {'reviewId': reviewId, 'response': response},
  );

  Future<Map<String, dynamic>> fetchVendorReviews({
    String? cursor,
    String? updatedSince,
    int limit = 20,
  }) => _backend.invoke(
    'list_vendor_reviews',
    body: {
      'cursor': cursor,
      if (updatedSince != null) 'updatedSince': updatedSince,
      'limit': limit,
    },
  );
}

int _integer(dynamic value) =>
    (value as num?)?.round() ?? int.tryParse(value?.toString() ?? '') ?? 0;

double _number(dynamic value) =>
    (value as num?)?.toDouble() ??
    double.tryParse(value?.toString() ?? '') ??
    0;

Map<String, dynamic>? _map(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

List<Map<String, dynamic>> _maps(dynamic value) {
  if (value is! List) return const [];
  return value.map(_map).whereType<Map<String, dynamic>>().toList();
}

Map<String, dynamic>? _cacheProfile(Map<String, dynamic>? profile) {
  if (profile == null) return null;
  return {
    for (final key in ['id', 'full_name', 'username', 'avatar_url'])
      if (profile[key] != null) key: profile[key],
  };
}

Map<String, dynamic>? _cacheDelivery(Map<String, dynamic>? delivery) {
  if (delivery == null) return null;
  return {
    for (final key in [
      'id',
      'order_id',
      'driver_id',
      'status',
      'delivery_fee_ugx',
      'delivery_method',
      'delivery_speed',
      'pickup_location',
      'dropoff_location',
      'dropoff_address',
      'pickup_ready_at',
      'assigned_at',
      'picked_up_at',
      'delivered_at',
      'completed_at',
      'proof',
      'updated_at',
    ])
      if (delivery[key] != null) key: delivery[key],
  };
}
