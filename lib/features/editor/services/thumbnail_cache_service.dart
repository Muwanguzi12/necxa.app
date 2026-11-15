import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';

/// LRU (Least Recently Used) thumbnail cache with size limits and automatic cleanup
class ThumbnailCacheService {
  static final ThumbnailCacheService _instance = ThumbnailCacheService._internal();
  factory ThumbnailCacheService() => _instance;
  ThumbnailCacheService._internal();

  // Cache storage
  final Map<String, _CacheEntry> _memoryCache = {};
  final List<String> _accessOrder = []; // Track access order for LRU
  
  // Cache limits
  static const int maxMemoryCacheSize = 100; // Maximum number of thumbnails in memory
  static const int maxMemoryCacheBytes = 100 * 1024 * 1024; // 100MB
  static const int maxDiskCacheBytes = 500 * 1024 * 1024; // 500MB
  
  // Current memory usage
  int _currentMemoryBytes = 0;
  
  // Disk cache directory
  Directory? _cacheDirectory;
  
  // Cleanup timer
  Timer? _cleanupTimer;

  /// Initialize the cache service
  Future<void> initialize() async {
    _cacheDirectory = await getTemporaryDirectory();
    final thumbnailDir = Directory(path.join(_cacheDirectory!.path, 'thumbnails'));
    
    if (!await thumbnailDir.exists()) {
      await thumbnailDir.create(recursive: true);
    }
    
    _cacheDirectory = thumbnailDir;
    
    // Start periodic cleanup
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) => _performCleanup());
    
    // Perform initial cleanup on startup
    await _performCleanup();
    
    debugPrint('ThumbnailCacheService initialized with directory: ${_cacheDirectory!.path}');
  }

  /// Get thumbnail for a video file
  Future<Uint8List?> getThumbnail(File videoFile, {Duration time = const Duration(seconds: 1)}) async {
    final cacheKey = _generateCacheKey(videoFile, time);
    
    // Check memory cache first
    if (_memoryCache.containsKey(cacheKey)) {
      _updateAccessOrder(cacheKey);
      return _memoryCache[cacheKey]!.data;
    }
    
    // Check disk cache
    final diskThumbnail = await _loadFromDiskCache(cacheKey);
    if (diskThumbnail != null) {
      await _addToMemoryCache(cacheKey, diskThumbnail);
      return diskThumbnail;
    }
    
    // Generate thumbnail
    final thumbnail = await _generateThumbnail(videoFile, time);
    if (thumbnail != null) {
      await _addToMemoryCache(cacheKey, thumbnail);
      await _saveToDiskCache(cacheKey, thumbnail);
    }
    
    return thumbnail;
  }

  /// Generate thumbnail from video file using FFmpeg
  Future<Uint8List?> _generateThumbnail(File videoFile, Duration time) async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final outputPath = path.join(cacheDir.path, 'temp_thumb_${DateTime.now().millisecondsSinceEpoch}.jpg');
      
      // Use FFmpeg to extract frame at specified time
      final timeStr = time.inSeconds > 0 ? '${time.inSeconds}' : '0.001';
      final command = '-i "${videoFile.path}" -ss $timeStr -vframes 1 -vf scale=320:-1 "$outputPath"';
      
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      
      if (ReturnCode.isSuccess(returnCode)) {
        final thumbnailFile = File(outputPath);
        if (await thumbnailFile.exists()) {
          final bytes = await thumbnailFile.readAsBytes();
          await thumbnailFile.delete();
          return bytes;
        }
      }
      
      // Cleanup on failure
      final tempFile = File(outputPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      
      return null;
    } catch (e) {
      debugPrint('Error generating thumbnail for ${videoFile.path}: $e');
      return null;
    }
  }

  /// Add to memory cache with LRU eviction
  Future<void> _addToMemoryCache(String key, Uint8List data) async {
    // Remove existing entry if present
    if (_memoryCache.containsKey(key)) {
      _removeEntry(key);
    }
    
    // Check if we need to evict
    while (_memoryCache.length >= maxMemoryCacheSize || 
           _currentMemoryBytes + data.length > maxMemoryCacheBytes) {
      if (_accessOrder.isEmpty) break;
      _evictLRU();
    }
    
    // Add new entry
    _memoryCache[key] = _CacheEntry(key, data, DateTime.now());
    _accessOrder.add(key);
    _currentMemoryBytes += data.length;
  }

  /// Update access order (move to end = most recently used)
  void _updateAccessOrder(String key) {
    _accessOrder.remove(key);
    _accessOrder.add(key);
    if (_memoryCache.containsKey(key)) {
      _memoryCache[key] = _CacheEntry(key, _memoryCache[key]!.data, DateTime.now());
    }
  }

  /// Remove entry from cache
  void _removeEntry(String key) {
    final entry = _memoryCache.remove(key);
    if (entry != null) {
      _currentMemoryBytes -= entry.data.length;
    }
    _accessOrder.remove(key);
  }

  /// Evict least recently used entry
  void _evictLRU() {
    if (_accessOrder.isEmpty) return;
    final lruKey = _accessOrder.removeAt(0);
    _removeEntry(lruKey);
  }

  /// Load from disk cache
  Future<Uint8List?> _loadFromDiskCache(String key) async {
    if (_cacheDirectory == null) return null;
    
    try {
      final file = File(path.join(_cacheDirectory!.path, '$key.jpg'));
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (e) {
      debugPrint('Error loading from disk cache: $e');
    }
    return null;
  }

  /// Save to disk cache
  Future<void> _saveToDiskCache(String key, Uint8List data) async {
    if (_cacheDirectory == null) return;
    
    try {
      final file = File(path.join(_cacheDirectory!.path, '$key.jpg'));
      await file.writeAsBytes(data);
    } catch (e) {
      debugPrint('Error saving to disk cache: $e');
    }
  }

  /// Perform cleanup of old cache entries
  Future<void> _performCleanup() async {
    if (_cacheDirectory == null) return;
    
    try {
      final files = await _cacheDirectory!.list().toList();
      int totalSize = 0;
      
      for (var file in files) {
        if (file is File) {
          totalSize += await file.length();
        }
      }
      
      // If over limit, remove oldest files
      if (totalSize > maxDiskCacheBytes) {
        final fileMetadata = <File, DateTime>{};
        for (var file in files.whereType<File>()) {
          fileMetadata[file] = await file.lastModified();
        }
        
        final sortedFiles = fileMetadata.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        
        int removedSize = 0;
        for (var entry in sortedFiles) {
          if (totalSize - removedSize <= maxDiskCacheBytes * 0.8) break; // Keep 80% capacity
          await entry.key.delete();
          removedSize += await entry.key.length();
        }
        
        debugPrint('Thumbnail cache cleanup: removed $removedSize bytes');
      }
    } catch (e) {
      debugPrint('Error during cache cleanup: $e');
    }
  }

  /// Clear all cache (memory and disk)
  Future<void> clearCache() async {
    _memoryCache.clear();
    _accessOrder.clear();
    _currentMemoryBytes = 0;
    
    if (_cacheDirectory != null) {
      try {
        await for (var entity in _cacheDirectory!.list()) {
          if (entity is File) {
            await entity.delete();
          }
        }
      } catch (e) {
        debugPrint('Error clearing disk cache: $e');
      }
    }
  }

  /// Get cache statistics
  Map<String, dynamic> getCacheStats() {
    return {
      'memoryCacheSize': _memoryCache.length,
      'memoryCacheBytes': _currentMemoryBytes,
      'maxMemoryCacheSize': maxMemoryCacheSize,
      'maxMemoryCacheBytes': maxMemoryCacheBytes,
      'memoryUsagePercent': (_currentMemoryBytes / maxMemoryCacheBytes * 100).toStringAsFixed(2),
    };
  }

  /// Generate cache key from file and time
  String _generateCacheKey(File file, Duration time) {
    final fileHash = file.path.hashCode;
    final timeHash = time.inMilliseconds.hashCode;
    return '${fileHash}_$timeHash';
  }

  /// Dispose resources
  void dispose() {
    _cleanupTimer?.cancel();
    _memoryCache.clear();
    _accessOrder.clear();
  }
}

/// Cache entry with timestamp
class _CacheEntry {
  final String key;
  final Uint8List data;
  final DateTime lastAccessed;
  
  _CacheEntry(this.key, this.data, this.lastAccessed);
}
