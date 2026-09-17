import 'package:universal_io/io.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../models/music_models.dart';

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
    final response = await _supabase.functions.invoke('clever-processor', body: {
      'action': 'search-music',
      'payload': {
        'query': query,
        'genre': genre,
        'license_type': licenseType,
        'limit': limit,
      },
    });
    
    if (response.status != 200) return [];
    final data = response.data['data'] as List;
    return data.map((json) => MusicTrack.fromJson(json)).toList();
  }

  Future<Map<String, dynamic>> getMusicDiscovery() async {
    final response = await _supabase.functions.invoke('clever-processor', body: {
      'action': 'fetch-music-discovery',
    });
    
    if (response.status != 200) throw Exception('Music Discovery Node Unreachable');
    final data = response.data['data'];
    
    return {
      'genres': (data['genres'] as List).map((json) => MusicGenre.fromJson(json)).toList(),
      'trending': (data['trending'] as List).map((json) => MusicTrack.fromJson(json)).toList(),
      'featured': (data['featured'] as List).map((json) => MusicTrack.fromJson(json)).toList(),
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
