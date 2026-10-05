import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:convert';
import 'dart:async';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:geolocator/geolocator.dart';
import '../services/logistics_engine.dart';
import '../models/transport_models.dart';
import '../services/wallet_service.dart';
import '../services/commerce_service.dart';

class CheckoutContainer extends StatefulWidget {
  final AppState state;
  final Map<String, dynamic> listing;
  final VoidCallback onDismiss;

  CheckoutContainer({
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
  final CommerceService _commerce = CommerceService();
  Timer? _trackingTimer;
  CommerceOrder? _trackedOrder;
  bool _trackingLoading = false;
  String? _trackingError;
  late final String _checkoutIdempotencyKey;
  final List<String> stages = [
    'confirmed',
    'ready_for_pickup',
    'driver_assigned',
    'picked_up',
    'out_for_delivery',
    'delivered',
    'completed',
  ];

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
    _checkoutIdempotencyKey =
        'checkout-${widget.listing['id']}-${DateTime.now().microsecondsSinceEpoch}';
    _deliveryFare = _calculateDeliveryFare(_selectedTier);
  }

  @override
  void dispose() {
    _trackingTimer?.cancel();
    _addressController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  // Order Details
  final TextEditingController _addressController = TextEditingController(
    text: 'Kampala, Uganda',
  );
  final TextEditingController _contactController = TextEditingController(
    text: '+256 700 123456',
  );
  String? _coordinates;

  void _next() {
    setState(() => _step++);
    if (_step == 5) _startTracking();
  }

  void _back() {
    if (_step == 5) _trackingTimer?.cancel();
    setState(() => _step--);
  }

  void _startTracking() {
    _trackingTimer?.cancel();
    _refreshTracking();
    _trackingTimer = Timer.periodic(
      Duration(seconds: 8),
      (_) => _refreshTracking(silent: true),
    );
  }

  Future<void> _refreshTracking({bool silent = false}) async {
    final orderId = _currentOrderId;
    if (orderId == null || _trackingLoading) return;
    if (!silent && mounted) setState(() => _trackingLoading = true);
    try {
      final order = await _commerce.fetchOrder(orderId);
      if (!mounted) return;
      setState(() {
        _trackedOrder = order;
        _trackingError = null;
      });
    } catch (error) {
      if (mounted && !silent) setState(() => _trackingError = error.toString());
    } finally {
      if (mounted) setState(() => _trackingLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: Color(0xFF0D121B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        border: Border.all(color: C.text.withOpacity(0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 40,
            spreadRadius: 10,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag Handle
              Container(
                width: 40,
                height: 4,
                margin: EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: C.dim,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              Flexible(
                child: AnimatedSwitcher(
                  duration: Duration(milliseconds: 300),
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
      padding: EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PRODUCT DETAILS',
            style: syne(sz: 12, w: FontWeight.w900, c: C.dim, ls: 2),
          ),
          SizedBox(height: 20),

          // Images Grid/Pictures Down
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.isEmpty ? 1 : photos.length,
              separatorBuilder: (_, __) => SizedBox(width: 12),
              itemBuilder: (context, i) {
                final url = photos.isNotEmpty
                    ? photos[i]
                    : _primaryListingImageUrl();
                return Container(
                  width: 120,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: C.dim),
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

          SizedBox(height: 24),
          Text(
            title,
            style: syne(sz: 24, w: FontWeight.w900, c: C.text),
          ),
          SizedBox(height: 8),
          Text(
            widget.listing['description'] ??
                'Exclusive digital asset from Necxa Film Hub.',
            style: dm(sz: 14, c: C.sub, h: 1.5),
          ),

          SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('QUANTITY', style: dm(sz: 10, c: C.dim)),
              Container(
                decoration: BoxDecoration(
                  color: C.text.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: C.dim),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.remove,
                        color: C.sub,
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
                      style: syne(sz: 16, w: FontWeight.bold, c: C.text),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.add,
                        color: C.sub,
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
          SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TOTAL PRICE', style: dm(sz: 10, c: C.dim)),
                  Text(
                    ugx(price.toDouble() * _quantity),
                    style: syne(sz: 20, w: FontWeight.w900, c: C.brand),
                  ),
                  SizedBox(height: 4),
                  Text('SKU: $sku', style: dm(sz: 9, c: C.dim)),
                ],
              ),
              GestureDetector(
                onTap: _next,
                child: Container(
                  padding: EdgeInsets.symmetric(
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
      padding: EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader('3', 'DELIVERY INFO', onBack: _back),
          SizedBox(height: 16),

          // Product Summary Card
          _summaryCard(),

          SizedBox(height: 24),
          Text(
            'DELIVERY ADDRESS',
            style: syne(sz: 11, w: FontWeight.w900, c: C.dim, ls: 1),
          ),
          SizedBox(height: 12),
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
              padding: EdgeInsets.only(top: 8, left: 12),
              child: Text(
                'GPS: $_coordinates',
                style: dm(sz: 10, c: Colors.greenAccent.withOpacity(0.7)),
              ),
            ),

          SizedBox(height: 24),
          Text(
            'CONTACT NUMBER',
            style: syne(sz: 11, w: FontWeight.w900, c: C.dim, ls: 1),
          ),
          SizedBox(height: 12),
          _checkoutInput(
            controller: _contactController,
            hint: 'Phone number for delivery',
            icon: Icons.phone_outlined,
            keyboardType: TextInputType.phone,
          ),

          SizedBox(height: 32),
          _actionButton('Select Delivery Type', () {
            if (_addressController.text.isEmpty ||
                _contactController.text.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
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
      padding: EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader('4', 'DELIVERY SPEED', onBack: _back),

          Text(
            'HOW FAST DO YOU NEED IT?',
            style: syne(sz: 11, w: FontWeight.w900, c: C.dim),
          ),
          SizedBox(height: 12),
          Text(
            'DELIVERY METHOD',
            style: syne(sz: 11, w: FontWeight.w900, c: C.dim),
          ),
          SizedBox(height: 10),
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
          SizedBox(height: 20),
          _deliveryOption(
            'Express Delivery',
            'Within 30-60 mins',
            DeliveryTier.express,
            Icons.bolt_rounded,
            color: Color(0xFF00E5FF),
          ),
          SizedBox(height: 12),
          _deliveryOption(
            'Standard Delivery',
            'Same day (3-6 hours)',
            DeliveryTier.standard,
            Icons.local_shipping_outlined,
          ),
          SizedBox(height: 12),
          _deliveryOption(
            'Batch Delivery',
            'Next available route (Best Value)',
            DeliveryTier.batch,
            Icons.layers_outlined,
            color: Colors.greenAccent,
          ),

          SizedBox(height: 32),
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
        duration: Duration(milliseconds: 200),
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: active
              ? (color ?? C.brand).withOpacity(0.1)
              : C.text.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active
                ? (color ?? C.brand).withOpacity(0.5)
                : C.dim,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: active ? (color ?? C.brand) : C.dim,
              size: 24,
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: syne(
                      sz: 14,
                      w: FontWeight.bold,
                      c: active ? C.text : C.sub,
                    ),
                  ),
                  Text(subtitle, style: dm(sz: 11, c: C.dim)),
                ],
              ),
            ),
            Text(
              ugx(fare),
              style: syne(
                sz: 14,
                w: FontWeight.w900,
                c: active ? (color ?? C.brand) : C.dim,
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
        color: C.text.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.dim),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: dm(sz: 14, c: C.text),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: dm(sz: 14, c: C.dim),
          prefixIcon: Icon(icon, color: C.brand, size: 20),
          suffixIcon: suffix,
          border: InputBorder.none,
          contentPadding: EdgeInsets.all(16),
        ),
      ),
    );
  }

  // --- STEP 2: PAYMENT METHOD ---
  Widget _buildPayment() {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader('4', 'PAYMENT METHOD', onBack: _back),

          Text(
            'PAY WITH NECXA',
            style: syne(sz: 11, w: FontWeight.w900, c: C.dim),
          ),
          SizedBox(height: 12),
          _payOption(
            'Necxa Balance',
            'UGX ${kNum(widget.state.cashBalance.toInt())}',
            'balance',
            Icons.account_balance_wallet_outlined,
          ),

          SizedBox(height: 24),
          Text(
            'OTHER METHODS',
            style: syne(sz: 11, w: FontWeight.w900, c: C.dim),
          ),
          SizedBox(height: 12),
          _payOption(
            'Mobile Money',
            'MTN / Airtel',
            'momo',
            Icons.phone_android_outlined,
          ),
          SizedBox(height: 12),
          _payOption(
            'Visa / Mastercard',
            'Debit or Credit Card',
            'card',
            Icons.credit_card_outlined,
          ),
          SizedBox(height: 12),
          _payOption(
            'USDT (Crypto)',
            'Pay with USDT',
            'crypto',
            Icons.currency_bitcoin_outlined,
          ),

          SizedBox(height: 32),
          _actionButton(
            'Pay ${ugx(((widget.listing['price'] ?? 0).toDouble() * _quantity) + _deliveryFare)}',
            () async {
              setState(() => _loading = true);
              try {
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
                    deliveryFeeUgx: _deliveryFare.toInt(),
                    idempotencyKey: '$_checkoutIdempotencyKey-wallet',
                  );

                  if (res.isSuccess && res.orderId != null) {
                    setState(() {
                      _currentOrderId = res.orderId;
                      _deliveryFare = res.deliveryFeeUgx ?? _deliveryFare;
                      _loading = false;
                    });
                    await widget.state.syncVault();
                    _next();
                  } else if (res.needsTopUp) {
                    throw Exception(
                      'Insufficient balance. Please deposit funds first.',
                    );
                  } else {
                    throw Exception(res.message);
                  }
                } else if (_selectedPaymentMethod == 'momo' ||
                    _selectedPaymentMethod == 'card') {
                  final coordinates = _dropoffCoordinates;
                  if (coordinates == null) {
                    throw Exception(
                      'Pin your delivery location before paying.',
                    );
                  }

                  // Initiate Pesapal order via finance-engine
                  final res = await WalletService().initiateShopPayment(
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
                    deliveryFeeUgx: _deliveryFare.toInt(),
                    idempotencyKey: '$_checkoutIdempotencyKey-pesapal',
                  );

                  if (res.isSuccess && res.redirectUrl != null) {
                    if (await canLaunchUrlString(res.redirectUrl!)) {
                      await launchUrlString(
                        res.redirectUrl!,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                    setState(() {
                      _currentOrderId = res.orderId;
                      _loading = false;
                    });
                    _next(); // Move to success/tracking screen immediately

                    // Poll for confirmation in background
                    if (res.paymentId != null) {
                      WalletService().pollShopPaymentStatus(res.paymentId!).then((
                        paid,
                      ) {
                        if (paid && mounted) {
                          widget.state.syncVault();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '? Payment confirmed! Your order is being processed.',
                              ),
                            ),
                          );
                        }
                      });
                    }
                  } else if (res.isSuccess && res.orderId != null) {
                    setState(() {
                      _currentOrderId = res.orderId;
                      _loading = false;
                    });
                    _next();
                  } else if (res.needsTopUp) {
                    throw Exception(
                      'Insufficient balance. Please top up your wallet first.',
                    );
                  } else {
                    throw Exception(res.message);
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
      padding: EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _stepHeader('5', 'ORDER CONFIRMATION'),

          SizedBox(height: 20),
          Icon(
            Icons.check_circle_outline,
            color: Colors.greenAccent,
            size: 80,
          ),
          SizedBox(height: 24),
          Text(
            'Order Placed Successfully!',
            style: syne(sz: 20, w: FontWeight.w900, c: C.text),
          ),
          SizedBox(height: 12),
          Text(
            'Your order has been received and is being processed.',
            textAlign: TextAlign.center,
            style: dm(sz: 14, c: C.sub),
          ),

          SizedBox(height: 32),
          Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: C.text.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                _row(
                  'Product Price (x$_quantity)',
                  ugx((widget.listing['price'] ?? 0).toDouble() * _quantity),
                ),
                SizedBox(height: 8),
                _row(
                  'Delivery (${_selectedTier.name.toUpperCase()})',
                  ugx(_deliveryFare),
                ),
                Divider(color: C.dim, height: 24),
                _row(
                  'Total Paid',
                  ugx(
                    ((widget.listing['price'] ?? 0).toDouble() * _quantity) +
                        _deliveryFare,
                  ),
                ),
                Divider(color: C.dim, height: 24),
                _row('Payment Method', _selectedPaymentMethod.toUpperCase()),
              ],
            ),
          ),

          SizedBox(height: 32),
          _actionButton('Track Order', _next),
        ],
      ),
    );
  }

  // --- STEP 4: TRACKING ---
  Widget _buildTracking() {
    final order = _trackedOrder;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader('7', 'TRACK ORDER', onBack: _back),
          Text(
            order?.orderNumber ?? _currentOrderId ?? 'ORD-PENDING',
            style: syne(sz: 16, w: FontWeight.w900, c: C.text),
          ),
          Text(
            'Protected delivery and escrow tracking',
            style: dm(sz: 11, c: C.dim),
          ),
          SizedBox(height: 24),
          if (_trackingLoading && order == null)
            Center(child: CircularProgressIndicator(color: C.brand))
          else if (_trackingError != null && order == null)
            Column(
              children: [
                Text(_trackingError!, style: dm(c: Colors.redAccent)),
                TextButton(
                  onPressed: _refreshTracking,
                  child: Text('Retry'),
                ),
              ],
            )
          else if (order == null)
            Text(
              'Waiting for order confirmation...',
              style: dm(c: C.sub),
            )
          else
            _buildCommerceTracking(order),
          SizedBox(height: 40),
          _actionButton('Done', widget.onDismiss),
        ],
      ),
    );
  }

  Widget _buildCommerceTracking(CommerceOrder order) {
    final currentIndex = stages.indexOf(order.status);
    final driverId = order.delivery?['driver_id']?.toString();
    final driverName = order.driver == null
        ? null
        : order.participantName('driver');
    final driverPhone = order.driver?['phone']?.toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (driverName != null) ...[
          _buildDriverHud(driverName, driverPhone, driverId),
          SizedBox(height: 24),
        ],
        if (order.deliveryCode != null &&
            [
              'driver_assigned',
              'picked_up',
              'out_for_delivery',
            ].contains(order.status)) ...[
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: C.brand.withOpacity(.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: C.brand.withOpacity(.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DELIVERY CODE',
                  style: syne(sz: 10, w: FontWeight.w800, c: C.brand, ls: 1),
                ),
                SizedBox(height: 4),
                Text(
                  order.deliveryCode!,
                  style: syne(sz: 26, w: FontWeight.w900, c: C.text),
                ),
                Text(
                  'Share it only when the package reaches you.',
                  style: dm(sz: 11, c: C.dim),
                ),
              ],
            ),
          ),
          SizedBox(height: 24),
        ],
        for (var index = 0; index < stages.length; index++) ...[
          _trackNode(
            _commerceStatusLabel(stages[index]),
            _commerceStatusMessage(stages[index]),
            index <= currentIndex,
            active: index == currentIndex,
          ),
          if (index < stages.length - 1) _trackLine(index < currentIndex),
        ],
        if (order.status == 'delivered') ...[
          SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _buyerOrderAction(order, 'buyer_confirm'),
              icon: Icon(Icons.verified_outlined),
              label: Text('Confirm package received'),
            ),
          ),
        ],
        if (![
          'completed',
          'cancelled',
          'refunded',
          'disputed',
        ].contains(order.status)) ...[
          SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: () => _buyerOrderAction(order, 'open_dispute'),
              icon: Icon(Icons.report_problem_outlined),
              label: Text('Report an order problem'),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _buyerOrderAction(CommerceOrder order, String transition) async {
    setState(() => _trackingLoading = true);
    try {
      await _commerce.transitionOrder(order.id, transition);
      await _refreshTracking();
      if (transition == 'buyer_confirm') await widget.state.syncVault();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString()),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _trackingLoading = false);
    }
  }

  String _commerceStatusLabel(String status) => status
      .split('_')
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');

  String _commerceStatusMessage(String status) => switch (status) {
    'confirmed' => 'Payment is protected in escrow.',
    'ready_for_pickup' => 'The seller has packed your order.',
    'driver_assigned' => 'A verified courier accepted the delivery.',
    'picked_up' => 'The pickup code was verified.',
    'out_for_delivery' => 'Your package is on the way.',
    'delivered' => 'The delivery code was verified.',
    'completed' => 'Escrow was released to the seller and courier.',
    _ => 'Order update received.',
  };

  Widget _buildDriverHud(String name, String? phone, String? driverId) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.text.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.brand.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: C.brand.withOpacity(0.2),
                child: Icon(Icons.delivery_dining, color: C.brand),
              ),
              SizedBox(width: 12),
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
                      style: syne(sz: 16, w: FontWeight.w900, c: C.text),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          Row(
            children: [
              _hudBtn(Icons.phone, 'CALL', () async {
                final number = phone?.trim();
                if (number == null || number.isEmpty) return;
                await launchUrlString('tel:${Uri.encodeComponent(number)}');
              }),
              SizedBox(width: 8),
              _hudBtn(Icons.chat_bubble_outline, 'CHAT', () {
                if (driverId != null) {
                  widget.state.openCreatorChat(
                    driverId,
                    name,
                    null,
                    initialContextText:
                        'Regarding commerce order ${_trackedOrder?.orderNumber ?? ''}',
                    context: 'commerce_order',
                  );
                  widget.onDismiss(); // Close checkout to enter chat
                }
              }),
              SizedBox(width: 8),
              _hudBtn(Icons.mic_none, 'VOICE', () {
                if (driverId != null) {
                  widget.state.openCreatorChat(
                    driverId,
                    name,
                    null,
                    initialContextText:
                        'Voice update for commerce order ${_trackedOrder?.orderNumber ?? ''}',
                    context: 'commerce_order',
                  );
                  widget.onDismiss();
                }
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
          padding: EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: (color ?? C.brand).withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: (color ?? C.brand).withOpacity(0.2)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color ?? C.brand),
              SizedBox(width: 6),
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
            child: Icon(
              Icons.arrow_back_ios,
              color: C.text,
              size: 18,
            ),
          ),
        Spacer(),
        Container(
          padding: EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Color(0xFF6C63FF),
            shape: BoxShape.circle,
          ),
          child: Text(
            num,
            style: syne(sz: 12, w: FontWeight.w900, c: C.text),
          ),
        ),
        SizedBox(width: 12),
        Text(
          title,
          style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 1),
        ),
        Spacer(),
        if (onBack != null) SizedBox(width: 24),
      ],
    );
  }

  Widget _summaryCard() {
    final url = _primaryListingImageUrl();
    return Container(
      margin: EdgeInsets.symmetric(vertical: 24),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.text.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.dim),
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
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.listing['title'] ?? 'Luxury Shard',
                  style: syne(sz: 14, w: FontWeight.bold, c: C.text),
                ),
                Text(
                  'by ${widget.listing['lister_name'] ?? 'Vendor'}',
                  style: dm(sz: 11, c: C.dim),
                ),
                SizedBox(height: 4),
                Text(
                  'SKU: ${widget.listing['sku'] ?? 'SKU-PENDING'}',
                  style: dm(sz: 9, c: C.dim),
                ),
                SizedBox(height: 4),
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
        duration: Duration(milliseconds: 200),
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: active
              ? Color(0xFF6C63FF).withOpacity(0.15)
              : C.text.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? Color(0xFF6C63FF) : C.dim,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: C.text.withOpacity(0.05),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: active ? Color(0xFF6C63FF) : C.dim,
                size: 20,
              ),
            ),
            SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: syne(sz: 14, w: FontWeight.bold, c: C.text),
                ),
                Text(sub, style: dm(sz: 11, c: C.dim)),
              ],
            ),
            Spacer(),
            Icon(
              active ? Icons.radio_button_checked : Icons.radio_button_off,
              color: active ? Color(0xFF6C63FF) : C.dim,
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
        padding: EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: Color(0xFF6C63FF),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Color(0xFF6C63FF).withOpacity(0.3),
              blurRadius: 15,
            ),
          ],
        ),
        child: Center(
          child: loading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: C.text,
                    strokeWidth: 2,
                  ),
                )
              : Text(
                  label.toUpperCase(),
                  style: syne(
                    sz: 14,
                    w: FontWeight.w900,
                    c: C.text,
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
        Text(label, style: dm(sz: 13, c: C.dim)),
        Text(
          val,
          style: syne(sz: 14, w: FontWeight.w900, c: C.text),
        ),
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
                : (active ? Color(0xFF6C63FF) : Colors.transparent),
            shape: BoxShape.circle,
            border: Border.all(
              color: done
                  ? Colors.green
                  : (active ? Color(0xFF6C63FF) : C.dim),
              width: 2,
            ),
          ),
          child: done
              ? Icon(Icons.check, color: C.text, size: 14)
              : null,
        ),
        SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: syne(
                sz: 13,
                w: FontWeight.bold,
                c: done || active ? C.text : C.dim,
              ),
            ),
            Text(sub, style: dm(sz: 11, c: C.dim)),
          ],
        ),
      ],
    );
  }

  Widget _trackLine(bool done) {
    return Container(
      margin: EdgeInsets.only(left: 11),
      width: 2,
      height: 30,
      color: done ? Colors.green : C.dim,
    );
  }
}



