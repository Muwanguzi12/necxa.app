import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../services/commerce_service.dart';
import '../services/local_db_service.dart';
import '../theme.dart';

class VendorDashboardScreen extends StatefulWidget {
  const VendorDashboardScreen({super.key, required this.state});

  final AppState state;

  @override
  State<VendorDashboardScreen> createState() => _VendorDashboardScreenState();
}

class _VendorDashboardScreenState extends State<VendorDashboardScreen>
    with SingleTickerProviderStateMixin {
  final CommerceService _commerce = CommerceService();
  final LocalDbService _localDb = LocalDbService();
  late final TabController _tabs;
  CommerceDashboardData? _dashboard;
  List<CommerceOrder> _orders = const [];
  List<Map<String, dynamic>> _reviews = const [];
  bool _loading = true;
  bool _ordersRefreshing = false;
  bool _reviewsRefreshing = false;
  bool _ordersSyncedThisSession = false;
  bool _reviewsSyncedThisSession = false;
  String? _error;
  String? _workingId;
  bool _autoLoyaltyVoucherEnabled = true;
  final String _activeLoyaltyCode = 'VIPREPEAT10';

  // ── Inventory Filters & Search State ──
  final TextEditingController _inventorySearchController = TextEditingController();
  String _inventorySearchQuery = '';
  String _selectedInventoryCategory = 'All';

  @override
  void initState() {
    super.initState();
    _inventorySearchController.addListener(() {
      final q = _inventorySearchController.text.trim().toLowerCase();
      if (q != _inventorySearchQuery) {
        setState(() => _inventorySearchQuery = q);
      }
    });
    _tabs = TabController(length: 6, vsync: this);
    _tabs.addListener(_onTabChanged);
    _hydrateThenRefresh();
  }

  @override
  void dispose() {
    _inventorySearchController.dispose();
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  String get _vendorId => widget.state.user?.id ?? '';

  void _onTabChanged() {
    if (_tabs.index == 1 && !_ordersSyncedThisSession) {
      _refreshOrders();
    } else if (_tabs.index == 4 && !_reviewsSyncedThisSession) {
      _refreshReviews();
    }
  }

  Future<void> _hydrateThenRefresh() async {
    final vendorId = _vendorId;
    if (vendorId.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Sign in again to open your vendor dashboard.';
        });
      }
      return;
    }

    try {
      final results = await Future.wait([
        _localDb.getCachedVendorDashboard(vendorId),
        _localDb.getCachedVendorOrders(vendorId),
        _localDb.getCachedVendorReviews(vendorId),
      ]);
      if (!mounted) return;
      setState(() {
        final cachedDashboard = results[0] as Map<String, dynamic>?;
        if (cachedDashboard != null) {
          _dashboard = CommerceDashboardData.fromJson(cachedDashboard);
        }
        _orders = (results[1] as List<Map<String, dynamic>>)
            .map(CommerceOrder.fromJson)
            .toList();
        _reviews = results[2] as List<Map<String, dynamic>>;
        _loading = false;
      });
    } catch (_) {
      // A damaged local row must never prevent a clean network recovery.
    }
    await _refreshDashboard();
  }

  Future<void> _refreshDashboard() async {
    if (_vendorId.isEmpty) return;
    final startedAt = DateTime.now().toUtc().toIso8601String();
    if (mounted) setState(() => _loading = _dashboard == null);
    try {
      final updatedSince = _dashboard == null
          ? null
          : await _localDb.getSyncCursor('vendor:$_vendorId:dashboard');
      final incoming = await _commerce.fetchVendorDashboard(
        updatedSince: updatedSince,
      );
      final dashboard = _dashboard?.mergeDelta(incoming) ?? incoming;
      await Future.wait([
        _localDb.saveVendorDashboard(_vendorId, dashboard.toJson()),
        _localDb.saveVendorOrders(
          _vendorId,
          dashboard.recentOrders.map((order) => order.toJson()).toList(),
        ),
        _localDb.setSyncCursor(
          'vendor:$_vendorId:dashboard',
          incoming.syncCursor ?? startedAt,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _dashboard = dashboard;
        _orders = _mergeOrders(_orders, dashboard.recentOrders);
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      if (_dashboard == null) {
        setState(() => _error = error.toString());
      } else {
        _showError(error);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshOrders() async {
    if (_vendorId.isEmpty || _ordersRefreshing) return;
    _ordersRefreshing = true;
    final startedAt = DateTime.now().toUtc().toIso8601String();
    try {
      final updatedSince = await _localDb.getSyncCursor(
        'vendor:$_vendorId:orders',
      );
      final page = await _commerce.fetchOrders(
        role: 'seller',
        updatedSince: updatedSince,
        limit: 30,
      );
      final merged = _mergeOrders(_orders, page.orders);
      await Future.wait([
        _localDb.saveVendorOrders(
          _vendorId,
          page.orders.map((order) => order.toJson()).toList(),
        ),
        _localDb.setSyncCursor(
          'vendor:$_vendorId:orders',
          page.syncCursor ?? startedAt,
        ),
      ]);
      if (mounted) setState(() => _orders = merged);
    } catch (error) {
      _showError(error);
    } finally {
      _ordersRefreshing = false;
      _ordersSyncedThisSession = true;
    }
  }

  Future<void> _refreshReviews() async {
    if (_vendorId.isEmpty || _reviewsRefreshing) return;
    _reviewsRefreshing = true;
    final startedAt = DateTime.now().toUtc().toIso8601String();
    try {
      final updatedSince = await _localDb.getSyncCursor(
        'vendor:$_vendorId:reviews',
      );
      final response = await _commerce.fetchVendorReviews(
        updatedSince: updatedSince,
        limit: 30,
      );
      final incoming = List<Map<String, dynamic>>.from(
        response['reviews'] ?? const [],
      );
      final merged = _mergeReviews(_reviews, incoming);
      await Future.wait([
        _localDb.saveVendorReviews(_vendorId, incoming),
        _localDb.setSyncCursor(
          'vendor:$_vendorId:reviews',
          response['syncCursor']?.toString() ?? startedAt,
        ),
      ]);
      if (mounted) setState(() => _reviews = merged);
    } catch (error) {
      _showError(error);
    } finally {
      _reviewsRefreshing = false;
      _reviewsSyncedThisSession = true;
    }
  }

  Future<void> _refreshCurrentTab() async {
    switch (_tabs.index) {
      case 1:
        return _refreshOrders();
      case 4:
        return _refreshReviews();
      default:
        return _refreshDashboard();
    }
  }

  List<CommerceOrder> _mergeOrders(
    List<CommerceOrder> cached,
    List<CommerceOrder> updates,
  ) {
    final byId = {for (final order in cached) order.id: order};
    for (final order in updates) {
      byId[order.id] = order;
    }
    final merged = byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return merged.take(100).toList();
  }

  List<Map<String, dynamic>> _mergeReviews(
    List<Map<String, dynamic>> cached,
    List<Map<String, dynamic>> updates,
  ) {
    final byId = <String, Map<String, dynamic>>{};
    for (final review in [...cached, ...updates]) {
      final id = review['id']?.toString();
      if (id != null && id.isNotEmpty) byId[id] = review;
    }
    final merged = byId.values.toList()
      ..sort((a, b) => _dateOf(b).compareTo(_dateOf(a)));
    return merged.take(60).toList();
  }

  DateTime _dateOf(Map<String, dynamic> value) =>
      DateTime.tryParse(
        value['updated_at']?.toString() ??
            value['created_at']?.toString() ??
            '',
      ) ??
      DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.bg,
        foregroundColor: C.text,
        title: Text(
          'Vendor Dashboard',
          style: syne(sz: 19, w: FontWeight.w800),
        ),
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => widget.state.go('profile'),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refreshCurrentTab,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: C.text,
          unselectedLabelColor: C.sub,
          indicatorColor: C.brandDk,
          dividerColor: C.border,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Orders'),
            Tab(text: 'Inventory'),
            Tab(text: 'Earnings'),
            Tab(text: 'Reviews'),
            Tab(text: 'Pro Retention'),
          ],
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading && _dashboard == null) {
      return const Center(child: CircularProgressIndicator(color: C.brandDk));
    }
    if (_error != null && _dashboard == null) {
      return _MessageState(
        icon: Icons.cloud_off_outlined,
        title: 'Dashboard unavailable',
        message: _error!,
        actionLabel: 'Retry',
        onAction: _refreshDashboard,
      );
    }

    return TabBarView(
      controller: _tabs,
      children: [
        _refreshable(_overview()),
        _refreshable(_ordersList()),
        _refreshable(_inventory()),
        _refreshable(_earnings()),
        _refreshable(_reviewsList()),
        _refreshable(_retention()),
      ],
    );
  }

  Widget _refreshable(Widget child) => RefreshIndicator(
    color: C.brandDk,
    onRefresh: _refreshCurrentTab,
    child: child,
  );

  Widget _overview() {
    final dashboard = _dashboard!;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      children: [
        Text('Store pulse', style: syne(sz: 15, w: FontWeight.w800)),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.7,
          children: [
            _MetricPanel(
              label: 'Open orders',
              value: '${dashboard.openOrders}',
              icon: Icons.receipt_long_outlined,
              color: C.blue,
            ),
            _MetricPanel(
              label: 'Active listings',
              value: '${dashboard.activeListings}',
              icon: Icons.storefront_outlined,
              color: C.brandDk,
            ),
            _MetricPanel(
              label: 'Held in escrow',
              value: _money(dashboard.heldEarningsUgx),
              icon: Icons.lock_clock_outlined,
              color: C.gold2,
            ),
            _MetricPanel(
              label: 'Released',
              value: _money(dashboard.releasedEarningsUgx),
              icon: Icons.account_balance_wallet_outlined,
              color: C.green,
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                'Recent orders',
                style: syne(sz: 15, w: FontWeight.w800),
              ),
            ),
            TextButton(
              onPressed: () => _tabs.animateTo(1),
              child: const Text('View all'),
            ),
          ],
        ),
        if (_orders.isEmpty)
          const _InlineEmpty(
            icon: Icons.inventory_2_outlined,
            label: 'No orders yet',
          )
        else
          ..._orders.take(5).map(_orderTile),
      ],
    );
  }

  Widget _ordersList() {
    if (_orders.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 140),
          _InlineEmpty(
            icon: Icons.receipt_long_outlined,
            label: 'Orders will appear here',
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      itemCount: _orders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, index) => _orderTile(_orders[index]),
    );
  }

  Widget _orderTile(CommerceOrder order) {
    final waiting = _workingId == order.id;
    return Material(
      color: C.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: C.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: waiting ? null : () => _showOrder(order),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _ProductImage(url: order.productMediaUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      order.productTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: syne(sz: 14, w: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${order.orderNumber}  |  ${_money(order.totalUgx)}',
                      style: dm(sz: 12, c: C.sub),
                    ),
                    const SizedBox(height: 8),
                    _StatusLabel(status: order.status),
                  ],
                ),
              ),
              if (waiting)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.chevron_right_rounded, color: C.sub),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inventory() {
    final allListings = _dashboard!.listings
        .where(CommerceDashboardData.isProductListing)
        .toList();

    // ── Metric calculations ───────────────────────────────────────────────
    final totalProducts = allListings.length;
    final totalStock = allListings.fold<int>(
      0,
      (sum, l) => sum + ((l['stock_count'] as num?)?.round() ?? 0),
    );
    final lowStock = allListings.where((l) {
      final s = (l['stock_count'] as num?)?.round() ?? 0;
      return s > 0 && s <= 5 && l['status'] == 'active';
    }).length;
    final outOfStock = allListings.where((l) {
      final s = (l['stock_count'] as num?)?.round() ?? 0;
      return s == 0 || l['status'] != 'active';
    }).length;

    final totalStockValue = allListings.fold<int>(
      0,
      (sum, l) {
        final p = (l['price_ugx'] as num?)?.round() ??
            (l['price'] as num?)?.round() ??
            0;
        final s = (l['stock_count'] as num?)?.round() ?? 0;
        return sum + (p * s);
      },
    );

    // ── Search & Category Filtering ───────────────────────────────────────
    final filtered = allListings.where((l) {
      final title = (l['title'] ?? '').toString().toLowerCase();
      final sku = (l['sku'] ?? 'SKU-${l['id']?.toString().substring(0, 4) ?? '001'}')
          .toString()
          .toLowerCase();
      final cat = (l['category'] ?? '').toString().toLowerCase();

      final matchesSearch = _inventorySearchQuery.isEmpty ||
          title.contains(_inventorySearchQuery) ||
          sku.contains(_inventorySearchQuery);

      final matchesCategory = _selectedInventoryCategory == 'All' ||
          cat.contains(_selectedInventoryCategory.toLowerCase());

      return matchesSearch && matchesCategory;
    }).toList();

    final categories = ['All', 'Electronics', 'Fashion', 'Home & Living', 'Beauty'];

    return Stack(
      children: [
        ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            // ── 1. Inventory Overview Card ────────────────────────────────
            _buildInventoryOverviewCard(
              totalProducts: totalProducts,
              totalStock: totalStock,
              lowStock: lowStock,
              outOfStock: outOfStock,
            ),
            const SizedBox(height: 16),

            // ── 2. Search & Category Chips ────────────────────────────────
            _buildSearchAndCategoryBar(categories, totalProducts),
            const SizedBox(height: 16),

            // ── 3. Product List / Empty State ─────────────────────────────
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.inventory_2_outlined, color: C.dim, size: 48),
                      const SizedBox(height: 12),
                      Text('No matching products found', style: syne(sz: 14, c: C.dim)),
                    ],
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, index) => _buildProductInventoryCard(filtered[index]),
              ),

            const SizedBox(height: 16),

            // ── 4. Stock Value Footer ─────────────────────────────────────
            _buildStockValueFooter(totalStockValue),
          ],
        ),

        // ── 5. Bottom Sticky Bar: Sole "+ Add Product" Button ───────────
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: _buildBottomActionBar(),
        ),
      ],
    );
  }

  // ── Overview Card ──────────────────────────────────────────────────────────
  Widget _buildInventoryOverviewCard({
    required int totalProducts,
    required int totalStock,
    required int lowStock,
    required int outOfStock,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D182E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1E3A6E), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0077FE).withOpacity(0.12),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00E5FF), Color(0xFF0066FF)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.inventory_2, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Inventory Overview',
                      style: syne(sz: 15, w: FontWeight.w800, c: Colors.white),
                    ),
                    Text(
                      'Your stock at a glance',
                      style: dm(sz: 11, c: Colors.white60),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withOpacity(0.12)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Today', style: dm(sz: 11, c: Colors.white70)),
                    const SizedBox(width: 4),
                    const Icon(Icons.keyboard_arrow_down, size: 14, color: Colors.white70),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 4 Metric Tiles Row
          Row(
            children: [
              Expanded(
                child: _metricTile(
                  icon: Icons.inventory_2_outlined,
                  value: '$totalProducts',
                  label: 'Total Products',
                  color: const Color(0xFF00E5FF),
                  bgColor: const Color(0xFF0A2B4C),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _metricTile(
                  icon: Icons.all_inbox_rounded,
                  value: _money(totalStock),
                  label: 'Total Stock',
                  color: const Color(0xFF00E676),
                  bgColor: const Color(0xFF0A3A2C),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _metricTile(
                  icon: Icons.warning_amber_rounded,
                  value: '$lowStock',
                  label: 'Low Stock',
                  color: const Color(0xFFFFB300),
                  bgColor: const Color(0xFF3B2E0A),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _metricTile(
                  icon: Icons.block_rounded,
                  value: '$outOfStock',
                  label: 'Out of Stock',
                  color: const Color(0xFFFF5252),
                  bgColor: const Color(0xFF3B0F14),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metricTile({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
    required Color bgColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      decoration: BoxDecoration(
        color: bgColor.withOpacity(0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 4),
          Text(
            value,
            style: syne(sz: 14, w: FontWeight.w900, c: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: dm(sz: 9, c: Colors.white70),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ── Search & Category Filter ───────────────────────────────────────────────
  Widget _buildSearchAndCategoryBar(List<String> categories, int total) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search Bar
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF0E1424),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF1E283F)),
          ),
          child: Row(
            children: [
              const Icon(Icons.search_rounded, color: Colors.white38, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _inventorySearchController,
                  style: dm(sz: 13, c: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search products...',
                    hintStyle: dm(sz: 13, c: Colors.white38),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (_inventorySearchQuery.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    _inventorySearchController.clear();
                    setState(() => _inventorySearchQuery = '');
                  },
                  child: const Icon(Icons.close_rounded, color: Colors.white54, size: 18),
                )
              else
                const Icon(Icons.tune_rounded, color: Colors.white38, size: 18),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Horizontal Category Chips
        SizedBox(
          height: 32,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: categories.length + 1,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              if (i == categories.length) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E1424),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF1E283F)),
                  ),
                  child: Row(
                    children: [
                      Text('More', style: dm(sz: 11, c: Colors.white70)),
                      const SizedBox(width: 4),
                      const Icon(Icons.keyboard_arrow_down, size: 14, color: Colors.white70),
                    ],
                  ),
                );
              }

              final cat = categories[i];
              final isSelected = _selectedInventoryCategory == cat;
              final label = cat == 'All' ? 'All ($total)' : cat;

              return GestureDetector(
                onTap: () => setState(() => _selectedInventoryCategory = cat),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF0E1424),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF1E283F),
                    ),
                  ),
                  child: Text(
                    label,
                    style: dm(
                      sz: 11,
                      c: isSelected ? Colors.black : Colors.white70,
                      w: isSelected ? FontWeight.w800 : FontWeight.w500,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Product Inventory Card (Matching Screenshot) ───────────────────────────
  Widget _buildProductInventoryCard(Map<String, dynamic> listing) {
    final id = listing['id']?.toString() ?? '';
    final title = listing['title']?.toString() ?? 'Product';
    final sku = listing['sku']?.toString() ??
        'SKU: ${id.length >= 6 ? id.substring(0, 6).toUpperCase() : 'PRD-001'}';
    final price = (listing['price_ugx'] ?? listing['price'] as num?)?.round() ?? 0;
    final stock = (listing['stock_count'] as num?)?.round() ?? 0;
    final status = listing['status']?.toString() ?? 'active';
    final isActive = status == 'active';
    final mediaUrl = listing['media_url']?.toString();
    final working = _workingId == id;

    final isOut = stock == 0 || !isActive;
    final isLow = !isOut && stock <= 5;

    final statusBg = isOut
        ? const Color(0xFF3B0F14)
        : isLow
            ? const Color(0xFF3B2E0A)
            : const Color(0xFF0A3A2C);
    final statusColor = isOut
        ? const Color(0xFFFF5252)
        : isLow
            ? const Color(0xFFFFB300)
            : const Color(0xFF00E676);
    final statusIcon = isOut
        ? Icons.cancel_outlined
        : isLow
            ? Icons.warning_amber_rounded
            : Icons.check_circle_outline_rounded;
    final statusText = isOut
        ? 'Out of Stock'
        : isLow
            ? 'Low Stock'
            : 'In Stock';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0B101D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF172238)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Square Thumbnail ──
          Container(
            width: 72,
            height: 72,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFF070B14),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.06)),
            ),
            child: mediaUrl != null && mediaUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: mediaUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00E5FF)),
                      ),
                    ),
                    errorWidget: (_, __, ___) => const Icon(
                      Icons.shopping_bag_outlined,
                      color: Colors.white24,
                      size: 28,
                    ),
                  )
                : const Icon(
                    Icons.shopping_bag_outlined,
                    color: Colors.white24,
                    size: 28,
                  ),
          ),
          const SizedBox(width: 12),

          // ── Details (Title, SKU, Price, Status Badge) ──
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: syne(sz: 14, w: FontWeight.w800, c: Colors.white),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  sku,
                  style: dm(sz: 10, c: Colors.white38),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  'UGX ${_money(price)}',
                  style: syne(sz: 13, w: FontWeight.w900, c: Colors.white),
                ),
                const SizedBox(height: 6),

                // In Stock / Low Stock badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: statusColor.withOpacity(0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, color: statusColor, size: 10),
                      const SizedBox(width: 4),
                      Text(
                        statusText,
                        style: dm(sz: 9, c: statusColor, w: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // ── Quantity & Stepper + Options Menu ──
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 3-dots Menu
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                iconSize: 18,
                icon: const Icon(Icons.more_vert, color: Colors.white38),
                color: const Color(0xFF131A2D),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onSelected: (action) {
                  if (action == 'delete') {
                    _confirmDelete(id, title);
                  } else if (action == 'toggle') {
                    _toggleStatus(id, isActive);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'toggle',
                    child: Text(
                      isActive ? 'Mark Inactive' : 'Mark Active',
                      style: dm(sz: 12, c: Colors.white),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Delete Product',
                      style: dm(sz: 12, c: Colors.redAccent),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),

              Text('Quantity', style: dm(sz: 9, c: Colors.white38)),
              const SizedBox(height: 2),
              Text(
                '$stock',
                style: syne(sz: 15, w: FontWeight.w900, c: Colors.white),
              ),
              const SizedBox(height: 6),

              // Stepper: [-]  [+]
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: (working || stock == 0) ? null : () => _setStock(id, stock - 1),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0xFF131A2D),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white.withOpacity(0.08)),
                      ),
                      child: Icon(
                        Icons.remove,
                        size: 14,
                        color: (working || stock == 0) ? Colors.white24 : Colors.white70,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: working ? null : () => _setStock(id, stock + 1),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E5FF),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.add,
                        size: 14,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Stock Value Footer ─────────────────────────────────────────────────────
  Widget _buildStockValueFooter(int totalStockValue) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1426),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E283F)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF00E5FF).withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.bar_chart_rounded, color: Color(0xFF00E5FF), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Stock Value', style: dm(sz: 10, c: Colors.white54)),
                const SizedBox(height: 2),
                Text(
                  'UGX ${_money(totalStockValue)}',
                  style: syne(sz: 14, w: FontWeight.w900, c: const Color(0xFF00E5FF)),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('View Report', style: dm(sz: 11, c: const Color(0xFF00E5FF), w: FontWeight.bold)),
              const SizedBox(width: 2),
              const Icon(Icons.chevron_right, size: 16, color: Color(0xFF00E5FF)),
            ],
          ),
        ],
      ),
    );
  }

  // ── Sole Bottom Action Bar: + Add Product ──────────────────────────────────
  Widget _buildBottomActionBar() {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withOpacity(0.25),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ElevatedButton.icon(
        icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.black, size: 20),
        label: Text(
          'Add Product',
          style: syne(sz: 14, w: FontWeight.w900, ls: 0.5, c: Colors.black),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00E5FF),
          foregroundColor: Colors.black,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
          elevation: 0,
        ),
        onPressed: () {
          // Links directly to the Sales objective in the upload screen
          widget.state.go('upload', extra: 'sales');
        },
      ),
    );
  }


  Widget _earnings() {
    final dashboard = _dashboard!;
    final released = _orders
        .expand((order) => order.settlements)
        .where((settlement) => settlement['beneficiary_type'] == 'seller')
        .toList();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      children: [
        _MoneyRow(
          label: 'Gross merchandise sales',
          value: _money(dashboard.grossSalesUgx),
          icon: Icons.bar_chart_rounded,
        ),
        _MoneyRow(
          label: 'Protected in escrow',
          value: _money(dashboard.heldEarningsUgx),
          icon: Icons.lock_clock_outlined,
        ),
        _MoneyRow(
          label: 'Released to wallet',
          value: _money(dashboard.releasedEarningsUgx),
          icon: Icons.account_balance_wallet_outlined,
        ),
        const SizedBox(height: 24),
        Text('Recent releases', style: syne(sz: 15, w: FontWeight.w800)),
        const SizedBox(height: 10),
        if (released.isEmpty)
          const _InlineEmpty(
            icon: Icons.payments_outlined,
            label: 'Completed settlements will appear here',
          )
        else
          ...released.map(
            (settlement) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.check_circle_outline_rounded,
                color: C.green,
              ),
              title: Text(
                _money((settlement['net_amount_ugx'] as num?)?.round() ?? 0),
                style: syne(w: FontWeight.w700),
              ),
              subtitle: Text(
                'Marketplace fee ${_money((settlement['fee_amount_ugx'] as num?)?.round() ?? 0)}',
                style: dm(sz: 12, c: C.sub),
              ),
            ),
          ),
      ],
    );
  }

  Widget _reviewsList() {
    if (_reviews.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 140),
          _InlineEmpty(
            icon: Icons.reviews_outlined,
            label: 'Verified buyer reviews will appear here',
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      itemCount: _reviews.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, index) {
        final review = _reviews[index];
        final buyer = review['buyer'] is Map
            ? Map<String, dynamic>.from(review['buyer'])
            : <String, dynamic>{};
        final listing = review['listing'] is Map
            ? Map<String, dynamic>.from(review['listing'])
            : <String, dynamic>{};
        final response = review['seller_response']?.toString();
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: C.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      listing['title']?.toString() ?? 'Product',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: syne(sz: 13, w: FontWeight.w800),
                    ),
                  ),
                  Row(
                    children: List.generate(
                      5,
                      (star) => Icon(
                        Icons.star,
                        size: 14,
                        color: star < ((review['rating'] as num?)?.round() ?? 0)
                            ? C.gold2
                            : C.border,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                buyer['full_name']?.toString() ??
                    buyer['username']?.toString() ??
                    'Verified buyer',
                style: dm(sz: 11, c: C.sub, w: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(review['comment']?.toString() ?? '', style: dm(sz: 13)),
              if (response != null && response.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: C.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Your response: $response',
                    style: dm(sz: 12, c: C.sub),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _respondToReview(review),
                    icon: const Icon(Icons.reply_rounded),
                    label: const Text('RESPOND'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  // ── Pro Retention ─────────────────────────────────────────────────────────

  Widget _retention() {
    final dashboard = _dashboard;
    if (dashboard == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 140),
          _InlineEmpty(
            icon: Icons.workspace_premium_rounded,
            label: 'Load the dashboard to view retention insights',
          ),
        ],
      );
    }

    // ── Computed metrics ──────────────────────────────────────────────────
    final buyerOrderCounts = <String, int>{};
    for (final order in _orders) {
      final key = order.orderNumber.split('-').first;
      buyerOrderCounts[key] = (buyerOrderCounts[key] ?? 0) + 1;
    }
    final repeatBuyers =
        buyerOrderCounts.values.where((c) => c > 1).length;
    final totalBuyers = buyerOrderCounts.length;
    final repeatRatio =
        totalBuyers > 0 ? (repeatBuyers / totalBuyers) : 0.0;

    // Review response rate
    final totalReviews = _reviews.length;
    final respondedReviews = _reviews
        .where((r) =>
            r['seller_response'] != null &&
            r['seller_response'].toString().isNotEmpty)
        .length;
    final responseRate =
        totalReviews > 0 ? (respondedReviews / totalReviews) : 0.0;

    // Retention score (0–100) weighted composite
    final avgRating = (dashboard.ratingAverage).clamp(0.0, 5.0);
    final ratingScore = avgRating / 5.0;
    final stockRisk = dashboard.lowStockListings > 0
        ? (1.0 -
                (dashboard.lowStockListings /
                    (dashboard.activeListings + 1)))
            .clamp(0.0, 1.0)
        : 1.0;
    final retentionScore = ((repeatRatio * 0.35 +
                ratingScore * 0.30 +
                responseRate * 0.25 +
                stockRisk * 0.10) *
            100)
        .round();

    // Top-5 buyers by order count
    final sortedBuyers = buyerOrderCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top5 = sortedBuyers.take(5).toList();

    // Churn-risk: buyers with only 1 order
    final churnRisk = buyerOrderCounts.entries
        .where((e) => e.value == 1)
        .take(5)
        .toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      children: [
        // ── 1. Retention Score ──────────────────────────────────────────
        _RetentionScoreCard(score: retentionScore),
        const SizedBox(height: 20),

        // ── 2. Loyalty Voucher Engine ───────────────────────────────────
        _SectionHeader(
          icon: Icons.card_giftcard_rounded,
          label: 'Loyalty Voucher Engine',
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Auto-send discount after order',
                          style: dm(sz: 14, w: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Sends a voucher code to buyers when their order is delivered',
                          style: dm(sz: 12, c: C.sub),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _autoLoyaltyVoucherEnabled,
                    activeColor: C.brandDk,
                    onChanged: (val) =>
                        setState(() => _autoLoyaltyVoucherEnabled = val),
                  ),
                ],
              ),
              if (_autoLoyaltyVoucherEnabled) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: C.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: C.border),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Active Code',
                              style: dm(sz: 10, c: C.sub),
                            ),
                            Text(
                              _activeLoyaltyCode,
                              style: syne(
                                  sz: 17,
                                  w: FontWeight.w800,
                                  c: C.brandDk),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy code',
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: _activeLoyaltyCode));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Code copied to clipboard')),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.trending_up_rounded,
                        size: 16, color: Colors.greenAccent),
                    const SizedBox(width: 6),
                    Text(
                      'Estimated +18% repeat-purchase lift',
                      style: dm(sz: 12, c: Colors.greenAccent),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),

        // ── 3. Buyer Re-engagement Nudges ───────────────────────────────
        _SectionHeader(
          icon: Icons.notifications_active_rounded,
          label: 'Re-engagement Nudges',
        ),
        const SizedBox(height: 4),
        Text(
          'Buyers with only one order — potential churn risk',
          style: dm(sz: 12, c: C.sub),
        ),
        const SizedBox(height: 10),
        if (churnRisk.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: C.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: C.border),
            ),
            child: const Text(
                '🎉 All tracked buyers have made repeat purchases!'),
          )
        else
          ...churnRisk.map((entry) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: C.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: C.border),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: C.surface,
                      child: Text(
                        entry.key.isNotEmpty
                            ? entry.key[0].toUpperCase()
                            : '?',
                        style: syne(sz: 14, w: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Buyer ${entry.key}',
                            style: dm(sz: 13, w: FontWeight.w700),
                          ),
                          Text(
                            '${entry.value} order · No repeat in 30+ days',
                            style: dm(sz: 11, c: C.sub),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.chat_bubble_outline_rounded,
                          size: 15),
                      label: const Text('Thank You'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        textStyle: const TextStyle(fontSize: 11),
                      ),
                      onPressed: () => widget.state.go('new_chat'),
                    ),
                  ],
                ),
              )),
        const SizedBox(height: 20),

        // ── 4. Top Buyer VIP Leaderboard ────────────────────────────────
        _SectionHeader(
          icon: Icons.emoji_events_rounded,
          label: 'Top Buyer Leaderboard',
        ),
        const SizedBox(height: 10),
        if (top5.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: C.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: C.border),
            ),
            child:
                const Text('Complete orders to unlock your top buyers.'),
          )
        else
          ...top5.asMap().entries.map((entry) {
            final rank = entry.key + 1;
            final buyer = entry.value;
            final isVip = rank == 1;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isVip
                    ? C.gold2.withValues(alpha: 0.08)
                    : C.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isVip
                      ? C.gold2.withValues(alpha: 0.5)
                      : C.border,
                ),
              ),
              child: Row(
                children: [
                  Text(
                    rank == 1
                        ? '🥇'
                        : rank == 2
                            ? '🥈'
                            : rank == 3
                                ? '🥉'
                                : '#$rank',
                    style: const TextStyle(fontSize: 20),
                  ),
                  const SizedBox(width: 12),
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: C.surface,
                    child: Text(
                      buyer.key.isNotEmpty
                          ? buyer.key[0].toUpperCase()
                          : '?',
                      style: syne(sz: 13, w: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Buyer ${buyer.key}',
                      style: dm(sz: 13, w: FontWeight.w700),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${buyer.value} orders',
                        style: dm(sz: 12, c: C.sub),
                      ),
                      if (isVip)
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: C.gold2.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: C.gold2.withValues(alpha: 0.5)),
                          ),
                          child: Text(
                            'VIP',
                            style: dm(
                                sz: 9,
                                w: FontWeight.w800,
                                c: C.gold2),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          }),
        const SizedBox(height: 20),

        // ── 5. Review Response Rate ─────────────────────────────────────
        _SectionHeader(
          icon: Icons.rate_review_rounded,
          label: 'Review Response Rate',
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$respondedReviews / $totalReviews responded',
                    style: dm(sz: 13, w: FontWeight.w700),
                  ),
                  Text(
                    '${(responseRate * 100).round()}%',
                    style: syne(
                      sz: 16,
                      w: FontWeight.w800,
                      c: responseRate >= 0.8
                          ? Colors.greenAccent
                          : responseRate >= 0.5
                              ? Colors.orangeAccent
                              : Colors.redAccent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: responseRate,
                  minHeight: 8,
                  backgroundColor: C.surface,
                  color: responseRate >= 0.8
                      ? Colors.greenAccent
                      : responseRate >= 0.5
                          ? Colors.orangeAccent
                          : Colors.redAccent,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                responseRate < 1.0
                    ? 'Replying to all reviews builds trust and lifts your Retention Score.'
                    : '✅ You have responded to every review — great job!',
                style: dm(sz: 12, c: C.sub),
              ),
              if (totalReviews > respondedReviews) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _tabs.animateTo(4),
                    icon: const Icon(Icons.reply_rounded, size: 16),
                    label: const Text('GO TO REVIEWS'),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),

        // ── 6. Price Competitiveness Radar ──────────────────────────────
        _SectionHeader(
          icon: Icons.radar_rounded,
          label: 'Price Competitiveness Radar',
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.lock_open_rounded,
                      size: 16, color: Colors.greenAccent),
                  const SizedBox(width: 6),
                  Text(
                    'Necxa Escrow Protects Every Buyer',
                    style: dm(sz: 13, w: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Our 5% marketplace fee covers secure escrow, dispute resolution and '
                'verified payments — giving buyers confidence to spend more with '
                'trusted sellers like you.',
                style: dm(sz: 12, c: C.sub),
              ),
              const SizedBox(height: 10),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                '💡 Tip: Sellers with competitive pricing AND fast response times '
                'see up to 2× repeat-purchase rates.',
                style: dm(sz: 12, c: C.sub),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _tabs.animateTo(3),
                  icon: const Icon(Icons.account_balance_wallet_rounded,
                      size: 16),
                  label: const Text('VIEW EARNINGS'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _respondToReview(Map<String, dynamic> review) async {
    final controller = TextEditingController();
    final response = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Respond to review'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          maxLength: 1000,
          decoration: const InputDecoration(
            hintText: 'Write a helpful response',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('PUBLISH'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (response == null || response.length < 2) return;
    try {
      await _commerce.respondToReview(
        reviewId: review['id'].toString(),
        response: response,
      );
      await _refreshReviews();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _setStock(String listingId, int stock) async {
    setState(() => _workingId = listingId);
    try {
      await _commerce.updateInventory(listingId: listingId, stockCount: stock);
      await _refreshDashboard();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _workingId = null);
    }
  }

  Future<void> _toggleStatus(String listingId, bool currentlyActive) async {
    setState(() => _workingId = listingId);
    try {
      await _commerce.updateInventory(
        listingId: listingId,
        stockCount: 0, // stock unchanged — backend will keep existing
        status: currentlyActive ? 'inactive' : 'active',
      );
      await _refreshDashboard();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _workingId = null);
    }
  }

  Future<void> _confirmDelete(String listingId, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.card,
        title: Text('Delete product?', style: syne(sz: 16, w: FontWeight.w800)),
        content: Text(
          'Remove "$title" permanently. This cannot be undone.',
          style: dm(sz: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _deleteListing(listingId);
    }
  }

  Future<void> _deleteListing(String listingId) async {
    setState(() => _workingId = listingId);
    try {
      await _commerce.deleteListing(listingId);
      await _refreshDashboard();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _workingId = null);
    }
  }

  Future<void> _runOrderAction(CommerceOrder order, String transition) async {
    Navigator.of(context).pop();
    setState(() => _workingId = order.id);
    try {
      await _commerce.transitionOrder(order.id, transition);
      await Future.wait([_refreshOrders(), _refreshDashboard()]);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _workingId = null);
    }
  }

  void _showOrder(CommerceOrder order) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(child: Container(width: 36, height: 4, color: C.border)),
                const SizedBox(height: 18),
                Text(
                  order.productTitle,
                  style: syne(sz: 18, w: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(order.orderNumber, style: dm(c: C.sub)),
                const SizedBox(height: 18),
                _DetailLine(label: 'Status', value: _statusText(order.status)),
                _DetailLine(
                  label: 'Buyer',
                  value: order.participantName('buyer'),
                ),
                _DetailLine(label: 'Quantity', value: '${order.quantity}'),
                _DetailLine(
                  label: 'Order total',
                  value: _money(order.totalUgx),
                ),
                _DetailLine(
                  label: 'Escrow',
                  value: _statusText(order.settlementStatus),
                ),
                if (order.pickupCode != null)
                  _DetailLine(label: 'Pickup code', value: order.pickupCode!),
                if (order.deliveryAddress.isNotEmpty)
                  _DetailLine(label: 'Delivery', value: order.deliveryAddress),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _openChat(sheetContext, order, 'buyer'),
                        icon: const Icon(Icons.chat_bubble_outline_rounded),
                        label: const Text('Buyer'),
                      ),
                    ),
                    if (order.driver != null) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              _openChat(sheetContext, order, 'driver'),
                          icon: const Icon(Icons.local_shipping_outlined),
                          label: const Text('Driver'),
                        ),
                      ),
                    ],
                  ],
                ),
                if (order.status == 'confirmed' ||
                    order.status == 'processing') ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _runOrderAction(order, 'seller_ready'),
                      icon: const Icon(Icons.inventory_2_outlined),
                      label: const Text('Ready for pickup'),
                    ),
                  ),
                ],
                if (![
                  'completed',
                  'cancelled',
                  'refunded',
                  'disputed',
                ].contains(order.status)) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () => _runOrderAction(order, 'open_dispute'),
                      icon: const Icon(Icons.report_problem_outlined),
                      label: const Text('Open dispute'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openChat(
    BuildContext sheetContext,
    CommerceOrder order,
    String role,
  ) async {
    final participant = role == 'buyer' ? order.buyer : order.driver;
    final participantId = role == 'buyer'
        ? order.buyerId
        : order.delivery?['driver_id']?.toString();
    if (participantId == null || participantId.isEmpty) return;
    Navigator.of(sheetContext).pop();
    await widget.state.openCreatorChat(
      participantId,
      order.participantName(role),
      participant?['avatar_url']?.toString(),
      initialContextText:
          'Regarding ${order.orderNumber}: ${order.productTitle}',
      context: 'commerce_order',
    );
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error.toString()),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class _MetricPanel extends StatelessWidget {
  const _MetricPanel({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: C.card,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: C.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Icon(icon, color: color, size: 20),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: syne(sz: 16, w: FontWeight.w800),
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: dm(sz: 11, c: C.sub),
        ),
      ],
    ),
  );
}

