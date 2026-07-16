import 'finance_backend.dart';
import 'finance_initializer.dart';

class FinanceWithdrawalService {
  Future<void> sendOtp() async {
    await FinanceInitializer.instance.ensureInitialized();
    await FinanceBackend.instance.invoke('send_withdrawal_otp');
  }

  Future<Map<String, dynamic>> request({
    required int amountUgx,
    required String method,
    required String accountNumber,
    required String recipientName,
    required String emailOtp,
    required Map<String, dynamic> securityMetadata,
  }) async {
    await FinanceInitializer.instance.ensureInitialized();
    return FinanceBackend.instance.invoke(
      'request_withdrawal',
      body: {
        'amount': amountUgx,
        'method': method,
        'accountNumber': accountNumber,
        'recipientName': recipientName,
        'emailOtp': emailOtp,
        'securityMetadata': securityMetadata,
        'idempotencyKey': 'withdrawal-${DateTime.now().microsecondsSinceEpoch}',
      },
    );
  }

  Future<Map<String, dynamic>> status(String withdrawalId) => FinanceBackend
      .instance
      .invoke('withdrawal_status', body: {'withdrawalId': withdrawalId});
}
