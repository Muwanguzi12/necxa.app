import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart';
import '../models/property_container.dart';
import '../services/payment_service.dart';
import '../utils/error_handler.dart';
import 'package:url_launcher/url_launcher.dart';

enum PaymentStage { form, processing, success, error }

class PaymentScreen extends StatefulWidget {
  final AppState state;
  PaymentScreen({super.key, required this.state});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen>
    with SingleTickerProviderStateMixin {
  final PaymentService _paymentService = PaymentService();
  final TextEditingController _phoneCtrl = TextEditingController();

  PaymentStage _stage = PaymentStage.form;
  String _method = 'MTN_MOMO'; // MTN_MOMO | AIRTEL_MONEY | NCX_COINS
  String _errMsg = '';

  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1000),
    );
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
      return Scaffold(body: Center(child: Text('Invalid Listing')));
    }

    switch (_stage) {
      case PaymentStage.processing:
        return _buildProcessingUI();
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
    return Scaffold(
      backgroundColor: C.bg,
      body: Column(
        children: [
          _buildNav(),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSummary(p),
                  SizedBox(height: 24),
                  _buildUnlockInclusion(),
                  SizedBox(height: 32),
                  Text(
                    'PAYMENT METHOD',
                    style: syne(sz: 14, ls: 1, w: FontWeight.bold, c: C.dim),
                  ),
                  SizedBox(height: 16),
                  _MethodTile(
                    id: 'MTN_MOMO',
                    label: 'MTN MoMo',
                    icon: '??',
                    sub: '256 77x / 78x / 39x',
                    selected: _method == 'MTN_MOMO',
                    onTap: () => setState(() => _method = 'MTN_MOMO'),
                  ),
                  _MethodTile(
                    id: 'AIRTEL_MONEY',
                    label: 'Money',
                    icon: '??',
                    sub: '256 70x / 75x',
                    selected: _method == 'AIRTEL_MONEY',
                    onTap: () => setState(() => _method = 'AIRTEL_MONEY'),
                  ),
                  _MethodTile(
                    id: 'NCX_COINS',
                    label: 'NCX Coins',
                    icon: '??',
                    sub: 'From your Necxa wallet',
                    selected: _method == 'NCX_COINS',
                    onTap: () => setState(() => _method = 'NCX_COINS'),
                  ),

                  if (_method != 'NCX_COINS') ...[
                    SizedBox(height: 24),
                    Text(
                      'PHONE NUMBER',
                      style: syne(sz: 14, ls: 1, w: FontWeight.bold, c: C.dim),
                    ),
                    SizedBox(height: 12),
                    _buildPhoneInput(),
                  ],

                  SizedBox(height: 48),
                  _buildCallToAction(p),
                  SizedBox(height: 20),
                  Text(
                    'By paying you agree to NECXA Terms. The fee goes to the platform, not the agent. Refunds are not available after contact is revealed.',
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
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('???? +256', style: syne(sz: 16, w: FontWeight.bold)),
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
                contentPadding: EdgeInsets.symmetric(
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
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.text.withOpacity(.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'WHAT YOU UNLOCK:',
            style: syne(sz: 12, w: FontWeight.bold, c: C.brand),
          ),
          SizedBox(height: 12),
          const _UnlockRow(icon: '??', label: 'Agent direct phone number'),
          const _UnlockRow(icon: '??', label: 'WhatsApp click-to-chat link'),
          const _UnlockRow(icon: '??', label: 'Exact GPS coordinates & Pin'),
          const _UnlockRow(icon: '??', label: 'Full street & Plot address'),
        ],
      ),
    );
  }

  // -- PROCESSING UI ----------------------------------------------------------
  Widget _buildProcessingUI() {
    return Scaffold(
      backgroundColor: C.bg,
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(40),
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
                    color: C.brand.withOpacity(.1),
                    border: Border.all(
                      color: C.brand.withOpacity(.3),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: CircularProgressIndicator(color: C.brand),
                  ),
                ),
              ),
              SizedBox(height: 32),
              Text('SYNCHRONIZING...', style: syne(sz: 24, w: FontWeight.bold)),
              SizedBox(height: 12),
              Text(
                _method == 'NCX_COINS'
                    ? 'Verifying Shard balance and unlocking asset...'
                    : 'Waiting for you to approve on your phone.\nThis can take up to 60 seconds.',
                textAlign: TextAlign.center,
                style: dm(sz: 14, c: C.dim, h: 1.5),
              ),
              SizedBox(height: 48),
              _buildStepIndicator('Payment request sent'),
              _buildStepIndicator('Waiting for your approval'),
              _buildStepIndicator(
                'Confirming with Blockchain/Network',
                active: true,
              ),
              _buildStepIndicator('Revealing Agent Credentials'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepIndicator(String label, {bool active = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 16,
            color: active ? C.brand : C.dim,
          ),
          SizedBox(width: 12),
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
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: C.green,
                ),
                child: Icon(
                  Icons.lock_open,
                  color: C.text,
                  size: 40,
                ),
              ),
              SizedBox(height: 24),
              Text(
                'SUCCESFULLY UNLOCKED!',
                style: syne(sz: 24, w: FontWeight.bold),
              ),
              SizedBox(height: 12),
              Text(
                'You now have full access to the agent\'s credentials and the property location.',
                textAlign: TextAlign.center,
                style: dm(sz: 14, c: C.dim),
              ),
              SizedBox(height: 32),
              Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: C.card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: C.green.withOpacity(.3)),
                ),
                child: Column(
                  children: [
                    Text(
                      'REVEALED:',
                      style: syne(sz: 12, w: FontWeight.bold, c: C.green),
                    ),
                    SizedBox(height: 16),
                    const _RevealedItem(Icons.phone, 'Agent Phone Revealed'),
                    const _RevealedItem(Icons.chat, 'WhatsApp Link Active'),
                    const _RevealedItem(Icons.location_on, 'GPS Pin Decoded'),
                  ],
                ),
              ),
              SizedBox(height: 48),
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
                      'VIEW CREDENTIALS ?',
                      style: syne(sz: 15, w: FontWeight.bold, c: C.bg),
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
          padding: EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, color: C.red, size: 80),
              SizedBox(height: 24),
              Text('PAYMENT FAILED', style: syne(sz: 24, w: FontWeight.bold)),
              SizedBox(height: 12),
              Text(
                _errMsg,
                textAlign: TextAlign.center,
                style: dm(sz: 14, c: C.dim),
              ),
              SizedBox(height: 48),
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
              SizedBox(height: 16),
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
      padding: EdgeInsets.fromLTRB(16, 52, 16, 12),
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
          Spacer(),
          Text(
            'SECURE CHECKOUT',
            style: syne(sz: 14, w: FontWeight.bold, ls: 1),
          ),
          Spacer(),
          SizedBox(width: 22),
        ],
      ),
    );
  }

  Widget _buildSummary(PropertyContainer p) {
    return Container(
      padding: EdgeInsets.all(16),
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
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'UNLOCK: ${p.core.title}',
                  style: dm(sz: 14, w: FontWeight.bold),
                ),
                Text(
                  'Asset ID: ${p.core.id.substring(0, 8)}',
                  style: dm(sz: 11, c: C.dim),
                ),
                SizedBox(height: 8),
                Text(
                  ugx(p.financial.unlockCost),
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
    return GestureDetector(
      onTap: () => _processPayment(p),
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          color: C.brand,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: C.brand.withOpacity(.2),
              blurRadius: 20,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Center(
          child: Text(
            'AUTHORIZE PAYMENT ?',
            style: syne(sz: 15, w: FontWeight.bold, c: C.bg),
          ),
        ),
      ),
    );
  }

  Future<void> _processPayment(PropertyContainer p) async {
    if (_method != 'NCX_COINS' && _phoneCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please enter your phone number')),
      );
      return;
    }

    setState(() => _stage = PaymentStage.processing);
    _startPulse();

    try {
      final user = widget.state.user;
      if (user == null) throw Exception('User not authenticated');

      final initiateRes = await _paymentService.initiateUnlock(
        listingId: p.core.id,
        method: _method,
        amount: p.financial.unlockCost.toDouble(),
        buyerId: user.id,
        buyerEmail: user.email ?? '',
        phone: _method != 'NCX_COINS' ? _phoneCtrl.text : null,
      );

      bool success = false;
      if (_method == 'NCX_COINS') {
        success = initiateRes['success'] == true;
      } else {
        // Launch Pesapal redirect URL externally
        final redirectUrl = initiateRes['redirect_url'];
        if (redirectUrl != null) {
          final uri = Uri.parse(redirectUrl);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } else {
            throw Exception('Could not open checkout page.');
          }
        } else {
          throw Exception('No payment link received.');
        }

        success = await _paymentService.pollForPaymentCompletion(
          initiateRes['payment_id'],
        );
      }

      if (success) {
        widget.state.unlockProperty(p.core.id);
        setState(() => _stage = PaymentStage.success);
      } else {
        throw Exception('Payment verification timed out');
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
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(icon, style: TextStyle(fontSize: 14)),
          SizedBox(width: 12),
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
      padding: EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: C.green, size: 18),
          SizedBox(width: 12),
          Text(label, style: dm(sz: 14, w: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _MethodTile extends StatelessWidget {
  final String id, label, icon, sub;
  final bool selected;
  final VoidCallback onTap;
  const _MethodTile({
    required this.id,
    required this.label,
    required this.icon,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        margin: EdgeInsets.only(bottom: 12),
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? C.brand.withOpacity(.05) : C.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? C.brand : C.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Text(icon, style: TextStyle(fontSize: 24)),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: dm(sz: 14, w: FontWeight.bold)),
                  Text(sub, style: dm(sz: 11, c: C.dim)),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.radio_button_checked, color: C.brand, size: 20)
            else
              Icon(Icons.radio_button_off, color: C.dim, size: 20),
          ],
        ),
      ),
    );
  }
}