class _ProductImage extends StatelessWidget {
  const _ProductImage({this.url});
  final String? url;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: Container(
      width: 52,
      height: 52,
      color: C.surface,
      child: url == null || url!.isEmpty
          ? Icon(Icons.inventory_2_outlined, color: C.sub)
          : CachedNetworkImage(
              imageUrl: url!,
              fit: BoxFit.cover,
              memCacheWidth: 160,
              memCacheHeight: 160,
              fadeInDuration: Duration.zero,
              placeholder: (_, __) => Container(color: C.surface),
              errorWidget: (_, __, ___) =>
                  Icon(Icons.broken_image_outlined, color: C.sub),
            ),
    ),
  );
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'completed' => C.green,
      'disputed' || 'cancelled' || 'refunded' => C.red,
      'ready_for_pickup' || 'driver_assigned' => C.gold2,
      _ => C.blue,
    };
    return Text(
      _statusText(status),
      style: dm(sz: 11, w: FontWeight.w700, c: color),
    );
  }
}

class _MoneyRow extends StatelessWidget {
  const _MoneyRow({
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: C.card,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: C.border),
    ),
    child: Row(
      children: [
        Icon(icon, color: C.brandDk),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label, style: dm(c: C.sub)),
        ),
        Text(value, style: syne(w: FontWeight.w800)),
      ],
    ),
  );
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(label, style: dm(sz: 12, c: C.sub)),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: dm(sz: 13, w: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28),
    child: Column(
      children: [
        Icon(icon, color: C.dim, size: 34),
        const SizedBox(height: 8),
        Text(label, style: dm(c: C.sub)),
      ],
    ),
  );
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });
  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: C.sub, size: 42),
          const SizedBox(height: 14),
          Text(title, style: syne(sz: 18, w: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: dm(c: C.sub),
          ),
          const SizedBox(height: 18),
          FilledButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    ),
  );
}

