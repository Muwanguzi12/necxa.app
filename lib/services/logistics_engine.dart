import 'dart:math';
import '../models/transport_models.dart';

enum DeliveryTier { standard, express, batch }

class LogisticsEngine {
  // Base Rates in UGX
  static const Map<VehicleType, double> baseRates = {
    VehicleType.bike: 3000,
    VehicleType.van: 15000,
    VehicleType.truck: 45000,
  };

  // Per-KM rate
  static const double ratePerKm = 2500;

  // Mock Geocoder for Kampala Hubs
  static const Map<String, Map<String, double>> hubCoordinates = {
    'kampala central': {'lat': 0.3163, 'lng': 32.5811},
    'nakawa': {'lat': 0.3341, 'lng': 32.6186},
    'makindye': {'lat': 0.2878, 'lng': 32.5857},
    'kawempe': {'lat': 0.3756, 'lng': 32.5564},
    'rubaga': {'lat': 0.3013, 'lng': 32.5542},
    'entebbe': {'lat': 0.0514, 'lng': 32.4637},
    'mukono': {'lat': 0.3547, 'lng': 32.7483},
    'wakiso': {'lat': 0.3951, 'lng': 32.4606},
  };

  // Tier Multipliers
  static const Map<DeliveryTier, double> tierMultipliers = {
    DeliveryTier.standard: 1.0,
    DeliveryTier.express: 1.8, // 80% Premium
    DeliveryTier.batch: 0.6, // 40% Discount for scheduled/grouped
  };

  /// Calculates estimated fare based on location, vehicle, and tier
  static double calculateFare({
    required String pickup,
    required String dropoff,
    required VehicleType vehicleType,
    DeliveryTier tier = DeliveryTier.standard,
    DateTime? scheduledDate,
    int quantity = 1,
    double unitWeightKg = 0,
    double lengthCm = 0,
    double widthCm = 0,
    double heightCm = 0,
    double? pickupLatitude,
    double? pickupLongitude,
    double? dropoffLatitude,
    double? dropoffLongitude,
  }) {
    final base = baseRates[vehicleType] ?? 3000;
    final multiplier = tierMultipliers[tier] ?? 1.0;

    // Normalize names for mock lookup
    final pKey = pickup.toLowerCase().trim();
    final dKey = dropoff.toLowerCase().trim();

    double distanceKm = 5.0; // Default fallback distance

    if (pickupLatitude != null &&
        pickupLongitude != null &&
        dropoffLatitude != null &&
        dropoffLongitude != null) {
      distanceKm = _getHaversineDistance(
        pickupLatitude,
        pickupLongitude,
        dropoffLatitude,
        dropoffLongitude,
      );
    } else if (hubCoordinates.containsKey(pKey) &&
        hubCoordinates.containsKey(dKey)) {
      final pPos = hubCoordinates[pKey]!;
      final dPos = hubCoordinates[dKey]!;
      distanceKm = _getHaversineDistance(
        pPos['lat']!,
        pPos['lng']!,
        dPos['lat']!,
        dPos['lng']!,
      );
    }

    // Minimum distance for pricing
    if (distanceKm < 1.0) distanceKm = 1.0;

    // Date-based optimization: Batch orders on weekends/evenings could be even lower
    double dateDiscount = 1.0;
    if (scheduledDate != null && tier == DeliveryTier.batch) {
      if (scheduledDate.weekday == DateTime.saturday ||
          scheduledDate.weekday == DateTime.sunday) {
        dateDiscount = 0.85; // Extra 15% off for weekend batching
      }
    }

    final safeQuantity = max(1, quantity);
    final actualWeight = max(0, unitWeightKg) * safeQuantity;
    final volumetricWeight =
        (max(0, lengthCm) * max(0, widthCm) * max(0, heightCm) / 5000) *
        safeQuantity;
    final chargeableWeight = max(actualWeight, volumetricWeight);
    final includedWeight = switch (vehicleType) {
      VehicleType.bike => 5.0,
      VehicleType.van => 50.0,
      VehicleType.truck => 500.0,
    };
    final excessWeightCharge = max(0, chargeableWeight - includedWeight) * 500;
    final handlingCharge = max(0, safeQuantity - 1) * 500;

    return ((base +
                (distanceKm * ratePerKm) +
                excessWeightCharge +
                handlingCharge) *
            multiplier *
            dateDiscount)
        .ceilToDouble();
  }

  /// Simple Haversine formula for distance in KM
  static double _getHaversineDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double radius = 6371; // Earth radius in KM
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) *
            cos(_toRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return radius * c;
  }

  static double _toRadians(double degree) => degree * pi / 180;

  /// Simulates finding the nearest available drivers for a given location
  static List<Map<String, dynamic>> findNearestDrivers(double lat, double lng) {
    // Mock driver pool in Kampala
    return [
      {
        'id': 'dr_1',
        'name': 'John Boda',
        'phone': '+256 780 111222',
        'dist': 0.8,
      },
      {
        'id': 'dr_2',
        'name': 'Sarah Van',
        'phone': '+256 701 333444',
        'dist': 1.5,
      },
      {
        'id': 'dr_3',
        'name': 'Musa Truck',
        'phone': '+256 755 555666',
        'dist': 3.2,
      },
    ];
  }
}
