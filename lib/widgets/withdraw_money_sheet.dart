import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/finance_withdrawal_service.dart';

class WithdrawMoneySheet extends StatefulWidget {
	const WithdrawMoneySheet({Key? key}) : super(key: key);

	@override
	State<WithdrawMoneySheet> createState() => _WithdrawMoneySheetState();
}

class _WithdrawMoneySheetState extends State<WithdrawMoneySheet> {
	final _amountCtrl = TextEditingController();
	final _accountCtrl = TextEditingController();
	final _nameCtrl = TextEditingController();
	final _otpCtrl = TextEditingController();
	String _method = 'mtn';
	bool _loading = false;

	final _service = FinanceWithdrawalService();

	@override
	void dispose() {
		_amountCtrl.dispose();
		_accountCtrl.dispose();
		_nameCtrl.dispose();
		_otpCtrl.dispose();
		super.dispose();
	}

	Future<void> _sendOtp() async {
		setState(() => _loading = true);
		try {
			final res = await _service.sendOtp();
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('OTP sent (expires soon).')),
			);
			// If backend returns OTP for testing, autofill it
			if (res['otp'] != null) _otpCtrl.text = res['otp'].toString();
		} catch (e) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Send OTP failed: $e')));
		} finally {
			setState(() => _loading = false);
		}
	}

	Future<void> _submit() async {
		final amountStr = _amountCtrl.text.trim();
		final account = _accountCtrl.text.trim();
		final name = _nameCtrl.text.trim();
		final otp = _otpCtrl.text.trim();
		if (amountStr.isEmpty || int.tryParse(amountStr) == null) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Enter valid amount')));
			return;
		}
		if (account.isEmpty || name.isEmpty || otp.isEmpty) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Complete all fields')));
			return;
		}

		setState(() => _loading = true);
		try {
			final idempotency = const Uuid().v4();
			final deviceFingerprint = await _deviceFingerprint();
			final res = await _service.request(
				amountUgx: int.parse(amountStr),
				method: _method,
				accountNumber: account,
				recipientName: name,
				emailOtp: otp,
				totpToken: null,
				securityMetadata: {'device_fingerprint': deviceFingerprint},
				idempotencyKey: idempotency,
			);
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Withdrawal requested')));
			Navigator.of(context).pop(res);
		} catch (e) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Withdraw failed: $e')));
		} finally {
			setState(() => _loading = false);
		}
	}

	Future<String> _deviceFingerprint() async {
		const key = 'withdrawal_device_fingerprint_v1';
		final preferences = await SharedPreferences.getInstance();
		final existing = preferences.getString(key);
		if (existing != null && existing.isNotEmpty) return existing;
		final fingerprint = const Uuid().v4();
		await preferences.setString(key, fingerprint);
		return fingerprint;
	}

	@override
	Widget build(BuildContext context) {
		return Padding(
			padding: MediaQuery.of(context).viewInsets.add(const EdgeInsets.all(16)),
			child: Column(
				mainAxisSize: MainAxisSize.min,
				children: [
					Row(
						children: [
							Expanded(child: TextField(controller: _amountCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'Amount (UGX)'))),
							const SizedBox(width: 8),
							const Text('MTN MoMo'),
						],
					),
					TextField(controller: _accountCtrl, decoration: InputDecoration(labelText: 'Account / Phone')),
					TextField(controller: _nameCtrl, decoration: InputDecoration(labelText: 'Recipient name')),
					Row(
						children: [
							Expanded(child: TextField(controller: _otpCtrl, decoration: InputDecoration(labelText: 'Email OTP'))),
							const SizedBox(width: 8),
							ElevatedButton(onPressed: _loading ? null : _sendOtp, child: Text('Send OTP')),
						],
					),
					const SizedBox(height: 12),
					ElevatedButton(onPressed: _loading ? null : _submit, child: _loading ? CircularProgressIndicator() : Text('Request Withdrawal')),
					const SizedBox(height: 8),
				],
			),
		);
	}
}
