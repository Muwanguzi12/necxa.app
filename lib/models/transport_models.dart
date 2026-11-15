
enum VehicleType { bike, van, truck }
enum OrderStatus { pending, accepted, inProgress, delivered, completed, cancelled, disputed }

class TransportDriver {
  final String id;
  final String name;
  final String email;
  final String numberPlate;
  final String phone;
  final VehicleType vehicleType;
  final String permitUrl;
  final bool isVerified;
  final bool isAvailable;
  final String countryCode;
  final String verificationStatus;
  final String verificationReasonCode;
  final double? lat;
  final double? lng;

  TransportDriver({
    required this.id,
    required this.name,
    required this.email,
    required this.numberPlate,
    required this.phone,
    required this.vehicleType,
    required this.permitUrl,
    this.isVerified = false,
    this.isAvailable = true,
    this.countryCode = '',
    this.verificationStatus = 'not_submitted',
    this.verificationReasonCode = '',
    this.lat,
    this.lng,
  });

  factory TransportDriver.fromJson(Map<String, dynamic> json) {
    return TransportDriver(
      id: json['id'],
      name: json['name'] ?? 'Unknown',
      email: json['email'] ?? '',
      numberPlate: json['number_plate'] ?? '',
      phone: json['phone'] ?? '',
      vehicleType: VehicleType.values.firstWhere(
        (v) => v.name == (json['vehicle_type'] ?? 'bike'),
        orElse: () => VehicleType.bike,
      ),
      permitUrl: json['permit_url'] ?? '',
      isVerified: json['is_verified'] ?? false,
      isAvailable: json['is_available'] ?? true,
      countryCode: json['country_code'] ?? '',
      verificationStatus: json['verification_status'] ?? (json['is_verified'] == true ? 'verified' : 'not_submitted'),
      verificationReasonCode: json['verification_reason_code'] ?? '',
      lat: json['lat'],
      lng: json['lng'],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'number_plate': numberPlate,
    'phone': phone,
    'vehicle_type': vehicleType.name,
    'permit_url': permitUrl,
    'is_verified': isVerified,
    'is_available': isAvailable,
    'country_code': countryCode,
    'verification_status': verificationStatus,
    'verification_reason_code': verificationReasonCode,
    'lat': lat,
    'lng': lng,
  };
}

class TransportOrder {
  final String id;
  final String userId;
  final String? driverId;
  final String pickupLocation;
  final String dropoffLocation;
  final OrderStatus status;
  final double price;
  final DateTime createdAt;
  final double? deliveryLat;
  final double? deliveryLng;

  TransportOrder({
    required this.id,
    required this.userId,
    this.driverId,
    required this.pickupLocation,
    required this.dropoffLocation,
    required this.status,
    required this.price,
    required this.createdAt,
    this.deliveryLat,
    this.deliveryLng,
  });

  factory TransportOrder.fromJson(Map<String, dynamic> json) {
    return TransportOrder(
      id: json['id'],
      userId: json['user_id'],
      driverId: json['driver_id'],
      pickupLocation: json['pickup_location'] ?? '',
      dropoffLocation: json['dropoff_location'] ?? '',
      status: OrderStatus.values.firstWhere(
        (s) => s.name == (json['status'] ?? 'pending'),
        orElse: () => OrderStatus.pending,
      ),
      price: (json['price'] as num).toDouble(),
      createdAt: DateTime.parse(json['created_at']),
      deliveryLat: json['delivery_lat'] != null ? (json['delivery_lat'] as num).toDouble() : null,
      deliveryLng: json['delivery_lng'] != null ? (json['delivery_lng'] as num).toDouble() : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'driver_id': driverId,
    'pickup_location': pickupLocation,
    'dropoff_location': dropoffLocation,
    'status': status.name,
    'price': price,
    'created_at': createdAt.toIso8601String(),
    'delivery_lat': deliveryLat,
    'delivery_lng': deliveryLng,
  };
}
