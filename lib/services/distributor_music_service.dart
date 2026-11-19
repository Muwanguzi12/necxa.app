import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/music_models.dart';
import 'goobox_artist_music_service.dart';

/// Resolves a distributor / streaming platform URL (Spotify, Apple Music,
/// DistroKid HyperFollow, Audiomack, SoundCloud, Tidal, Deezer) into a
/// [MusicTrack] object and optionally registers it in the Goobox music catalog.
///
/// Artists paste their smart-link here — no audio is uploaded to Necxa.
/// The [previewUrl] streams directly from the distributor CDN; the
/// [distributorUrl] is the outbound canonical link shown in the feed.
class DistributorMusicService {
  static const _itunes =
      'https://itunes.apple.com/search?media=music&entity=song&limit=1&term=';
  static const _oEmbed = 'https://open.spotify.com/oembed?url=';

  // ─── Platform detection ────────────────────────────────────────────────────

  /// Detects which streaming platform a URL belongs to.
  static String detectPlatform(String url) {
    final u = url.toLowerCase();
    if (u.contains('spotify.com')) return 'spotify';
    if (u.contains('music.apple.com') || u.contains('itunes.apple.com'))
      return 'apple_music';
    if (u.contains('distrokid.com')) return 'distrokid';
    if (u.contains('audiomack.com')) return 'audiomack';
    if (u.contains('tidal.com')) return 'tidal';
    if (u.contains('deezer.com')) return 'deezer';
    if (u.contains('soundcloud.com')) return 'soundcloud';
    if (u.contains('linktr.ee') || u.contains('hyperfollow')) return 'other';
    return 'other';
  }

  // ─── Main resolver ─────────────────────────────────────────────────────────

  /// Resolves [url] to a [MusicTrack].
  ///
  /// Throws an [Exception] with a human-readable message when the URL cannot
  /// be resolved or is not recognised as a supported platform link.
  Future<MusicTrack> resolve(String url) async {
    url = url.trim();
    if (url.isEmpty) throw Exception('Please paste a valid distributor link.');

    final platform = detectPlatform(url);

    try {
      switch (platform) {
        case 'spotify':
          return await _resolveSpotify(url);
        case 'apple_music':
          return await _resolveAppleMusic(url);
        case 'audiomack':
          return await _resolveAudiomack(url);
        case 'soundcloud':
          return await _resolveSoundCloud(url);
        default:
          // Generic OEmbed fallback for DistroKid, Tidal, Deezer, Linktree
          return await _resolveOEmbedFallback(url, platform);
      }
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception(
          'Could not read this link. Make sure it is a public song URL.');
    }
  }

  // ─── Spotify ───────────────────────────────────────────────────────────────
  Future<MusicTrack> _resolveSpotify(String url) async {
    // Spotify OEmbed gives us title, thumbnail and embed HTML.
    final oEmbedRes = await http
        .get(Uri.parse('$_oEmbed${Uri.encodeComponent(url)}'))
        .timeout(const Duration(seconds: 10));

    if (oEmbedRes.statusCode != 200) {
      throw Exception(
          'Spotify link could not be read. Make sure the song is public.');
    }

    final oe = jsonDecode(oEmbedRes.body) as Map<String, dynamic>;

    // Extract the Spotify track ID so we can get a 30-second preview
    final trackId = _extractSpotifyTrackId(url);

    // Try the unofficial preview endpoint (no auth required for 30-second clips)
    final previewUrl = trackId != null
        ? await _fetchSpotifyPreview(trackId)
        : null;

    final title = (oe['title'] as String? ?? 'Unknown Track')
        .replaceAll(RegExp(r'\s*by\s+.*', caseSensitive: false), '');
    final artist = _extractSpotifyArtist(oe['title'] as String? ?? '');
    final thumbUrl = oe['thumbnail_url'] as String?;

    return _buildTrack(
      title: title,
      artistName: artist,
      albumArtUrl: thumbUrl,
      previewUrl: previewUrl,
      distributorUrl: url,
      distributorPlatform: 'spotify',
    );
  }

