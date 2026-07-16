import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import 'dart:ui';
import 'dart:async';
import 'package:url_launcher/url_launcher_string.dart';
import '../services/finance_backend.dart';

class VaultBuyShardsOverlay extends StatefulWidget {
  final AppState state;
  const VaultBuyShardsOverlay({super.key, required this.state});

  @override
  State<VaultBuyShardsOverlay> createState() => _VaultBuyShardsOverlayState();
}

class _VaultBuyShardsOverlayState extends State<VaultBuyShardsOverlay> {
  int _stage = 1; // 1: Selection, 2: Transit, 3: Synthesis, 4: Success
  String? _selectedPackId; 
  String _selectedPaymentMethod = 'fiat_balance';
  String? _idempotencyKey;
  int _yield = 0;
  Timer? _yieldTimer;

  @override
  void initState() {
    super.initState();
    if (widget.state.coinPacks.isNotEmpty) {
      _selectedPackId = widget.state.coinPacks.first['id'].toString();
    }
  }

  @override
  void dispose() {
    _yieldTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Color(0xFF05080c), // Dark Blue Base
        borderRadius: BorderRadius.vertical(top: Radius.circular(40)),
        border: Border(top: BorderSide(color: Colors.blueAccent, width: 0.5)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Column(
            children: [
              _buildHeader(),
              Expanded(child: _buildStageContent()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white10))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Buy NCX Coins', style: syne(sz: 18, w: FontWeight.w700, c: Colors.cyanAccent)),
              Text('Step $_stage of 4', style: dm(sz: 11, c: Colors.cyanAccent.withOpacity(.4))),
            ],
          ),
          IconButton(icon: const Icon(Icons.close, color: Colors.white38), onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
  }

  Widget _buildStageContent() {
    switch (_stage) {
      case 1: return _buildSelectionStage();
      case 2: return _buildTransitStage();
      case 3: return _buildSynthesisStage();
      case 4: return _buildSuccessStage();
      default: return const SizedBox();
    }
  }

  // ── STAGE 1: SELECTION ────────────────────────────────
  Widget _buildSelectionStage() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Choose a pack', style: dm(sz: 12, w: FontWeight.w600, c: Colors.white38)),
          const SizedBox(height: 20),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              mainAxisSpacing: 16, crossAxisSpacing: 16,
              childAspectRatio: 0.85,
              children: widget.state.coinPacks.map((p) => _ShardCard(
                data: p,
                active: _selectedPackId == p['id'].toString(),
                onTap: () => setState(() => _selectedPackId = p['id'].toString()),
              )).toList(),
            ),
          ),
          _BottomBtn(label: 'Pay with...', icon: Icons.arrow_forward_ios, color: Colors.blueAccent, onTap: () => setState(() => _stage = 2)),
        ],
      ),
    );
  }

  // ── STAGE 2: TRANSIT ──────────────────────────────────
  Widget _buildTransitStage() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pay with', style: dm(sz: 12, w: FontWeight.w600, c: Colors.white38)),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () => setState(() => _selectedPaymentMethod = 'fiat_balance'),
            child: _TransitRailNode(label: 'Vault Balance', category: 'Instant', icon: Icons.account_balance_wallet, status: _selectedPaymentMethod == 'fiat_balance' ? 'Selected' : 'Ready'),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => setState(() => _selectedPaymentMethod = 'card'),
            child: _TransitRailNode(label: 'Card via Pesapal', category: 'External', icon: Icons.credit_card, status: _selectedPaymentMethod == 'card' ? 'Selected' : 'Ready'),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => setState(() => _selectedPaymentMethod = 'mtn'),
            child: _TransitRailNode(label: 'MTN MoMo via Pesapal', category: 'Mobile', icon: Icons.phone_android, status: _selectedPaymentMethod == 'mtn' ? 'Selected' : 'Ready'),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => setState(() => _selectedPaymentMethod = 'airtel'),
            child: _TransitRailNode(label: 'Airtel Money via Pesapal', category: 'Mobile', icon: Icons.phone_android, status: _selectedPaymentMethod == 'airtel' ? 'Selected' : 'Ready'),
          ),
          const Spacer(),
          _BottomBtn(label: 'Buy Now', icon: Icons.bolt, color: Colors.cyanAccent, onTap: () => _startSynthesis()),
        ],
      ),
    );
  }

  void _startSynthesis() async {
    setState(() => _stage = 3);
    _yieldTimer = Timer.periodic(const Duration(milliseconds: 30), (t) {
      if (mounted) {
        setState(() {
        _yield += 2;
        if (_yield >= 100) {
          _yieldTimer?.cancel();
          _finalizeSynthesis();
        }
      });
      }
    });
  }

  void _finalizeSynthesis() async {
    if (_selectedPackId == null) return;
    try {
      _idempotencyKey ??= 'coin-purchase-${DateTime.now().microsecondsSinceEpoch}';
      final result = await widget.state.buyShards(
        _selectedPackId!,
        method: _selectedPaymentMethod,
        idempotencyKey: _idempotencyKey!,
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
      if (mounted) setState(() => _stage = 4);
    } catch (e) {
      if (e is FinanceBackendException &&
          (e.code == 'payment_final' || e.code == 'payment_initialization_failed')) {
        _idempotencyKey = null;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
        setState(() => _stage = 2); // Go back on failure
      }
    }
  }

  // ── STAGE 3: SYNTHESIS ────────────────────────────────
  Widget _buildSynthesisStage() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _SynthesisPulse(),
        const SizedBox(height: 48),
        Text('Processing: $_yield%', style: syne(sz: 24, w: FontWeight.w700, c: Colors.cyanAccent)),
        const SizedBox(height: 12),
        Text('Adding coins to your wallet...', style: dm(sz: 12, c: Colors.white38)),
        const Spacer(),
        _YieldBar(progress: _yield / 100),
        const SizedBox(height: 60),
      ],
    );
  }

  // ── STAGE 4: SUCCESS ──────────────────────────────────
  Widget _buildSuccessStage() {
    final pack = widget.state.coinPacks.firstWhere((p) => p['id'] == _selectedPackId, orElse: () => widget.state.coinPacks.first);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SuccessHalo(),
          const SizedBox(height: 32),
          Text('Coins added!', style: syne(sz: 28, w: FontWeight.w700, c: Colors.white)),
          const SizedBox(height: 24),
          _ConversionCard(coins: (pack['ncx_amount'] ?? 0).toString()),
          const SizedBox(height: 60),
          _BottomBtn(label: 'Done', icon: Icons.sync, color: Colors.white, onTap: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}

// ── WIDGETS ──────────────────────────────────────────────

class _ShardCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool active;
  final VoidCallback onTap;
  const _ShardCard({required this.data, required this.active, required this.onTap});

  Color _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return Colors.blueAccent;
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return Colors.blueAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(data['color_hex']);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(.15) : Colors.white.withOpacity(.02),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: active ? color : Colors.white.withOpacity(.05), width: active ? 2 : 1),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: color.withOpacity(.2), borderRadius: BorderRadius.circular(10)), child: Icon(Icons.toll, color: color, size: 16)),
              if (active) Icon(Icons.check_circle_rounded, color: color, size: 16),
            ]),
            const Spacer(),
            Text((data['ncx_amount'] ?? 0).toInt().toString(), style: syne(sz: 32, w: FontWeight.w900, fs: FontStyle.italic)),
            const SizedBox(height: 4),
            Text('SHARDS', style: dm(sz: 11, w: FontWeight.w600, c: Colors.white38)),
            const Spacer(),
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)), child: Text('UGX ${(data['fiat_price'] ?? 0).toInt()}', style: dm(sz: 10, w: FontWeight.w700, c: Colors.white70))),
          ],
        ),
      ),
    );
  }
}

