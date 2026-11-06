import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:universal_io/io.dart';

class NecxaFilterMeta {
  final String id;
  final String displayName;
  final String category;
  final String? description;
  final String assetVersion;
  final String? assetPath;
  final String? thumbnailPath;
  final String? assetSha256;
  final bool isEnabled;
  final double brightness;
  final double contrast;
  final double saturation;
  final double hue;
  final String? colorMatrixPreset;

  const NecxaFilterMeta({
    required this.id,
    required this.displayName,
    required this.category,
    this.description,
    this.assetVersion = '1.0.0',
    this.assetPath,
    this.thumbnailPath,
    this.assetSha256,
    this.isEnabled = true,
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.hue = 0.0,
    this.colorMatrixPreset,
  });

  factory NecxaFilterMeta.fromJson(Map<String, dynamic> json) {
    final params = json['effect_params'] is Map
        ? json['effect_params'] as Map<String, dynamic>
        : (json['effect_params'] is String
            ? jsonDecode(json['effect_params'] as String) as Map<String, dynamic>
            : <String, dynamic>{});
    return NecxaFilterMeta(
      id: json['id'] as String,
      displayName: json['display_name'] as String,
      category: json['category'] as String,
      description: json['description'] as String?,
      assetVersion: json['asset_version'] as String? ?? '1.0.0',
      assetPath: json['asset_path'] as String?,
      thumbnailPath: json['thumbnail_path'] as String?,
      assetSha256: json['asset_sha256'] as String?,
      isEnabled: json['is_enabled'] as bool? ?? true,
      brightness: (params['brightness'] as num?)?.toDouble() ?? 0.0,
      contrast: (params['contrast'] as num?)?.toDouble() ?? 1.0,
      saturation: (params['saturation'] as num?)?.toDouble() ?? 1.0,
      hue: (params['hue'] as num?)?.toDouble() ?? 0.0,
      colorMatrixPreset: params['colorMatrixPreset'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'display_name': displayName,
    'category': category,
    'description': description,
    'asset_version': assetVersion,
    'asset_path': assetPath,
    'thumbnail_path': thumbnailPath,
    'asset_sha256': assetSha256,
    'is_enabled': isEnabled,
    'effect_params': {
      'brightness': brightness,
      'contrast': contrast,
      'saturation': saturation,
      'hue': hue,
      if (colorMatrixPreset != null) 'colorMatrixPreset': colorMatrixPreset,
    },
  };

  /// The "Normal" sentinel — no effect applied.
  static const NecxaFilterMeta none = NecxaFilterMeta(
    id: 'none',
    displayName: 'Normal',
    category: 'color',
  );

  bool get isNone => id == 'none';
}

class FilterCatalogueService {
  static const _cacheKey = 'necxa_filter_catalogue_v1';
  static const _cacheTsKey = 'necxa_filter_catalogue_ts_v1';
  static const _cacheTtlMs = 3600000; // 1 hour

  static List<NecxaFilterMeta> _cached = [];

  /// Built-in fallback filters when offline or before initial network fetch
  static List<NecxaFilterMeta> get fallbackFilters => const [
    NecxaFilterMeta.none,
    NecxaFilterMeta(
      id: 'builtin-natural',
      displayName: 'Natural',
      category: 'beauty',
      description: 'Subtle skin smoothing, warm tones',
      brightness: 0.05,
      contrast: 1.05,
      saturation: 1.1,
    ),
    NecxaFilterMeta(
      id: 'builtin-cinema',
      displayName: 'Cinema',
      category: 'color',
      description: 'Orange & teal grade, film contrast',
      brightness: -0.05,
      contrast: 1.15,
      saturation: 0.9,
      hue: 0.08,
      colorMatrixPreset: 'cinema',
    ),
    NecxaFilterMeta(
      id: 'builtin-neon',
      displayName: 'Neon',
      category: 'creative',
      description: 'Purple tint, high saturation glow',
      contrast: 1.1,
      saturation: 1.6,
      hue: -0.15,
      colorMatrixPreset: 'neon',
    ),
    NecxaFilterMeta(
      id: 'builtin-noir',
      displayName: 'Noir',
      category: 'color',
      description: 'Black & white desaturation',
      contrast: 1.2,
      saturation: 0.0,
      colorMatrixPreset: 'grayscale',
    ),
    NecxaFilterMeta(
      id: 'builtin-vivid',
      displayName: 'Vivid',
      category: 'color',
      description: 'Boosted vibrance and clarity',
      brightness: 0.05,
      contrast: 1.1,
      saturation: 1.5,
    ),
    NecxaFilterMeta(
      id: 'builtin-glow',
      displayName: 'Glow',
      category: 'glow',
      description: 'Soft warm highlight bloom',
      brightness: 0.12,
      contrast: 0.95,
      saturation: 1.2,
      hue: 0.02,
    ),
    NecxaFilterMeta(
      id: 'builtin-golden',
      displayName: 'Golden',
      category: 'beauty',
      description: 'Warm golden hour skin tone',
      brightness: 0.08,
      contrast: 1.05,
      saturation: 1.15,
      hue: 0.06,
    ),
  ];

  /// Load catalogue: memory -> SharedPrefs -> Supabase -> fallback.
  static Future<List<NecxaFilterMeta>> loadCatalogue({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cached.isNotEmpty) return _cached;

    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_cacheTsKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = prefs.getString(_cacheKey);

    if (!forceRefresh && cached != null && (now - ts) < _cacheTtlMs) {
      try {
        final list = (jsonDecode(cached) as List)
            .map((e) => NecxaFilterMeta.fromJson(e as Map<String, dynamic>))
            .toList();
        _cached = [NecxaFilterMeta.none, ...list];
        return _cached;
      } catch (_) {}
    }

    try {
      final data = await Supabase.instance.client
          .from('necxa_filters')
          .select()
          .eq('is_enabled', true)
          .order('display_name');
      final list = (data as List)
          .map((e) => NecxaFilterMeta.fromJson(e as Map<String, dynamic>))
          .toList();
      await prefs.setString(_cacheKey, jsonEncode(data));
      await prefs.setInt(_cacheTsKey, now);
      _cached = [NecxaFilterMeta.none, ...list];
      return _cached;
    } catch (e) {
      debugPrint('[FilterCatalogue] Supabase load failed: $e');
      if (cached != null) {
        try {
          final list = (jsonDecode(cached) as List)
              .map((e) => NecxaFilterMeta.fromJson(e as Map<String, dynamic>))
              .toList();
          _cached = [NecxaFilterMeta.none, ...list];
          return _cached;
        } catch (_) {}
      }
      _cached = fallbackFilters;
      return _cached;
    }
  }

  /// Get a signed thumbnail URL for a filter that has a thumbnail_path.
  static Future<String?> getThumbnailUrl(NecxaFilterMeta meta) async {
    if (meta.thumbnailPath == null) return null;
    try {
      final response = await Supabase.instance.client.storage
          .from('necxa-filters')
          .createSignedUrl(meta.thumbnailPath!, 3600);
      return response;
    } catch (e) {
      debugPrint('[FilterCatalogue] Thumbnail URL error: $e');
      return null;
    }
  }

  /// Download and cache a filter asset zip. Verifies SHA-256. Returns local path.
  static Future<String?> downloadFilterAsset(
    NecxaFilterMeta meta, {
    void Function(double)? onProgress,
  }) async {
    if (meta.assetPath == null) return null;

    final cacheDir = await getApplicationCacheDirectory();
    final filterDir = Directory(
      '${cacheDir.path}/necxa_filter_cache/${meta.id}_${meta.assetVersion}',
    );
    final assetFile = File('${filterDir.path}/asset.zip');
    final hashFile = File('${filterDir.path}/.sha256');

    // Check if valid cached version exists.
    if (await assetFile.exists() && await hashFile.exists()) {
      final storedHash = await hashFile.readAsString();
      if (meta.assetSha256 == null || storedHash.trim() == meta.assetSha256) {
        return assetFile.path;
      }
    }

    // Get a signed download URL.
    String downloadUrl;
    try {
      downloadUrl = await Supabase.instance.client.storage
          .from('necxa-filters')
          .createSignedUrl(meta.assetPath!, 3600);
    } catch (e) {
      debugPrint('[FilterCatalogue] Signed URL error: $e');
      return null;
    }

    // Download with progress.
    try {
      await filterDir.create(recursive: true);
      final request = http.Request('GET', Uri.parse(downloadUrl));
      final response = await http.Client().send(request);
      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = assetFile.openWrite();
      await response.stream.listen((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }).asFuture<void>();
      await sink.close();

      // Verify SHA-256.
      if (meta.assetSha256 != null) {
        final bytes = await assetFile.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        if (digest != meta.assetSha256) {
          await assetFile.delete();
          throw Exception('[FilterCatalogue] SHA-256 mismatch for ${meta.displayName}');
        }
        await hashFile.writeAsString(digest);
      }

      return assetFile.path;
    } catch (e) {
      debugPrint('[FilterCatalogue] Download error: $e');
      return null;
    }
  }

  /// Find a filter by displayName in the cached list or fallback list.
  static NecxaFilterMeta? findByName(String name) {
    final pool = _cached.isNotEmpty ? _cached : fallbackFilters;
    try {
      return pool.firstWhere(
        (f) => f.displayName.toLowerCase() == name.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Evict stale cache entries older than max versions to keep.
  static Future<void> evictOldCacheVersions({
    int keepVersions = 2,
  }) async {
    try {
      final cacheDir = await getApplicationCacheDirectory();
      final root = Directory('${cacheDir.path}/necxa_filter_cache');
      if (!await root.exists()) return;
      final byId = <String, List<Directory>>{};
      await for (final entry in root.list()) {
        if (entry is Directory) {
          final name = entry.path.split('/').last.split('\\').last;
          final idx = name.lastIndexOf('_');
          if (idx < 0) continue;
          final id = name.substring(0, idx);
          byId.putIfAbsent(id, () => []).add(entry);
        }
      }
      for (final dirs in byId.values) {
        dirs.sort((a, b) => a.path.compareTo(b.path));
        for (var i = 0; i < dirs.length - keepVersions; i++) {
          await dirs[i].delete(recursive: true);
        }
      }
    } catch (e) {
      debugPrint('[FilterCatalogue] Eviction error: $e');
    }
  }
}
