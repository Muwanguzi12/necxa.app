import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/services/ai_service.dart';

void main() {
  group('identity shard payloads', () {
    test('builds an ID verification payload', () {
      final payload = NecxaAI.buildIdentityShardPayload(
        action: 'verify-id',
        primaryBase64: 'abc',
        userId: 'user-1',
      );
      expect(payload['action'], 'verify-id');
      expect(payload['payload']['imageBase64'], 'abc');
      expect(payload['payload']['userId'], 'user-1');
    });

    test('builds a selfie verification payload', () {
      final payload = NecxaAI.buildIdentityShardPayload(
        action: 'verify-selfie',
        primaryBase64: 'selfie',
        secondaryBase64: 'id',
        userId: 'user-2',
      );
      expect(payload['action'], 'verify-selfie');
      expect(payload['payload']['imageBase64'], 'selfie');
      expect(payload['payload']['idImageBase64'], 'id');
      expect(payload['payload']['userId'], 'user-2');
    });

    test('builds a face-only liveness payload without an ID reference', () {
      final payload = NecxaAI.buildIdentityShardPayload(
        action: 'verify-face-only',
        primaryBase64: 'selfie',
        userId: 'user-3',
      );
      expect(payload['action'], 'verify-face-only');
      expect(payload['payload']['imageBase64'], 'selfie');
      expect(payload['payload'].containsKey('idImageBase64'), isFalse);
      expect(payload['payload']['userId'], 'user-3');
    });
  });
}