  String? _extractSpotifyTrackId(String url) {
    final match = RegExp(r'spotify\.com/track/([A-Za-z0-9]+)').firstMatch(url);
    return match?.group(1);
  }

  String _extractSpotifyArtist(String oEmbedTitle) {
    // OEmbed title format: "Song Name by Artist Name"
    final idx = oEmbedTitle.toLowerCase().lastIndexOf(' by ');
    if (idx != -1) return oEmbedTitle.substring(idx + 4).trim();
    return 'Unknown Artist';
  }

  Future<String?> _fetchSpotifyPreview(String trackId) async {
    // The unofficial but publicly accessible Spotify track page embeds the
    // preview URL in its JSON-LD or in the embed iframe's JSON payload.
    try {
      final res = await http
          .get(Uri.parse(
              'https://open.spotify.com/embed/track/$trackId'))
          .timeout(const Duration(seconds: 8));
      final body = res.body;
      final match = RegExp(r'"audioPreview"\s*:\s*\{"url"\s*:\s*"([^"]+)"')
          .firstMatch(body);
      if (match != null) return match.group(1);
      // Fallback: look for a p.scdn.co/mp3-preview URL
      final mp3Match =
          RegExp(r'https://p\.scdn\.co/mp3-preview/[A-Za-z0-9]+').firstMatch(body);
      return mp3Match?.group(0);
    } catch (_) {
      return null;
    }
  }

  // ─── Apple Music ───────────────────────────────────────────────────────────
  Future<MusicTrack> _resolveAppleMusic(String url) async {
    // Extract the song name from the URL slug as a search term
    final slug = Uri.parse(url).pathSegments.lastWhere(
          (s) => s.isNotEmpty,
          orElse: () => '',
        );
    final term = slug.replaceAll('-', '+');

    final res = await http
        .get(Uri.parse('$_itunes${Uri.encodeComponent(term)}'))
        .timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final results = data['results'] as List?;
      if (results != null && results.isNotEmpty) {
        final r = results.first as Map<String, dynamic>;
        final artUrl = (r['artworkUrl100'] as String?)
            ?.replaceAll('100x100', '600x600');
        return _buildTrack(
          title: r['trackName'] as String? ?? 'Unknown Track',
          artistName: r['artistName'] as String? ?? 'Unknown Artist',
          albumArtUrl: artUrl,
          previewUrl: r['previewUrl'] as String?,
          duration: ((r['trackTimeMillis'] as num?) ?? 30000) ~/ 1000,
          distributorUrl: url,
          distributorPlatform: 'apple_music',
        );
      }
    }

