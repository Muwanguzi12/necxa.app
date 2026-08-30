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
  final String? contextType;
  final VoidCallback onDismiss;

  const GiftContainer({
    super.key,
    required this.state,
    required this.receiverId,
    this.postId,
    this.contextType,
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

  final List<Map<String, dynamic>> categories = [
    {'name': 'All', 'icon': null},
    {'name': 'Popular', 'icon': Icons.whatshot_rounded},
    {'name': 'Premium', 'icon': Icons.workspace_premium_rounded},
    {'name': 'Luxury', 'icon': Icons.auto_awesome_rounded},
    {'name': 'Big Gifts', 'icon': Icons.directions_car_rounded},
  ];

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
    if (widget.receiverId.isEmpty) {
      _showError('No recipient selected.');
      return;
    }
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
      _rechargeUGX =
          ((preset.ncxValue - widget.state.coinBalance) * 100)
              .clamp(5000, 500000)
              .toDouble();
      _next(1);
      return;
    }

    if (widget.state.user == null) {
      _showError('Please sign in to send gifts.');
      return;
    }

    setState(() => _sending = true);
    await SoundService().playGiftSound();

    try {
      final res = await widget.state.financeGifting.sendGift(
        senderId: widget.state.user!.id,
        receiverId: widget.receiverId,
        giftItemId: preset.id,
        ncxAmount: preset.ncxValue,
        contextType:
            widget.contextType ??
            (widget.postId != null ? 'creator_post' : 'direct'),
        contextId: widget.postId,
        senderName: widget.state.myDisplayName,
        senderAvatar: widget.state.myAvatarUrl,
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
    if (widget.state.user == null) {
      _showError('Sync error: User not authenticated.');
      return;
    }
    setState(() => _sending = true);
    try {
      final packId = FinanceCoinPurchaseService.packIdForUgx(_rechargeUGX);
      _rechargeIdempotencyKey ??=
          'gift-recharge-${DateTime.now().microsecondsSinceEpoch}';
      final result = await widget.state.buyShards(
        packId,
        method: method,
        idempotencyKey: _rechargeIdempotencyKey!,
        contextType: 'gift_recharge',
        contextId: widget.postId,
      );
      final redirectUrl =
          result['redirectUrl']?.toString() ??
          result['redirect_url']?.toString();
      final paymentId = result['paymentId']?.toString();
      if (redirectUrl != null) {
        if (!await canLaunchUrlString(redirectUrl)) {
          throw Exception('Unable to open Pesapal checkout');
        }
        await launchUrlString(redirectUrl, mode: LaunchMode.externalApplication);
        if (paymentId == null) throw Exception('Payment reference is missing');
        final completed = await widget.state.financeCoinPurchases
            .waitForCompletion(paymentId);
        if (!completed) {
          throw Exception(
            'Payment is not confirmed. Coins will only be added after Pesapal confirms payment.',
          );
        }
        await widget.state.syncVault();
      }
      _rechargeIdempotencyKey = null;
      _next(0);
    } catch (e) {
      if (e is FinanceBackendException &&
          (e.code == 'payment_final' ||
              e.code == 'payment_initialization_failed')) {
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
      constraints: BoxConstraints(maxHeight: maxHeight),
      width: double.infinity,
      decoration: BoxDecoration(
        color: C.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border(
          top: BorderSide(color: C.text.withOpacity(0.05), width: 1.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: C.text.withOpacity(0.1),
              borderRadius: BorderRadius.circular(2),
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
    );
  }

  Widget _buildStepContent() {
    if (_loading) {
      return SizedBox(
        height: 300,
        child: Center(
          child: CircularProgressIndicator(color: C.brand),
        ),
      );
    }

    switch (_step) {
      case 0:
        return _buildSelection();
      case 1:
        return _buildRecharge();
      case 2:
        return _buildPaymentConfirmation();
      case 3:
        return _buildSuccess();
      default:
        return _buildSelection();
    }
  }

  Widget _buildGiftIcon(GiftItem p) {
    final url = p.imageUrl;
    // Explicitly use system font for emojis to avoid 'question mark' glyph issues with custom Google Fonts
    final emojiStyle = TextStyle(
      fontSize: 32,
      fontFamily: kIsWeb ? 'sans-serif' : null, // Default system font handles emojis best
    );

    if (url == null || url.isEmpty) {
      return Center(child: Text(p.emoji, style: emojiStyle));
    }
    if (url.startsWith('assets/')) {
      return Image.asset(url, fit: BoxFit.contain);
    }
    if (widget.state.isDataSaverMode) {
      return Center(child: Text(p.emoji, style: emojiStyle));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.contain,
        placeholder: (_, __) => Center(
          child: Text(p.emoji, style: emojiStyle),
        ),
        errorWidget: (_, __, ___) => Center(
          child: Text(p.emoji, style: emojiStyle),
        ),
      ),
    );
  }

  Widget _buildSelection() {
    final balance = widget.state.coinBalance;
    final filtered =
        _presets.where((gift) {
          if (_category == 'All') return true;
          if (_category == 'Popular') {
            return ['rose', 'fire', 'rocket', 'heart', 'clap'].contains(gift.id);
          }
          if (_category == 'Premium') {
            return ['crown', 'diamond', 'trophy', 'money_bag', 'star'].contains(
              gift.id,
            );
          }
          if (_category == 'Luxury') {
            return ['sports_car', 'yacht', 'villa', 'mansion'].contains(gift.id);
          }
          if (_category == 'Big Gifts') {
            return ['jet', 'dragon', 'globe', 'stadium', 'ressort'].contains(gift.id);
          }
          return true;
        }).toList();

    return Column(
      children: [
        const SizedBox(height: 16),
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              // Balance Pill
              GestureDetector(
                onTap: () => _next(1),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131D2D),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF00E5FF).withOpacity(0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: const BoxDecoration(
                          color: Color(0xFF00E5FF),
                          shape: BoxShape.circle,
                        ),
                        child: const Center(
                          child: Text(
                            'N',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${balance.toInt()}',
                        style: syne(
                          sz: 14,
                          w: FontWeight.w800,
                          c: const Color(0xFF00E5FF),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.add_circle_rounded,
                        color: Color(0xFF00E5FF),
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),

              // Title
              Expanded(
                child: Column(
                  children: [
                    Icon(
                      Icons.card_giftcard_rounded,
                      color: C.brand,
                      size: 20,
                    ),
                    Text('Gift Coins', style: syne(sz: 16, w: FontWeight.w900, c: C.text)),
                    Text(
                      'Send gifts • Support creators',
                      style: dm(sz: 10, c: C.sub),
                    ),
                  ],
                ),
              ),

              // Close
              GestureDetector(
                onTap: widget.onDismiss,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: C.text.withOpacity(0.05),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: C.icon,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // Tabs
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final cat = categories[index];
              final isSelected = _category == cat['name'];
              return GestureDetector(
                onTap: () => setState(() => _category = cat['name'] as String),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    gradient:
                        isSelected
                            ? const LinearGradient(
                              colors: [Color(0xFF00E5FF), Color(0xFF00B2CC)],
                            )
                            : null,
                    color: isSelected ? null : C.text.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow:
                        isSelected
                            ? [
                              BoxShadow(
                                color: const Color(0xFF00E5FF).withOpacity(0.3),
                                blurRadius: 8,
                                offset: const Offset(0, 4),
                              ),
                            ]
                            : null,
                  ),
                  child: Row(
                    children: [
                      if (cat['icon'] != null) ...[
                        Icon(
                          cat['icon'] as IconData,
                          size: 14,
                          color: isSelected ? Colors.black : C.sub,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        cat['name'] as String,
                        style: dm(
                          sz: 13,
                          w: isSelected ? FontWeight.w800 : FontWeight.w500,
                          c: isSelected ? Colors.black : C.sub,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 16),

        // Grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              childAspectRatio: 0.75,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final gift = filtered[index];
              final isSelected = _selectedPreset?.id == gift.id;

              return GestureDetector(
                onTap: () {
                  setState(() => _selectedPreset = gift);
                  _sendGift(gift); // Initiate send on tap like live gifting
                },
                child: Container(
                  decoration: BoxDecoration(
                    color:
                        isSelected
                            ? const Color(0xFF00E5FF).withOpacity(0.1)
                            : C.cardDk,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color:
                          isSelected
                              ? const Color(0xFF00E5FF)
                              : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: _buildGiftIcon(gift),
                        ),
                      ),
                      Text(
                        gift.name,
                        style: dm(sz: 11, w: FontWeight.w600, c: C.text),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: C.surface,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.stars_rounded,
                              color: Color(0xFF00E5FF),
                              size: 10,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${gift.ncxValue}',
                              style: syne(
                                sz: 10,
                                w: FontWeight.w900,
                                c: const Color(0xFF00E5FF),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // Footer Banner
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF6366F1), Color(0xFFA855F7), Color(0xFFEC4899)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
               BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, -2))
            ]
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.card_giftcard_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _selectedPreset == null
                            ? 'Make someone\'s day!'
                            : 'Sending ${_selectedPreset!.name}',
                        style: syne(sz: 14, w: FontWeight.w900, c: Colors.white),
                      ),
                      Text(
                        _selectedPreset == null
                            ? 'Send gifts and celebrate your favorite creators on Necxa.'
                            : 'Value: ${_selectedPreset!.ncxValue} NCX',
                        style: dm(
                          sz: 10,
                          c: Colors.white.withOpacity(0.8),
                          h: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _buildSendAnimatedButton(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSendAnimatedButton() {
    return ElevatedButton(
      onPressed:
          _sending
              ? null
              : () {
                if (_selectedPreset == null) return;
                _sendGift(_selectedPreset!);
              },
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 8,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        elevation: 0,
      ),
      child:
          _sending
              ? AnimatedValueSent(value: _selectedPreset?.ncxValue ?? 0)
              : Row(
                children: [
                  Text(
                    'Send Gift',
                    style: syne(
                      sz: 12,
                      w: FontWeight.w900,
                      c: Colors.black,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.send_rounded, size: 14),
                ],
              ),
    );
  }

  Widget _buildRecharge() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        _buildHeader('RECHARGE NCX', onBack: () => _next(0)),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'INSUFFICIENT BALANCE',
                style: syne(
                  sz: 12,
                  w: FontWeight.w900,
                  c: Colors.redAccent,
                  ls: 1,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You need ${(_selectedPreset!.ncxValue - widget.state.coinBalance).toInt()} more NCX coins to send this gift.',
                style: dm(sz: 14, c: C.text.withOpacity(0.7)),
              ),

              const SizedBox(height: 24),

              // Amount Selector
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: C.text.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: C.text.withOpacity(0.1)),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Recharge Amount', style: dm(sz: 13, c: C.sub)),
                        Text(
                          ugx(_rechargeUGX),
                          style: syne(
                            sz: 18,
                            w: FontWeight.bold,
                            c: C.text,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Slider(
                      value: _rechargeUGX,
                      min: 5000,
                      max: 500000,
                      divisions: 99,
                      activeColor: C.brand,
                      inactiveColor: C.text.withOpacity(0.1),
                      onChanged: (v) => setState(() => _rechargeUGX = v),
                    ),
                    Text(
                      'Yields ${(_rechargeUGX / 100).toInt()} NCX Coins',
                      style: dm(
                        sz: 12,
                        c: C.brand,
                        w: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              Text(
                'SELECT PAYMENT METHOD',
                style: syne(
                  sz: 12,
                  w: FontWeight.w900,
                  c: C.sub,
                  ls: 1,
                ),
              ),
              const SizedBox(height: 16),

              _paymentOption(
                'Vault Balance',
                Icons.account_balance_wallet,
                Colors.cyan[600]!,
                () => _initiateRecharge('fiat_balance'),
              ),
              _paymentOption(
                'MTN MoMo via Pesapal',
                Icons.phone_android,
                Colors.yellow[700]!,
                () => _initiateRecharge('mtn'),
              ),
              _paymentOption(
                'Airtel Money via Pesapal',
                Icons.phone_android,
                Colors.red[600]!,
                () => _initiateRecharge('airtel'),
              ),
              _paymentOption(
                'Visa / Mastercard via Pesapal',
                Icons.credit_card,
                Colors.blue[600]!,
                () => _initiateRecharge('card'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(String title, {VoidCallback? onBack}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          if (onBack != null)
            GestureDetector(
              onTap: onBack,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: C.text.withOpacity(0.05),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.arrow_back_ios_new,
                  color: C.icon,
                  size: 18,
                ),
              ),
            ),
          if (onBack == null) const SizedBox(width: 36),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: syne(sz: 16, w: FontWeight.w900, ls: 1.2, c: C.text),
            ),
          ),
          const SizedBox(width: 36),
        ],
      ),
    );
  }

  Widget _paymentOption(
    String label,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: _sending ? null : onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: C.text.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: C.text.withOpacity(0.1)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 16),
            Text(label, style: dm(sz: 14, w: FontWeight.bold, c: C.text)),
            const Spacer(),
            Icon(Icons.chevron_right, color: C.text.withOpacity(0.2)),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentConfirmation() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        _buildHeader('COMPLETE PAYMENT', onBack: () => _next(1)),

        Icon(
          Icons.hourglass_top_rounded,
          color: C.brand,
          size: 64,
        ),
        const SizedBox(height: 24),
        Text(
          'Payment Initiated',
          style: syne(sz: 20, w: FontWeight.bold, c: C.text),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            'Please check your phone for a push notification or follow the instructions in your provider app.',
            textAlign: TextAlign.center,
            style: dm(sz: 14, c: C.text.withOpacity(0.7)),
          ),
        ),
        const SizedBox(height: 32),

        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: C.text.withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Text('REFERENCE ID', style: dm(sz: 10, c: C.sub)),
              const SizedBox(height: 4),
              SelectableText(
                _paymentRef ?? 'REF-XXXX',
                style: syne(
                  sz: 16,
                  w: FontWeight.w900,
                  c: C.brand,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GestureDetector(
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
              decoration: BoxDecoration(
                gradient: brandGrad,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Text(
                  'CHECK STATUS',
                  style: dm(sz: 14, w: FontWeight.w900, c: Colors.black),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccess() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 60),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 600),
          curve: Curves.elasticOut,
          builder: (context, val, child) => Transform.scale(
            scale: val,
            child: const Icon(
              Icons.check_circle,
              color: Colors.greenAccent,
              size: 100,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'GIFT DELIVERED!',
          style: syne(sz: 24, w: FontWeight.w900, c: C.text, ls: 2),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            'Your ${_selectedPreset?.name ?? 'Gift'} was successfully received. The creator has been notified.',
            textAlign: TextAlign.center,
            style: dm(sz: 15, c: C.text.withOpacity(0.7)),
          ),
        ),
        const SizedBox(height: 40),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GestureDetector(
            onTap: widget.onDismiss,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                gradient: brandGrad,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E5FF).withOpacity(0.2),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  'AWESOME',
                  style: dm(sz: 14, w: FontWeight.w900, c: Colors.black),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}

class AnimatedValueSent extends StatefulWidget {
  final int value;
  const AnimatedValueSent({super.key, required this.value});

  @override
  State<AnimatedValueSent> createState() => _AnimatedValueSentState();
}

class _AnimatedValueSentState extends State<AnimatedValueSent> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _val;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    _val = Tween<double>(begin: 0, end: widget.value.toDouble()).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.linear)
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _val,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.stars_rounded, color: Colors.black, size: 14),
            const SizedBox(width: 4),
            Text(
              '+${_val.value.toInt()}',
              style: syne(sz: 14, w: FontWeight.w900, c: Colors.black),
            ),
          ],
        );
      },
    );
  }
}
