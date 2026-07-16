import 'package:flutter/material.dart';
import 'dart:ui';
import '../theme.dart';
import '../app_state.dart';
import 'package:url_launcher/url_launcher_string.dart';

class VaultDepositOverlay extends StatefulWidget {
  final AppState state;
  const VaultDepositOverlay({super.key, required this.state});

  @override
  State<VaultDepositOverlay> createState() => _VaultDepositOverlayState();
}

class _VaultDepositOverlayState extends State<VaultDepositOverlay> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  String _selectedPaymentMethod = 'momo'; // Default to mobile money
  bool _loading = false;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _phoneController.text = widget.state.myProfile?['phone'] ?? '';
  }

  @override
  void dispose() {
    _amountController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
        decoration: BoxDecoration(
          color: const Color(0xFF0D121B),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag Handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('DEPOSIT FIAT (UGX)', style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 1)),
                  const SizedBox(height: 24),
                  
                  // Amount Input
                  Text('AMOUNT (UGX)', style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38, ls: 1)),
                  const SizedBox(height: 12),
                  _buildAmountInput(),

                  const SizedBox(height: 24),
                  Text('PHONE NUMBER FOR PAYMENT', style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38, ls: 1)),
                  const SizedBox(height: 12),
                  _buildPhoneInput(),

                  const SizedBox(height: 32),
                  Text('PAYMENT METHOD', style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38, ls: 1)),
                  const SizedBox(height: 12),
                  _payOption('Mobile Money', 'MTN / Airtel', 'momo', Icons.phone_android_outlined),
                  const SizedBox(height: 12),
                  _payOption('Visa / Mastercard', 'Debit or Credit Card', 'card', Icons.credit_card_outlined),
                  
                  const SizedBox(height: 32),
                  _actionButton('Deposit Funds', _handlePayment, loading: _loading),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAmountInput() {
    return TextFormField(
      controller: _amountController,
      keyboardType: TextInputType.number,
      style: syne(sz: 24, w: FontWeight.bold, c: Colors.white),
      decoration: InputDecoration(
        hintText: '0',
        hintStyle: syne(sz: 24, w: FontWeight.bold, c: Colors.white24),
        prefixText: 'UGX ',
        prefixStyle: syne(sz: 14, w: FontWeight.bold, c: Colors.white38),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: C.brand)),
      ),
      validator: (value) {
        if (value == null || value.isEmpty) {
          return 'Please enter an amount';
        }
        final amount = double.tryParse(value);
        if (amount == null || amount < 500) {
          return 'Minimum deposit is UGX 500';
        }
        return null;
      },
    );
  }

  Widget _buildPhoneInput() {
    return TextFormField(
      controller: _phoneController,
      keyboardType: TextInputType.phone,
      style: syne(sz: 16, w: FontWeight.bold, c: Colors.white),
      decoration: InputDecoration(
        hintText: 'e.g. 07...',
        hintStyle: syne(sz: 16, w: FontWeight.bold, c: Colors.white24),
        prefixIcon: const Icon(Icons.phone_outlined, color: C.brand, size: 20),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: C.brand)),
      ),
      validator: (value) {
        if (value == null || value.isEmpty) {
          return 'Phone number is required';
        }
        if (value.length < 10) {
          return 'Enter a valid phone number';
        }
        return null;
      },
    );
  }

  Widget _payOption(String label, String sub, String val, IconData icon) {
    final active = _selectedPaymentMethod == val;
    return GestureDetector(
      onTap: () => setState(() => _selectedPaymentMethod = val),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: active ? C.brand.withOpacity(0.15) : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? C.brand : Colors.white10),
        ),
        child: Row(
          children: [
            Icon(icon, color: active ? C.brand : Colors.white38, size: 24),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: syne(sz: 14, w: FontWeight.bold, c: Colors.white)),
                Text(sub, style: dm(sz: 11, c: Colors.white38)),
              ],
            ),
            const Spacer(),
            Icon(
              active ? Icons.radio_button_checked : Icons.radio_button_off,
              color: active ? C.brand : Colors.white10,
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton(String label, VoidCallback onTap, {bool loading = false}) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: C.brand,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: C.brand.withOpacity(0.3), blurRadius: 15)],
        ),
        child: Center(
          child: loading
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
              : Text(label.toUpperCase(), style: syne(sz: 14, w: FontWeight.w900, c: Colors.black, ls: 1.5)),
        ),
      ),
    );
  }

  void _handlePayment() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() => _loading = true);
    final amount = double.tryParse(_amountController.text);
    if (amount == null) {
      setState(() => _loading = false);
      return;
    }

    try {
      final res = await widget.state.depositFiat(
        amount,
        phone: _phoneController.text,
      );

      if (res['success'] == true) {
        final redirectUrl = res['redirectUrl']?.toString() ?? res['redirect_url']?.toString();
        final paymentId = res['paymentId']?.toString() ?? res['order_id']?.toString();
        if (redirectUrl == null || paymentId == null) {
          throw Exception('The payment provider returned an incomplete checkout response.');
        }
        if (await canLaunchUrlString(redirectUrl)) {
          await launchUrlString(redirectUrl, mode: LaunchMode.externalApplication);
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Complete payment in the window that opened. Verifying your deposit…')),
        );
        final completed = await widget.state.financeDeposits.waitForCompletion(paymentId);
        if (!mounted) return;
        if (!completed) {
          throw Exception('Deposit is not confirmed yet. Your wallet will only be credited after Pesapal confirms payment.');
        }
        await widget.state.syncVault();
        if (!mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Deposit confirmed and wallet credited.')),
        );
      } else {
        throw Exception(res['message'] ?? 'Failed to initiate Pesapal payment.');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: ${e.toString()}')));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }
}
