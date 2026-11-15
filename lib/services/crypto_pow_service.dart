import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Cryptographic Proof-of-Work (PoW) model for high-integrity micropayments and community gifting.
/// Binds sender, receiver, gift, amount, timestamp, chain, and nonce into an immutable hash commitment.
class PowProof {
  const PowProof({
    required this.algorithm,
    required this.difficulty,
    required this.challenge,
    required this.nonce,
    required this.hash,
    required this.timestampMs,
    required this.timeTakenMs,
    required this.chainId,
  });

  final String algorithm; // 'SHA-256'
  final int difficulty; // Number of leading zero hex chars required
  final String challenge; // Challenge payload string
  final int nonce; // Winning counter
  final String hash; // The resulting hash with leading zeroes
  final int timestampMs; // Epoch milliseconds when generated
  final int timeTakenMs; // Computation elapsed time in ms
  final String chainId; // Ledger / blockchain reference

  Map<String, dynamic> toJson() => {
    'algorithm': algorithm,
    'difficulty': difficulty,
    'challenge': challenge,
    'nonce': nonce,
    'hash': hash,
    'timestamp_ms': timestampMs,
    'time_taken_ms': timeTakenMs,
    'chain_id': chainId,
  };

  factory PowProof.fromJson(Map<String, dynamic> json) => PowProof(
    algorithm: json['algorithm']?.toString() ?? 'SHA-256',
    difficulty: (json['difficulty'] as num?)?.toInt() ?? 3,
    challenge: json['challenge']?.toString() ?? '',
    nonce: (json['nonce'] as num?)?.toInt() ?? 0,
    hash: json['hash']?.toString() ?? '',
    timestampMs: (json['timestamp_ms'] as num?)?.toInt() ?? 0,
    timeTakenMs: (json['time_taken_ms'] as num?)?.toInt() ?? 0,
    chainId: json['chain_id']?.toString() ?? 'necxa-mainnet-ugx',
  );
}

/// Service providing client-side cryptographic Proof of Work to prevent
/// automated Sybil attacks, bot spamming, script execution, and replay fraud.
class CryptoPowService {
  CryptoPowService._();
  static final CryptoPowService instance = CryptoPowService._();

  static const String defaultChainId = 'necxa-mainnet-ugx';
  static const int standardDifficulty = 3; // '000...' (instant on mobile ~10-40ms)
  static const int highValueDifficulty = 4; // '0000...' (for luxury/big gifts >= 100 NCX, ~150-300ms)

  /// Generates and computes a valid cryptographic proof of work for a gift transfer.
  Future<PowProof> generateProof({
    required String senderId,
    required String receiverId,
    required String giftItemId,
    required int ncxAmount,
    required String idempotencyKey,
    String chainId = defaultChainId,
    int? customDifficulty,
  }) async {
    final difficulty = customDifficulty ??
        (ncxAmount >= 100 ? highValueDifficulty : standardDifficulty);
    final targetPrefix = '0' * difficulty;
    final timestampMs = DateTime.now().millisecondsSinceEpoch;

    // Challenge string binds all core economic parameters to prevent parameter tampering
    final challenge =
        '$senderId|$receiverId|$giftItemId|$ncxAmount|$timestampMs|$idempotencyKey|$chainId';

    final stopwatch = Stopwatch()..start();
    int nonce = 0;
    String winningHash = '';

    while (true) {
      final input = '$challenge:$nonce';
      final digest = sha256.convert(utf8.encode(input)).toString();
      if (digest.startsWith(targetPrefix)) {
        winningHash = digest;
        break;
      }
      nonce++;

      // Yield control every 5,000 hashes so UI remains perfectly fluid on mobile threads
      if (nonce % 5000 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    stopwatch.stop();

    final proof = PowProof(
      algorithm: 'SHA-256',
      difficulty: difficulty,
      challenge: challenge,
      nonce: nonce,
      hash: winningHash,
      timestampMs: timestampMs,
      timeTakenMs: stopwatch.elapsedMilliseconds,
      chainId: chainId,
    );

    debugPrint(
      '🔒 [CryptoPow] Solved PoW in ${proof.timeTakenMs}ms (diff: $difficulty, nonce: $nonce, hash: ${winningHash.substring(0, 10)}...)',
    );
    return proof;
  }

  /// Verifies a Proof of Work in O(1) time complexity.
  static bool verifyProof(PowProof proof, {Duration maxAge = const Duration(minutes: 5)}) {
    if (proof.difficulty <= 0 || proof.challenge.isEmpty || proof.hash.isEmpty) {
      return false;
    }

    // Check freshness: proof must not be older than allowed window
    final ageMs = DateTime.now().millisecondsSinceEpoch - proof.timestampMs;
    if (ageMs.abs() > maxAge.inMilliseconds) {
      debugPrint('⚠️ [CryptoPow] Verification rejected: Proof expired (age: ${ageMs}ms)');
      return false;
    }

    final targetPrefix = '0' * proof.difficulty;
    if (!proof.hash.startsWith(targetPrefix)) {
      return false;
    }

    final input = '${proof.challenge}:${proof.nonce}';
    final computed = sha256.convert(utf8.encode(input)).toString();
    return computed == proof.hash;
  }
}
