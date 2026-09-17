import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import 'dart:ui';
import 'dart:async';

class VaultWithdrawOverlay extends StatefulWidget {
  final AppState state;
  const VaultWithdrawOverlay({super.key, required this.state});

  @override
  State<VaultWithdrawOverlay> createState() => _VaultWithdrawOverlayState();
}

class _VaultWithdrawOverlayState extends State<VaultWithdrawOverlay> {
  int _stage = 1; // 1: Bio-Shield, 2: Amount, 3: Destination, 4: Account, 5: Verification, 6: Pulse, 7: Success
  double _scanProgress = 0.0;
  Timer? _scanTimer;
  Timer? _statusTimer;
  String? _withdrawalId;
  String? _idempotencyKey;
  String _withdrawalStatus = 'initiated';
  String _selectedAmount = '10,000';
  String _selectedMethod = 'mtn'; // Default method
  String _statusText = 'Signing Intent';
  final TextEditingController _accountController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _totpController = TextEditingController();
  final TextEditingController _emailOtpController = TextEditingController();
  bool _sendingEmail = false;

  @override
  void initState() {
    super.initState();
    _initData();
    widget.state.checkSecurityStatus();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _statusTimer?.cancel();
    _accountController.dispose();
    _nameController.dispose();
    _totpController.dispose();
    _emailOtpController.dispose();
    super.dispose();
  }

