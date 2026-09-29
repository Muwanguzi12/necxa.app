import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../services/coin_liquidation_service.dart';
import 'dart:ui';
import 'dart:async';

class VaultSellShardsOverlay extends StatefulWidget {
  final AppState state;
  VaultSellShardsOverlay({super.key, required this.state});

  @override
  State<VaultSellShardsOverlay> createState() => _VaultSellShardsOverlayState();
}

class _VaultSellShardsOverlayState extends State<VaultSellShardsOverlay> {
  int _stage = 1; // 1: Synthesis, 2: Safe Sign, 3: Bridge, 4: Success
  double _sellAmount = 100;
  double _progress = 0;
  Timer? _timer;
  Timer? _quoteDebounce;
  String? _txHash;
  LiquidationResult? _result;
  LiquidationQuote? _quote;
  bool _isFetchingQuote = false;

  @override
  void initState() {
    super.initState();
    // Prevent Slider assertion error: value must be <= max
    double safeMax = widget.state.shardBalance < 10
        ? 11
        : widget.state.shardBalance;
    if (_sellAmount > safeMax) {
      _sellAmount = safeMax;
    }
    if (_sellAmount < 10) {
      _sellAmount = 10;
    }
    _fetchQuote();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: Color(0xFF070a0f),
        borderRadius: BorderRadius.vertical(top: Radius.circular(40)),
        border: Border(top: BorderSide(color: Colors.yellow, width: 0.5)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(top: Radius.circular(40)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
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
      padding: EdgeInsets.all(28),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.dim)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sell NCX Coins',
                style: syne(sz: 18, w: FontWeight.w700, c: Colors.yellow),
              ),
              Text(
                'Step $_stage of 4',
                style: dm(sz: 11, c: Colors.yellow.withOpacity(.4)),
              ),
            ],
          ),
          IconButton(
            icon: Icon(Icons.close, color: C.dim),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildStageContent() {
    switch (_stage) {
      case 1:
        return _buildSynthesisStage();
      case 2:
        return _buildSafeSignStage();
      case 3:
        return _buildBridgeStage();
      case 4:
        return _buildSuccessStage();
      default:
        return SizedBox();
    }
  }

  void _fetchQuote() {
    _quoteDebounce?.cancel();
    _quoteDebounce = Timer(Duration(milliseconds: 500), () async {
      setState(() => _isFetchingQuote = true);
      try {
        final q = await widget.state.liquidation.getQuote(_sellAmount);
        if (mounted) setState(() => _quote = q);
      } catch (e) {
        debugPrint('Quote error: $e');
      }
      if (mounted) setState(() => _isFetchingQuote = false);
    });
  }

  // -- STAGE 1: LIQUIDATION SYNTHESIS ----------------------
  Widget _buildSynthesisStage() {
    return Padding(
      padding: EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_quote != null)
            _HandshakeMath(
              fee: _quote!.ncxBurned.toInt(),
              injection: _quote!.ugxReceived.toInt(),
              burnPercent: _quote!.burnPercentage,
            )
          else
            SizedBox(
              height: 80,
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.yellow,
                ),
              ),
            ),
          SizedBox(height: 48),
          Text(
            'How many coins to sell',
            style: dm(sz: 12, w: FontWeight.w600, c: C.dim),
          ),
          SizedBox(height: 20),
          _ShardSlider(
            value: _sellAmount,
            max: widget.state.shardBalance < 10
                ? 10
                : widget.state.shardBalance,
            onChanged: (v) {
              setState(() => _sellAmount = v);
              _fetchQuote();
            },
          ),
          Spacer(),
          _BottomBtn(
            label: _isFetchingQuote ? 'SYNCING...' : 'CONFIRM SALE',
            icon: Icons.arrow_forward,
            color: C.text,
            onTap: _isFetchingQuote ? null : () => setState(() => _stage = 2),
          ),
        ],
      ),
    );
  }

  // -- STAGE 2: SAFE SIGN ----------------------------------
  Widget _buildSafeSignStage() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const _NodeBadge(label: 'Verify your identity', color: Colors.yellow),
        SizedBox(height: 60),
        _BiometricNode(onSuccess: () => _handleSafeSign()),
        SizedBox(height: 40),
        Text(
          'Press & hold to confirm',
          style: dm(sz: 12, w: FontWeight.w600, c: C.dim),
        ),
      ],
    );
  }

  Future<void> _handleSafeSign() async {
    final authenticated = await widget.state.verifyBiometrics();
    if (authenticated) {
      _startBridge();
    } else {
      // Re-prompt or show error
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Biometric verification cancelled')),
      );
    }
  }

  void _startBridge() {
    setState(() => _stage = 3);
    _timer = Timer.periodic(Duration(milliseconds: 40), (t) {
      if (mounted) {
        setState(() {
          _progress += 0.02;
          if (_progress >= 1.0) {
            _timer?.cancel();
            _finalizeSale();
          }
        });
      }
    });
  }

  void _finalizeSale() async {
    try {
      final securityMetadata = await widget.state.getFullSecurityMetadata();

      final res = await widget.state.liquidation.liquidate(
        userId: widget.state.user!.id,
        ncxAmount: _sellAmount,
        securityMetadata: securityMetadata,
      );

      _result = res;
      _txHash = res.txCommitHash;
      await widget.state.syncVault();

      if (mounted) setState(() => _stage = 4);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Liquidation Error: $e')));
      setState(() => _stage = 1);
    }
  }

  // -- STAGE 3: ATOMIC BRIDGE ------------------------------
  Widget _buildBridgeStage() {
    final statuses = [
      'Confirming sale',
      'Transferring funds',
      'Adding UGX to balance',
    ];
    final idx = ((_progress * 2.9).floor()).clamp(0, 2);
    // Use the hash if available, otherwise a placeholder
    final displayHash =
        _txHash ??
        'TX_COMMIT_0x${(DateTime.now().millisecondsSinceEpoch ~/ 1000).toRadixString(16).toUpperCase()}';

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const _NodeBadge(
          label: 'Processing your sale',
          color: Colors.blueAccent,
        ),
        SizedBox(height: 60),
        _DissolveCore(progress: _progress),
        SizedBox(height: 48),
        Text(
          statuses[idx],
          style: dm(sz: 13, w: FontWeight.w600, c: Colors.blueAccent),
        ),
        Spacer(),
        _HashProtocol(hash: displayHash),
        SizedBox(height: 60),
      ],
    );
  }

  // -- STAGE 4: ASSET SOLD ---------------------------------
  Widget _buildSuccessStage() {
    final received =
        _result?.ugxReceived.toInt() ?? (_sellAmount * 0.5).toInt();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _SuccessHalo(),
        SizedBox(height: 32),
        Text(
          'Sold!',
          style: syne(sz: 28, w: FontWeight.w700, c: C.text),
        ),
        SizedBox(height: 24),
        _ArmorBoundConfirmation(amt: received.toString()),
        Spacer(),
        _BottomBtn(
          label: 'Done',
          icon: Icons.sync,
          color: C.text,
          onTap: () => Navigator.pop(context),
        ),
        SizedBox(height: 60),
      ],
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// -- WIDGETS ----------------------------------------------

