import 'package:flutter/material.dart';
import 'dart:ui';
import '../theme.dart';
import '../app_state.dart';
import '../services/finance_deposit_service.dart';
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
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  String _selectedPaymentMethod = 'momo';
  bool _loading = false;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final profile = widget.state.myProfile;
    _phoneController.text = profile?['phone'] ?? '';
    _emailController.text = profile?['email'] ?? '';
    final nameParts = (profile?['full_name'] ?? '').toString().split(' ');
    _firstNameController.text = nameParts.isNotEmpty ? nameParts.first : '';
    _lastNameController.text = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
  }

  @override
  void dispose() {
    _amountController.dispose();
    _phoneController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
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
              child: SingleChildScrollView(
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

                    // Amount
                    Text('AMOUNT (UGX)', style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38, ls: 1)),
                    const SizedBox(height: 12),
                    _buildAmountInput(),

                    const SizedBox(height: 20),
                    // Name row — required by Pesapal billing
                    Row(
                      children: [
                        Expanded(child: _buildTextField(_firstNameController, 'FIRST NAME', 'John', Icons.person_outline)),
                        const SizedBox(width: 12),
                        Expanded(child: _buildTextField(_lastNameController, 'LAST NAME', 'Doe', Icons.person_outline)),
                      ],
                    ),

                    const SizedBox(height: 16),
                    _buildTextField(
                      _emailController,
                      'EMAIL ADDRESS',
                      'you@example.com',
                      Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                    ),

                    const SizedBox(height: 16),
                    Text('PHONE NUMBER FOR PAYMENT', style: syne(sz: 11, w: FontWeight.w900, c: Colors.white38, ls: 1)),
                    const SizedBox(height: 12),
                    _buildPhoneInput(),

                    const SizedBox(height: 24),
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
        if (value == null || value.isEmpty) return 'Please enter an amount';
        final amount = int.tryParse(value.replaceAll(',', ''));
        if (amount == null || amount < 500) return 'Minimum deposit is UGX 500';
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
        hintText: 'e.g. 0700000000',
        hintStyle: syne(sz: 16, w: FontWeight.bold, c: Colors.white24),
        prefixIcon: const Icon(Icons.phone_outlined, color: C.brand, size: 20),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: C.brand)),
      ),
      validator: (value) {
        if (value == null || value.isEmpty) return 'Phone number is required';
        if (value.length < 10) return 'Enter a valid phone number';
        return null;
      },
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    String hint,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: syne(sz: 10, w: FontWeight.w900, c: Colors.white38, ls: 1)),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          style: syne(sz: 14, w: FontWeight.bold, c: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: syne(sz: 14, w: FontWeight.bold, c: Colors.white24),
            prefixIcon: Icon(icon, color: C.brand, size: 18),
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.brand)),
            contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          ),
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
        ),
      ],
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
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _loading = true);
    final amount = int.tryParse(_amountController.text.replaceAll(',', ''));
    if (amount == null || amount < 500) {
      setState(() => _loading = false);
      return;
    }

    try {
      final svc = FinanceDepositService();
      final res = await svc.initiate(
        amountUgx: amount,
        phone: _phoneController.text.trim(),
      );

      if (res['success'] == true) {
        final redirectUrl = res['redirectUrl']?.toString();
        final paymentId = res['paymentId']?.toString();

        if (redirectUrl == null || paymentId == null) {
          throw Exception('Payment provider returned an incomplete response.');
        }

        if (await canLaunchUrlString(redirectUrl)) {
          await launchUrlString(redirectUrl, mode: LaunchMode.externalApplication);
        }

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Complete payment in the browser. Your wallet will be credited once confirmed.'),
            duration: Duration(seconds: 5),
          ),
        );

        // Poll for completion (5 min timeout, checks every 3s)
        final completed = await svc.waitForCompletion(paymentId);
        if (!mounted) return;

        if (completed) {
          await widget.state.syncVault();
          if (!mounted) return;
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✅ Deposit confirmed and wallet credited!')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Payment pending — your wallet will be credited once Pesapal confirms.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        throw Exception(res['message'] ?? 'Failed to initiate deposit.');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