  void _initData() {
    // Already handled by initState calling checkSecurityStatus
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.redAccent,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Color(0xFF0d0505), // Dark Crimson Base
        borderRadius: BorderRadius.vertical(top: Radius.circular(40)),
        border: Border(top: BorderSide(color: Colors.redAccent, width: 0.5)),
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
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.dim))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Withdraw Money', style: syne(sz: 18, w: FontWeight.w700, c: Colors.redAccent)),
              Text('Step $_stage of 7', style: dm(sz: 11, c: Colors.redAccent.withOpacity(.4))),
            ],
          ),
          IconButton(icon: Icon(Icons.close, color: C.dim), onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
  }

  Widget _buildStageContent() {
    switch (_stage) {
      case 1: return _buildBioShield();
      case 2: return _buildAmountStage();
      case 3: return _buildDestinationStage();
      case 4: return _buildAccountStage();
      case 5: return _buildVerificationStage();
      case 6: return _buildPulseStage();
      case 7: return _buildSuccessStage();
      default: return const SizedBox();
    }
  }

  // -- STAGE 1: BIO-SHIELD --------------------------------
  Widget _buildBioShield() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ScannerBadge(),
          const SizedBox(height: 60),
          _FingerprintNode(
            progress: _scanProgress,
            onPressed: () => _startScan(),
            onReleased: () => _cancelScan(),
          ),
          const SizedBox(height: 40),
          Text('Verify it\'s you', style: syne(sz: 16, w: FontWeight.w700, c: C.text)),
          const SizedBox(height: 12),
          Text('Press and hold to authorize extraction.', style: dm(sz: 12, c: C.dim)),
        ],
      ),
    );
  }

  void _startScan() async {
    _scanTimer = Timer.periodic(const Duration(milliseconds: 20), (t) {
      if (mounted) setState(() => _scanProgress += 0.02);
      if (_scanProgress >= 0.8 && _scanTimer != null) {
        _scanTimer?.cancel(); _scanTimer = null;
        _doRealVerify();
      }
    });
  }

  void _doRealVerify() async {
    final success = await widget.state.verifyBiometrics();
    if (success) {
      setState(() { _scanProgress = 1.0; _stage = 2; });
    } else {
      _cancelScan();
    }
  }

  void _cancelScan() {
    _scanTimer?.cancel(); _scanTimer = null;
    if (mounted) setState(() => _scanProgress = 0.0);
  }

  // -- STAGE 2: EXTRACTION SYNTHESIS ----------------------
  Widget _buildAmountStage() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BalanceGuard(balance: widget.state.fiatBalance),
          const SizedBox(height: 40),
          Text('Choose amount', style: dm(sz: 12, w: FontWeight.w600, c: Colors.redAccent.withOpacity(.6))),
          const SizedBox(height: 16),
          _AmountGrid(
            selected: _selectedAmount,
            currentRate: widget.state.currentForexRate,
            onSelect: (s) => setState(() => _selectedAmount = s),
          ),
          const Spacer(),
          _BottomBtn(
            label: 'Continue', 
            icon: Icons.north, 
            onTap: () {
              final amt = double.parse(_selectedAmount.replaceAll(',', ''));
              final limit = widget.state.currentForexRate * 1000;
              if (amt > limit) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('AML Limit: Maximum withdrawal is UGX ${limit.toInt().toString()} (\$1,000) based on live rates.'))
                );
                return;
              }
              setState(() => _stage = 3);
            }
          ),
        ],
      ),
    );
  }

  // -- STAGE 3: TRANSIT NODES ----------------------------
  Widget _buildDestinationStage() {
    final methods = widget.state.paymentMethods
        .where((m) => m['type'] == 'both' || m['type'] == 'disbursement')
        .toList();

    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Send to', style: dm(sz: 12, w: FontWeight.w600, c: Colors.redAccent.withOpacity(.6))),
          const SizedBox(height: 24),
          if (methods.isEmpty)
             Center(child: Text('No payout methods available.', style: dm(sz: 14, c: C.dim)))
          else
            ...methods.map((m) {
              final isSelected = _selectedMethod == m['id'];
              final isActive = m['status'] == 'active';
              final label = m['name'] ?? m['id'];
              
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: GestureDetector(
                  onTap: !isActive ? null : () => setState(() => _selectedMethod = m['id']),
                  child: Opacity(
                    opacity: isActive ? 1.0 : 0.5,
                    child: _TransitTile(
                      label: label, 
                      status: !isActive ? 'Maintenance' : (isSelected ? 'Selected' : 'Active'), 
                      icon: m['id'] == 'card' ? Icons.account_balance_wallet : Icons.phone_android, 
                      color: m['id'] == 'mtn' ? Color(0xFFeab308) : (m['id'] == 'airtel' ? Colors.red : C.sub)
                    ),
                  ),
                ),
              );
            }),
          const Spacer(),
          _BottomBtn(
            label: 'Next', 
            icon: Icons.chevron_right, 
            onTap: () {
              // Ensure selected method is still active
              final current = methods.firstWhere((m) => m['id'] == _selectedMethod, orElse: () => {});
              if (current['status'] != 'active') {
                _showError('This method is currently unavailable.');
                return;
              }
              setState(() => _stage = 4);
            }
          ),
        ],
      ),
    );
  }

  // -- STAGE 4: ACCOUNT IDENTIFICATION ------------------
  Widget _buildAccountStage() {
    String hint = _selectedMethod == 'card' ? 'Card / Bank Account Number' : 'Phone Number (e.g. 077xxxxxxx)';
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Account details', style: dm(sz: 12, w: FontWeight.w600, c: Colors.redAccent.withOpacity(.6))),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: C.text.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: C.dim),
            ),
            child: TextField(
              controller: _accountController,
              keyboardType: TextInputType.phone,
              style: syne(sz: 18, w: FontWeight.w600, c: C.text),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                hintStyle: dm(sz: 14, c: C.dim),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Recipient Name', style: dm(sz: 12, w: FontWeight.w600, c: Colors.redAccent.withOpacity(.6))),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: C.text.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: C.dim),
            ),
            child: TextField(
              controller: _nameController,
              style: syne(sz: 16, w: FontWeight.w600, c: C.text),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'Full Legal Name',
                hintStyle: dm(sz: 14, c: C.dim),
              ),
            ),
          ),
          const Spacer(),
          _BottomBtn(
            label: 'Next', 
            icon: Icons.chevron_right, 
            onTap: () async {
              if (_accountController.text.length < 5 || _nameController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter valid account and name.')));
                return;
              }
              // Request Email OTP when moving to verification
              setState(() => _sendingEmail = true);
              try {
                final amount = double.parse(_selectedAmount.replaceAll(',', '')).round();
                await widget.state.financeWithdrawals.eligibility(amount);
                await widget.state.financeWithdrawals.sendOtp();
                if (!mounted) return;
                setState(() => _stage = 5);
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Email error: $e')));
              }
              setState(() => _sendingEmail = false);
            }
          ),
        ],
      ),
    );
  }

  // -- STAGE 5: MULTI-FACTOR VERIFICATION ---------------
  Widget _buildVerificationStage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Security Verification', style: syne(sz: 18, w: FontWeight.w700, c: C.text)),
          const SizedBox(height: 8),
          Text('We sent a six-digit verification code to your email address.', style: dm(sz: 12, c: C.dim)),
          
          const SizedBox(height: 32),
          
          // Email OTP
          Text('EMAIL VERIFICATION CODE', style: dm(sz: 11, w: FontWeight.w900, c: Colors.redAccent, ls: 1)),
          const SizedBox(height: 12),
          _SecureInput(
            controller: _emailOtpController,
            hint: 'Enter 6-digit code',
            icon: Icons.email,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _sendingEmail ? null : () async {
              setState(() => _sendingEmail = true);
              try {
                await widget.state.financeWithdrawals.sendOtp();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('A new verification code was sent.')),
                );
              } catch (error) {
                if (mounted) _showError('Could not send a new code: $error');
              } finally {
                if (mounted) setState(() => _sendingEmail = false);
              }
            },
            child: Text(_sendingEmail ? 'Sending...' : 'Resend Code', style: dm(sz: 12, c: Colors.redAccent)),
          ),

          const SizedBox(height: 24),

          // TOTP (Only if enabled)
          if (widget.state.is2faEnabled) ...[
            Text('GOOGLE AUTHENTICATOR CODE', style: dm(sz: 11, w: FontWeight.w900, c: Colors.blueAccent, ls: 1)),
            const SizedBox(height: 12),
            _SecureInput(
              controller: _totpController,
              hint: '6-digit 2FA code',
              icon: Icons.security,
              color: Colors.blueAccent,
            ),
            const SizedBox(height: 24),
          ],

          const SizedBox(height: 40),
          _BottomBtn(
            label: 'Finalize Extraction', 
            icon: Icons.vpn_key, 
            onTap: () {
              if (_emailOtpController.text.length < 6) {
                _showError('Please enter the 6-digit email code.');
                return;
              }
              if (widget.state.is2faEnabled && _totpController.text.length < 6) {
                _showError('Please enter your 2FA token.');
                return;
              }
              _initExtraction();
            }
          ),
        ],
      ),
    );
  }

  void _initExtraction() async {
    setState(() => _stage = 6);
    await Future.delayed(const Duration(seconds: 1));
    setState(() => _statusText = 'Securing withdrawal request');
    await Future.delayed(const Duration(seconds: 1));
    setState(() => _statusText = 'Submitting for payout review');
    await Future.delayed(const Duration(seconds: 1));
    
    await _finalizeWithdraw();
  }

  Future<void> _finalizeWithdraw() async {
    final amt = double.parse(_selectedAmount.replaceAll(',', ''));
    try {
      _idempotencyKey ??= 'withdrawal-${DateTime.now().microsecondsSinceEpoch}';
      final result = await widget.state.withdraw(
        amt, 
        accountNumber: _accountController.text.trim(), 
        recipientName: _nameController.text.trim(),
        totpToken: widget.state.is2faEnabled ? _totpController.text.trim() : null,
        emailOtp: _emailOtpController.text.trim(),
        method: _selectedMethod,
        idempotencyKey: _idempotencyKey!,
      );
      final withdrawal = result['withdrawal'];
      final withdrawalData = withdrawal is Map ? withdrawal : const <String, dynamic>{};
      _withdrawalId = result['withdrawalId']?.toString() ?? withdrawalData['id']?.toString();
      _withdrawalStatus = result['status']?.toString() ??
          withdrawalData['workflow_status']?.toString() ??
          withdrawalData['status']?.toString() ??
          'initiated';
      if (mounted) setState(() => _stage = 7);
      _startStatusPolling();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
        setState(() => _stage = 3); // Go back on failure
      }
    }
  }

  void _startStatusPolling() {
    if (_withdrawalId == null) return;
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      try {
        final result = await widget.state.financeWithdrawals.status(_withdrawalId!);
        final withdrawal = result['withdrawal'];
        final withdrawalData = withdrawal is Map ? withdrawal : const <String, dynamic>{};
        final status = result['status']?.toString() ??
            withdrawalData['workflow_status']?.toString() ??
            withdrawalData['status']?.toString();
        if (status != null && mounted) setState(() => _withdrawalStatus = status);
        if (status == 'paid' || status == 'failed' || status == 'refunded' || status == 'reversed' || status == 'sandbox_completed') _statusTimer?.cancel();
      } catch (_) {
        // A temporary network failure must not change the last verified status.
      }
    });
  }

  // -- STAGE 4: EXTRACTION PULSE --------------------------
  Widget _buildPulseStage() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _PulseCoreNode(),
        const SizedBox(height: 40),
        Text(_statusText, style: syne(sz: 16, w: FontWeight.w700, c: C.text)),
        const SizedBox(height: 12),
        Text('Real-time ledger bridging active...', style: dm(sz: 11, c: C.dim)),
        const Spacer(),
        _HandshakeProgress(),
        const SizedBox(height: 60),
      ],
    );
  }

  // -- STAGE 5: FINALIZED --------------------------------
  Widget _buildSuccessStage() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SuccessHalo(),
          const SizedBox(height: 32),
          Text('Withdrawal ${_withdrawalStatus.toUpperCase()}', style: syne(sz: 22, w: FontWeight.w700, c: C.text)),
          const SizedBox(height: 24),
          _SummaryCard(amt: _selectedAmount, method: _selectedMethod, status: _withdrawalStatus),
          const SizedBox(height: 48),
          _BottomBtn(label: 'Close', icon: Icons.check, onTap: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}

