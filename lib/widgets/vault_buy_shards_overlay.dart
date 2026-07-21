import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import 'dart:ui';
import 'dart:async';
import 'package:url_launcher/url_launcher_string.dart';
import '../services/finance_backend.dart';
import '../services/finance_coin_purchase_service.dart';

class VaultBuyShardsOverlay extends StatefulWidget {
  final AppState state;
  final int minimumNcx;
  final String? purchaseContextType;
  final String? purchaseContextId;
  final String? targetGiftItemId;

  const VaultBuyShardsOverlay({
    super.key,
    required this.state,
    this.minimumNcx = 0,
    this.purchaseContextType,
    this.purchaseContextId,
    this.targetGiftItemId,
  });

  @override
  State<VaultBuyShardsOverlay> createState() => _VaultBuyShardsOverlayState();
}

class _VaultBuyShardsOverlayState extends State<VaultBuyShardsOverlay> {
  int _stage = 1; // 1: Packs, 2: Payment Method, 3: Processing, 4: Success
  String? _selectedPackId;
  String _selectedPaymentMethod = 'fiat_balance';
  String? _idempotencyKey;
  String _processingStatus = 'Initializing...';
  bool _isPolling = false;
  bool _isLoadingPacks = false;
  List<Map<String, dynamic>> _localPacks = [];

  @override
  void initState() {
    super.initState();
    _loadPacks();
  }

