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
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedCategory = 'All';
  String _selectedTimeRange = 'Today';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 6, vsync: this);
    _tabs.addListener(_onTabChanged);
    _hydrateThenRefresh();
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _searchController.dispose();
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

    final totalProducts = allListings.length;
    final totalStock = allListings.fold<int>(
      0,
      (sum, l) => sum + ((l['stock_count'] as num?)?.round() ?? 0),
    );
    final lowStockCount = allListings.where((l) {
      final s = (l['stock_count'] as num?)?.round() ?? 0;
      return s > 0 && s <= 5;
    }).length;
    final outOfStockCount = allListings.where((l) {
      final s = (l['stock_count'] as num?)?.round() ?? 0;
      return s == 0;
    }).length;
    final totalStockValue = allListings.fold<int>(0, (sum, l) {
      final s = (l['stock_count'] as num?)?.round() ?? 0;
      final p =
          (l['price_ugx'] as num?)?.round() ??
          (l['price'] as num?)?.round() ??
          0;
      return sum + (s * p);
    });

    final categories = <String>['All'];
    for (final l in allListings) {
      final c = l['category']?.toString().trim();
      if (c != null && c.isNotEmpty && !categories.contains(c)) {
        categories.add(c);
      }
    }
    for (final defCat in ['Electronics', 'Fashion', 'Home & Living']) {
      if (!categories.contains(defCat)) categories.add(defCat);
    }

    final filteredListings = allListings.where((l) {
      if (_selectedCategory != 'All') {
        final cat = l['category']?.toString().trim().toLowerCase() ?? '';
        if (cat != _selectedCategory.toLowerCase()) return false;
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final title = (l['title']?.toString() ?? '').toLowerCase();
        final sku = (l['sku']?.toString() ?? '').toLowerCase();
        if (!title.contains(q) && !sku.contains(q)) return false;
      }
      return true;
    }).toList();

    return Column(
      children: [
        Expanded(
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              _buildInventoryOverviewCard(
                totalProducts: totalProducts,
                totalStock: totalStock,
                lowStockCount: lowStockCount,
                outOfStockCount: outOfStockCount,
              ),
              const SizedBox(height: 14),
              _buildSearchAndFilterBar(),
              const SizedBox(height: 12),
              _buildCategoryFilterChips(categories, totalProducts),
              const SizedBox(height: 14),
              if (filteredListings.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: _InlineEmpty(
                    icon: Icons.inventory_2_outlined,
                    label: _searchQuery.isNotEmpty
                        ? 'No products match "$_searchQuery"'
                        : 'No product listings yet',
                  ),
                )
              else
                ...filteredListings.map(_buildProductCard),
            ],
          ),
        ),
        _buildStickyBottomSection(
          totalStockValue: totalStockValue,
          allListings: allListings,
        ),
      ],
    );
  }

  Widget _buildInventoryOverviewCard({
    required int totalProducts,
    required int totalStock,
    required int lowStockCount,
    required int outOfStockCount,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0D1B2A), Color(0xFF102844)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.1),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00E5FF), Color(0xFF0077B6)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.inventory_2_outlined,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Inventory Overview',
                      style: syne(sz: 16, w: FontWeight.w800, c: Colors.white),
                    ),
                    const SizedBox(height: 2),
                    Text('Your stock at a glance', style: dm(sz: 12, c: C.sub)),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Time Range',
                color: const Color(0xFF1E293B),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onSelected: (val) => setState(() => _selectedTimeRange = val),
                itemBuilder: (_) =>
                    ['Today', 'This Week', 'This Month', 'All Time']
                        .map(
                          (t) => PopupMenuItem(
                            value: t,
                            child: Text(t, style: dm(sz: 13, c: Colors.white)),
                          ),
                        )
                        .toList(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B1528),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _selectedTimeRange,
                        style: dm(
                          sz: 11,
                          c: Colors.white70,
                          w: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 15,
                        color: Colors.white70,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildStatBadge(
                  icon: Icons.inventory_2_outlined,
                  iconColor: const Color(0xFF00E5FF),
                  count: '$totalProducts',
                  label: 'Total Products',
                  borderColor: const Color(0xFF00E5FF).withValues(alpha: 0.3),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildStatBadge(
                  icon: Icons.all_inbox_rounded,
                  iconColor: const Color(0xFF10B981),
                  count: _formatCount(totalStock),
                  label: 'Total Stock',
                  borderColor: const Color(0xFF10B981).withValues(alpha: 0.3),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildStatBadge(
                  icon: Icons.warning_amber_rounded,
                  iconColor: const Color(0xFFF59E0B),
                  count: '$lowStockCount',
                  label: 'Low Stock',
                  borderColor: const Color(0xFFF59E0B).withValues(alpha: 0.3),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildStatBadge(
                  icon: Icons.do_not_disturb_on_outlined,
                  iconColor: const Color(0xFFEF4444),
                  count: '$outOfStockCount',
                  label: 'Out of Stock',
                  borderColor: const Color(0xFFEF4444).withValues(alpha: 0.3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatBadge({
    required IconData icon,
    required Color iconColor,
    required String count,
    required String label,
    required Color borderColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF081225).withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: iconColor, size: 16),
          ),
          const SizedBox(height: 6),
          Text(
            count,
            style: syne(sz: 15, w: FontWeight.w900, c: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: dm(sz: 9, c: C.sub, w: FontWeight.w600),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilterBar() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: TextField(
              controller: _searchController,
              onChanged: (val) => setState(() => _searchQuery = val.trim()),
              style: dm(sz: 13, c: Colors.white),
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.search_rounded, color: C.sub, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: C.sub, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                hintText: 'Search products...',
                hintStyle: dm(sz: 13, c: C.sub),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: IconButton(
            tooltip: 'Filter options',
            icon: const Icon(
              Icons.tune_rounded,
              color: Colors.white70,
              size: 20,
            ),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Filter by price and stock options are available above.',
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryFilterChips(List<String> categories, int totalCount) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: categories.map((cat) {
          final isSelected =
              _selectedCategory.toLowerCase() == cat.toLowerCase();
          final label = cat == 'All' ? 'All ($totalCount)' : cat;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _selectedCategory = cat),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF00E5FF)
                      : const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF00E5FF)
                        : const Color(0xFF1E293B),
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: const Color(
                              0xFF00E5FF,
                            ).withValues(alpha: 0.3),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  label,
                  style: syne(
                    sz: 12,
                    w: FontWeight.w700,
                    c: isSelected ? Colors.black : Colors.white70,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildProductCard(Map<String, dynamic> listing) {
    final id = listing['id']?.toString() ?? '';
    final title = listing['title']?.toString() ?? 'Product';
    final sku = listing['sku']?.toString() ?? '';
    final price =
        (listing['price_ugx'] as num?)?.round() ??
        (listing['price'] as num?)?.round() ??
        0;
    final stock = (listing['stock_count'] as num?)?.round() ?? 0;
    final status = listing['status']?.toString() ?? 'active';
    final working = _workingId == id;
    final mediaUrl = listing['media_url']?.toString();

    final displaySku = sku.isNotEmpty
        ? sku
        : 'PRD-${id.length > 5 ? id.substring(0, 5).toUpperCase() : id.toUpperCase()}';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: mediaUrl != null && mediaUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: mediaUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                      color: const Color(0xFF1E293B),
                      child: const Center(
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF00E5FF),
                          ),
                        ),
                      ),
                    ),
                    errorWidget: (_, __, ___) => const Center(
                      child: Icon(
                        Icons.shopping_bag_outlined,
                        color: Color(0xFF00E5FF),
                        size: 30,
                      ),
                    ),
                  )
                : const Center(
                    child: Icon(
                      Icons.shopping_bag_outlined,
                      color: Color(0xFF00E5FF),
                      size: 30,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: syne(sz: 14, w: FontWeight.bold, c: Colors.white),
                ),
                const SizedBox(height: 3),
                Text(
                  'SKU: $displaySku',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: dm(sz: 11, c: C.sub, w: FontWeight.w500),
                ),
                const SizedBox(height: 5),
                Text(
                  _money(price),
                  style: syne(sz: 14, w: FontWeight.bold, c: Colors.white),
                ),
                const SizedBox(height: 6),
                _buildStatusBadge(stock, status),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              PopupMenuButton<String>(
                tooltip: 'Options',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: Colors.white70,
                  size: 20,
                ),
                color: const Color(0xFF1E293B),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                onSelected: (val) {
                  if (val == 'edit') {
                    _showEditProductSheet(listing);
                  } else if (val == 'delete') {
                    _confirmDelete(id, title);
                  } else if (val == 'toggle') {
                    _toggleStatus(id, status == 'active');
                  }
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        const Icon(
                          Icons.edit_outlined,
                          size: 16,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Edit Product',
                          style: dm(sz: 13, c: Colors.white),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'toggle',
                    child: Row(
                      children: [
                        Icon(
                          status == 'active'
                              ? Icons.pause_circle_outline
                              : Icons.play_circle_outline,
                          size: 16,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          status == 'active'
                              ? 'Pause Listing'
                              : 'Activate Listing',
                          style: dm(sz: 13, c: Colors.white),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        const Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: Colors.redAccent,
                        ),
                        const SizedBox(width: 8),
                        Text('Delete', style: dm(sz: 13, c: Colors.redAccent)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('Quantity', style: dm(sz: 10, c: C.sub)),
              const SizedBox(height: 2),
              Text(
                '$stock',
                style: syne(sz: 15, w: FontWeight.bold, c: Colors.white),
              ),
              const SizedBox(height: 6),
              if (working)
                const SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF00E5FF),
                  ),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: stock == 0 ? null : () => _setStock(id, stock - 1),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: stock == 0
                              ? const Color(0xFF1E293B).withValues(alpha: 0.5)
                              : const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.remove,
                          size: 16,
                          color: stock == 0 ? Colors.white30 : Colors.white70,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '$stock',
                        style: syne(
                          sz: 13,
                          w: FontWeight.bold,
                          c: Colors.white,
                        ),
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _setStock(id, stock + 1),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E5FF),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.add,
                          size: 16,
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

  Widget _buildStatusBadge(int stock, String status) {
    final bool isOut = stock == 0;
    final bool isPaused = status != 'active' && !isOut;
    final bool isLow = stock > 0 && stock <= 5 && status == 'active';

    final Color color = isOut
        ? const Color(0xFFEF4444)
        : (isPaused
              ? C.sub
              : (isLow ? const Color(0xFFF59E0B) : const Color(0xFF10B981)));
    final String label = isOut
        ? 'Out of Stock'
        : (isPaused ? 'Paused' : (isLow ? 'Low Stock' : 'In Stock'));
    final IconData icon = isOut
        ? Icons.do_not_disturb_on_outlined
        : (isPaused
              ? Icons.pause_circle_outline
              : (isLow
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline_rounded));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: dm(sz: 10, w: FontWeight.bold, c: color),
          ),
        ],
      ),
    );
  }

  Widget _buildStickyBottomSection({
    required int totalStockValue,
    required List<Map<String, dynamic>> allListings,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        border: Border(top: BorderSide(color: const Color(0xFF1E293B))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.bar_chart_rounded,
                  color: Color(0xFF00E5FF),
                  size: 24,
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Stock Value', style: dm(sz: 11, c: C.sub)),
                    const SizedBox(height: 2),
                    Text(
                      _money(totalStockValue),
                      style: syne(
                        sz: 15,
                        w: FontWeight.w800,
                        c: const Color(0xFF00E5FF),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Detailed inventory valuation report coming soon.',
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E5FF).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF00E5FF).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'View Report',
                          style: syne(
                            sz: 11,
                            w: FontWeight.bold,
                            c: const Color(0xFF00E5FF),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 10,
                          color: Color(0xFF00E5FF),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 12,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    elevation: 0,
                  ),
                  onPressed: _showAddProductSheet,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(
                    'Add Product',
                    style: syne(sz: 13, w: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 10,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF334155)),
                    backgroundColor: const Color(0xFF0F172A),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  onPressed: () => _showBulkUpdateSheet(allListings),
                  icon: const Icon(
                    Icons.file_download_outlined,
                    size: 17,
                    color: Colors.white70,
                  ),
                  label: Text(
                    'Bulk Update',
                    style: syne(sz: 11, w: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 10,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF334155)),
                    backgroundColor: const Color(0xFF0F172A),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  onPressed: _showStockHistorySheet,
                  icon: const Icon(
                    Icons.history_rounded,
                    size: 17,
                    color: Colors.white70,
                  ),
                  label: Text(
                    'Stock History',
                    style: syne(sz: 11, w: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showAddProductSheet() {
    final titleCtrl = TextEditingController();
    final skuCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final stockCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final mediaCtrl = TextEditingController();
    String category = 'Electronics';
    bool saving = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              MediaQuery.of(modalCtx).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '+ Add New Product',
                        style: syne(
                          sz: 18,
                          w: FontWeight.w800,
                          c: Colors.white,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white70,
                        ),
                        onPressed: () => Navigator.of(modalCtx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _sheetTextField(
                    titleCtrl,
                    'Product Title *',
                    Icons.title_rounded,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _sheetTextField(
                          skuCtrl,
                          'SKU (e.g. KSH-001)',
                          Icons.qr_code_rounded,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF334155)),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: category,
                              dropdownColor: const Color(0xFF1E293B),
                              style: dm(sz: 13, c: Colors.white),
                              items:
                                  [
                                        'Electronics',
                                        'Fashion',
                                        'Home & Living',
                                        'Beauty',
                                        'Food',
                                        'General',
                                      ]
                                      .map(
                                        (c) => DropdownMenuItem(
                                          value: c,
                                          child: Text(c),
                                        ),
                                      )
                                      .toList(),
                              onChanged: (val) {
                                if (val != null)
                                  setModalState(() => category = val);
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _sheetTextField(
                          priceCtrl,
                          'Price (UGX) *',
                          Icons.payments_outlined,
                          isNumeric: true,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _sheetTextField(
                          stockCtrl,
                          'Initial Stock *',
                          Icons.all_inbox_rounded,
                          isNumeric: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _sheetTextField(
                    mediaCtrl,
                    'Image URL (optional)',
                    Icons.link_rounded,
                  ),
                  const SizedBox(height: 12),
                  _sheetTextField(
                    descCtrl,
                    'Description (optional)',
                    Icons.notes_rounded,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      onPressed: saving
                          ? null
                          : () async {
                              final title = titleCtrl.text.trim();
                              final price =
                                  int.tryParse(priceCtrl.text.trim()) ?? 0;
                              final stock =
                                  int.tryParse(stockCtrl.text.trim()) ?? 0;
                              if (title.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Please enter a product title.',
                                    ),
                                  ),
                                );
                                return;
                              }
                              setModalState(() => saving = true);
                              try {
                                await _commerce.addProduct(
                                  title: title,
                                  priceUgx: price,
                                  stockCount: stock,
                                  sku: skuCtrl.text.trim(),
                                  category: category,
                                  description: descCtrl.text.trim(),
                                  mediaUrl: mediaCtrl.text.trim(),
                                );
                                if (mounted) {
                                  Navigator.of(modalCtx).pop();
                                  await _refreshDashboard();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Product added successfully!',
                                      ),
                                    ),
                                  );
                                }
                              } catch (e) {
                                setModalState(() => saving = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Failed to add product: $e'),
                                  ),
                                );
                              }
                            },
                      child: saving
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : Text(
                              'Create Product',
                              style: syne(sz: 14, w: FontWeight.w800),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showBulkUpdateSheet(List<Map<String, dynamic>> listings) {
    final Map<String, int> stockValues = {
      for (final l in listings)
        l['id'].toString(): (l['stock_count'] as num?)?.round() ?? 0,
    };
    bool saving = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => SafeArea(
          child: Container(
            height: MediaQuery.of(modalCtx).size.height * 0.75,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Bulk Stock Update',
                      style: syne(sz: 18, w: FontWeight.w800, c: Colors.white),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white70,
                      ),
                      onPressed: () => Navigator.of(modalCtx).pop(),
                    ),
                  ],
                ),
                Text(
                  'Adjust quantities across your entire inventory',
                  style: dm(sz: 12, c: C.sub),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView.separated(
                    itemCount: listings.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final item = listings[i];
                      final id = item['id'].toString();
                      final currentVal = stockValues[id] ?? 0;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item['title']?.toString() ?? 'Product',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: syne(
                                      sz: 13,
                                      w: FontWeight.w700,
                                      c: Colors.white,
                                    ),
                                  ),
                                  Text(
                                    'Current: ${(item['stock_count'] as num?)?.round() ?? 0}',
                                    style: dm(sz: 11, c: C.sub),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.remove_circle_outline,
                                color: Colors.white70,
                                size: 20,
                              ),
                              onPressed: currentVal == 0
                                  ? null
                                  : () => setModalState(
                                      () => stockValues[id] = currentVal - 1,
                                    ),
                            ),
                            SizedBox(
                              width: 44,
                              child: Text(
                                '$currentVal',
                                textAlign: TextAlign.center,
                                style: syne(
                                  sz: 14,
                                  w: FontWeight.w800,
                                  c: const Color(0xFF00E5FF),
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.add_circle_outline,
                                color: Color(0xFF00E5FF),
                                size: 20,
                              ),
                              onPressed: () => setModalState(
                                () => stockValues[id] = currentVal + 1,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    onPressed: saving
                        ? null
                        : () async {
                            setModalState(() => saving = true);
                            try {
                              final results = await _commerce
                                  .bulkUpdateInventory(stockValues);
                              final failed = results
                                  .where((result) => result['success'] != true)
                                  .toList();
                              final succeeded = results.length - failed.length;
                              if (mounted) {
                                Navigator.of(modalCtx).pop();
                                await _refreshDashboard();
                                final message = failed.isEmpty
                                    ? 'Updated stock for $succeeded products.'
                                    : '$succeeded updated; ${failed.length} failed. '
                                          'Refresh and retry the failed products.';
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(message)),
                                );
                              }
                            } catch (e) {
                              setModalState(() => saving = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Failed to update inventory: $e',
                                  ),
                                ),
                              );
                            }
                          },
                    child: saving
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : Text(
                            'Save All Updates',
                            style: syne(sz: 14, w: FontWeight.w800),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showStockHistorySheet() async {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Container(
          height: MediaQuery.of(ctx).size.height * 0.65,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Stock History',
                    style: syne(sz: 18, w: FontWeight.w800, c: Colors.white),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                    ),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              Text(
                'Audit log of all manual and order stock transitions',
                style: dm(sz: 12, c: C.sub),
              ),
              const SizedBox(height: 20),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _commerce.fetchStockHistory(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Expanded(
                      child: Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF00E5FF),
                        ),
                      ),
                    );
                  }
                  final events = snapshot.data ?? const [];
                  if (events.isEmpty) {
                    return Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.history_toggle_off_rounded,
                              size: 48,
                              color: C.sub,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No stock change events recorded yet',
                              style: dm(sz: 13, c: C.sub),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  return Expanded(
                    child: ListView.separated(
                      itemCount: events.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) {
                        final ev = events[i];
                        final oldStock = ev['old_stock'] ?? 0;
                        final newStock = ev['new_stock'] ?? 0;
                        final isIncrease =
                            (newStock as num) >= (oldStock as num);
                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isIncrease
                                    ? Icons.arrow_upward_rounded
                                    : Icons.arrow_downward_rounded,
                                color: isIncrease
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFFEF4444),
                                size: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Stock Adjusted: $oldStock → $newStock',
                                      style: syne(
                                        sz: 13,
                                        w: FontWeight.w700,
                                        c: Colors.white,
                                      ),
                                    ),
                                    Text(
                                      ev['created_at']?.toString() ?? '',
                                      style: dm(sz: 11, c: C.sub),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditProductSheet(Map<String, dynamic> listing) {
    final id = listing['id']?.toString() ?? '';
    final titleCtrl = TextEditingController(
      text: listing['title']?.toString() ?? '',
    );
    final priceCtrl = TextEditingController(
      text:
          ((listing['price_ugx'] as num?)?.round() ??
                  (listing['price'] as num?)?.round() ??
                  0)
              .toString(),
    );
    final stockCtrl = TextEditingController(
      text: ((listing['stock_count'] as num?)?.round() ?? 0).toString(),
    );
    bool saving = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              MediaQuery.of(modalCtx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Edit Product',
                      style: syne(sz: 18, w: FontWeight.w800, c: Colors.white),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white70,
                      ),
                      onPressed: () => Navigator.of(modalCtx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _sheetTextField(titleCtrl, 'Title', Icons.title_rounded),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _sheetTextField(
                        priceCtrl,
                        'Price (UGX)',
                        Icons.payments_outlined,
                        isNumeric: true,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _sheetTextField(
                        stockCtrl,
                        'Stock Count',
                        Icons.all_inbox_rounded,
                        isNumeric: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    onPressed: saving
                        ? null
                        : () async {
                            final newStock = int.tryParse(
                              stockCtrl.text.trim(),
                            );
                            setModalState(() => saving = true);
                            try {
                              final newTitle = titleCtrl.text.trim();
                              final newPrice = int.tryParse(
                                priceCtrl.text.trim(),
                              );
                              if (newTitle.isEmpty ||
                                  newPrice == null ||
                                  newPrice < 0 ||
                                  newStock == null ||
                                  newStock < 0) {
                                throw const FormatException(
                                  'Enter a product title and valid non-negative price and stock.',
                                );
                              }
                              await _commerce.updateInventory(
                                listingId: id,
                                title: newTitle,
                                priceUgx: newPrice?.toDouble(),
                                stockCount: newStock,
                              );
                              if (mounted) {
                                Navigator.of(modalCtx).pop();
                                await _refreshDashboard();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Product updated successfully!',
                                    ),
                                  ),
                                );
                              }
                            } catch (e) {
                              setModalState(() => saving = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Failed to update product: $e'),
                                ),
                              );
                            }
                          },
                    child: saving
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : Text(
                            'Save Changes',
                            style: syne(sz: 14, w: FontWeight.w800),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sheetTextField(
    TextEditingController controller,
    String label,
    IconData icon, {
    bool isNumeric = false,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      keyboardType: isNumeric ? TextInputType.number : TextInputType.text,
      maxLines: maxLines,
      style: dm(sz: 13, c: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: dm(sz: 12, c: C.sub),
        prefixIcon: Icon(icon, color: C.sub, size: 18),
        filled: true,
        fillColor: const Color(0xFF1E293B),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF334155)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF00E5FF)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }

  static String _formatCount(int amount) {
    final digits = amount.abs().toString();
    final buffer = StringBuffer();
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
      buffer.write(digits[index]);
    }
    return '${amount < 0 ? '-' : ''}$buffer';
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
    final repeatBuyers = buyerOrderCounts.values.where((c) => c > 1).length;
    final totalBuyers = buyerOrderCounts.length;
    final repeatRatio = totalBuyers > 0 ? (repeatBuyers / totalBuyers) : 0.0;

    // Review response rate
    final totalReviews = _reviews.length;
    final respondedReviews = _reviews
        .where(
          (r) =>
              r['seller_response'] != null &&
              r['seller_response'].toString().isNotEmpty,
        )
        .length;
    final responseRate = totalReviews > 0
        ? (respondedReviews / totalReviews)
        : 0.0;

    // Retention score (0–100) weighted composite
    final avgRating = (dashboard.ratingAverage).clamp(0.0, 5.0);
    final ratingScore = avgRating / 5.0;
    final stockRisk = dashboard.lowStockListings > 0
        ? (1.0 - (dashboard.lowStockListings / (dashboard.activeListings + 1)))
              .clamp(0.0, 1.0)
        : 1.0;
    final retentionScore =
        ((repeatRatio * 0.35 +
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
                    horizontal: 14,
                    vertical: 10,
                  ),
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
                            Text('Active Code', style: dm(sz: 10, c: C.sub)),
                            Text(
                              _activeLoyaltyCode,
                              style: syne(
                                sz: 17,
                                w: FontWeight.w800,
                                c: C.brandDk,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy code',
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: _activeLoyaltyCode),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Code copied to clipboard'),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(
                      Icons.trending_up_rounded,
                      size: 16,
                      color: Colors.greenAccent,
                    ),
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
              '🎉 All tracked buyers have made repeat purchases!',
            ),
          )
        else
          ...churnRisk.map(
            (entry) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                      entry.key.isNotEmpty ? entry.key[0].toUpperCase() : '?',
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
                    icon: const Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 15,
                    ),
                    label: const Text('Thank You'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                    onPressed: () => widget.state.go('new_chat'),
                  ),
                ],
              ),
            ),
          ),
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
            child: const Text('Complete orders to unlock your top buyers.'),
          )
        else
          ...top5.asMap().entries.map((entry) {
            final rank = entry.key + 1;
            final buyer = entry.value;
            final isVip = rank == 1;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isVip ? C.gold2.withValues(alpha: 0.08) : C.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isVip ? C.gold2.withValues(alpha: 0.5) : C.border,
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
                      buyer.key.isNotEmpty ? buyer.key[0].toUpperCase() : '?',
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
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: C.gold2.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: C.gold2.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            'VIP',
                            style: dm(sz: 9, w: FontWeight.w800, c: C.gold2),
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
                  const Icon(
                    Icons.lock_open_rounded,
                    size: 16,
                    color: Colors.greenAccent,
                  ),
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
                  icon: const Icon(
                    Icons.account_balance_wallet_rounded,
                    size: 16,
                  ),
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
        status: currentlyActive ? 'paused' : 'active',
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
                Text('Retention Score', style: dm(sz: 12, c: C.sub)),
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
