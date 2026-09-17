import 'package:video_player/video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'data_saver_service.dart';
import 'dart:async';
// ignore: depend_on_referenced_packages

class VideoPreloadManager {
  static final Map<String, VideoPlayerController> _preloadedControllers = {};
  static final Map<String, StreamSubscription> _activeDownloads = {};
  
  static String? _currentUrl;
  static String? _nextUrl;

  /// Sets the active item and triggers preload for the NEXT item only.
  /// Strictly enforces: 1 Active, 1 Preload, 0 Idle downloads.
  static void setContext(String currentUrl, String? nextUrl, {bool isImage = false}) {
    _currentUrl = currentUrl;
    
    // 1. Cancel previous preload if it's no longer the "next" item
    if (_nextUrl != null && _nextUrl != nextUrl && _nextUrl != _currentUrl) {
      _cancelPreload(_nextUrl!);
    }

    _nextUrl = nextUrl;

    if (_nextUrl != null) {
      _startPreload(_nextUrl!, isImage: isImage);
    }

    // 2. Cleanup everything else (TikTok-style aggressive pruning)
    _cleanupIdleExcept([_currentUrl!, if (_nextUrl != null) _nextUrl!]);
  }

  static void _startPreload(String url, {bool isImage = false}) {
    if (url.isEmpty || _preloadedControllers.containsKey(url)) return;
    if (_activeDownloads.containsKey(url)) return;

    debugPrint("🚀 PRELOAD START: $url");

    // 1. Memory Preload only (Initialized Controller)
    // We REMOVED the full Disk Cache Download here because it was consuming too much data (1GB/10min).
    // The VideoPlayer handles its own buffering once initialized.
    
    if (isImage) {
      NetworkImage(url).resolve(ImageConfiguration.empty);
      return;
    }

    if (DataSaverService().isEnabled) return;

    // 2. Memory Preload (Initialized Controller)
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _preloadedControllers[url] = controller;
    controller.initialize().then((_) {
      debugPrint("✅ PRELOAD MEMORY READY: $url");
    }).catchError((e) {
      debugPrint("Memory Preload error: $url $e");
    });
  }

  static void _cancelPreload(String url) {
    debugPrint("🛑 PRELOAD CANCEL: $url");
    _activeDownloads.remove(url)?.cancel();
    _preloadedControllers.remove(url)?.dispose();
  }

  static void _cleanupIdleExcept(List<String> keepUrls) {
    final urls = _preloadedControllers.keys.toList();
    for (final url in urls) {
      if (!keepUrls.contains(url)) {
        _preloadedControllers.remove(url)?.dispose();
      }
    }
    
    final downloads = _activeDownloads.keys.toList();
    for (final url in downloads) {
      if (!keepUrls.contains(url)) {
        _activeDownloads.remove(url)?.cancel();
      }
    }
  }

  /// Tries to get a controller from memory preload or disk cache.
  static Future<VideoPlayerController> getController(String url) async {
    // 1. Check Memory Preload
    final memoryController = _preloadedControllers.remove(url);
    if (memoryController != null) {
      return memoryController;
    }

    // 2. On web, VideoPlayerController.file() is not available.
    //    Skip disk-cache entirely and fall through to network.
    if (!kIsWeb) {
      try {
        final file = await DefaultCacheManager().getSingleFile(url);
        if (file.existsSync()) {
          final controller = VideoPlayerController.file(file);
          await controller.initialize();
          return controller;
        }
      } catch (e) {
        debugPrint('Disk cache download/get error: $e');
      }
    }

    // 3. Fallback to Network (always used on web, fallback elsewhere)
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    await controller.initialize();
    return controller;
  }
}