  Future<void> _loadPacks() async {
    setState(() => _isLoadingPacks = true);
    try {
      // Use cached app state packs or fetch fresh
      if (widget.state.coinPacks.isNotEmpty) {
        _localPacks = widget.state.coinPacks;
      } else {
        _localPacks = await FinanceCoinPurchaseService().packs();
        // Cache into app state for other widgets
        widget.state.coinPacks = _localPacks;
        widget.state.notify();
      }
      if (_localPacks.isNotEmpty) {
        final sorted = [..._localPacks]
          ..sort((a, b) => ((a['ncx_amount'] as num?)?.toInt() ?? 0)
              .compareTo((b['ncx_amount'] as num?)?.toInt() ?? 0));
        final requiredNcx = widget.minimumNcx;
        final selected = sorted.firstWhere(
          (pack) => ((pack['ncx_amount'] as num?)?.toInt() ?? 0) >= requiredNcx,
          orElse: () => sorted.last,
        );
        _selectedPackId = selected['id'].toString();
      }
    } catch (e) {
      debugPrint('Error loading coin packs: $e');
    }
    if (mounted) setState(() => _isLoadingPacks = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Color(0xFF0A0E17), // Deep premium dark background
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: Stack(
        children: [
          // Background Glows
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.cyanAccent.withOpacity(0.05),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
                child: const SizedBox(),
              ),
            ),
          ),
          Positioned(
            bottom: -50,
            right: -50,
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.purpleAccent.withOpacity(0.05),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
                child: const SizedBox(),
              ),
            ),
          ),
          
          Column(
            children: [
              _buildHeader(),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _buildStageContent(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Get NCX Coins', style: syne(sz: 20, w: FontWeight.bold, c: Colors.white)),
              const SizedBox(height: 4),
              Text('Step $_stage of 4', style: dm(sz: 13, w: FontWeight.w500, c: Colors.white54)),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white54),
            onPressed: () => Navigator.pop(context),
            splashRadius: 24,
          ),
        ],
      ),
    );
  }

  Widget _buildStageContent() {
    switch (_stage) {
      case 1:
        return _buildPackSelection();
      case 2:
        return _buildPaymentSelection();
      case 3:
        return _buildProcessing();
      case 4:
        return _buildSuccess();
      default:
        return const SizedBox();
    }
  }

  // ── STAGE 1: PACK SELECTION ────────────────────────────────
  Widget _buildPackSelection() {
    if (_isLoadingPacks) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(64),
          child: CircularProgressIndicator(color: Colors.cyanAccent),
        ),
      );
    }
    if (_localPacks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off_rounded, color: Colors.white24, size: 48),
              const SizedBox(height: 16),
              Text('Could not load coin packs.', style: dm(sz: 14, c: Colors.white54)),
              const SizedBox(height: 16),
              TextButton.icon(
                icon: const Icon(Icons.refresh_rounded, color: Colors.cyanAccent),
                label: Text('Retry', style: dm(sz: 14, c: Colors.cyanAccent, w: FontWeight.bold)),
                onPressed: _loadPacks,
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Select a package', style: dm(sz: 14, w: FontWeight.w600, c: Colors.white54)),
          const SizedBox(height: 20),
          Expanded(
            child: GridView.builder(
              itemCount: _localPacks.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 0.85,
              ),
              itemBuilder: (context, i) {
                final pack = _localPacks[i];
                return _CoinPackCard(
                  pack: pack,
                  isSelected: _selectedPackId == pack['id'].toString(),
                  onTap: () => setState(() => _selectedPackId = pack['id'].toString()),
                );
              },
            ),
          ),
          _PrimaryButton(
            label: 'Continue',
            icon: Icons.arrow_forward_rounded,
            onTap: () {
              if (_selectedPackId != null) setState(() => _stage = 2);
            },
          ),
        ],
      ),
    );
  }

  // ── STAGE 2: PAYMENT METHOD ──────────────────────────────────
  Widget _buildPaymentSelection() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Select payment method', style: dm(sz: 14, w: FontWeight.w600, c: Colors.white54)),
          const SizedBox(height: 20),
          _PaymentMethodTile(
            id: 'fiat_balance',
            title: 'Wallet Balance',
            subtitle: 'Instant deduction',
            icon: Icons.account_balance_wallet_rounded,
            color: Colors.cyanAccent,
            isSelected: _selectedPaymentMethod == 'fiat_balance',
            onTap: () => setState(() => _selectedPaymentMethod = 'fiat_balance'),
          ),
          const SizedBox(height: 12),
          _PaymentMethodTile(
            id: 'mtn',
            title: 'MTN Mobile Money',
            subtitle: 'Via Pesapal Secure',
            icon: Icons.phone_android_rounded,
            color: const Color(0xFFFFCC00),
            isSelected: _selectedPaymentMethod == 'mtn',
            onTap: () => setState(() => _selectedPaymentMethod = 'mtn'),
          ),
          const SizedBox(height: 12),
          _PaymentMethodTile(
            id: 'airtel',
            title: 'Airtel Money',
            subtitle: 'Via Pesapal Secure',
            icon: Icons.phone_android_rounded,
            color: const Color(0xFFFF0000),
            isSelected: _selectedPaymentMethod == 'airtel',
            onTap: () => setState(() => _selectedPaymentMethod = 'airtel'),
          ),
          const SizedBox(height: 12),
          _PaymentMethodTile(
            id: 'card',
            title: 'Credit / Debit Card',
            subtitle: 'Visa, Mastercard',
            icon: Icons.credit_card_rounded,
            color: Colors.blueAccent,
            isSelected: _selectedPaymentMethod == 'card',
            onTap: () => setState(() => _selectedPaymentMethod = 'card'),
          ),
          const Spacer(),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () => setState(() => _stage = 1),
                style: IconButton.styleFrom(backgroundColor: Colors.white10),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _PrimaryButton(
                  label: 'Pay Securely',
                  icon: Icons.lock_rounded,
                  onTap: _processPayment,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _processPayment() async {
    setState(() {
      _stage = 3;
      _processingStatus = 'Securely initiating payment...';
      _isPolling = false;
    });

    try {
      _idempotencyKey ??= 'coin-purchase-${DateTime.now().microsecondsSinceEpoch}';
      
      final result = await widget.state.buyShards(
        _selectedPackId!,
        method: _selectedPaymentMethod,
        idempotencyKey: _idempotencyKey!,
        contextType: widget.purchaseContextType,
        contextId: widget.purchaseContextId,
        targetGiftItemId: widget.targetGiftItemId,
      );

      final redirectUrl = result['redirectUrl']?.toString() ?? result['redirect_url']?.toString();
      final paymentId = result['paymentId']?.toString();

      if (redirectUrl != null) {
        setState(() {
          _processingStatus = 'Awaiting payment on Pesapal...';
          _isPolling = true;
        });

        if (!await canLaunchUrlString(redirectUrl)) {
          throw Exception('Unable to open browser for checkout');
        }
        await launchUrlString(redirectUrl, mode: LaunchMode.externalApplication);

        if (paymentId == null) throw Exception('Payment reference missing from backend.');
        
        // Wait for user to complete on Pesapal
        final completed = await widget.state.financeCoinPurchases.waitForCompletion(paymentId);
        
        if (!completed) {
          throw Exception('Payment was cancelled or failed.');
        }
      }

      await widget.state.syncVault();
      if (mounted) {
        setState(() {
          _stage = 4;
        });
      }
    } catch (e) {
      if (e is FinanceBackendException &&
          (e.code == 'payment_final' || e.code == 'payment_initialization_failed')) {
        _idempotencyKey = null; // allow retry
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString(), style: dm(c: Colors.white)),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
        setState(() => _stage = 2); // Go back to payment selection
      }
    }
  }

  // ── STAGE 3: PROCESSING ────────────────────────────────
  Widget _buildProcessing() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.blueAccent.withOpacity(0.1),
            ),
            child: const Center(
              child: CircularProgressIndicator(
                color: Colors.cyanAccent,
                strokeWidth: 3,
              ),
            ),
          ),
          const SizedBox(height: 32),
          Text(
            _isPolling ? 'Awaiting Payment' : 'Processing',
            style: syne(sz: 22, w: FontWeight.bold, c: Colors.white),
          ),
          const SizedBox(height: 12),
          Text(
            _processingStatus,
            textAlign: TextAlign.center,
            style: dm(sz: 14, c: Colors.white54, h: 1.5),
          ),
          if (_isPolling) ...[
            const SizedBox(height: 40),
            TextButton.icon(
              icon: const Icon(Icons.refresh_rounded, color: Colors.cyanAccent, size: 18),
              label: Text('Check Status Again', style: dm(sz: 13, c: Colors.cyanAccent, w: FontWeight.bold)),
              onPressed: () {
                // Polling runs in background, but this gives users a placebo/manual trigger feeling
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Checking with Pesapal...', style: dm(c: Colors.white)), backgroundColor: Colors.blueGrey, duration: const Duration(seconds: 1)),
                );
              },
            ),
          ]
        ],
      ),
    );
  }

  // ── STAGE 4: SUCCESS ──────────────────────────────────
  Widget _buildSuccess() {
    final pack = _localPacks.firstWhere(
      (p) => p['id'] == _selectedPackId,
      orElse: () => _localPacks.isNotEmpty ? _localPacks.first : <String, dynamic>{},
    );
    final amount = pack['ncx_amount'] ?? 0;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.greenAccent.withOpacity(0.15),
              border: Border.all(color: Colors.greenAccent.withOpacity(0.5), width: 2),
            ),
            child: const Icon(Icons.check_rounded, color: Colors.greenAccent, size: 64),
          ),
          const SizedBox(height: 32),
          Text('Purchase Successful!', style: syne(sz: 24, w: FontWeight.bold, c: Colors.white)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.toll_rounded, color: Colors.amberAccent, size: 28),
                const SizedBox(width: 12),
                Text('+$amount NCX', style: syne(sz: 22, w: FontWeight.bold, c: Colors.amberAccent)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text('Coins have been securely added to your wallet.', textAlign: TextAlign.center, style: dm(sz: 13, c: Colors.white54)),
          const Spacer(),
          _PrimaryButton(
            label: 'Awesome, Thanks!',
            icon: Icons.done_all_rounded,
            onTap: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
  }
}

