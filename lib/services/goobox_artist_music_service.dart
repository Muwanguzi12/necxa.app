import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:universal_io/io.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/music_models.dart';

/// GooboxArtistMusicService manages music tracks stored in Goobox Supabase
/// (https://anregykcgolpgxecfxej.supabase.co).
///
/// Under the strict project architecture, the primary Supabase database
/// (lzdtrmjcwzalckszdzpt) does NOT store audio files or artist music tracks.
/// Instead, all music audio, artwork, and track catalogs are stored and
/// fetched directly from Goobox Supabase storage and endpoints.
class GooboxArtistMusicService {
  GooboxArtistMusicService._internal() {
    _initAudioListeners();
  }
  static final GooboxArtistMusicService instance = GooboxArtistMusicService._internal();

  // Goobox Supabase Configuration
  static const String gooboxBaseUrl = 'https://anregykcgolpgxecfxej.supabase.co';
  static const String gooboxAnonKey = 'sb_publishable_KzEAI6a7Xvw-Jz-BqPQRRA_mn4iKnou';
  static const String _gooboxServiceKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFucmVneWtjZ29scGd4ZWNmeGVqIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MDQ2MjU1NCwiZXhwIjoyMDk2MDM4NTU0fQ.519sxkeFrEL-zIyP2MM4kbSZ3sHHP7OY-uwXoDV7cnc';
  static const String storageBucket = 'ticket-attachments';

