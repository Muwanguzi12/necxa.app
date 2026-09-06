import 'package:universal_io/io.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'auth_retry.dart';

/// Converts raw backend exceptions and network errors into clean, user-friendly messages.
String getUserFriendlyError(dynamic error) {
  if (error == null) return "An unknown error occurred. Please try again.";

  final errorStr = error.toString().toLowerCase();

  // Network / Socket Exceptions
  if (error is SocketException ||
      errorStr.contains('socketexception') ||
      errorStr.contains('failed host lookup')) {
    return "No internet connection. Please check your network and try again.";
  }

  if (error is TimeoutException || errorStr.contains('timeout')) {
    return "Connection timed out. Please try again.";
  }

  // Preserve safe identity-function outcomes instead of hiding them behind the
  // generic loading message.
  const identityMessages = <String, String>{
    'verification results are still syncing':
        'Verification is still syncing. Tap Verify again without retaking your photos.',
    'verification receipts are missing':
        'Verification receipts are missing. Please complete the identity capture again.',
    'direct identity verification receipts':
        'Identity verification could not save its results. Please try Verify again.',
    'biometric receipt':
        'The face verification result was not approved. Please retry the face capture.',
    'document receipt':
        'One of the document captures was not approved. Please retry that capture.',
  };
  for (final entry in identityMessages.entries) {
    if (errorStr.contains(entry.key)) return entry.value;
  }

  // Supabase Auth Exceptions
  if (error is AuthException) {
    if (error.message.toLowerCase().contains('invalid login credentials')) {
      return "Invalid email or verification code. Please check and try again.";
    }
    if (isAuthRateLimitError(error)) {
      final delay = magicLinkRetryDelay(error);
      return "A sign-in email was requested recently. Try again in ${formatRetryCountdown(delay.inSeconds)} or use the link already in your inbox.";
    }
    if (error.message.toLowerCase().contains('expired')) {
      return "The magic link or code has expired. Please request a new one.";
    }
    return error
        .message; // AuthException messages are usually somewhat clean, but fallback if needed.
  }

  // Platform Exceptions (e.g., Camera, Biometrics)
  if (error is PlatformException) {
    if (error.code == 'NotAvailable') {
      return "This feature is not available on your device.";
    }
    if (errorStr.contains('camera') || errorStr.contains('microphone')) {
      return "Camera or microphone access was denied. Please allow permissions and try again.";
    }
    return "A device error occurred. Please try again.";
  }

  // Live streaming / Agora-specific failures
  if (errorStr.contains('permission') || errorStr.contains('denied')) {
    return "Camera or microphone access was denied. Please allow permissions and try again.";
  }

  if (errorStr.contains('token') ||
      errorStr.contains('authentication failed') ||
      errorStr.contains('identity verification required')) {
    return "Live streaming authentication failed. Please try again in a moment.";
  }

  if (errorStr.contains('channel') ||
      errorStr.contains('joinchannel') ||
      errorStr.contains('join channel')) {
    return "Unable to connect to the live channel. Please try again.";
  }

  // Fallback Catch-All
  // If the error contains raw backend URLs or keys, we MUST mask it.
  if (errorStr.contains('supabase.co') ||
      errorStr.contains('apikey') ||
      errorStr.contains('http')) {
    return "Loading unsuccessful. Please check your connection and try again.";
  }

  // If it's a standard generic exception, it might be a developer string or a clean message.
  // If it's explicitly marked as UserMessageException, return it.
  if (error is UserMessageException) {
    return error.message;
  }

  // Return a generic safe message for any other raw exceptions
  return "Loading unsuccessful. Please try again.";
}

/// Use this exception for messages that are already safe to show to the user.
class UserMessageException implements Exception {
  final String message;
  UserMessageException(this.message);
  @override
  String toString() => message;
}
