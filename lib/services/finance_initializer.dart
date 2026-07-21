import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'finance_backend.dart';

/// Lazily validates the isolated Supabase 2 finance backend.
class FinanceInitializer {
  static final FinanceInitializer instance = FinanceInitializer._internal();

  FinanceInitializer._internal();

  bool _isInitialized = false;

  Future<void> ensureInitialized() async {
    if (_isInitialized) return;

    debugPrint('Initializing Necxa Finance on Supabase 2...');
    if (Supabase.instance.client.auth.currentSession == null) {
      throw const FinanceBackendException(
        code: 'unauthenticated',
        message: 'Sign in before using Necxa Finance.',
      );
    }

    await FinanceBackend.instance.invoke('health');
    _isInitialized = true;
    debugPrint('Necxa Finance Supabase 2 backend is active.');
  }
}
