import 'package:universal_io/io.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';

/// Handles all voice note lifecycle:
/// - Compressed recording (tiny files, ~120KB per 30s)
/// - Local-only persistence (zero Supabase Storage, zero egress)
/// - Base64 transport through Supabase Realtime pipeline
/// - Permanent device-side caching (plays from disk, never re-downloads)
class VoiceNoteService {
  static const _subDir = 'necxa_voice_notes';

  // ── Optimal recording config ─────────────────────────────────────────────
  // 16kHz mono 32kbps AAC ≈ 120KB per 30s (vs ~900KB default).
  // This is WhatsApp-grade voice quality — perfectly clear for speech.
  static const recordConfig = RecordConfig(
    encoder: AudioEncoder.aacLc,
    sampleRate: 16000,
    bitRate: 32000,
    numChannels: 1,
  );

  // ── Local Storage ────────────────────────────────────────────────────────

  /// Returns the permanent directory where voice notes are cached on this device.
  static Future<Directory> _getVoiceNoteDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_subDir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Saves raw audio bytes to permanent local storage under a stable message ID.
  /// Returns the local file path.
  static Future<String> saveToLocal(Uint8List bytes, String messageId) async {
    final dir = await _getVoiceNoteDir();
    final file = File('${dir.path}/$messageId.m4a');
    await file.writeAsBytes(bytes, flush: true);
    debugPrint('[VoiceNote] Saved locally: ${file.path} (${bytes.length} bytes)');
    return file.path;
  }

  /// Returns the local file if it exists for a given message ID, or null.
  /// Called before any attempt to decode from transport.
  static Future<File?> loadFromLocal(String messageId) async {
    final dir = await _getVoiceNoteDir();
    final file = File('${dir.path}/$messageId.m4a');
    return await file.exists() ? file : null;
  }

  // ── Transport (Base64 through Supabase Realtime) ─────────────────────────

  /// Reads a recorded .m4a file and base64-encodes it for inclusion in the
  /// Supabase Realtime message payload. The audio bytes travel through the
  /// websocket pipeline — no Storage bucket, zero cached egress.
  static Future<String> encodeForTransport(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final b64 = base64Encode(bytes);
    debugPrint('[VoiceNote] Encoded for transport: ${bytes.length} bytes → ${b64.length} chars');
    return b64;
  }

  /// Decodes a base64 voice note received from Supabase Realtime and saves
  /// it permanently to local storage. After this call, the file is on-device
  /// and never needs to be fetched from Supabase again.
  static Future<String> decodeFromTransport(String b64, String messageId) async {
    // Check cache first — if already saved, skip decoding entirely.
    final cached = await loadFromLocal(messageId);
    if (cached != null) return cached.path;

    final bytes = base64Decode(b64);
    return saveToLocal(Uint8List.fromList(bytes), messageId);
  }

  // ── Duration Utilities ───────────────────────────────────────────────────

  /// Gets the duration of a local audio file. Used to stamp the message bubble.
  static Future<Duration?> getDuration(String filePath) async {
    final player = AudioPlayer();
    try {
      await player.setFilePath(filePath);
      return player.duration;
    } catch (_) {
      return null;
    } finally {
      await player.dispose();
    }
  }

  /// Formats a Duration into a compact string like "0:23" or "1:05".
  static String formatDuration(Duration? d) {
    if (d == null) return '0:00';
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Cleanup ──────────────────────────────────────────────────────────────

  /// Deletes a specific cached voice note from local storage.
  static Future<void> deleteLocal(String messageId) async {
    final file = await loadFromLocal(messageId);
    if (file != null) await file.delete();
  }
}