// -- WIDGETS ----------------------------------------------

class _ScannerBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: Colors.redAccent.withOpacity(.1), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.redAccent.withOpacity(.3))), child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.security, color: Colors.redAccent, size: 12), const SizedBox(width: 8), Text('Secure withdrawal', style: dm(sz: 11, w: FontWeight.w600, c: Colors.redAccent))]));
}

class _FingerprintNode extends StatelessWidget {
  final double progress;
  final VoidCallback onPressed, onReleased;
  const _FingerprintNode({required this.progress, required this.onPressed, required this.onReleased});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => onPressed(),
      onLongPressEnd: (_) => onReleased(),
      child: Stack(alignment: Alignment.center, children: [
        Container(width: 120, height: 120, decoration: BoxDecoration(color: C.text.withOpacity(.03), shape: BoxShape.circle, border: Border.all(color: Colors.redAccent.withOpacity(.2)), boxShadow: [BoxShadow(color: Colors.redAccent.withOpacity(progress * 0.3), blurRadius: 40)])),
        SizedBox(width: 120, height: 120, child: CircularProgressIndicator(value: progress, color: Colors.redAccent, strokeWidth: 3)),
        const Icon(Icons.fingerprint, color: Colors.redAccent, size: 56),
      ]),
    );
  }
}