class _TransitRailNode extends StatelessWidget {
  final String label, category, status;
  final IconData icon;
  const _TransitRailNode({required this.label, required this.category, required this.icon, required this.status});
  @override
  Widget build(BuildContext context) {
    final isSelected = status == 'Selected';
    return Container(
      padding: const EdgeInsets.all(20), 
      decoration: BoxDecoration(
        color: isSelected ? Colors.blueAccent.withOpacity(.15) : Colors.white.withOpacity(.03), 
        borderRadius: BorderRadius.circular(20), 
        border: Border.all(color: isSelected ? Colors.blueAccent : Colors.white.withOpacity(.05))
      ), 
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12), 
            decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(.1), borderRadius: BorderRadius.circular(14)), 
            child: Icon(icon, color: Colors.blueAccent, size: 20)
          ), 
          const SizedBox(width: 16), 
          Column(
            crossAxisAlignment: CrossAxisAlignment.start, 
            children: [
              Text(label, style: syne(sz: 14, w: FontWeight.w800)), 
              Row(
                children: [
                  Container(width: 6, height: 6, decoration: BoxDecoration(color: isSelected ? Colors.green : Colors.grey, shape: BoxShape.circle)), 
                  const SizedBox(width: 6), 
                  Text('Rail Connection: $status', style: dm(sz: 10, c: Colors.white38)), 
                  const SizedBox(width: 8), 
                  Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)), child: Text(category, style: dm(sz: 7, w: FontWeight.w800, c: Colors.white38)))
                ]
              )
            ]
          ), 
          const Spacer(), 
          if (isSelected) const Icon(Icons.check_circle, color: Colors.blueAccent) else const Icon(Icons.chevron_right, color: Colors.white24)
        ]
      )
    );
  }
}

