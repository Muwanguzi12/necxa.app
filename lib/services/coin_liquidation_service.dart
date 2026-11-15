import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:universal_io/io.dart';
import 'package:flutter/foundation.dart';

class CoinLiquidationService {
  SupabaseClient get _supabase => Supabase.instance.client;
  final LocalAuthentication _localAuth = LocalAuthentication();
  
  // Get liquidation quote before selling
  Future<LiquidationQuote> getQuote(double ncxAmount) async {
    final response = await _supabase.rpc('get_liquidation_quote', params: {
      'p_ncx_amount': ncxAmount,
    });
    
    // Check if response is a list (Supabase returns a list for TABLE returns)
    final data = (response is List) ? response.first : response;

    return LiquidationQuote(
      ncxAmount: (data['ncx_amount'] as num).toDouble(),
      ugxReceived: (data['ugx_received'] as num).toDouble(),
      ncxBurned: (data['ncx_burned'] as num).toDouble(),
      burnPercentage: (data['burn_percentage'] as num).toInt(),
      effectiveRate: (100 - (data['burn_percentage'] as num)) / 100.0,
    );
  }
  
  // Perform biometric verification (Safe Sign)
  Future<bool> verifyBiometric() async {
    try {
      final isAvailable = await _localAuth.canCheckBiometrics;
      if (!isAvailable) return false;
      
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Verify your identity to liquidate NCX coins',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
      
      return authenticated;
    } on PlatformException catch (e) {
      debugPrint('Biometric error: $e');
      return false;
    }
  }
  
  // Execute liquidation (sell coins)
  Future<LiquidationResult> liquidateCoins({
    required double ncxAmount,
    required String biometricHash,
    String? deviceId,
  }) async {
    final user = _supabase.auth.currentUser;
    if (user == null) throw Exception('User not authenticated');

    final response = await _supabase.rpc('liquidate_coins', params: {
      'p_user_id': user.id,
      'p_ncx_amount': ncxAmount,
      'p_biometric_hash': biometricHash,
      'p_device_id': deviceId,
    });

    // Supabase RPC returns a list for TABLE RETURNS
    final data = (response is List) ? response.first : response;
    
    if (data['success'] == true) {
      return LiquidationResult(
        success: true,
        ugxReceived: (data['ugx_received'] as num).toDouble(),
        ncxBurned: (data['ncx_burned'] as num).toDouble(),
        newCoinBalance: (data['new_coin_balance'] as num).toDouble(),
        newFiatBalance: (data['new_fiat_balance'] as num).toDouble(),
        txCommitHash: data['tx_commit_hash'],
        newNcxPrice: (data['new_ncx_price'] as num).toDouble(),
        message: data['message'],
      );
    } else {
      throw Exception(data['message'] ?? 'Liquidation failed');
    }
  }

  Future<String?> getDeviceId() async {
    final dev = DeviceInfoPlugin();
    if (!kIsWeb) {
      if (Platform.isAndroid) {
        final androidInfo = await dev.androidInfo;
        return androidInfo.id;
      } else if (Platform.isIOS) {
        final iosInfo = await dev.iosInfo;
        return iosInfo.identifierForVendor;
      }
    }
    return 'web_client';
  }
}

class LiquidationQuote {
  final double ncxAmount;
  final double ugxReceived;
  final double ncxBurned;
  final int burnPercentage;
  final double effectiveRate;
  
  LiquidationQuote({
    required this.ncxAmount,
    required this.ugxReceived,
    required this.ncxBurned,
    required this.burnPercentage,
    required this.effectiveRate,
  });
  
  String get burnMessage => '$burnPercentage% will be burned (${ncxBurned.toStringAsFixed(2)} NCX)';
  String get receiveMessage => 'You receive ${ugxReceived.toStringAsFixed(2)} UGX';
}

class LiquidationResult {
  final bool success;
  final double ugxReceived;
  final double ncxBurned;
  final double newCoinBalance;
  final double newFiatBalance;
  final String txCommitHash;
  final double newNcxPrice;
  final String message;
  
  LiquidationResult({
    required this.success,
    required this.ugxReceived,
    required this.ncxBurned,
    required this.newCoinBalance,
    required this.newFiatBalance,
    required this.txCommitHash,
    required this.newNcxPrice,
    required this.message,
  });
}