class _BalanceGuard extends StatelessWidget {
  final double balance;
  const _BalanceGuard({required this.balance});
  @override
  Widget build(BuildContext context) => Container(padding: EdgeInsets.all(24), decoration: BoxDecoration(color: C.text.withOpacity(.02), borderRadius: BorderRadius.circular(24), border: Border.all(color: C.text.withOpacity(.05))), child: Column(children: [
    Text('Available balance', style: dm(sz: 11, w: FontWeight.w600, c: C.dim)),
    const SizedBox(height: 8),
    Text(ugx(balance.toInt()), style: syne(sz: 32, w: FontWeight.w700, fs: FontStyle.italic, c: C.text))]));
}

class _AmountGrid extends StatelessWidget {
  final String selected;
  final double currentRate;
  final Function(String) onSelect;
  const _AmountGrid({required this.selected, required this.currentRate, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    final maxPot = (currentRate * 1000).toInt();
    final List<String> pots = ['10,000', '50,000', '100,000', '500,000', '1,000,000', ugx(maxPot)];
    return GridView.count(
      shrinkWrap: true, 
      crossAxisCount: 2, 
      mainAxisSpacing: 16, 
      crossAxisSpacing: 16, 
      childAspectRatio: 2.2, 
      children: pots.map((s) => _PotsBtn(label: s, active: selected == s, onTap: () => onSelect(s))).toList()
    );
  }
}

class _PotsBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _PotsBtn({required this.label, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(onTap: onTap, child: AnimatedContainer(duration: Duration(milliseconds: 200), decoration: BoxDecoration(color: active ? Colors.redAccent : C.text.withOpacity(.02), borderRadius: BorderRadius.circular(16), border: Border.all(color: active ? Colors.redAccent : C.text.withOpacity(.1))), child: Center(child: Text(label, style: syne(sz: 18, w: FontWeight.w900, fs: FontStyle.italic, c: active ? Colors.black : C.sub)))));
}

class _TransitTile extends StatelessWidget {
  final String label, status;
  final IconData icon;
  final Color color;
  const _TransitTile({required this.label, required this.status, required this.icon, required this.color});
  @override
  Widget build(BuildContext context) {
    final isSelected = status == 'Selected';
    return Container(
      padding: const EdgeInsets.all(18), 
      decoration: BoxDecoration(
        color: isSelected ? color.withOpacity(.15) : C.text.withOpacity(.03), 
        borderRadius: BorderRadius.circular(20), 
        border: Border.all(color: isSelected ? color : C.text.withOpacity(.05))
      ), 
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12), 
            decoration: BoxDecoration(color: color.withOpacity(.15), borderRadius: BorderRadius.circular(14)), 
            child: Icon(icon, color: color, size: 20)
          ), 
          const SizedBox(width: 16), 
          Column(
            crossAxisAlignment: CrossAxisAlignment.start, 
            children: [
              Text(label, style: syne(sz: 14, w: FontWeight.w800, c: C.text)), 
              Row(
                children: [
                  Container(width: 6, height: 6, decoration: BoxDecoration(color: isSelected ? Colors.green : Colors.grey, shape: BoxShape.circle)), 
                  const SizedBox(width: 6), 
                  Text('Sync Status: $status', style: dm(sz: 10, c: C.dim))
                ]
              )
            ]
          ), 
          const Spacer(), 
          if (isSelected) Icon(Icons.check_circle, color: color) else Icon(Icons.chevron_right, color: C.dim)
        ]
      )
    );
  }
}

