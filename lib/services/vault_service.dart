import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';

class VaultService {
  SupabaseClient get client => Supabase.instance.client;
  final LocalAuthentication auth = LocalAuthentication();

  Future<Map<String, double>> fetchBalances(String userId) async {
    final res = await client
        .from('wallets')
        .select()
        .eq('user_id', userId)
        .single();
    return {
      'fiat': (res['fiat_balance'] as num).toDouble(),
      'shard': (res['coin_balance'] as num).toDouble(),
      'escrow': (res['escrow_balance'] as num).toDouble(),
    };
  }

  Future<Map<String, dynamic>> fetchVaultSummary(String userId) async {
    final res = await client
        .from('ncx_vault_user_summary')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    return res ?? {};
  }

  Future<void> stake(String userId, double amount, String type) async {
    final response = await client.rpc('deposit_into_vault', params: {
      'p_user_id': userId,
      'p_amount_ncx': amount,
      'p_vault_type': type,
    });
    if (response['success'] == false) {
      throw Exception(response['message']);
    }
  }

  Future<void> unstake(String userId, String depositId) async {
    final response = await client.rpc('withdraw_from_vault', params: {
      'p_deposit_id': depositId,
      'p_user_id': userId,
    });
    if (response['success'] == false) {
      throw Exception(response['message']);
    }
  }

  Future<void> sellShards(String userId, int shards) async {
    final response = await client.rpc(
      'liquidate_coins',
      params: {
        'p_user_id': userId, 
        'p_shards_to_sell': shards.toDouble(),
      },
    );
    if (response == false) {
      throw Exception('Insufficient Shard Balance for Liquidation');
    }
  }

  Future<bool> verifyBiometrics() async {
    try {
      return await auth.authenticate(
        localizedReason: 'AUTHENTICATE TO ACCESS VAULT EXTRACTION',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
    } catch (e) {
      debugPrint('Biometric Fail: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> getSecurityMetadata() async {
    final dev = DeviceInfoPlugin();
    final pos = await Geolocator.getCurrentPosition();
    String deviceId = 'unknown';
    if (!kIsWeb) {
      if (Platform.isAndroid) {
        final androidInfo = await dev.androidInfo;
        deviceId = androidInfo.id;
      } else if (Platform.isIOS) {
        final iosInfo = await dev.iosInfo;
        deviceId = iosInfo.identifierForVendor ?? 'unknown';
      }
    }
    return {
      'device_id': deviceId,
      'lat': pos.latitude,
      'lng': pos.longitude,
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  Future<void> deposit(String userId, double amount) async {
    // Maps to recharge_ncx RPC for Ugx to Ncx conversion
    final response = await client.rpc('recharge_ncx', params: {
      'p_user_id': userId,
      'p_amount_ugx': amount,
      'p_payment_method': 'momo', // Default for now
    });
    
    if (response is Map && response['success'] == false) {
      throw Exception(response['message'] ?? 'Recharge Failed');
    }
  }

  Future<void> withdraw(String userId, double amount, Map<String, dynamic> metadata) async {
    // Placeholder for withdrawal logic - would sync with a 'withdraw_fiat' RPC
    debugPrint('Withdrawal Requested: $amount UGX for $userId');
    // For now, we manually update for the demo or throw if not implemented
    // In a real scenario, this would trigger an escrow/payout flow
  }
}
