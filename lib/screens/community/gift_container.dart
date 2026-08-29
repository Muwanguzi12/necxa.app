import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import '../../theme.dart';
import '../../app_state.dart';
import '../../data.dart';
import '../../services/sound_service.dart';
import '../../services/finance_gifting_service.dart';
import '../../utils/error_handler.dart';
import '../../services/finance_coin_purchase_service.dart';
import '../../services/finance_backend.dart';
import 'package:url_launcher/url_launcher_string.dart';

class GiftContainer extends StatefulWidget {
  final AppState state;
  final String receiverId;
  final String? postId;
  final VoidCallback onDismiss;

  const GiftContainer({
    super.key,
    required this.state,
    required this.receiverId,
    this.postId,
    required this.onDismiss,
  });

  @override
  State<GiftContainer> createState() => _GiftContainerState();
}

class _GiftContainerState extends State<GiftContainer> {
  int _step = 0; // 0: Selection, 1: Recharge, 2: Payment, 3: Success

  List<GiftItem> _presets = [];
  bool _loading = true;
  bool _sending = false;

  GiftItem? _selectedPreset;
  String _category = 'All';
  double _rechargeUGX = 10000;
  String? _paymentRef;
  String? _rechargeIdempotencyKey;
  String? _giftIdempotencyKey;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    setState(() => _loading = true);
    final dataSaverMode = widget.state.isDataSaverMode;
    try {
      _presets = await widget.state.financeGifting.fetchGiftItems(
        allowNetwork: !dataSaverMode,
      );
      _presets.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      if (!dataSaverMode) await widget.state.syncVault();
    } catch (e) {
      debugPrint('Gift Data Error: $e');
    }
    if (_presets.isEmpty) {
      _presets = gifts
          .map(
            (g) => GiftItem(
              id: g.id,
              name: g.name,
              emoji: g.emoji,
              ncxValue: g.price,
              ugxValue: g.price * 100,
              category: 'standard',
              sortOrder: 0,
              imageUrl: g.imageUrl,
            ),
          )
          .toList();
    }
    setState(() => _loading = false);
  }

  void _next(int step) => setState(() => _step = step);

  Future<void> _sendGift(GiftItem preset) async {
    if (widget.receiverId.isEmpty) { _showError('No recipient selected.'); return; }
    if (!widget.state.isOnline) {
      _showError('Connect to the internet before sending a gift.');
      return;
    }

    if (widget.state.coinBalance < preset.ncxValue) {
      if (widget.state.isDataSaverMode) {
        await widget.state.syncVault();
      }
    }

    if (widget.state.coinBalance < preset.ncxValue) {
      _selectedPreset = preset;
      _rechargeUGX = ((preset.ncxValue - widget.state.coinBalance) * 100).clamp(5000, 500000).toDouble();
      _next(1);
      return;
    }

    if (widget.state.user == null) { _showError('Please sign in to send gifts.'); return; }

    setState(() => _sending = true);
    await SoundService().playGiftSound();

    try {
      final res = await widget.state.financeGifting.sendGift(
        senderId: widget.state.user!.id,
        receiverId: widget.receiverId,
        giftItemId: preset.id,
        ncxAmount: preset.ncxValue,
        contextType: widget.postId != null ? 'creator_post' : 'direct',
        contextId: widget.postId,
        idempotencyKey: _giftIdempotencyKey ??= _newGiftIdempotencyKey(),
      );

      if (res.success) {
        try {
          await widget.state.syncVault();
        } catch (error) {
          debugPrint('Gift wallet refresh failed after successful send: $error');
        }
        await SoundService().playWithFade(
          soundPath: SoundService.SOUND_SUCCESS,
          targetVolume: 0.9,
          fadeDuration: const Duration(milliseconds: 800),
          curve: Curves.bounceOut,
        );
        _next(3);
        _giftIdempotencyKey = null;
      } else {
        _showError(res.message);
      }
    } catch (e) {
      _showError(getUserFriendlyError(e));
    }
    setState(() => _sending = false);
  }

  String _newGiftIdempotencyKey() =>
      'community-gift-${widget.receiverId}-${widget.postId ?? 'direct'}-${DateTime.now().microsecondsSinceEpoch}';

  Future<void> _initiateRecharge(String method) async {
    if (widget.state.user == null) { _showError('Sync error: User not authenticated.'); return; }
    setState(() => _sending = true);
    try {
      // Route recharge through the Supabase 2 coin purchase flow.
      final packId = FinanceCoinPurchaseService.packIdForUgx(_rechargeUGX);
      _rechargeIdempotencyKey ??= 'gift-recharge-${DateTime.now().microsecondsSinceEpoch}';
      final result = await widget.state.buyShards(
        packId,
        method: method,
        idempotencyKey: _rechargeIdempotencyKey!,
      );
      final redirectUrl = result['redirectUrl']?.toString() ?? result['redirect_url']?.toString();
      final paymentId = result['paymentId']?.toString();
      if (redirectUrl != null) {
        if (!await canLaunchUrlString(redirectUrl)) throw Exception('Unable to open Pesapal checkout');
        await launchUrlString(redirectUrl, mode: LaunchMode.externalApplication);
        if (paymentId == null) throw Exception('Payment reference is missing');
        final completed = await widget.state.financeCoinPurchases.waitForCompletion(paymentId);
        if (!completed) throw Exception('Payment is not confirmed. Coins will only be added after Pesapal confirms payment.');
        await widget.state.syncVault();
      }
      _rechargeIdempotencyKey = null;
      _next(0);
    } catch (e) {
      if (e is FinanceBackendException &&
          (e.code == 'payment_final' || e.code == 'payment_initialization_failed')) {
        _rechargeIdempotencyKey = null;
      }
      _showError(getUserFriendlyError(e));
    }
    setState(() => _sending = false);
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.90;
    return Container(
      constraints: BoxConstraints(
        maxHeight: maxHeight,
      ),
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0B111D),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(
            color: Colors.white.withOpacity(0.1),
            width: 1.0,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle Bar
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
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
    if (_loading) return const SizedBox(height: 300, child: Center(child: CircularProgressIndicator(color: C.brand)));

    switch (_step) {
      case 0: return _buildSelection();
      case 1: return _buildRecharge();
      case 2: return _buildPaymentConfirmation();
      case 3: return _buildSuccess();
      default: return _buildSelection();
    }
  }

  Widget _buildHeader(String title, {VoidCallback? onBack}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          if (onBack != null)
            GestureDetector(
              onTap: onBack,
              child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
            ),
          if (onBack == null) const SizedBox(width: 20),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: syne(sz: 16, w: FontWeight.w900, ls: 1.2, c: Colors.white),
            ),
          ),
          const SizedBox(width: 20),
        ],
      ),
    );
  }

  Widget _buildGiftIcon(GiftItem p) {
    final url = p.imageUrl;
    if (url == null || url.isEmpty) {
      return Center(child: Text(p.emoji, style: const TextStyle(fontSize: 32)));
    }
    if (url.startsWith('assets/')) {
      return Image.asset(url, fit: BoxFit.contain);
    }
    if (widget.state.isDataSaverMode) {
      return Center(child: Text(p.emoji, style: const TextStyle(fontSize: 32)));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.contain,
        placeholder: (_, __) => Center(
          child: Text(p.emoji, style: const TextStyle(fontSize: 32)),
        ),
        errorWidget: (_, __, ___) => Center(
          child: Text(p.emoji, style: const TextStyle(fontSize: 32)),
        ),
      ),
    );
  }

  Widget _buildSelection() {
    final balance = widget.state.coinBalance;
    final filtered = _presets.where((gift) {
      if (_category == 'All') return true;
      if (_category == 'Popular') return gift.ncxValue <= 20;
      if (_category == 'Premium') return gift.ncxValue >= 25 && gift.ncxValue < 300;
      return gift.ncxValue >= 300;
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => _next(1),
                child: _balanceBadge(balance),
              ),
              Expanded(
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.card_giftcard_rounded, color: C.brand, size: 30),
                        const SizedBox(width: 10),
                        Text('Gift Coins', style: syne(sz: 20, w: FontWeight.w900)),
                      ],
                    ),
                    Text('Send gifts · Support creators', style: dm(sz: 12, c: C.sub)),
                  ],
                ),
              ),
              IconButton(
                onPressed: widget.onDismiss,
                tooltip: 'Close gifts',
                icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 46,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            scrollDirection: Axis.horizontal,
            children: [
              _categoryTab('All', Icons.favorite_rounded),
              _categoryTab('Popular', Icons.local_fire_department_rounded),
              _categoryTab('Premium', Icons.workspace_premium_rounded),
              _categoryTab('Luxury', Icons.auto_awesome_rounded),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: RawScrollbar(
              thumbColor: C.brand.withOpacity(0.55),
              radius: const Radius.circular(4),
              thickness: 4,
              thumbVisibility: true,
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(2, 2, 6, 8),
                physics: const BouncingScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  childAspectRatio: 0.76,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 10,
                ),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final gift = filtered[index];
                  final selected = _selectedPreset?.id == gift.id;
                  final canAfford = balance >= gift.ncxValue;
                  return _giftCard(gift, selected, canAfford);
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
          child: GestureDetector(
            onTap: _sending
                ? null
                : () {
                    final selected = _selectedPreset;
                    if (selected == null) {
                      _next(1);
                    } else {
                      _sendGift(selected);
                    }
                  },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF0B5CFF), Color(0xFFB900FF)]),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: C.brand.withOpacity(0.7)),
                boxShadow: [BoxShadow(color: C.brand.withOpacity(0.18), blurRadius: 16)],
              ),
              child: Row(
                children: [
                  const Icon(Icons.card_giftcard_rounded, color: Colors.white, size: 38),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedPreset == null ? 'Make someone’s day!' : 'Send ${_selectedPreset!.name}',
                          style: syne(sz: 15, w: FontWeight.w900),
                        ),
                        Text(
                          _selectedPreset == null
                              ? 'Send gifts and celebrate your favorite creators on Necxa.'
                              : 'Send for ${_selectedPreset!.ncxValue} NCX to support this creator.',
                          style: dm(sz: 10, c: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white, size: 16),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _balanceBadge(double balance) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF10233E),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: C.brand.withOpacity(0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircleAvatar(radius: 11, backgroundColor: Color(0xFF00AEEF), child: Text('N', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900))),
          const SizedBox(width: 5),
          Text('NCX', style: dm(sz: 11, w: FontWeight.w700, c: Colors.white70)),
          const SizedBox(width: 4),
          Text('${balance.toInt()}', style: syne(sz: 16, w: FontWeight.w900, c: C.brand)),
          const SizedBox(width: 5),
          const Icon(Icons.add_circle, color: C.brand, size: 22),
        ],
      ),
    );
  }

  Widget _categoryTab(String label, IconData icon) {
    final selected = _category == label;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: ChoiceChip(
        selected: selected,
        label: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 16), const SizedBox(width: 6), Text(label)]),
        labelStyle: dm(sz: 12, w: FontWeight.w700, c: selected ? Colors.white : C.sub),
        selectedColor: const Color(0xFF087CEB),
        backgroundColor: const Color(0xFF121D35),
        side: BorderSide(color: selected ? C.brand : Colors.white.withOpacity(0.14)),
        showCheckmark: false,
        onSelected: (_) => setState(() => _category = label),
      ),
    );
  }

  Widget _giftCard(GiftItem gift, bool selected, bool canAfford) {
    return Semantics(
      button: true,
      enabled: !_sending,
      label: 'Send ${gift.name} for ${gift.ncxValue} NCX',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _sending ? null : () => setState(() => _selectedPreset = gift),
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.fromLTRB(4, 7, 4, 5),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF102D52) : const Color(0xFF0D192C),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: selected ? C.brand : const Color(0xFF203653), width: selected ? 2 : 1),
              boxShadow: selected ? [BoxShadow(color: C.brand.withOpacity(0.35), blurRadius: 14)] : null,
            ),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: canAfford ? 1 : 0.45,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(child: _buildGiftIcon(gift)),
                  Text(gift.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: dm(sz: 11, w: FontWeight.w600, c: Colors.white)),
                  const SizedBox(height: 4),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const CircleAvatar(radius: 10, backgroundColor: Color(0xFF00AEEF), child: Text('N', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w900))),
                    const SizedBox(width: 4),
                    Text('${gift.ncxValue}', style: dm(sz: 12, w: FontWeight.w800, c: C.brand)),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecharge() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader('RECHARGE NCX', onBack: () => _next(0)),
        
        Text('INSUFFICIENT BALANCE', style: syne(sz: 12, w: FontWeight.w900, c: Colors.redAccent, ls: 1)),
        const SizedBox(height: 8),
        Text('You need ${(_selectedPreset!.ncxValue - widget.state.coinBalance).toInt()} more NCX coins to send this gift.',
          style: dm(sz: 14, c: Colors.white70)
        ),
        
        const SizedBox(height: 24),
        
        // Amount Selector
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Recharge Amount', style: dm(sz: 13, c: Colors.white38)),
                  Text(ugx(_rechargeUGX), style: syne(sz: 18, w: FontWeight.bold, c: Colors.white)),
                ],
              ),
              const SizedBox(height: 20),
              Slider(
                value: _rechargeUGX,
                min: 5000,
                max: 500000,
                divisions: 99,
                activeColor: C.brand,
                inactiveColor: Colors.white10,
                onChanged: (v) => setState(() => _rechargeUGX = v),
              ),
              Text('Yields ${(_rechargeUGX / 100).toInt()} NCX Coins', style: dm(sz: 12, c: C.brand, w: FontWeight.bold)),
            ],
          ),
        ),
        
        const SizedBox(height: 24),
        
        Text('SELECT PAYMENT METHOD', style: syne(sz: 12, w: FontWeight.w900, c: Colors.white38, ls: 1)),
        const SizedBox(height: 16),
        
        _paymentOption('Vault Balance', Icons.account_balance_wallet, Colors.cyan[600]!, () => _initiateRecharge('fiat_balance')),
        _paymentOption('MTN MoMo via Pesapal', Icons.phone_android, Colors.yellow[700]!, () => _initiateRecharge('mtn')),
        _paymentOption('Airtel Money via Pesapal', Icons.phone_android, Colors.red[600]!, () => _initiateRecharge('airtel')),
        _paymentOption('Visa / Mastercard via Pesapal', Icons.credit_card, Colors.blue[600]!, () => _initiateRecharge('card')),
      ],
    );
  }

  Widget _paymentOption(String label, IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: _sending ? null : onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 16),
            Text(label, style: dm(sz: 14, w: FontWeight.bold, c: Colors.white)),
            const Spacer(),
            const Icon(Icons.chevron_right, color: Colors.white24),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentConfirmation() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader('COMPLETE PAYMENT', onBack: () => _next(1)),
        
        const Icon(Icons.hourglass_top_rounded, color: C.brand, size: 64),
        const SizedBox(height: 24),
        Text('Payment Initiated', style: syne(sz: 20, w: FontWeight.bold, c: Colors.white)),
        const SizedBox(height: 12),
        Text('Please check your phone for a push notification or follow the instructions in your provider app.',
          textAlign: TextAlign.center,
          style: dm(sz: 14, c: Colors.white70)
        ),
        const SizedBox(height: 32),
        
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12)),
          child: Column(
            children: [
              Text('REFERENCE ID', style: dm(sz: 10, c: Colors.white38)),
              const SizedBox(height: 4),
              SelectableText(_paymentRef ?? 'REF-XXXX', style: syne(sz: 16, w: FontWeight.w900, c: C.brand)),
            ],
          ),
        ),
        
        const SizedBox(height: 32),
        GestureDetector(
          onTap: () async {
            setState(() => _loading = true);
            await widget.state.syncVault();
            if (widget.state.coinBalance >= _selectedPreset!.ncxValue) {
              _next(0); // Go back to selection with new balance
            } else {
              _showError('Payment not yet detected. Please wait.');
              _next(0); 
            }
            setState(() => _loading = false);
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(gradient: brandGrad, borderRadius: BorderRadius.circular(16)),
            child: Center(child: Text('CHECK STATUS', style: dm(sz: 14, w: FontWeight.w900, c: Colors.black))),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccess() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 20),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 600),
          curve: Curves.elasticOut,
          builder: (context, val, child) => Transform.scale(
            scale: val,
            child: const Icon(Icons.check_circle, color: Colors.greenAccent, size: 100),
          ),
        ),
        const SizedBox(height: 24),
        Text('GIFT DELIVERED!', style: syne(sz: 24, w: FontWeight.w900, c: Colors.white, ls: 2)),
        const SizedBox(height: 12),
        Text('Your ${_selectedPreset?.name ?? 'Gift'} was successfully received. The creator has been notified.',
          textAlign: TextAlign.center,
          style: dm(sz: 15, c: Colors.white70)
        ),
        const SizedBox(height: 40),
        GestureDetector(
          onTap: widget.onDismiss,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              gradient: brandGrad,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: C.brand.withOpacity(0.2), blurRadius: 20, spreadRadius: 2),
              ],
            ),
            child: Center(child: Text('AWESOME', style: dm(sz: 14, w: FontWeight.w900, c: Colors.black))),
          ),
        ),
      ],
    );
  }
}
