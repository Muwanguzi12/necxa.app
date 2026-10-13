import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    _tabs.addListener(_onTabChanged);
    _hydrateThenRefresh();
  }

  @override
  void dispose() {
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
    final listings = _dashboard!.listings;
    if (listings.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 140),
          _InlineEmpty(
            icon: Icons.storefront_outlined,
            label: 'No product listings yet',
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      itemCount: listings.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, index) {
        final listing = listings[index];
        final id = listing['id']?.toString() ?? '';
        final stock = (listing['stock_count'] as num?)?.round() ?? 0;
        final working = _workingId == id;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: stock <= 5 ? C.gold2.withValues(alpha: .6) : C.border,
            ),
          ),
          child: Row(
            children: [
              _ProductImage(url: listing['media_url']?.toString()),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      listing['title']?.toString() ?? 'Listing',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: syne(sz: 14, w: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      stock <= 5 ? 'Low stock' : 'In stock',
                      style: dm(
                        sz: 12,
                        c: stock <= 5 ? C.gold2 : C.green,
                        w: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Reduce stock',
                onPressed: working || stock == 0
                    ? null
                    : () => _setStock(id, stock - 1),
                icon: const Icon(Icons.remove_circle_outline_rounded),
              ),
              SizedBox(
                width: 32,
                child: Text(
                  '$stock',
                  textAlign: TextAlign.center,
                  style: syne(w: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Add stock',
                onPressed: working ? null : () => _setStock(id, stock + 1),
                icon: const Icon(Icons.add_circle_outline_rounded),
              ),
            ],
          ),
        );
      },
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
