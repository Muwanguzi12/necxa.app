import 'package:universal_io/io.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../models/music_models.dart';
import 'goobox_artist_music_service.dart';

class MusicLibraryService {
  SupabaseClient get _supabase => Supabase.instance.client;
  final AudioPlayer _previewPlayer = AudioPlayer();

  // 1. DISCOVERY & SEARCH
  Future<List<MusicTrack>> searchMusic({
    String? query,
    String? genre,
    String? licenseType,
    int limit = 50,
  }) async {
    // 1. Fetch Goobox artist tracks first
    List<MusicTrack> gooboxTracks = [];
    try {
      gooboxTracks = await GooboxArtistMusicService.instance
          .fetchDiscoveryTracks(genre: genre, query: query);
    } catch (e) {
      debugPrint('[MusicLibrary] Goobox discovery notice: $e');
    }

    if (licenseType == 'artist_upload') {
      if (gooboxTracks.isNotEmpty) return gooboxTracks;
    }

    // 2. Query platform backend
    try {
      final response = await _supabase.functions.invoke('clever-processor', body: {
        'action': 'search-music',
        'payload': {
          'query': query,
          'genre': genre,
          'license_type': licenseType,
          'limit': limit,
        },
      });

      if (response.status == 200 && response.data != null) {
        final data = response.data['data'] as List?;
        if (data != null) {
          final platformTracks = data.map((json) => MusicTrack.fromJson(json)).toList();
          final combined = [...gooboxTracks, ...platformTracks];
          final seen = <String>{};
          return combined.where((t) => seen.add(t.id)).take(limit).toList();
        }
      }
    } catch (e) {
      debugPrint('[MusicLibrary] Backend search notice: $e');
    }

    return gooboxTracks;
  }

  Future<Map<String, dynamic>> getMusicDiscovery() async {
    List<MusicTrack> gooboxTracks = [];
    try {
      gooboxTracks = await GooboxArtistMusicService.instance.fetchDiscoveryTracks();
    } catch (_) {}

    try {
      final response = await _supabase.functions.invoke('clever-processor', body: {
        'action': 'fetch-music-discovery',
      });

      if (response.status == 200 && response.data != null) {
        final data = response.data['data'];
        final trending = (data['trending'] as List? ?? [])
            .map((json) => MusicTrack.fromJson(json))
            .toList();
        final featured = (data['featured'] as List? ?? [])
            .map((json) => MusicTrack.fromJson(json))
            .toList();
        final genres = (data['genres'] as List? ?? [])
            .map((json) => MusicGenre.fromJson(json))
            .toList();

        return {
          'genres': genres,
          'trending': [...gooboxTracks, ...trending],
          'featured': [...gooboxTracks, ...featured],
        };
      }
    } catch (e) {
      debugPrint('[MusicLibrary] Backend discovery notice: $e');
    }

    // Resilient fallback with standard genres and Goobox artist tracks
    final fallbackGenres = [
      MusicGenre(id: 'afrobeats', name: 'Afrobeats', icon: '??', color: '#FF7B2F'),
      MusicGenre(id: 'hiphop', name: 'Hip Hop', icon: '??', color: '#7B2FFF'),
      MusicGenre(id: 'pop', name: 'Pop', icon: '?', color: '#00E5FF'),
      MusicGenre(id: 'rnb', name: 'R&B', icon: '??', color: '#EC4899'),
      MusicGenre(id: 'amapiano', name: 'Amapiano', icon: '??', color: '#F59E0B'),
      MusicGenre(id: 'electronic', name: 'Electronic', icon: '??', color: '#10B981'),
    ];

    return {
      'genres': fallbackGenres,
      'trending': gooboxTracks,
      'featured': gooboxTracks,
    };
  }

  Future<MusicTrack?> getTrackById(String soundId) async {
    // 🔍 Query the Unified View instead of just music_tracks
    final response = await _supabase
        .from('v_unified_music_library')
        .select()
        .eq('sound_id', soundId)
        .maybeSingle();
    
    if (response == null) return null;
    return MusicTrack.fromJson(response);
  }

  Future<List<MusicGenre>> getGenres() async {
    final discovery = await getMusicDiscovery();
    return discovery['genres'] as List<MusicGenre>;
  }

  // 2. SAVED MUSIC
  Future<void> toggleSaveMusic(String trackId, bool save) async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    if (save) {
      await _supabase.from('user_saved_music').upsert({
        'user_id': user.id,
        'track_id': trackId,
      });
    } else {
      await _supabase
          .from('user_saved_music')
          .delete()
          .match({'user_id': user.id, 'track_id': trackId});
    }
  }

  // 3. PLAYBACK
  Future<void> previewMusic(String url) async {
    await _previewPlayer.stop();
    await _previewPlayer.play(UrlSource(url));
  }

  Future<void> stopPreview() async {
    await _previewPlayer.stop();
  }

  // 4. OFFLINE PROCESSING
  Future<File> downloadMusicTrack(MusicTrack track) async {
    final response = await http.get(Uri.parse(track.audioUrl));
    final directory = await getTemporaryDirectory();
    final extension = track.audioUrl.split('.').last.split('?').first;
    final file = File('${directory.path}/track_${track.id}.$extension');
    await file.writeAsBytes(response.bodyBytes);
    return file;
  }

  void dispose() {
    _previewPlayer.dispose();
  }
}
