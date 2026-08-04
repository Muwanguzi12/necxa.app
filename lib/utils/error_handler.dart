import 'package:universal_io/io.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';

/// Converts raw backend exceptions and network errors into clean, user-friendly messages.
String getUserFriendlyError(dynamic error) {
  if (error == null) return "An unknown error occurred. Please try again.";

  final errorStr = error.toString().toLowerCase();

  // Network / Socket Exceptions
  if (error is SocketException || errorStr.contains('socketexception') || errorStr.contains('failed host lookup')) {
    return "No internet connection. Please check your network and try again.";
  }

  if (error is TimeoutException || errorStr.contains('timeout')) {
    return "Connection timed out. Please try again.";
  }

  // Supabase Auth Exceptions
  if (error is AuthException) {
    if (error.message.toLowerCase().contains('invalid login credentials')) {
      return "Invalid email or verification code. Please check and try again.";
    }
    if (error.message.toLowerCase().contains('rate limit')) {
      return "Too many requests. Please wait a moment before trying again.";
    }
    if (error.message.toLowerCase().contains('expired')) {
      return "The magic link or code has expired. Please request a new one.";
    }
    return error.message; // AuthException messages are usually somewhat clean, but fallback if needed.
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

  if (errorStr.contains('token') || errorStr.contains('authentication failed') || errorStr.contains('identity verification required')) {
    return "Live streaming authentication failed. Please try again in a moment.";
  }

  if (errorStr.contains('channel') || errorStr.contains('joinchannel') || errorStr.contains('join channel')) {
    return "Unable to connect to the live channel. Please try again.";
  }

  // Fallback Catch-All
  // If the error contains raw backend URLs or keys, we MUST mask it.
  if (errorStr.contains('supabase.co') || errorStr.contains('apikey') || errorStr.contains('http')) {
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
