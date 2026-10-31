/// Utility helpers for resolving Necxa user display names consistently.
///
/// Priority chain for names:
///   full_name → display_name → username → email prefix → 'Necxa User'
///
/// Never returns: 'Unknown User', 'User', 'John Doe', 'Anonymous', 'USER'
library necxa_user;

class NecxaUser {
  NecxaUser._();

  static const _fallback = 'Necxa User';

  /// Resolves the best display name from a profile map (or any data map).
  ///
  /// Pass the raw profile map from Supabase, AppState.myProfile, etc.
  static String name(Map<String, dynamic>? profile, {String? email}) {
    final candidates = [
      profile?['full_name'],
      profile?['display_name'],
      profile?['username'],
      // strip leading @ if stored with it
      if (profile?['username'] != null)
        (profile!['username'] as String).replaceFirst('@', ''),
      // email prefix as last resort
      if (email != null && email.isNotEmpty) email.split('@').first,
      if (profile?['email'] != null)
        (profile!['email'] as String).split('@').first,
    ];
    for (final c in candidates) {
      final s = c?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return _fallback;
  }

  /// Like [name] but returns null instead of the fallback when no name found.
  /// Useful for conditionally showing a placeholder avatar initial.
  static String? nameOrNull(Map<String, dynamic>? profile, {String? email}) {
    final resolved = name(profile, email: email);
    return resolved == _fallback ? null : resolved;
  }

  /// Returns just the first word (first name) of the resolved display name.
  static String firstName(Map<String, dynamic>? profile, {String? email}) {
    return name(profile, email: email).split(' ').first;
  }

  /// Resolves the avatar URL from a profile map.
  static String? avatar(Map<String, dynamic>? profile) {
    final candidates = [
      profile?['avatar_url'],
      profile?['photo_url'],
      profile?['avatar'],
    ];
    for (final c in candidates) {
      final s = c?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  /// Returns the initial letter to use in an avatar placeholder.
  static String initial(Map<String, dynamic>? profile, {String? email}) {
    final n = name(profile, email: email);
    return n.isNotEmpty ? n[0].toUpperCase() : 'N';
  }
}