    throw Exception(
        'Could not load this Apple Music track. Try a direct song link.');
  }

  // ─── Audiomack ─────────────────────────────────────────────────────────────
  Future<MusicTrack> _resolveAudiomack(String url) async {
    // Audiomack supports OEmbed
    final oEmbedUrl =
        'https://audiomack.com/api/oembed?url=${Uri.encodeComponent(url)}&format=json';
    final res = await http
        .get(Uri.parse(oEmbedUrl))
        .timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final oe = jsonDecode(res.body) as Map<String, dynamic>;
      return _buildTrack(
        title: oe['title'] as String? ?? 'Unknown Track',
        artistName: oe['author_name'] as String? ?? 'Unknown Artist',
        albumArtUrl: oe['thumbnail_url'] as String?,
        previewUrl: null, // Audiomack does not expose a raw preview URL via OEmbed
        distributorUrl: url,
        distributorPlatform: 'audiomack',
      );
    }

    throw Exception('Could not load this Audiomack track. Use a direct song link.');
  }

  // ─── SoundCloud ────────────────────────────────────────────────────────────
  Future<MusicTrack> _resolveSoundCloud(String url) async {
    final oEmbedUrl =
        'https://soundcloud.com/oembed?url=${Uri.encodeComponent(url)}&format=json';
    final res = await http
        .get(Uri.parse(oEmbedUrl))
        .timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      final oe = jsonDecode(res.body) as Map<String, dynamic>;
      return _buildTrack(
        title: oe['title'] as String? ?? 'Unknown Track',
        artistName: oe['author_name'] as String? ?? 'Unknown Artist',
        albumArtUrl: oe['thumbnail_url'] as String?,
        previewUrl: null,
        distributorUrl: url,
        distributorPlatform: 'soundcloud',
      );
    }

    throw Exception('Could not load this SoundCloud track. Use a direct song link.');
  }

  // ─── Generic OEmbed fallback ───────────────────────────────────────────────
  Future<MusicTrack> _resolveOEmbedFallback(
      String url, String platform) async {
    // Best-effort: try oEmbed with various endpoints
    final endpoints = [
      'https://noembed.com/embed?url=${Uri.encodeComponent(url)}',
    ];

    for (final endpoint in endpoints) {
      try {
        final res = await http
            .get(Uri.parse(endpoint))
            .timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final oe = jsonDecode(res.body) as Map<String, dynamic>;
          if (oe['title'] != null) {
            return _buildTrack(
              title: oe['title'] as String,
              artistName: oe['author_name'] as String? ?? 'Unknown Artist',
              albumArtUrl: oe['thumbnail_url'] as String?,
              previewUrl: null,
              distributorUrl: url,
              distributorPlatform: platform,
            );
          }
        }
      } catch (_) {}
    }

    throw Exception(
        'This distributor link is not yet supported. Try Spotify, Apple Music, Audiomack, or SoundCloud.');
  }

  // ─── Catalog registration ──────────────────────────────────────────────────

  /// Registers the resolved track in the Goobox music catalog so it appears
  /// in the artist's "My Releases" tab in the Music Library.
  ///
  /// Returns the [MusicTrack] with a stable [id] assigned from Goobox.
  Future<MusicTrack> registerInCatalog({
    required MusicTrack track,
    required String artistId,
  }) async {
    try {
      final catalogPayload = {
        'sound_id': 'dist_${artistId}_${DateTime.now().millisecondsSinceEpoch}',
        'title': track.title,
        'artist': track.artistName,
        'artist_id': artistId,
        'cover_url': track.albumArtUrl,
        'preview_url': track.previewUrl,
        'audio_url': track.previewUrl ?? '', // stream from distributor
        'duration': track.duration,
        'license_type': 'artist_verified',
        'sound_type': 'distributor_linked',
        'distributor_url': track.distributorUrl,
        'distributor_platform': track.distributorPlatform,
        'is_trending': false,
        'is_featured': false,
        'usage_count': 0,
      };

      final id = catalogPayload['sound_id'] as String;
      await GooboxArtistMusicService.instance
          .registerDistributorTrack(artistId: artistId, payload: catalogPayload);

      return MusicTrack(
        id: id,
        title: track.title,
        artistName: track.artistName,
        albumArtUrl: track.albumArtUrl,
        previewUrl: track.previewUrl,
        audioUrl: track.previewUrl ?? '',
        duration: track.duration,
        licenseType: 'artist_verified',
        soundType: 'distributor_linked',
        distributorUrl: track.distributorUrl,
        distributorPlatform: track.distributorPlatform,
      );
    } catch (e) {
      debugPrint('[DistributorMusicService] Catalog registration notice: $e');
      // Return the track even if Goobox registration fails —
      // the artist can still use it in the editor this session.
      return track;
    }
  }

  // ─── Helper ────────────────────────────────────────────────────────────────
  MusicTrack _buildTrack({
    required String title,
    required String artistName,
    String? albumArtUrl,
    String? previewUrl,
    int duration = 30,
    required String distributorUrl,
    required String distributorPlatform,
  }) {
    return MusicTrack(
      id: 'dist_preview_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      artistName: artistName,
      albumArtUrl: albumArtUrl,
      previewUrl: previewUrl,
      audioUrl: previewUrl ?? '',
      duration: duration,
      licenseType: 'artist_verified',
      soundType: 'distributor_linked',
      distributorUrl: distributorUrl,
      distributorPlatform: distributorPlatform,
    );
  }
}