class _HandshakeMath extends StatelessWidget {
  final int fee, injection, burnPercent;
  const _HandshakeMath({
    required this.fee,
    required this.injection,
    required this.burnPercent,
  });
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _MathPane(
          label: 'Fee',
          val: '-$fee NCX',
          icon: Icons.whatshot,
          color: Colors.redAccent,
          sub: '$burnPercent% of coins',
        ),
      ),
      SizedBox(width: 12),
      Expanded(
        child: _MathPane(
          label: 'You receive',
          val: 'UGX $injection',
          icon: Icons.bolt,
          color: Colors.blueAccent,
          sub: 'To your balance',
        ),
      ),
    ],
  );
}

class _MathPane extends StatelessWidget {
  final String label, val, sub;
  final IconData icon;
  final Color color;
  const _MathPane({
    required this.label,
    required this.val,
    required this.icon,
    required this.color,
    required this.sub,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: color.withOpacity(.05),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(.1)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 12),
            SizedBox(width: 8),
            Text(
              label,
              style: dm(sz: 8, w: FontWeight.w900, ls: 1, c: color),
            ),
          ],
        ),
        SizedBox(height: 12),
        Text(val, style: syne(sz: 16, w: FontWeight.w900)),
        SizedBox(height: 4),
        Text(sub, style: dm(sz: 8, c: C.dim)),
      ],
    ),
  );
}

