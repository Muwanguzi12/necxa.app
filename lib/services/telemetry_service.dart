import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:universal_io/io.dart';

class TelemetryService {
  static final TelemetryService _instance = TelemetryService._internal();
  factory TelemetryService() => _instance;
  TelemetryService._internal();

  /// Logs an error and stack trace to the Supabase `crash_logs` table.
  /// Does not block the main thread and gracefully degrades if offline.
  Future<void> logCrash(dynamic exception, StackTrace stackTrace, {String? context}) async {
    // Only log in release mode or if explicitly requested, but for now we'll log everything for testing.
    debugPrint('🚨 [TELEMETRY CAUGHT]: $exception');
    
    try {
      final session = Supabase.instance.client.auth.currentSession;
      
      await Supabase.instance.client.from('crash_logs').insert({
        'error_message': exception.toString(),
        'stack_trace': stackTrace.toString(),
        'context': context ?? 'global',
        'user_id': session?.user.id,
        'os': kIsWeb ? 'web' : Platform.operatingSystem,
        'os_version': kIsWeb ? 'browser' : Platform.operatingSystemVersion,
        'app_version': '1.0.0+1', // In a real app, use package_info_plus
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      // If the telemetry service fails (e.g. offline), we swallow the error so we don't cause an infinite crash loop.
      debugPrint('⚠️ Telemetry log failed: $e');
    }
  }
}
