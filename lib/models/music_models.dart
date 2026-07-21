class MusicTrack {
  final String id;
  final String title;
  final String artistName;
  final String? albumArtUrl;
  final String? previewUrl;
  final String audioUrl;
  final int duration;
  final String licenseType;
  final String soundType; // 'official' or 'user_sound'
  final String? genre;
  final int usageCount;
  final bool isTrending;
  final bool isFeatured;
  final Map<String, dynamic>? waveformData;

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
  });

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
