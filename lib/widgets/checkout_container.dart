import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:convert';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../services/logistics_engine.dart';
import '../models/transport_models.dart';
import '../services/wallet_service.dart';

class CheckoutContainer extends StatefulWidget {
  final AppState state;
  final Map<String, dynamic> listing;
  final VoidCallback onDismiss;

  const CheckoutContainer({
    super.key,
    required this.state,
    required this.listing,
    required this.onDismiss,
  });

  @override
  State<CheckoutContainer> createState() => _CheckoutContainerState();
}

class _CheckoutContainerState extends State<CheckoutContainer> {
  int _step =
      0; // 0: Product, 1: Place Order, 2: Delivery, 3: Payment, 4: Success, 5: Tracking
  String _selectedPaymentMethod = 'balance';
  String? _currentOrderId;
  bool _loading = false;
  DeliveryTier _selectedTier = DeliveryTier.standard;
  VehicleType _selectedVehicle = VehicleType.bike;
  double _deliveryFare = 0;
  int _quantity = 1;

  double _listingNumber(String key) =>
      double.tryParse(widget.listing[key]?.toString() ?? '') ?? 0;

  List<double>? get _dropoffCoordinates {
    final parts = _coordinates?.split(',');
    if (parts == null || parts.length != 2) return null;
    final latitude = double.tryParse(parts[0].trim());
    final longitude = double.tryParse(parts[1].trim());
    return latitude == null || longitude == null ? null : [latitude, longitude];
  }

  double _calculateDeliveryFare(DeliveryTier tier) =>
      LogisticsEngine.calculateFare(
        pickup:
            widget.listing['pickup_address']?.toString() ?? 'Kampala Central',
        dropoff: _addressController.text.isEmpty
            ? 'Nakawa'
            : _addressController.text,
        vehicleType: _selectedVehicle,
        tier: tier,
        quantity: _quantity,
        unitWeightKg: _listingNumber('weight_kg'),
        lengthCm: _listingNumber('length_cm'),
        widthCm: _listingNumber('width_cm'),
        heightCm: _listingNumber('height_cm'),
        pickupLatitude: double.tryParse(
          widget.listing['latitude']?.toString() ?? '',
        ),
        pickupLongitude: double.tryParse(
          widget.listing['longitude']?.toString() ?? '',
        ),
        dropoffLatitude: _dropoffCoordinates?.first,
        dropoffLongitude: _dropoffCoordinates?.last,
      );

