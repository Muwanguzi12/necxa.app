import 'package:universal_io/io.dart';

class MediaHelpers {
  
  /// Formats a Dart Duration into a human-readable mm:ss format.
  static String formatDuration(Duration d) {
    if (d.inHours > 0) {
      final h = d.inHours.toString();
      final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$h:$m:$s';
    } else {
      final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$m:$s';
    }
  }

  /// Retrieves and formats a file size asynchronously into a readable KB/MB format.
  static Future<String> getReadableFileSize(File file) async {
    if (!await file.exists()) return "0 B";
    int bytes = await file.length();
    return formatBytes(bytes);
  }

  /// Converts a raw byte count into a readable string format.
  static String formatBytes(int bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    int i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }
  
  /// Validates if the selected file sits beneath the grid's hard maximum limit (e.g., 50MB)
  static Future<bool> isWithinUploadLimits(File file, {int maxMegabytes = 50}) async {
    if (!await file.exists()) return false;
    int bytes = await file.length();
    double mb = bytes / (1024 * 1024);
    return mb <= maxMegabytes;
  }
}
