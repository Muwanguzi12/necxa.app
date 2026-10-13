const Duration defaultMagicLinkCooldown = Duration(seconds: 60);

bool isAuthRateLimitError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('rate limit') ||
      message.contains('too many requests') ||
      message.contains('over_email_send_rate_limit') ||
      message.contains('only request this after') ||
      message.contains('statuscode: 429') ||
      message.contains('status code: 429');
}

Duration magicLinkRetryDelay(
  Object error, {
  Duration fallback = defaultMagicLinkCooldown,
}) {
  final message = error.toString().toLowerCase();
  final match = RegExp(
    r'(?:retry(?: again)?|request this|try again)?\s*(?:after|in)\s+(\d+)\s*(second|minute)s?',
  ).firstMatch(message);

  if (match == null) return fallback;

  final amount = int.tryParse(match.group(1) ?? '');
  if (amount == null || amount <= 0) return fallback;

  return match.group(2) == 'minute'
      ? Duration(minutes: amount)
      : Duration(seconds: amount);
}

String formatRetryCountdown(int totalSeconds) {
  final safeSeconds = totalSeconds < 0 ? 0 : totalSeconds;
  final minutes = safeSeconds ~/ 60;
  final seconds = safeSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