  // Audio Playback
  final AudioPlayer _audioPlayer = AudioPlayer();
  final ValueNotifier<String?> playingTrackId = ValueNotifier<String?>(null);
  final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false);

  // In-memory cache for fast UI access
  final Map<String, List<MusicTrack>> _artistCache = {};
  List<MusicTrack>? _globalDiscoveryCache;

  void _initAudioListeners() {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      isPlaying.value = (state == PlayerState.playing);
      if (state == PlayerState.completed || state == PlayerState.stopped) {
        playingTrackId.value = null;
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 1. FETCH ARTIST TRACKS (from Goobox Supabase)
  // ─────────────────────────────────────────────────────────────────────────

  /// Fetches all music tracks for a specific artist by their user/artist ID
  /// from Goobox Supabase.
  Future<List<MusicTrack>> fetchArtistTracks(
    String artistId, {
    bool forceRefresh = false,
  }) async {
    if (artistId.trim().isEmpty) return [];

    if (!forceRefresh && _artistCache.containsKey(artistId)) {
      return _artistCache[artistId]!;
    }

    // Path to artist's catalog in Goobox storage:
    // ticket-attachments/music/{artistId}/catalog.json
    final catalogPublicUrl =
        '$gooboxBaseUrl/storage/v1/object/public/$storageBucket/music/$artistId/catalog.json';

    try {
      final res = await http.get(
        Uri.parse(catalogPublicUrl),
        headers: {
          'Cache-Control': 'no-cache',
        },
      ).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200 && res.body.trim().isNotEmpty) {
        final decoded = jsonDecode(res.body);
        if (decoded is List) {
          final tracks = decoded
              .map((item) => MusicTrack.fromJson(item as Map<String, dynamic>))
              .toList();
          _artistCache[artistId] = tracks;
          debugPrint('[GooboxMusic] Loaded ${tracks.length} tracks for artist $artistId from Goobox');
          return tracks;
        }
      }
    } catch (e) {
      debugPrint('[GooboxMusic] Notice reading catalog.json for $artistId: $e');
    }

    // Fallback: If catalog.json isn't present yet, list objects under prefix
    try {
      final listUri = Uri.parse('$gooboxBaseUrl/storage/v1/object/list/$storageBucket');
      final listRes = await http.post(
        listUri,
        headers: {
          'apikey': gooboxAnonKey,
          'Authorization': 'Bearer $gooboxAnonKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'prefix': 'music/$artistId/',
          'limit': 100,
        }),
      ).timeout(const Duration(seconds: 8));

      if (listRes.statusCode == 200) {
        final List<dynamic> items = jsonDecode(listRes.body);
        final List<MusicTrack> recoveredTracks = [];

        for (final item in items) {
          final name = item['name']?.toString() ?? '';
          if (_isAudioExtension(name)) {
            final audioUrl =
                '$gooboxBaseUrl/storage/v1/object/public/$storageBucket/music/$artistId/$name';
            final cleanTitle = name
                .replaceAll(RegExp(r'^\d+_'), '')
                .replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '')
                .replaceAll('_', ' ');

            recoveredTracks.add(MusicTrack(
              id: 'goobox_${name.hashCode}',
              title: cleanTitle.isEmpty ? 'Release Track' : cleanTitle,
              artistName: 'Verified Artist',
              audioUrl: audioUrl,
              duration: 180,
              licenseType: 'official',
              soundType: 'official',
              genre: 'Music',
            ));
          }
        }

        if (recoveredTracks.isNotEmpty) {
          _artistCache[artistId] = recoveredTracks;
          return recoveredTracks;
        }
      }
    } catch (e) {
      debugPrint('[GooboxMusic] Fallback storage list notice: $e');
    }

    return [];
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 2. FETCH GLOBAL DISCOVERY TRACKS (from Goobox Supabase)
  // ─────────────────────────────────────────────────────────────────────────

  /// Fetches global artist tracks stored in Goobox Supabase for discovery in feed/editor.
  Future<List<MusicTrack>> fetchDiscoveryTracks({
    String? genre,
    String? query,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _globalDiscoveryCache != null) {
      return _filterTracks(_globalDiscoveryCache!, genre: genre, query: query);
    }

    const globalCatalogUrl =
        '$gooboxBaseUrl/storage/v1/object/public/$storageBucket/music/global_catalog.json';

    try {
      final res = await http.get(
        Uri.parse(globalCatalogUrl),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200 && res.body.trim().isNotEmpty) {
        final decoded = jsonDecode(res.body);
        if (decoded is List) {
          final tracks = decoded
              .map((item) => MusicTrack.fromJson(item as Map<String, dynamic>))
              .toList();
          _globalDiscoveryCache = tracks;
          return _filterTracks(tracks, genre: genre, query: query);
        }
      }
    } catch (e) {
      debugPrint('[GooboxMusic] Notice reading global_catalog.json: $e');
    }

    return [];
  }

  List<MusicTrack> _filterTracks(List<MusicTrack> all, {String? genre, String? query}) {
    return all.where((t) {
      if (genre != null && genre.isNotEmpty && genre.toLowerCase() != 'all') {
        if ((t.genre ?? '').toLowerCase() != genre.toLowerCase()) return false;
      }
      if (query != null && query.trim().isNotEmpty) {
        final q = query.toLowerCase().trim();
        final matchTitle = t.title.toLowerCase().contains(q);
        final matchArtist = t.artistName.toLowerCase().contains(q);
        final matchGenre = (t.genre ?? '').toLowerCase().contains(q);
        if (!matchTitle && !matchArtist && !matchGenre) return false;
      }
      return true;
    }).toList();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 3. UPLOAD TRACK (to Goobox Supabase)
  // ─────────────────────────────────────────────────────────────────────────

  /// Uploads an artist's audio file and cover image directly to Goobox Supabase,
  /// builds a [MusicTrack], and updates the artist's catalog and global catalog.
  Future<MusicTrack> uploadTrack({
    required String artistId,
    required String artistName,
    required File audioFile,
    File? coverFile,
    required String title,
    String? genre,
    int duration = 180,
    String licenseType = 'official',
  }) async {
    if (!await audioFile.exists()) {
      throw Exception('Audio file could not be found');
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final audioExt = audioFile.path.split('.').last.toLowerCase();
    final cleanAudioName = 'track_${ts}_${_sanitizeFilename(title)}.$audioExt';
    final audioStoragePath = 'music/$artistId/$cleanAudioName';

    // 1. Upload audio file bytes to Goobox Supabase storage
    final audioBytes = await audioFile.readAsBytes();
    final audioUploadUri =
        Uri.parse('$gooboxBaseUrl/storage/v1/object/$storageBucket/$audioStoragePath');

    final audioRes = await http.post(
      audioUploadUri,
      headers: {
        'apikey': _gooboxServiceKey,
        'Authorization': 'Bearer $_gooboxServiceKey',
        'Content-Type': _mimeForExtension(audioExt),
        'x-upsert': 'true',
      },
      body: audioBytes,
    );

    if (audioRes.statusCode != 200 && audioRes.statusCode != 201) {
      throw Exception('Failed to upload audio to Goobox Supabase: ${audioRes.body}');
    }

    final publicAudioUrl =
        '$gooboxBaseUrl/storage/v1/object/public/$storageBucket/$audioStoragePath';

    // 2. Upload cover artwork if provided
    String? publicCoverUrl;
    if (coverFile != null && await coverFile.exists()) {
      try {
        final coverExt = coverFile.path.split('.').last.toLowerCase();
        final coverStoragePath = 'music/$artistId/cover_$ts.$coverExt';
        final coverBytes = await coverFile.readAsBytes();
        final coverUploadUri =
            Uri.parse('$gooboxBaseUrl/storage/v1/object/$storageBucket/$coverStoragePath');

        final coverRes = await http.post(
          coverUploadUri,
          headers: {
            'apikey': _gooboxServiceKey,
            'Authorization': 'Bearer $_gooboxServiceKey',
            'Content-Type': _mimeForExtension(coverExt),
            'x-upsert': 'true',
          },
          body: coverBytes,
        );

        if (coverRes.statusCode == 200 || coverRes.statusCode == 201) {
          publicCoverUrl =
              '$gooboxBaseUrl/storage/v1/object/public/$storageBucket/$coverStoragePath';
        }
      } catch (e) {
        debugPrint('[GooboxMusic] Artwork upload notice: $e');
      }
    }

    // 3. Construct new MusicTrack
    final newTrack = MusicTrack(
      id: 'goobox_${artistId}_$ts',
      title: title.trim(),
      artistName: artistName.trim().isEmpty ? 'Verified Artist' : artistName.trim(),
      albumArtUrl: publicCoverUrl,
      audioUrl: publicAudioUrl,
      duration: duration,
      licenseType: licenseType,
      soundType: 'official',
      genre: (genre != null && genre.isNotEmpty) ? genre : 'Music',
      usageCount: 0,
    );

    // 4. Update the artist's catalog in Goobox storage
    try {
      final existingTracks = await fetchArtistTracks(artistId, forceRefresh: true);
      final updatedTracks = [newTrack, ...existingTracks];

      await _saveCatalogToStorage(
        'music/$artistId/catalog.json',
        updatedTracks.map((t) => _trackToJson(t)).toList(),
      );

      _artistCache[artistId] = updatedTracks;
    } catch (e) {
      debugPrint('[GooboxMusic] Error saving artist catalog: $e');
    }

    // 5. Update global discovery catalog in Goobox storage
    try {
      final existingGlobal = await fetchDiscoveryTracks(forceRefresh: true);
      final updatedGlobal = [newTrack, ...existingGlobal];

      await _saveCatalogToStorage(
        'music/global_catalog.json',
        updatedGlobal.map((t) => _trackToJson(t)).toList(),
      );

      _globalDiscoveryCache = updatedGlobal;
    } catch (e) {
      debugPrint('[GooboxMusic] Error saving global discovery catalog: $e');
    }

    return newTrack;
  }

  Future<void> _saveCatalogToStorage(String path, List<Map<String, dynamic>> items) async {
    final uri = Uri.parse('$gooboxBaseUrl/storage/v1/object/$storageBucket/$path');
    final body = jsonEncode(items);

    final res = await http.post(
      uri,
      headers: {
        'apikey': _gooboxServiceKey,
        'Authorization': 'Bearer $_gooboxServiceKey',
        'Content-Type': 'application/json',
        'x-upsert': 'true',
      },
      body: body,
    );

    if (res.statusCode != 200 && res.statusCode != 201) {
      debugPrint('[GooboxMusic] Notice updating $path (${res.statusCode}): ${res.body}');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 4. AUDIO PLAYBACK CONTROLS
  // ─────────────────────────────────────────────────────────────────────────

  /// Play or toggle play/pause for a track directly from its Goobox URL.
  Future<void> togglePlay(MusicTrack track) async {
    if (playingTrackId.value == track.id && isPlaying.value) {
      await _audioPlayer.pause();
    } else if (playingTrackId.value == track.id && !isPlaying.value) {
      await _audioPlayer.resume();
    } else {
      await _audioPlayer.stop();
      playingTrackId.value = track.id;
      await _audioPlayer.play(UrlSource(track.audioUrl));
    }
  }

  Future<void> stopPlayback() async {
    await _audioPlayer.stop();
    playingTrackId.value = null;
    isPlaying.value = false;
  }

  void dispose() {
    _audioPlayer.dispose();
    playingTrackId.dispose();
    isPlaying.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 5. HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  Map<String, dynamic> _trackToJson(MusicTrack track) {
    return {
      'sound_id': track.id,
      'title': track.title,
      'artist': track.artistName,
      'cover_url': track.albumArtUrl,
      'preview_url': track.previewUrl,
      'audio_url': track.audioUrl,
      'duration': track.duration,
      'license_type': track.licenseType,
      'sound_type': track.soundType,
      'genre': track.genre,
      'usage_count': track.usageCount,
      'is_trending': track.isTrending,
      'is_featured': track.isFeatured,
    };
  }

  bool _isAudioExtension(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.flac');
  }

  String _sanitizeFilename(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
  }

  String _mimeForExtension(String ext) {
    switch (ext.toLowerCase()) {
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'm4a':
      case 'aac':
        return 'audio/aac';
      case 'ogg':
        return 'audio/ogg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'jpg':
      case 'jpeg':
      default:
        return 'image/jpeg';
    }
  }
}
