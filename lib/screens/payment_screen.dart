import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart';
import '../models/property_container.dart';
import '../services/payment_service.dart';
import '../services/wallet_service.dart';
import '../utils/error_handler.dart';
import 'package:url_launcher/url_launcher.dart';

enum PaymentStage { form, processing, success, error }

class PaymentScreen extends StatefulWidget {
  final AppState state;
  const PaymentScreen({super.key, required this.state});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen>
    with SingleTickerProviderStateMixin {
  final PaymentService _paymentService = PaymentService();
  final WalletService _walletService = WalletService();
  final TextEditingController _phoneCtrl = TextEditingController();

  PaymentStage _stage = PaymentStage.form;
  String _method = 'FIAT_WALLET'; // FIAT_WALLET | NCX_COINS | MTN_MOMO | AIRTEL_MONEY | CARD
  String _errMsg = '';

  double _fiatBalance = 0;
  int _coinBalance = 0;
  bool _loadingBalances = true;

  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _loadWalletBalances();
  }

  Future<void> _loadWalletBalances() async {
    try {
      final w = await _walletService.getWalletDetails();
      if (mounted) {
        final fiat = (w['fiat_balance'] as num?)?.toDouble() ??
            (w['ugx_balance'] as num?)?.toDouble() ??
            0.0;
        final coins = (w['coin_balance'] as num?)?.toInt() ??
            (w['ncx_balance'] as num?)?.toInt() ??
            0;
        setState(() {
          _fiatBalance = fiat;
          _coinBalance = coins;
          _loadingBalances = false;

          final cost = widget.state.currentProperty?.financial.unlockCost ?? 0;
          if (_fiatBalance >= cost && cost > 0) {
            _method = 'FIAT_WALLET';
          } else if (_coinBalance >= (cost ~/ 100) && cost > 0) {
            _method = 'NCX_COINS';
          } else {
            _method = 'MTN_MOMO';
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingBalances = false;
          _method = 'MTN_MOMO';
        });
      }
    }
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _startPulse() {
    _pulseCtrl.repeat(reverse: true);
  }

  void _stopPulse() {
    _pulseCtrl.stop();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.state.currentProperty;
    if (p == null) {
      return Scaffold(
        backgroundColor: C.bg,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Property not selected', style: syne(sz: 18, c: C.text)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => widget.state.go('detail'),
                style: ElevatedButton.styleFrom(backgroundColor: C.brand),
                child: Text('Return to Property', style: dm(c: Colors.black)),
              ),
            ],
          ),
        ),
      );
    }

    switch (_stage) {
      case PaymentStage.processing:
        return _buildProcessingUI(p);
      case PaymentStage.success:
        return _buildSuccessUI(p);
      case PaymentStage.error:
        return _buildErrorUI();
      default:
        return _buildFormUI(p);
    }
  }

  // -- FORM UI --------------------------------------------------------------
  Widget _buildFormUI(PropertyContainer p) {
    final unlockCost = p.financial.unlockCost;
    final coinCost = (unlockCost / 100).round();
    final hasEnoughFiat = _fiatBalance >= unlockCost;
    final hasEnoughCoins = _coinBalance >= coinCost;

    return Scaffold(
      backgroundColor: C.bg,
      body: Column(
        children: [
          _buildNav(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSummary(p),
                  const SizedBox(height: 24),
                  _buildUnlockInclusion(),
                  const SizedBox(height: 28),

                  // ── IN-APP WALLET OPTIONS ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'NECXA IN-APP WALLETS',
                        style: syne(sz: 12, ls: 1, w: FontWeight.bold, c: C.brand),
                      ),
                      if (_loadingBalances)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: C.brand),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _MethodTile(
                    id: 'FIAT_WALLET',
                    label: 'Necxa Fiat Wallet (UGX)',
                    icon: '💼',
                    sub: 'Available: UGX ${ugx(_fiatBalance.toInt())}${hasEnoughFiat ? ' · Instant' : ' (Insufficient)'}',
                    selected: _method == 'FIAT_WALLET',
                    badge: hasEnoughFiat ? 'INSTANT' : 'LOW BALANCE',
                    badgeColor: hasEnoughFiat ? C.green : Colors.orangeAccent,
                    onTap: () => setState(() => _method = 'FIAT_WALLET'),
                  ),
                  _MethodTile(
                    id: 'NCX_COINS',
                    label: 'Necxa Coins (NCX)',
                    icon: '🪙',
                    sub: 'Available: $_coinBalance NCX ($coinCost NCX needed)${hasEnoughCoins ? '' : ' (Insufficient)'}',
                    selected: _method == 'NCX_COINS',
                    badge: hasEnoughCoins ? 'INSTANT' : 'LOW BALANCE',
                    badgeColor: hasEnoughCoins ? C.brand : Colors.orangeAccent,
                    onTap: () => setState(() => _method = 'NCX_COINS'),
                  ),

                  const SizedBox(height: 24),

                  // ── EXTERNAL PAYMENT GATEWAYS ──
                  Text(
                    'MOBILE MONEY & CARDS (UGANDA)',
                    style: syne(sz: 12, ls: 1, w: FontWeight.bold, c: C.dim),
                  ),
                  const SizedBox(height: 12),
                  _MethodTile(
                    id: 'MTN_MOMO',
                    label: 'MTN Mobile Money',
                    icon: '📱',
                    sub: '256 77x / 78x / 39x · Instant push prompt',
                    selected: _method == 'MTN_MOMO',
                    onTap: () => setState(() => _method = 'MTN_MOMO'),
                  ),
                  _MethodTile(
                    id: 'AIRTEL_MONEY',
                    label: 'Airtel Money',
                    icon: '❤️',
                    sub: '256 70x / 75x · Instant push prompt',
                    selected: _method == 'AIRTEL_MONEY',
                    onTap: () => setState(() => _method = 'AIRTEL_MONEY'),
                  ),
                  _MethodTile(
                    id: 'CARD',
                    label: 'Visa / Mastercard',
                    icon: '💳',
                    sub: 'Pay securely via Pesapal',
                    selected: _method == 'CARD',
                    onTap: () => setState(() => _method = 'CARD'),
                  ),

                  if (_method == 'MTN_MOMO' || _method == 'AIRTEL_MONEY') ...[
                    const SizedBox(height: 20),
                    Text(
                      'ENTER PHONE NUMBER FOR PUSH PROMPT',
                      style: syne(sz: 12, ls: 1, w: FontWeight.bold, c: C.dim),
                    ),
                    const SizedBox(height: 10),
                    _buildPhoneInput(),
                  ],

                  const SizedBox(height: 36),
                  _buildCallToAction(p),
                  const SizedBox(height: 20),
                  Text(
                    'Direct contact credentials and verified location are permanently unlocked upon payment.',
                    textAlign: TextAlign.center,
                    style: dm(sz: 11, c: C.dim, h: 1.5),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneInput() {
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('🇺🇬 +256', style: syne(sz: 16, w: FontWeight.bold)),
          ),
          Container(width: 1, height: 24, color: C.border),
          Expanded(
            child: TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              style: syne(sz: 16, w: FontWeight.bold),
              decoration: InputDecoration(
                hintText: '772 000 000',
                hintStyle: syne(c: C.dim),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 18,
                ),
                border: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnlockInclusion() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.text.withValues(alpha: .03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'WHAT GETS UNLOCKED:',
            style: syne(sz: 12, w: FontWeight.bold, c: C.brand),
          ),
          const SizedBox(height: 12),
          const _UnlockRow(icon: '📞', label: 'Verified owner / agent phone number'),
          const _UnlockRow(icon: '💬', label: 'Instant WhatsApp direct chat link'),
          const _UnlockRow(icon: '📍', label: 'Exact physical address & GPS map pin'),
          const _UnlockRow(icon: '🎥', label: 'Direct in-app video chat capability'),
        ],
      ),
    );
  }

  // -- PROCESSING UI ----------------------------------------------------------
  Widget _buildProcessingUI(PropertyContainer p) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ScaleTransition(
                scale: Tween(begin: 1.0, end: 1.2).animate(_pulseCtrl),
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: C.brand.withValues(alpha: .1),
                    border: Border.all(
                      color: C.brand.withValues(alpha: .3),
                      width: 2,
                    ),
                  ),
                  child: const Center(
                    child: CircularProgressIndicator(color: C.brand),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text('AUTHORIZING...', style: syne(sz: 24, w: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(
                _method == 'FIAT_WALLET'
                    ? 'Debiting UGX ${ugx(p.financial.unlockCost)} from your Necxa Fiat Wallet...'
                    : _method == 'NCX_COINS'
                        ? 'Debiting ${(p.financial.unlockCost / 100).round()} NCX Coins from your wallet...'
                        : 'Waiting for approval on your mobile phone.\nCheck your device screen to confirm.',
                textAlign: TextAlign.center,
                style: dm(sz: 14, c: C.dim, h: 1.5),
              ),
              const SizedBox(height: 48),
              _buildStepIndicator('Payment request initiated', active: true),
              _buildStepIndicator(
                _method == 'FIAT_WALLET' || _method == 'NCX_COINS'
                    ? 'Processing via Necxa Finance Engine'
                    : 'Awaiting Pesapal / Telecom confirmation',
                active: true,
              ),
              _buildStepIndicator(
                'Revealing contact credentials & GPS pin',
                active: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepIndicator(String label, {bool active = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 16,
            color: active ? C.brand : C.dim,
          ),
          const SizedBox(width: 12),
          Text(label, style: dm(sz: 13, c: active ? C.text : C.dim)),
        ],
      ),
    );
  }

  // -- SUCCESS UI -------------------------------------------------------------
  Widget _buildSuccessUI(PropertyContainer p) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: C.green,
                ),
                child: Icon(
                  Icons.lock_open,
                  color: C.text,
                  size: 40,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'SUCCESSFULLY UNLOCKED!',
                style: syne(sz: 24, w: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                'You now have full access to the owner\'s credentials and exact location.',
                textAlign: TextAlign.center,
                style: dm(sz: 14, c: C.dim),
              ),
              const SizedBox(height: 32),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: C.card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: C.green.withValues(alpha: .3)),
                ),
                child: Column(
                  children: [
                    Text(
                      'REVEALED CREDENTIALS:',
                      style: syne(sz: 12, w: FontWeight.bold, c: C.green),
                    ),
                    const SizedBox(height: 16),
                    const _RevealedItem(Icons.phone, 'Agent Phone Revealed'),
                    const _RevealedItem(Icons.chat, 'WhatsApp Link Active'),
                    const _RevealedItem(Icons.location_on, 'Exact GPS Pin Decoded'),
                  ],
                ),
              ),
              const SizedBox(height: 48),
              GestureDetector(
                onTap: () {
                  widget.state.go('detail');
                },
                child: Container(
                  height: 60,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: C.brand,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Text(
                      'VIEW CREDENTIALS 🔓',
                      style: syne(sz: 15, w: FontWeight.bold, c: Colors.black),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -- ERROR UI ---------------------------------------------------------------
  Widget _buildErrorUI() {
    return Scaffold(
      backgroundColor: C.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: C.red, size: 80),
              const SizedBox(height: 24),
              Text('PAYMENT FAILED', style: syne(sz: 24, w: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(
                _errMsg,
                textAlign: TextAlign.center,
                style: dm(sz: 14, c: C.dim),
              ),
              const SizedBox(height: 48),
              GestureDetector(
                onTap: () => setState(() => _stage = PaymentStage.form),
                child: Container(
                  height: 60,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: C.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: C.border),
                  ),
                  child: Center(
                    child: Text(
                      'TRY AGAIN',
                      style: syne(sz: 15, w: FontWeight.bold),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => widget.state.go('detail'),
                child: Text(
                  'CANCEL',
                  style: syne(sz: 14, w: FontWeight.bold, c: C.dim),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -- COMPONENTS ------------------------------------------------------------
  Widget _buildNav() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 52, 16, 12),
      decoration: BoxDecoration(
        color: C.card,
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => widget.state.go('detail'),
            child: Icon(Icons.close, color: C.text, size: 22),
          ),
          const Spacer(),
          Text(
            'SECURE CHECKOUT',
            style: syne(sz: 14, w: FontWeight.bold, ls: 1),
          ),
          const Spacer(),
          const SizedBox(width: 22),
        ],
      ),
    );
  }

  Widget _buildSummary(PropertyContainer p) {
    final cost = p.financial.unlockCost;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.border),
      ),
      child: Row(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              image: p.core.images.isNotEmpty
                  ? DecorationImage(
                      image: NetworkImage(p.core.images.first),
                      fit: BoxFit.cover,
                    )
                  : null,
              color: C.border,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'REVEAL: ${p.core.title}',
                  style: dm(sz: 14, w: FontWeight.bold),
                ),
                Text(
                  'Listing Ref: ${p.core.id.substring(0, p.core.id.length.clamp(0, 8))}',
                  style: dm(sz: 11, c: C.dim),
                ),
                const SizedBox(height: 8),
                Text(
                  _method == 'NCX_COINS'
                      ? '${cost ~/ 100} NCX COINS'
                      : 'UGX ${ugx(cost)}',
                  style: syne(sz: 18, c: C.brand, w: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCallToAction(PropertyContainer p) {
    String ctaText = 'AUTHORIZE PAYMENT 💳';
    if (_method == 'FIAT_WALLET') {
      ctaText = 'PAY WITH FIAT WALLET ⚡';
    } else if (_method == 'NCX_COINS') {
      ctaText = 'PAY ${(p.financial.unlockCost / 100).round()} NCX COINS ⚡';
    }

    return GestureDetector(
      onTap: () => _processPayment(p),
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          color: C.brand,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: C.brand.withValues(alpha: .2),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Center(
          child: Text(
            ctaText,
            style: syne(sz: 15, w: FontWeight.bold, c: Colors.black),
          ),
        ),
      ),
    );
  }

  Future<void> _processPayment(PropertyContainer p) async {
    final isEscrowMode = widget.state.currentEscrowInitiation != null;
    final requiresPhone = _method == 'MTN_MOMO' || _method == 'AIRTEL_MONEY';
    if (requiresPhone && _phoneCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your Uganda phone number for Mobile Money.')),
      );
      return;
    }

    // Balance checks for instant wallet debits
    if (_method == 'FIAT_WALLET' && !isEscrowMode) {
      if (_fiatBalance < p.financial.unlockCost) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Insufficient Fiat Wallet balance (UGX ${ugx(_fiatBalance.toInt())}). Please choose Mobile Money or top up.',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }
    } else if (_method == 'NCX_COINS' && !isEscrowMode) {
      final coinCost = (p.financial.unlockCost / 100).round();
      if (_coinBalance < coinCost) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Insufficient NCX Coins ($_coinBalance available, $coinCost required). Please choose another payment method.',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }
    }

    setState(() => _stage = PaymentStage.processing);
    _startPulse();

    try {
      final user = widget.state.user;
      if (user == null) throw Exception('User not authenticated. Please log in.');

      if (isEscrowMode) {
        // ── ESCROW FCFS FLOW ──────────────────────────────────────────────
        final escrow = widget.state.currentEscrowInitiation!;
        final escrowResId = escrow['escrow_id']?.toString() ?? '';
        final depositAmount = (escrow['deposit_amount'] as num?)?.toDouble() ??
            p.financial.escrowDeposit.toDouble();

        final initiateRes = await _paymentService.initiateEscrowPayment(
          listingId: p.core.id,
          escrowReservationId: escrowResId,
          depositAmount: depositAmount,
          buyerId: user.id,
          buyerEmail: user.email ?? '',
        );

        final redirectUrl = initiateRes['redirectUrl'];
        if (redirectUrl != null) {
          final uri = Uri.parse(redirectUrl);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } else {
            throw Exception('Could not open checkout page.');
          }
        }

        final won = await _paymentService.pollForEscrowCompletion(
          initiateRes['paymentId'],
        );

        if (won) {
          widget.state.currentEscrowInitiation = null;
          await widget.state.loadProperties();
          setState(() => _stage = PaymentStage.success);
        } else {
          throw Exception('Payment timed out. Please check your wallet.');
        }
      } else {
        // ── UNLOCK CONTACT INFO FLOW ──────────────────────────────────────
        final initiateRes = await _paymentService.initiateUnlock(
          listingId: p.core.id,
          method: _method,
          amount: _method == 'NCX_COINS'
              ? (p.financial.unlockCost / 100).roundToDouble()
              : p.financial.unlockCost.toDouble(),
          buyerId: user.id,
          buyerEmail: user.email ?? '',
          phone: requiresPhone ? _phoneCtrl.text.trim() : null,
        );

        bool success = false;
        if (_method == 'FIAT_WALLET' || _method == 'NCX_COINS') {
          // In-app wallet payments are authorized and completed synchronously by finance-engine
          success = initiateRes['success'] == true;
        } else {
          // External Pesapal path (MTN, Airtel, Card)
          final redirectUrl = initiateRes['redirectUrl'];
          if (redirectUrl != null) {
            final uri = Uri.parse(redirectUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          }
          final paymentId = initiateRes['paymentId'];
          if (paymentId == null) throw Exception('No payment tracking ID received.');
          success = await _paymentService.pollForPaymentCompletion(paymentId);
        }

        if (success) {
          await widget.state.markPropertyUnlockedAfterPayment(p.core.id);
          setState(() => _stage = PaymentStage.success);
        } else {
          throw Exception('Payment verification could not be confirmed.');
        }
      }
    } catch (e) {
      setState(() {
        _stage = PaymentStage.error;
        _errMsg = getUserFriendlyError(e);
      });
    } finally {
      _stopPulse();
    }
  }
}

class _UnlockRow extends StatelessWidget {
  final String icon, label;
  const _UnlockRow({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 12),
          Text(label, style: dm(sz: 13, c: C.sub)),
        ],
      ),
    );
  }
}

class _RevealedItem extends StatelessWidget {
  final IconData icon;
  final String label;
  const _RevealedItem(this.icon, this.label);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: C.green, size: 18),
          const SizedBox(width: 12),
          Text(label, style: dm(sz: 14, w: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _MethodTile extends StatelessWidget {
  final String id, label, icon, sub;
  final bool selected;
  final String? badge;
  final Color? badgeColor;
  final VoidCallback onTap;
  const _MethodTile({
    required this.id,
    required this.label,
    required this.icon,
    required this.sub,
    required this.selected,
    this.badge,
    this.badgeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? C.brand.withValues(alpha: .06) : C.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? C.brand : C.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(label, style: dm(sz: 14, w: FontWeight.bold)),
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (badgeColor ?? C.brand).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge!,
                            style: dm(sz: 8, w: FontWeight.bold, c: badgeColor ?? C.brand),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(sub, style: dm(sz: 11, c: C.dim)),
                ],
              ),
            ),
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? C.brand : C.dim,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