  List<String> _getProductPhotos() {
    final rawPhotos =
        widget.listing['miniature_photos'] ??
        widget.listing['photos'] ??
        widget.listing['listing_photos'];
    if (rawPhotos == null) return [];
    if (rawPhotos is List) {
      return rawPhotos
          .map(_extractImageUrl)
          .whereType<String>()
          .where((url) => url.isNotEmpty)
          .toList();
    } else if (rawPhotos is String && rawPhotos.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPhotos);
        if (decoded is List) {
          return decoded
              .map(_extractImageUrl)
              .whereType<String>()
              .where((url) => url.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }
    return [];
  }

  String? _extractImageUrl(dynamic value) {
    if (value == null) return null;
    if (value is String) return value.trim().isEmpty ? null : value.trim();
    if (value is Map) {
      for (final key in [
        'url',
        'image_url',
        'thumbnail_url',
        'media_url',
        'path',
      ]) {
        final url = _extractImageUrl(value[key]);
        if (url != null) return url;
      }
    }
    return null;
  }

  String? _primaryListingImageUrl() {
    final photos = _getProductPhotos();
    if (photos.isNotEmpty) return photos.first;
    return _extractImageUrl(widget.listing['thumbnail_url']) ??
        _extractImageUrl(widget.listing['image_url']) ??
        _extractImageUrl(widget.listing['media_url']) ??
        _extractImageUrl(widget.listing['film_hub_content']);
  }

  @override
  void initState() {
    super.initState();
    _deliveryFare = _calculateDeliveryFare(_selectedTier);
  }

  // Order Details
  final TextEditingController _addressController = TextEditingController(
    text: 'Kampala, Uganda',
  );
  final TextEditingController _contactController = TextEditingController(
    text: '+256 700 123456',
  );
  String? _coordinates;

  void _next() => setState(() => _step++);
  void _back() => setState(() => _step--);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0D121B),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 40,
            spreadRadius: 10,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag Handle
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: SizedBox(
                    key: ValueKey(_step),
                    child: _buildStepContent(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepContent() {
    switch (_step) {
      case 0:
        return _buildProductOverview();
      case 1:
        return _buildPlaceOrder();
      case 2:
        return _buildDeliveryTier();
      case 3:
        return _buildPayment();
      case 4:
        return _buildSuccess();
      case 5:
        return _buildTracking();
      default:
        return _buildProductOverview();
    }
  }

  // --- STEP 0: PRODUCT OVERVIEW ---
  Widget _buildProductOverview() {
    final photos = _getProductPhotos();
    final price = widget.listing['price'] ?? 0;
    final title = widget.listing['title'] ?? 'Luxury Shard';
    final sku = widget.listing['sku'] ?? 'SKU-PENDING';

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PRODUCT DETAILS',
            style: syne(sz: 12, w: FontWeight.w900, c: Colors.white38, ls: 2),
          ),
          const SizedBox(height: 20),

          // Images Grid/Pictures Down
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.isEmpty ? 1 : photos.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final url = photos.isNotEmpty
                    ? photos[i]
                    : _primaryListingImageUrl();
                return Container(
                  width: 120,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white10),
                    image: url != null
                        ? DecorationImage(
                            image: NetworkImage(url),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 24),
          Text(
            title,
            style: syne(sz: 24, w: FontWeight.w900, c: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(
            widget.listing['description'] ??
                'Exclusive digital asset from Necxa Film Hub.',
            style: dm(sz: 14, c: Colors.white70, h: 1.5),
          ),

          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('QUANTITY', style: dm(sz: 10, c: Colors.white38)),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.remove,
                        color: Colors.white70,
                        size: 16,
                      ),
                      onPressed: () {
                        if (_quantity > 1)
                          setState(() {
                            _quantity--;
                            _deliveryFare = _calculateDeliveryFare(
                              _selectedTier,
                            );
                          });
                      },
                    ),
                    Text(
                      '$_quantity',
                      style: syne(sz: 16, w: FontWeight.bold, c: Colors.white),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.add,
                        color: Colors.white70,
                        size: 16,
                      ),
                      onPressed: () {
                        // Max out at stock_count if available
                        final stock = widget.listing['stock_count'] ?? 999;
                        if (_quantity < stock)
                          setState(() {
                            _quantity++;
                            _deliveryFare = _calculateDeliveryFare(
                              _selectedTier,
                            );
                          });
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TOTAL PRICE', style: dm(sz: 10, c: Colors.white38)),
                  Text(
                    ugx(price.toDouble() * _quantity),
                    style: syne(sz: 20, w: FontWeight.w900, c: C.brand),
                  ),
                  const SizedBox(height: 4),
                  Text('SKU: $sku', style: dm(sz: 9, c: Colors.white38)),
                ],
              ),
              GestureDetector(
                onTap: _next,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    gradient: brandGrad,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: C.brand.withOpacity(0.3),
                        blurRadius: 15,
                      ),
                    ],
                  ),
                  child: Text(
                    'BUY NOW',
                    style: dm(sz: 14, w: FontWeight.w900, c: Colors.black),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- STEP 1: PLACE ORDER ---
  Widget _buildPlaceOrder() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader('3', 'DELIVERY INFO', onBack: _back),
          const SizedBox(height: 16),

          // Product Summary Card
          _summaryCard(),

          const SizedBox(height: 24),
          Text(
            'DELIVERY ADDRESS',
            style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38, ls: 1),
          ),
          const SizedBox(height: 12),
          _checkoutInput(
            controller: _addressController,
            hint: 'Street, House Number, City',
            icon: Icons.location_on_outlined,
            suffix: IconButton(
              icon: Icon(
                Icons.my_location,
                color: _coordinates != null ? Colors.greenAccent : C.brand,
                size: 20,
              ),
              onPressed: _captureLocation,
              tooltip: 'Pin current location',
            ),
          ),
          if (_coordinates != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 12),
              child: Text(
                'GPS: $_coordinates',
                style: dm(sz: 10, c: Colors.greenAccent.withOpacity(0.7)),
              ),
            ),

          const SizedBox(height: 24),
          Text(
            'CONTACT NUMBER',
            style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38, ls: 1),
          ),
          const SizedBox(height: 12),
          _checkoutInput(
            controller: _contactController,
            hint: 'Phone number for delivery',
            icon: Icons.phone_outlined,
            keyboardType: TextInputType.phone,
          ),

          const SizedBox(height: 32),
          _actionButton('Select Delivery Type', () {
            if (_addressController.text.isEmpty ||
                _contactController.text.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Please fill all delivery details'),
                ),
              );
              return;
            }
            // Re-calculate fare before showing options
            setState(() {
              _deliveryFare = _calculateDeliveryFare(_selectedTier);
            });
            _next();
          }),
        ],
      ),
    );
  }

  // --- STEP 4: DELIVERY TIER ---
  Widget _buildDeliveryTier() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader('4', 'DELIVERY SPEED', onBack: _back),

          Text(
            'HOW FAST DO YOU NEED IT?',
            style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38),
          ),
          const SizedBox(height: 12),
          Text(
            'DELIVERY METHOD',
            style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: VehicleType.values.map((vehicle) {
              final selected = vehicle == _selectedVehicle;
              return ChoiceChip(
                label: Text(vehicle.name.toUpperCase()),
                selected: selected,
                onSelected: (_) => setState(() {
                  _selectedVehicle = vehicle;
                  _deliveryFare = _calculateDeliveryFare(_selectedTier);
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          _deliveryOption(
            'Express Delivery',
            'Within 30-60 mins',
            DeliveryTier.express,
            Icons.bolt_rounded,
            color: const Color(0xFF00E5FF),
          ),
          const SizedBox(height: 12),
          _deliveryOption(
            'Standard Delivery',
            'Same day (3-6 hours)',
            DeliveryTier.standard,
            Icons.local_shipping_outlined,
          ),
          const SizedBox(height: 12),
          _deliveryOption(
            'Batch Delivery',
            'Next available route (Best Value)',
            DeliveryTier.batch,
            Icons.layers_outlined,
            color: Colors.greenAccent,
          ),

          const SizedBox(height: 32),
          _actionButton('Confirm Delivery & Pay', _next),
        ],
      ),
    );
  }

  Widget _deliveryOption(
    String title,
    String subtitle,
    DeliveryTier tier,
    IconData icon, {
    Color? color,
  }) {
    final active = _selectedTier == tier;
    final fare = _calculateDeliveryFare(tier);

    return GestureDetector(
      onTap: () => setState(() {
        _selectedTier = tier;
        _deliveryFare = fare;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: active
              ? (color ?? C.brand).withOpacity(0.1)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active
                ? (color ?? C.brand).withOpacity(0.5)
                : Colors.white10,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: active ? (color ?? C.brand) : Colors.white38,
              size: 24,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: syne(
                      sz: 14,
                      w: FontWeight.bold,
                      c: active ? Colors.white : Colors.white70,
                    ),
                  ),
                  Text(subtitle, style: dm(sz: 11, c: Colors.white38)),
                ],
              ),
            ),
            Text(
              ugx(fare),
              style: syne(
                sz: 14,
                w: FontWeight.w900,
                c: active ? (color ?? C.brand) : Colors.white38,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _captureLocation() async {
    setState(() => _loading = true);
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        setState(() {
          _coordinates =
              "${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}";
          _deliveryFare = _calculateDeliveryFare(_selectedTier);
          _loading = false;
        });
      } else {
        throw 'Location permission denied';
      }
    } catch (e) {
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Widget _checkoutInput({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    Widget? suffix,
    TextInputType? keyboardType,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: dm(sz: 14, c: Colors.white),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: dm(sz: 14, c: Colors.white24),
          prefixIcon: Icon(icon, color: C.brand, size: 20),
          suffixIcon: suffix,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(16),
        ),
      ),
    );
  }

  // --- STEP 2: PAYMENT METHOD ---
  Widget _buildPayment() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader('4', 'PAYMENT METHOD', onBack: _back),

          Text(
            'PAY WITH NECXA',
            style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38),
          ),
          const SizedBox(height: 12),
          _payOption(
            'Necxa Balance',
            'UGX ${kNum(widget.state.cashBalance.toInt())}',
            'balance',
            Icons.account_balance_wallet_outlined,
          ),

          const SizedBox(height: 24),
          Text(
            'OTHER METHODS',
            style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38),
          ),
          const SizedBox(height: 12),
          _payOption(
            'Mobile Money',
            'MTN / Airtel',
            'momo',
            Icons.phone_android_outlined,
          ),
          const SizedBox(height: 12),
          _payOption(
            'Visa / Mastercard',
            'Debit or Credit Card',
            'card',
            Icons.credit_card_outlined,
          ),
          const SizedBox(height: 12),
          _payOption(
            'USDT (Crypto)',
            'Pay with USDT',
            'crypto',
            Icons.currency_bitcoin_outlined,
          ),

          const SizedBox(height: 32),
          _actionButton(
            'Pay ${ugx(((widget.listing['price'] ?? 0).toDouble() * _quantity) + _deliveryFare)}',
            () async {
              setState(() => _loading = true);
              try {
                final itemsUgx =
                    (widget.listing['price'] ?? 0).toDouble() * _quantity;
                final totalUgx = itemsUgx + _deliveryFare;

                if (_selectedPaymentMethod == 'balance') {
                  final coordinates = _dropoffCoordinates;
                  if (coordinates == null) {
                    throw Exception(
                      'Pin your delivery location before paying.',
                    );
                  }
                  final res = await WalletService().processShopPurchase(
                    listingId: widget.listing['id'],
                    quantity: _quantity,
                    deliverySpeed: _selectedTier.name,
                    deliveryMethod: _selectedVehicle.name,
                    customerLocation: {
                      'lat': coordinates[0],
                      'lng': coordinates[1],
                    },
                    deliveryAddress: _addressController.text,
                    customerNumber: _contactController.text,
                  );

                  if (res.isSuccess && res.orderId != null) {
                    setState(() {
                      _currentOrderId = res.orderId;
                      _deliveryFare = res.deliveryFeeUgx ?? _deliveryFare;
                      _loading = false;
                    });
                    await widget.state.syncVault();
                    _next();
                  } else {
                    throw Exception(res.message);
                  }
                } else if (_selectedPaymentMethod == 'momo' ||
                    _selectedPaymentMethod == 'card') {
                  // Call initiatePesapalPayment via Vault
                  final res = await widget.state.firebaseVault
                      .initiatePesapalPayment(
                        amount: totalUgx,
                        currency: 'UGX',
                        description: 'Shop purchase',
                        type: 'shop_purchase',
                        email: widget.state.user?.email ?? 'guest@necxa.com',
                        phone: _contactController.text,
                        packId: widget.listing['id'],
                        listingId: widget.listing['id'],
                      );

                  if (res['success'] == true) {
                    final redirectUrl = res['redirect_url'];
                    if (await canLaunchUrlString(redirectUrl)) {
                      await launchUrlString(
                        redirectUrl,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                    setState(() {
                      _currentOrderId = res['order_id']?.toString();
                      _loading = false;
                    });
                    // Move to tracking; Webhook will mark as paid
                    _next();
                  } else {
                    throw Exception(
                      res['message'] ?? 'Failed to launch Pesapal',
                    );
                  }
                } else {
                  throw Exception("Payment method not supported yet.");
                }
              } catch (e) {
                setState(() => _loading = false);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(e.toString())));
              }
            },
            loading: _loading,
          ),
        ],
      ),
    );
  }

  // --- STEP 3: SUCCESS ---
  Widget _buildSuccess() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _stepHeader('5', 'ORDER CONFIRMATION'),

          const SizedBox(height: 20),
          const Icon(
            Icons.check_circle_outline,
            color: Colors.greenAccent,
            size: 80,
          ),
          const SizedBox(height: 24),
          Text(
            'Order Placed Successfully!',
            style: syne(sz: 20, w: FontWeight.w900, c: Colors.white),
          ),
          const SizedBox(height: 12),
          Text(
            'Your order has been received and is being processed.',
            textAlign: TextAlign.center,
            style: dm(sz: 14, c: Colors.white70),
          ),

          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                _row(
                  'Product Price (x$_quantity)',
                  ugx((widget.listing['price'] ?? 0).toDouble() * _quantity),
                ),
                const SizedBox(height: 8),
                _row(
                  'Delivery (${_selectedTier.name.toUpperCase()})',
                  ugx(_deliveryFare),
                ),
                const Divider(color: Colors.white10, height: 24),
                _row(
                  'Total Paid',
                  ugx(
                    ((widget.listing['price'] ?? 0).toDouble() * _quantity) +
                        _deliveryFare,
                  ),
                ),
                const Divider(color: Colors.white10, height: 24),
                _row('Payment Method', _selectedPaymentMethod.toUpperCase()),
              ],
            ),
          ),

          const SizedBox(height: 32),
          _actionButton('Track Order', _next),
        ],
      ),
    );
  }

  // --- STEP 4: TRACKING ---
  Widget _buildTracking() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader('7', 'TRACK ORDER', onBack: _back),

          Text(
            _currentOrderId ?? 'ORD-PENDING',
            style: syne(sz: 16, w: FontWeight.w900, c: Colors.white),
          ),
          Text(
            'Real-time tracking enabled via Firebase',
            style: dm(sz: 11, c: Colors.white38),
          ),

          const SizedBox(height: 24),
          StreamBuilder<DocumentSnapshot>(
            stream: _currentOrderId != null
                ? widget.state.orders.streamOrder(_currentOrderId!)
                : const Stream.empty(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (!snapshot.hasData || snapshot.data?.data() == null) {
                return const Text('Waiting for order confirmation...');
              }

              final data = snapshot.data!.data() as Map<String, dynamic>;
              final history = data['tracking_history'] as List? ?? [];
              final status = data['status'] ?? 'pending';
              final driverName = data['driver_name'] as String?;
              final driverPhone = data['driver_phone'] as String?;
              final driverLat = (data['driver_lat'] as num?)?.toDouble();
              final driverLng = (data['driver_lng'] as num?)?.toDouble();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 🗺️ Live Map Tracking
                  if (driverLat != null && driverLng != null) ...[
                    Container(
                      height: 200,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: C.brand.withOpacity(0.3)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: GoogleMap(
                        initialCameraPosition: CameraPosition(
                          target: LatLng(driverLat, driverLng),
                          zoom: 15.0,
                        ),
                        markers: {
                          Marker(
                            markerId: const MarkerId('driver'),
                            position: LatLng(driverLat, driverLng),
                            infoWindow: InfoWindow(
                              title: driverName ?? 'Courier',
                            ),
                            icon: BitmapDescriptor.defaultMarkerWithHue(
                              BitmapDescriptor.hueOrange,
                            ),
                          ),
                        },
                        myLocationButtonEnabled: false,
                        zoomControlsEnabled: false,
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // 🚚 Driver Identity & Coordination HUD
                  if (driverName != null) ...[
                    _buildDriverHud(driverName, driverPhone, data['driver_id']),
                    const SizedBox(height: 24),
                  ],

                  for (int i = 0; i < history.length; i++) ...[
                    _trackNode(
                      history[i]['status'],
                      history[i]['message'],
                      true,
                      active: i == history.length - 1,
                    ),
                    if (i < history.length - 1) _trackLine(true),
                  ],
                  if (status != 'delivered' && status != 'completed') ...[
                    _trackLine(false),
                    _trackNode('Next Step', 'Finalizing fulfillment...', false),
                  ],
                ],
              );
            },
          ),

          const SizedBox(height: 40),
          _actionButton('Done', widget.onDismiss),
        ],
      ),
    );
  }

  Widget _buildDriverHud(String name, String? phone, String? driverId) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.brand.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: C.brand.withOpacity(0.2),
                child: const Icon(Icons.delivery_dining, color: C.brand),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'COURIER ASSIGNED',
                      style: syne(sz: 9, w: FontWeight.w900, c: C.brand, ls: 1),
                    ),
                    Text(
                      name,
                      style: syne(sz: 16, w: FontWeight.w900, c: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _hudBtn(Icons.phone, 'CALL', () {
                if (phone != null) {
                  // In a real app: launch('tel:$phone');
                  debugPrint('📞 Calling Driver: $phone');
                }
              }),
              const SizedBox(width: 8),
              _hudBtn(Icons.chat_bubble_outline, 'CHAT', () {
                if (driverId != null) {
                  widget.state.openCreatorChat(
                    driverId,
                    name,
                    null,
                    context: 'vendor', // Treat driver as a service vendor
                  );
                  widget.onDismiss(); // Close checkout to enter chat
                }
              }),
              const SizedBox(width: 8),
              _hudBtn(Icons.mic_none, 'VOICE', () {
                // Coordination voice note logic
              }, color: Colors.redAccent),
            ],
          ),
        ],
      ),
    );
  }

  Widget _hudBtn(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color? color,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: (color ?? C.brand).withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: (color ?? C.brand).withOpacity(0.2)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color ?? C.brand),
              const SizedBox(width: 6),
              Text(
                label,
                style: syne(sz: 10, w: FontWeight.w900, c: color ?? C.brand),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- HELPERS ---

  Widget _stepHeader(String num, String title, {VoidCallback? onBack}) {
    return Row(
      children: [
        if (onBack != null)
          GestureDetector(
            onTap: onBack,
            child: const Icon(
              Icons.arrow_back_ios,
              color: Colors.white,
              size: 18,
            ),
          ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: const BoxDecoration(
            color: Color(0xFF6C63FF),
            shape: BoxShape.circle,
          ),
          child: Text(
            num,
            style: syne(sz: 12, w: FontWeight.w900, c: Colors.white),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 1),
        ),
        const Spacer(),
        if (onBack != null) const SizedBox(width: 24),
      ],
    );
  }

  Widget _summaryCard() {
    final url = _primaryListingImageUrl();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              image: url != null
                  ? DecorationImage(image: NetworkImage(url), fit: BoxFit.cover)
                  : null,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.listing['title'] ?? 'Luxury Shard',
                  style: syne(sz: 14, w: FontWeight.bold, c: Colors.white),
                ),
                Text(
                  'by ${widget.listing['lister_name'] ?? 'Vendor'}',
                  style: dm(sz: 11, c: Colors.white38),
                ),
                const SizedBox(height: 4),
                Text(
                  'SKU: ${widget.listing['sku'] ?? 'SKU-PENDING'}',
                  style: dm(sz: 9, c: Colors.white24),
                ),
                const SizedBox(height: 4),
                Text(
                  ugx((widget.listing['price'] ?? 0).toDouble()),
                  style: syne(sz: 16, w: FontWeight.w900, c: C.brand),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _payOption(String label, String sub, String val, IconData icon) {
    final active = _selectedPaymentMethod == val;
    return GestureDetector(
      onTap: () => setState(() => _selectedPaymentMethod = val),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFF6C63FF).withOpacity(0.15)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? const Color(0xFF6C63FF) : Colors.white10,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: active ? const Color(0xFF6C63FF) : Colors.white38,
                size: 20,
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: syne(sz: 14, w: FontWeight.bold, c: Colors.white),
                ),
                Text(sub, style: dm(sz: 11, c: Colors.white38)),
              ],
            ),
            const Spacer(),
            Icon(
              active ? Icons.radio_button_checked : Icons.radio_button_off,
              color: active ? const Color(0xFF6C63FF) : Colors.white10,
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton(
    String label,
    VoidCallback onTap, {
    bool loading = false,
  }) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF6C63FF),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6C63FF).withOpacity(0.3),
              blurRadius: 15,
            ),
          ],
        ),
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : Text(
                  label.toUpperCase(),
                  style: syne(
                    sz: 14,
                    w: FontWeight.w900,
                    c: Colors.white,
                    ls: 1.5,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _row(String label, String val) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: dm(sz: 13, c: Colors.white38)),
        Text(
          val,
          style: syne(sz: 14, w: FontWeight.w900, c: Colors.white),
        ),
      ],
    );
  }

  Widget _trackingStepper() {
    return Column(
      children: [
        _trackNode('Order Confirmed', 'May 24, 10:15 AM', true),
        _trackLine(true),
        _trackNode('Picked Up by Jumia', 'May 24, 02:30 PM', true),
        _trackLine(true),
        _trackNode('In Transit', 'May 24, 08:45 PM', true, active: true),
        _trackLine(false),
        _trackNode('Out for Delivery', 'May 25, 09:00 AM', false),
        _trackLine(false),
        _trackNode('Delivered', 'May 25, Before 6 PM', false),
      ],
    );
  }

  Widget _trackNode(
    String title,
    String sub,
    bool done, {
    bool active = false,
  }) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: done
                ? Colors.green
                : (active ? const Color(0xFF6C63FF) : Colors.transparent),
            shape: BoxShape.circle,
            border: Border.all(
              color: done
                  ? Colors.green
                  : (active ? const Color(0xFF6C63FF) : Colors.white24),
              width: 2,
            ),
          ),
          child: done
              ? const Icon(Icons.check, color: Colors.white, size: 14)
              : null,
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: syne(
                sz: 13,
                w: FontWeight.bold,
                c: done || active ? Colors.white : Colors.white38,
              ),
            ),
            Text(sub, style: dm(sz: 11, c: Colors.white24)),
          ],
        ),
      ],
    );
  }

  Widget _trackLine(bool done) {
    return Container(
      margin: const EdgeInsets.only(left: 11),
      width: 2,
      height: 30,
      color: done ? Colors.green : Colors.white10,
    );
  }
}