class _ShardSlider extends StatelessWidget {
  final double value, max;
  final ValueChanged<double> onChanged;
  const _ShardSlider({
    required this.value,
    required this.max,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '${value.toInt()} coins',
            style: syne(sz: 24, w: FontWeight.w700, c: Colors.yellow),
          ),
          Text('Max: ${max.toInt()}', style: dm(sz: 11, c: C.dim)),
        ],
      ),
      SizedBox(height: 12),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: Colors.yellow,
          inactiveTrackColor: C.dim,
          thumbColor: C.text,
          trackHeight: 8,
        ),
        child: Slider(
          value: value,
          min: 10,
          max: max > 10 ? max : 11,
          onChanged: onChanged,
        ),
      ),
    ],
  );
}

class _BiometricNode extends StatefulWidget {
  final VoidCallback onSuccess;
  const _BiometricNode({required this.onSuccess});
  @override
  State<_BiometricNode> createState() => _BiometricNodeState();
}

class _BiometricNodeState extends State<_BiometricNode> {
  double _p = 0;
  Timer? _t;
  void _start() {
    _t = Timer.periodic(Duration(milliseconds: 20), (t) {
      setState(() {
        _p += 0.02;
        if (_p >= 1) {
          _t?.cancel();
          widget.onSuccess();
        }
      });
    });
  }

  void _stop() {
    _t?.cancel();
    setState(() => _p = 0);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTapDown: (_) => _start(),
    onTapUp: (_) => _stop(),
    onTapCancel: _stop,
    child: Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(
          width: 140,
          height: 140,
          child: CircularProgressIndicator(
            value: _p,
            strokeWidth: 4,
            color: Colors.yellow,
            backgroundColor: C.dim,
          ),
        ),
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: Colors.yellow.withOpacity(.1),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.fingerprint, color: Colors.yellow, size: 48),
        ),
      ],
    ),
  );
}

class _DissolveCore extends StatelessWidget {
  final double progress;
  const _DissolveCore({required this.progress});
  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      Container(
        width: 140,
        height: 140,
        decoration: BoxDecoration(
          color: C.text.withOpacity(.02),
          shape: BoxShape.circle,
          border: Border.all(color: C.dim),
        ),
      ),
      Icon(
        Icons.toll,
        color: Colors.yellow.withOpacity(1 - progress),
        size: 56,
      ),
      Positioned(
        bottom: 20 * progress,
        child: Opacity(
          opacity: progress,
          child: Icon(
            Icons.water_drop,
            color: Colors.blueAccent,
            size: 16,
          ),
        ),
      ),
    ],
  );
}

class _SuccessHalo extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(40),
    decoration: BoxDecoration(
      color: Colors.blueAccent.withOpacity(.1),
      shape: BoxShape.circle,
    ),
    child: Icon(Icons.bolt, color: Colors.blueAccent, size: 80),
  );
}

class _ArmorBoundConfirmation extends StatelessWidget {
  final String amt;
  const _ArmorBoundConfirmation({required this.amt});
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(28),
    decoration: BoxDecoration(
      color: C.text.withOpacity(.02),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: C.text.withOpacity(.05)),
    ),
    child: Column(
      children: [
        Text(
          'Sale complete',
          style: dm(sz: 11, w: FontWeight.w600, c: C.dim),
        ),
        SizedBox(height: 16),
        Text(
          'UGX $amt',
          style: syne(
            sz: 32,
            w: FontWeight.w700,
            fs: FontStyle.italic,
            c: Colors.blueAccent,
          ),
        ),
        SizedBox(height: 16),
        Text('Added to your balance', style: dm(sz: 11, c: C.dim)),
      ],
    ),
  );
}

class _NodeBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _NodeBadge({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    decoration: BoxDecoration(
      color: color.withOpacity(.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(.2)),
    ),
    child: Text(
      label,
      style: dm(sz: 11, w: FontWeight.w600, c: color),
    ),
  );
}

class _HashProtocol extends StatelessWidget {
  final String hash;
  const _HashProtocol({required this.hash});
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.black,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      hash,
      style: dm(sz: 9, w: FontWeight.w700, c: Colors.blueAccent),
    ),
  );
}

class _BottomBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  const _BottomBtn({
    required this.label,
    required this.icon,
    required this.color,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedOpacity(
      duration: Duration(milliseconds: 200),
      opacity: onTap == null ? 0.3 : 1.0,
      child: Container(
        height: 64,
        width: double.infinity,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: color == C.text ? Colors.black : C.text,
              size: 20,
            ),
            SizedBox(width: 12),
            Text(
              label,
              style: syne(
                sz: 15,
                w: FontWeight.w700,
                c: color == C.text ? Colors.black : C.text,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}