String _money(int amount) {
  final digits = amount.abs().toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return 'UGX ${amount < 0 ? '-' : ''}$buffer';
}

String _statusText(String value) => value
    .split('_')
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join(' ');

// ─────────────────────────────────────────────────────────────────────────────
// _RetentionScoreCard
// ─────────────────────────────────────────────────────────────────────────────

class _RetentionScoreCard extends StatelessWidget {
  const _RetentionScoreCard({required this.score});

  final int score;

  Color get _color {
    if (score >= 75) return Colors.greenAccent;
    if (score >= 50) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  String get _label {
    if (score >= 75) return 'Strong';
    if (score >= 50) return 'Growing';
    return 'Needs Work';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _color.withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(
            color: _color.withValues(alpha: 0.12),
            blurRadius: 16,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            height: 88,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: score / 100,
                  strokeWidth: 8,
                  backgroundColor: C.surface,
                  color: _color,
                  strokeCap: StrokeCap.round,
                ),
                Text(
                  '$score',
                  style: syne(sz: 26, w: FontWeight.w900, c: _color),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Retention Score',
                  style: dm(sz: 12, c: C.sub),
                ),
                const SizedBox(height: 4),
                Text(
                  _label,
                  style: syne(sz: 22, w: FontWeight.w900, c: _color),
                ),
                const SizedBox(height: 6),
                Text(
                  'Weighted from repeat buyers, rating, '
                  'review responses & stock health.',
                  style: dm(sz: 11, c: C.sub),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SectionHeader
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: C.brandDk),
        const SizedBox(width: 8),
        Text(label, style: syne(sz: 15, w: FontWeight.w800)),
      ],
    );
  }
}
