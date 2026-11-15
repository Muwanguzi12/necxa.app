import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/utils/auth_retry.dart';

void main() {
  group('magic link retry handling', () {
    test('recognizes common Supabase rate-limit messages', () {
      expect(
        isAuthRateLimitError(Exception('Email rate limit exceeded')),
        isTrue,
      );
      expect(
        isAuthRateLimitError(
          Exception(
            'For security purposes, you can only request this after 42 seconds.',
          ),
        ),
        isTrue,
      );
      expect(isAuthRateLimitError(Exception('Invalid OTP')), isFalse);
    });

    test('uses the retry duration provided by the server', () {
      expect(
        magicLinkRetryDelay(
          Exception(
            'For security purposes, you can only request this after 42 seconds.',
          ),
        ),
        const Duration(seconds: 42),
      );
      expect(
        magicLinkRetryDelay(Exception('Please try again after 2 minutes.')),
        const Duration(minutes: 2),
      );
    });

    test('falls back safely and formats the countdown', () {
      expect(
        magicLinkRetryDelay(Exception('Too many requests')),
        defaultMagicLinkCooldown,
      );
      expect(formatRetryCountdown(65), '1:05');
      expect(formatRetryCountdown(-1), '0:00');
    });
  });
}
