import 'package:flutter/material.dart';
import 'dart:ui';
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
  double _rechargeUGX = 10000;
  String? _paymentRef;
  String? _rechargeIdempotencyKey;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    setState(() => _loading = true);
    try {
      _presets = await widget.state.financeGifting.fetchGiftItems();
      _presets.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      await widget.state.syncVault();
    } catch (e) {
      debugPrint('Gift Data Error: $e');
    }
    setState(() => _loading = false);
  }

  void _next(int step) => setState(() => _step = step);

  Future<void> _sendGift(GiftItem preset) async {
    if (widget.receiverId.isEmpty) { _showError('No recipient selected.'); return; }

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
      );

      if (res.success) {
        await widget.state.syncVault();
        await SoundService().playWithFade(
          soundPath: SoundService.SOUND_SUCCESS,
          targetVolume: 0.9,
          fadeDuration: const Duration(milliseconds: 800),
          curve: Curves.bounceOut,
        );
        _next(3);
      } else {
        _showError(res.message);
      }
    } catch (e) {
      _showError(getUserFriendlyError(e));
    }
    setState(() => _sending = false);
  }

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
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0D121B),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 40, spreadRadius: 10),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.05, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: SizedBox(
                key: ValueKey(_step),
                child: _buildStepContent(),
              ),
            ),
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
    return Column(
      children: [
        Container(
          width: 40, height: 4,
          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            if (onBack != null) 
              GestureDetector(
                onTap: onBack,
                child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
              ),
            if (onBack == null) const SizedBox(width: 20),
            Expanded(
              child: Text(title, 
                textAlign: TextAlign.center,
                style: syne(sz: 18, w: FontWeight.w900, ls: 1.5, c: Colors.white)
              ),
            ),
            const SizedBox(width: 20), 
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildSelection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader('GIFT COINS'),
        
        // Balance Banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: C.brand.withOpacity(0.2)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('NCX BALANCE', style: dm(sz: 11, w: FontWeight.bold, c: Colors.white70)),
              Row(
                children: [
                  const Icon(Icons.generating_tokens, color: C.brand, size: 16),
                  const SizedBox(width: 6),
                  Text('${widget.state.coinBalance.toInt()}', style: syne(sz: 18, w: FontWeight.bold, c: C.brand)),
                ],
              ),
            ],
          ),
        ),
        
        const SizedBox(height: 24),
        
        if (_presets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(
              children: [
                const Icon(Icons.style_outlined, color: Colors.white10, size: 48),
                const SizedBox(height: 12),
                Text('No gift presets available.', style: dm(sz: 13, c: Colors.white30)),
              ],
            ),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 0.85,
            ),
            itemCount: _presets.length,
            itemBuilder: (context, i) {
              final p = _presets[i];
              final canAfford = widget.state.coinBalance >= p.ncxValue;
              return GestureDetector(
                onTap: _sending ? null : () => _sendGift(p),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: canAfford ? 1.0 : 0.4,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white.withOpacity(0.1)),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(p.emoji, style: const TextStyle(fontSize: 32)),
                        const SizedBox(height: 10),
                        Text(p.name, 
                          maxLines: 1, 
                          overflow: TextOverflow.ellipsis,
                          style: syne(sz: 12, w: FontWeight.bold, c: Colors.white)
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.generating_tokens, color: C.brand, size: 10),
                            const SizedBox(width: 4),
                            Text('${p.ncxValue}', style: dm(sz: 12, w: FontWeight.w900, c: C.brand)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
      ],
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