// ── WIDGETS ──────────────────────────────────────────────

class _CoinPackCard extends StatelessWidget {
  final Map<String, dynamic> pack;
  final bool isSelected;
  final VoidCallback onTap;

  const _CoinPackCard({required this.pack, required this.isSelected, required this.onTap});

  Color _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return Colors.cyanAccent;
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return Colors.cyanAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(pack['color_hex']);
    final amount = pack['ncx_amount'] ?? 0;
    final price = pack['fiat_price'] ?? 0;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.1) : Colors.white.withOpacity(0.02),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isSelected ? color : Colors.white.withOpacity(0.05),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: color.withOpacity(0.2), blurRadius: 20, spreadRadius: -5)]
              : [],
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(Icons.toll_rounded, color: color, size: 24),
                if (isSelected)
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                    child: const Icon(Icons.check_rounded, color: Colors.black, size: 12),
                  ),
              ],
            ),
            const Spacer(),
            Text(amount.toString(), style: syne(sz: 32, w: FontWeight.w800, c: Colors.white)),
            Text('NCX COINS', style: dm(sz: 10, w: FontWeight.bold, c: Colors.white54, ls: 1.2)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'UGX $price',
                style: dm(sz: 11, w: FontWeight.bold, c: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentMethodTile extends StatelessWidget {
  final String id, title, subtitle;
  final IconData icon;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  const _PaymentMethodTile({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.1) : Colors.white.withOpacity(0.02),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? color.withOpacity(0.5) : Colors.white.withOpacity(0.05),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: syne(sz: 15, w: FontWeight.bold, c: Colors.white)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: dm(sz: 12, c: Colors.white54)),
                ],
              ),
            ),
            Icon(
              isSelected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
              color: isSelected ? color : Colors.white24,
            ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _PrimaryButton({required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Colors.cyanAccent, Colors.blueAccent]),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: Colors.cyanAccent.withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 5)),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, style: syne(sz: 16, w: FontWeight.bold, c: Colors.black)),
            const SizedBox(width: 12),
            Icon(icon, color: Colors.black, size: 20),
          ],
        ),
      ),
    );
  }
}
