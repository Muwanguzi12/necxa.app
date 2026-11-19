class MusicTrack {
  final String id;
  final String title;
  final String artistName;
  final String? albumArtUrl;
  final String? previewUrl;
  final String audioUrl;
  final int duration;
  final String licenseType;
  final String soundType; // 'official' | 'user_sound' | 'distributor_linked'
  final String? genre;
  final int usageCount;
  final bool isTrending;
  final bool isFeatured;
  final Map<String, dynamic>? waveformData;

  // ── Distributor / streaming platform fields ──────────────────────────────
  /// The canonical smart-link on the distributor platform
  /// (e.g. https://open.spotify.com/track/xxx or a DistroKid hyperfollow link).
  final String? distributorUrl;

  /// Short platform key: 'spotify' | 'apple_music' | 'distrokid' |
  /// 'audiomack' | 'tidal' | 'deezer' | 'soundcloud' | 'other'
  final String? distributorPlatform;

  MusicTrack({
    required this.id,
    required this.title,
    required this.artistName,
    this.albumArtUrl,
    this.previewUrl,
    required this.audioUrl,
    required this.duration,
    required this.licenseType,
    this.soundType = 'official',
    this.genre,
    this.usageCount = 0,
    this.isTrending = false,
    this.isFeatured = false,
    this.waveformData,
    this.distributorUrl,
    this.distributorPlatform,
  });

  /// Whether this track was linked from an external distributor / streaming
  /// platform (as opposed to being directly uploaded to Goobox storage).
  bool get isDistributorLinked =>
      soundType == 'distributor_linked' || distributorUrl != null;

  /// Human-readable label shown on the feed attribution pill.
  String get distributorLabel {
    switch (distributorPlatform) {
      case 'spotify':
        return 'Spotify';
      case 'apple_music':
        return 'Apple Music';
      case 'distrokid':
        return 'DistroKid';
      case 'audiomack':
        return 'Audiomack';
      case 'tidal':
        return 'TIDAL';
      case 'deezer':
        return 'Deezer';
      case 'soundcloud':
        return 'SoundCloud';
      default:
        return 'Stream';
    }
  }

  factory MusicTrack.fromJson(Map<String, dynamic> json) {
    return MusicTrack(
      id: json['sound_id'] ?? json['id'],
      title: json['title'],
      artistName: json['artist'] ?? json['artist_name'] ?? 'Unknown Artist',
      albumArtUrl: json['cover_url'] ?? json['album_art_url'],
      previewUrl: json['preview_url'],
      audioUrl: json['audio_url'],
      duration: json['duration'] ?? 15,
      licenseType: json['license_type'] ?? 'user_sound',
      soundType: json['sound_type'] ?? 'official',
      genre: json['genre'],
      usageCount: json['usage_count'] ?? 0,
      isTrending: json['is_trending'] ?? false,
      isFeatured: json['is_featured'] ?? false,
      waveformData: json['waveform_data'],
      distributorUrl: json['distributor_url'],
      distributorPlatform: json['distributor_platform'],
    );
  }

  String get formattedDuration {
    final minutes = duration ~/ 60;
    final seconds = duration % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Duration get timelineDuration => Duration(seconds: duration);
}


class MusicGenre {
  final String id;
  final String name;
  final String? icon;
  final String? color;

  MusicGenre({required this.id, required this.name, this.icon, this.color});

  factory MusicGenre.fromJson(Map<String, dynamic> json) {
    return MusicGenre(
      id: json['id'],
      name: json['name'],
      icon: json['icon'],
      color: json['color'],
    );
  }
}