class _PulseCoreNode extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(width: 100, height: 100, decoration: BoxDecoration(color: Colors.redAccent.withOpacity(.1), shape: BoxShape.circle, border: Border.all(color: Colors.redAccent.withOpacity(.3))), child: const Center(child: Icon(Icons.bolt, color: Colors.redAccent, size: 48)));
}

class _HandshakeProgress extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Padding(padding: EdgeInsets.symmetric(horizontal: 40), child: Container(height: 2, width: double.infinity, decoration: BoxDecoration(color: C.dim, borderRadius: BorderRadius.circular(1)), child: LinearProgressIndicator(backgroundColor: Colors.transparent, color: Colors.redAccent)));
}

class _SuccessHalo extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(32), decoration: BoxDecoration(color: Colors.redAccent.withOpacity(.1), shape: BoxShape.circle), child: const Icon(Icons.check_circle_outline, color: Colors.redAccent, size: 72));
}

class _SummaryCard extends StatelessWidget {
  final String amt;
  final String method;
  final String status;
  const _SummaryCard({required this.amt, required this.method, required this.status});
  
  String get _methodLabel {
    switch (method) {
      case 'airtel': return 'Airtel Money';
      case 'mtn': return 'MTN Mobile Money';
      case 'card': return 'Card / Google Pay';
      default: return method;
    }
  }

  @override
  Widget build(BuildContext context) => Container(padding: EdgeInsets.all(24), decoration: BoxDecoration(color: C.text.withOpacity(.02), borderRadius: BorderRadius.circular(24), border: Border.all(color: C.text.withOpacity(.05))), child: Column(children: [
    Text('Withdrawal amount', style: dm(sz: 11, w: FontWeight.w600, c: C.dim)),
    const SizedBox(height: 12),
    Text('UGX $amt', style: syne(sz: 24, w: FontWeight.w700, fs: FontStyle.italic, c: Colors.redAccent)),
    const SizedBox(height: 12),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.verified_user, color: Colors.blue, size: 10),
      const SizedBox(width: 6),
      Text('Payout ${status.toUpperCase()}', style: dm(sz: 10, w: FontWeight.w600, c: Colors.blue)),
    ]),
    const SizedBox(height: 8),
    Text('Sent to: $_methodLabel', style: dm(sz: 11, c: C.dim))
  ]));
}

class _BottomBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _BottomBtn({required this.label, required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(onTap: onTap, child: Container(height: 64, width: double.infinity, decoration: BoxDecoration(color: C.text, borderRadius: BorderRadius.circular(20)), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: Colors.black, size: 20), SizedBox(width: 12), Text(label, style: syne(sz: 16, w: FontWeight.w700, c: Colors.black))])));
}

class _SecureInput extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final Color color;

  const _SecureInput({
    required this.controller,
    required this.hint,
    required this.icon,
    this.color = Colors.redAccent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: C.text.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.dim),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: syne(sz: 18, w: FontWeight.w600, c: C.text, ls: 2),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                hintStyle: dm(sz: 14, c: C.dim, ls: 0),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String ugx(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return 'UGX $buf';
}


