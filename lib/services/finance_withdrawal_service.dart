import 'finance_backend.dart';
import 'finance_initializer.dart';

class FinanceWithdrawalService {
  Future<Map<String, dynamic>> eligibility(int amountUgx) async {
    await FinanceInitializer.instance.ensureInitialized();
    return FinanceBackend.instance.invoke(
      'check_withdrawal_eligibility',
      body: {'amount': amountUgx},
    );
  }

  Future<Map<String, dynamic>> sendOtp() async {
    await FinanceInitializer.instance.ensureInitialized();
    return FinanceBackend.instance.invoke('send_withdrawal_otp');
  }

  Future<Map<String, dynamic>> request({
    required int amountUgx,
    required String method,
    required String accountNumber,
    required String recipientName,
    required String emailOtp,
    String? totpToken,
    required Map<String, dynamic> securityMetadata,
    required String idempotencyKey,
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
        'totpToken': totpToken,
        'securityMetadata': securityMetadata,
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  Future<Map<String, dynamic>> status(String withdrawalId) => FinanceBackend
      .instance
      .invoke('withdrawal_status', body: {'withdrawalId': withdrawalId});
}
