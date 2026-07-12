import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';
import 'media_compression_service.dart';

class EditorExportResult {
  final bool success;
  final String? outputPath;
  final String? thumbnailPath;
  final String? verificationSummary;
  final List<String> issues;
  final Map<String, dynamic> verificationPayload;

  const EditorExportResult({
    required this.success,
    this.outputPath,
    this.thumbnailPath,
    this.verificationSummary,
    this.issues = const [],
    this.verificationPayload = const {},
  });
}

class EditorExportService {
  static const _exportHistoryKey = 'necxa_editor_export_history_v1';

  static Future<EditorExportResult> exportProject({
    required File sourceVideo,
    String projectName = 'Project',
    String description = '',
    String creatorName = 'Creator',
    String copyright = 'All rights reserved',
    String platform = 'NECXA Platform',
  }) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final outputFile = File('${tempDir.path}/$projectName-${DateTime.now().millisecondsSinceEpoch}.mp4');
      await sourceVideo.copy(outputFile.path);

      final compressedFile = await MediaCompressionService.compressVideo(outputFile);

      final thumbnailFile = File('${tempDir.path}/${projectName}_thumb.jpg');
      await thumbnailFile.writeAsBytes(base64Decode(base64Encode(await compressedFile.readAsBytes())));

      final payload = {
        'project': projectName,
        'description': description,
        'creator': creatorName,
        'copyright': copyright,
        'platform': platform,
        'videoPath': compressedFile.path,
        'thumbnailPath': thumbnailFile.path,
      };

      final verification = await NecxaAI.verifyVideoWorker([compressedFile]);
      final issues = <String>[];
      if (verification['success'] == false) {
        issues.add(verification['error']?.toString() ?? 'AI verification failed');
      } else if (verification['safe'] == false) {
        issues.add('AI verification flagged the content');
      }

      final prefs = await SharedPreferences.getInstance();
      final history = prefs.getStringList(_exportHistoryKey) ?? [];
      history.add(jsonEncode(payload));
      await prefs.setStringList(_exportHistoryKey, history.take(20).toList());

      return EditorExportResult(
        success: issues.isEmpty,
        outputPath: compressedFile.path,
        thumbnailPath: thumbnailFile.path,
        verificationSummary: issues.isEmpty ? 'Verified for publishing' : null,
        issues: issues,
        verificationPayload: verification,
      );
    } catch (e) {
      debugPrint('Editor export failed: $e');
      return const EditorExportResult(success: false, issues: ['Export failed']);
    }
  }
}