class _SynthesisPulse extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(width: 120, height: 120, decoration: BoxDecoration(color: Colors.cyanAccent.withOpacity(.05), shape: BoxShape.circle, border: Border.all(color: Colors.cyanAccent.withOpacity(.2)), boxShadow: [BoxShadow(color: Colors.cyanAccent.withOpacity(.1), blurRadius: 40)]), child: const Center(child: Icon(Icons.bolt_outlined, color: Colors.cyanAccent, size: 56)));
}

class _YieldBar extends StatelessWidget {
  final double progress;
  const _YieldBar({required this.progress});
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.symmetric(horizontal: 40), child: Container(height: 2, width: double.infinity, decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(1)), child: LinearProgressIndicator(value: progress, backgroundColor: Colors.transparent, color: Colors.cyanAccent)));
}

class _SuccessHalo extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(32), decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(.1), shape: BoxShape.circle), child: const Icon(Icons.check_circle_outline, color: Colors.blueAccent, size: 72));
}

class _ConversionCard extends StatelessWidget {
  final String coins;
  const _ConversionCard({required this.coins});
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(28), decoration: BoxDecoration(color: Colors.white.withOpacity(.02), borderRadius: BorderRadius.circular(28), border: Border.all(color: Colors.white.withOpacity(.05))), child: Column(children: [Text('Purchase complete', style: dm(sz: 11, w: FontWeight.w600, c: Colors.white38)), const SizedBox(height: 16), Text('$coins NCX Coins', style: syne(sz: 32, w: FontWeight.w700, fs: FontStyle.italic, c: Colors.cyanAccent)), const SizedBox(height: 16), Text('Added to your wallet', style: dm(sz: 11, c: Colors.white24))]));
}

class _BottomBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _BottomBtn({required this.label, required this.icon, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(onTap: onTap, child: Container(height: 64, width: double.infinity, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: color == Colors.white ? Colors.black : Colors.white, size: 20), const SizedBox(width: 12), Text(label, style: syne(sz: 15, w: FontWeight.w700, c: color == Colors.white ? Colors.black : Colors.white))])));
}
