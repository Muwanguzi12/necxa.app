import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// ── Necxa Cloud Service (Media & Sync Protocol) ────────────────────────
class NecxaCloud {
  SupabaseClient get client => Supabase.instance.client;

  // ── Storage Node: Uploads ──────────────────────────────────────────
  /// Uploads file to a specific public/private bucket under user's directory.
  /// Standard pattern for Necxa: bucket / uid / filename
  Future<Map<String, dynamic>?> uploadMedia(
    File file, {
    String bucket = 'listing-photos',
    String assetType = 'generic',
  }) async {
    try {
      final user = client.auth.currentUser;
      if (user == null) {
        throw Exception('Please sign in before uploading media');
      }
      if (!await file.exists()) {
        throw Exception('The selected media file is missing');
      }
      final String extension = p.extension(file.path).toLowerCase();
      final String fileName =
          '${DateTime.now().millisecondsSinceEpoch}$extension';
      final isVideo = ['.mp4', '.mov', '.avi', '.m4v'].contains(extension);

      String path;
      String? assetId;

      try {
        // ── STAGE 1: EDGE HANDSHAKE (Hyper-API) ──
        final handshake = await client.functions.invoke(
          'clever-processor',
          body: {
            'action': 'get-upload-url',
            'payload': {
              'bucket': bucket,
              'asset_type': assetType,
              'file_name': fileName,
            },
          },
        );

        final data = handshake.data;
        if (data is! Map ||
            data['success'] != true ||
            data['path']?.toString().isEmpty != false) {
          throw Exception(data is Map ? data['error'] : 'Handshake failed');
        }
        path = data['path'].toString();
        assetId = data['asset_id']?.toString();
      } catch (e) {
        debugPrint('Handshake Fallback: Using direct upload path. Error: $e');
        // Fallback: Direct path if edge function is missing/failing
        path = '${user.id}/$fileName';
        assetId = 'legacy-${DateTime.now().millisecondsSinceEpoch}';
      }

      // ── STAGE 2: NEURAL UPLOAD ──
      // Note: We use the signed URL to upload directly to storage
      await client.storage.from(bucket).upload(path, file);

      // ── STAGE 3: AUDIT TRIGGER ──
      try {
        await client.functions.invoke(
          'clever-processor',
          body: {
            'action': 'verify-asset',
            'payload': {'asset_id': assetId},
          },
        );
      } catch (_) {
        // Ignore audit failure in fallback mode
      }

      final publicUrl = client.storage.from(bucket).getPublicUrl(path);

      return {
        'id': assetId,
        'url': publicUrl,
        'path': path,
        'bucket': bucket,
        'media_type': isVideo ? 'video' : 'image',
      };
    } catch (e) {
      debugPrint('Necxa Cloud AI Error (Upload): $e');
      throw Exception('Media upload failed: $e');
    }
  }

  /// ── MULTI-UPLOAD PROTOCOL ──
  Future<List<String>> uploadMultiMedia(
    List<File> files, {
    String bucket = 'listing-photos',
    String assetType = 'generic',
  }) async {
    List<String> urls = [];
    for (var file in files) {
      final res = await uploadMedia(file, bucket: bucket, assetType: assetType);
      if (res != null) {
        final url = res['url'] as String?;
        if (url != null) urls.add(url);
      }
    }
    return urls;
  }

  // ── Storage Node: Deletions ─────────────────────────────────────────
  /// Deletes media from a specific bucket.
  /// Requires path to start with userId to satisfy RLS.
  Future<bool> deleteMedia(
    String path, {
    String bucket = 'listing-photos',
  }) async {
    try {
      await client.storage.from(bucket).remove([path]);
      return true;
    } catch (e) {
      debugPrint('Necxa Cloud Error (Delete): $e');
      return false;
    }
  }

  // ── Sync Node: Real-time Streams ──────────────────────────────────
  // Broadcaster for global community posts
  Stream<List<Map<String, dynamic>>> syncPosts() {
    return client
        .from('community_posts')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false)
        .map((data) => List<Map<String, dynamic>>.from(data));
  }

  // Broadcaster for marketplace properties (verified and active only)
  Stream<List<Map<String, dynamic>>> syncProperties() {
    return client
        .from('listings')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false)
        .map(
          (data) => data
              .where(
                (m) =>
                    m['is_active'] == true &&
                    m['is_verified'] == true &&
                    m['is_honeypot'] == false,
              )
              .toList(),
        );
  }

  // ── Sync Node: Specific Profile ──────────────────────────────────
  Stream<Map<String, dynamic>> syncProfile(String userId) {
    return client
        .from('profiles')
        .stream(primaryKey: ['id'])
        .eq('id', userId)
        .limit(1)
        .map((data) => data.isEmpty ? {} : data.first);
  }

  // ── Download Protocol ─────────────────────────────────────────────
  // Gets signed URL for private nodes
  Future<String?> getSecureUrl(
    String path, {
    String bucket = 'necxa-media',
  }) async {
    try {
      return await client.storage
          .from(bucket)
          .createSignedUrl(path, 3600); // 1 hour link
    } catch (e) {
      debugPrint('Necxa Cloud Error (SecureLink): $e');
      return null;
    }
  }

  // Physical file download to local storage
  Future<File?> downloadFile(String url, String saveName) async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final File file = File('${tempDir.path}/$saveName');

      final res = await client.storage.from('necxa-media').download(url);
      await file.writeAsBytes(res);

      return file;
    } catch (e) {
      debugPrint('Necxa Cloud Error (Download): $e');
      return null;
    }
  }
}
