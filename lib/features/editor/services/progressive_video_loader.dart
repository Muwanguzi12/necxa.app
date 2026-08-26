import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/media_information_session.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

/// Progressive video loading strategy that replaces the 20-second timeout
/// with a multi-stage loading approach for better UX
enum VideoLoadStage {
  analyzing,
  generatingProxy,
  loadingProxy,
  loadingOriginal,
  ready,
  failed,
}

class ProgressiveVideoLoader {
  final File videoFile;
  final Function(VideoLoadStage, double)? onProgress;
  final Function(String)? onError;
  
  VideoPlayerController? _controller;
  VideoLoadStage _currentStage = VideoLoadStage.analyzing;
  bool _isDisposed = false;
  Timer? _timeoutTimer;
  File? _proxyFile;
  
  ProgressiveVideoLoader({
    required this.videoFile,
    this.onProgress,
    this.onError,
  });

  /// Load video with progressive strategy
  Future<VideoPlayerController?> load() async {
    try {
      // Stage 1: Analyze video file
      _updateStage(VideoLoadStage.analyzing, 0.1);
      final videoInfo = await _analyzeVideo();
      
      if (_isDisposed) return null;
      
      // Stage 2: Determine if we need a proxy
      final needsProxy = videoInfo['needsProxy'] as bool;
      
      if (needsProxy) {
        // Stage 3: Generate proxy
        _updateStage(VideoLoadStage.generatingProxy, 0.3);
        _proxyFile = await _generateProxy(videoFile);
        
        if (_isDisposed || _proxyFile == null) {
          // Fallback to original if proxy generation fails
          debugPrint('Proxy generation failed, falling back to original');
          return await _loadOriginalVideo();
        }
        
        // Stage 4: Load proxy
        _updateStage(VideoLoadStage.loadingProxy, 0.6);
        final proxyController = await _loadVideoFile(_proxyFile!);
        
        if (proxyController != null) {
          _controller = proxyController;
          _updateStage(VideoLoadStage.ready, 1.0);
          
          // Start loading original in background
          _loadOriginalInBackground();
          
          return _controller;
        }
      }
      
      // Stage 5: Load original directly
      return await _loadOriginalVideo();
      
    } catch (e) {
      debugPrint('Progressive video loading error: $e');
      onError?.call(e.toString());
      _updateStage(VideoLoadStage.failed, 0);
      return null;
    }
  }

  /// Analyze video file to determine loading strategy
  Future<Map<String, dynamic>> _analyzeVideo() async {
    try {
      final fileSize = await videoFile.length();
      final fileSizeMB = fileSize / (1024 * 1024);
      
      // Use FFmpeg to get video info
      final command = '-i "${videoFile.path}" -f null -';
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      
      Duration duration = Duration.zero;
      int width = 0;
      int height = 0;
      
      if (ReturnCode.isSuccess(returnCode)) {
        final log = await session.getAllLogsAsString();
        // Parse duration from FFmpeg output
        final durationMatch = RegExp(r'Duration: (\d{2}):(\d{2}):(\d{2}\.\d{2})').firstMatch(log);
        if (durationMatch != null) {
          final hours = int.parse(durationMatch.group(1) ?? '0');
          final minutes = int.parse(durationMatch.group(2) ?? '0');
          final seconds = double.parse(durationMatch.group(3) ?? '0');
          duration = Duration(
            hours: hours,
            minutes: minutes,
            milliseconds: (seconds * 1000).toInt(),
          );
        }
        
        // Parse resolution
        final resolutionMatch = RegExp(r'(\d{3,4})x(\d{3,4})').firstMatch(log);
        if (resolutionMatch != null) {
          width = int.parse(resolutionMatch.group(1) ?? '0');
          height = int.parse(resolutionMatch.group(2) ?? '0');
        }
      }
      
      // Determine if proxy is needed
      final needsProxy = fileSizeMB > 50 || // > 50MB file
                         duration.inSeconds > 60 || // > 1 minute
                         (width * height) > 1920 * 1080; // > 1080p
      
      return {
        'fileSizeMB': fileSizeMB,
        'duration': duration,
        'width': width,
        'height': height,
        'needsProxy': needsProxy,
      };
    } catch (e) {
      debugPrint('Error analyzing video: $e');
      // Conservative fallback - assume proxy needed
      return {
        'fileSizeMB': 100,
        'duration': const Duration(minutes: 2),
        'width': 1920,
        'height': 1080,
        'needsProxy': true,
      };
    }
  }

  /// Generate a low-quality proxy video
  Future<File?> _generateProxy(File originalFile) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final proxyPath = path.join(
        tempDir.path,
        'proxy_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      
      // Generate proxy with reduced resolution and bitrate
      final command = '''
        -i "${originalFile.path}" 
        -vf "scale=640:-2" 
        -c:v libx264 
        -preset ultrafast 
        -crf 28 
        -c:a aac 
        -b:a 128k 
        -t 30 
        "$proxyPath"
      '''.replaceAll('\n', ' ').trim();
      
      // Set timeout for proxy generation (30 seconds max)
      final proxyFuture = FFmpegKit.execute(command);
      final timeoutFuture = Future.delayed(const Duration(seconds: 30));
      
      final result = await Future.any([proxyFuture, timeoutFuture]);
      
      if (result is Session) {
        final returnCode = await result.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          final proxyFile = File(proxyPath);
          if (await proxyFile.exists()) {
            debugPrint('Proxy generated successfully: ${proxyFile.path}');
            return proxyFile;
          }
        }
      }
      
      // Cleanup on failure
      final tempFile = File(proxyPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      
      return null;
    } catch (e) {
      debugPrint('Error generating proxy: $e');
      return null;
    }
  }

  /// Load video file with progressive timeout
  Future<VideoPlayerController?> _loadVideoFile(File file) async {
    try {
      final controller = VideoPlayerController.file(file);
      
      // Progressive timeout: start with 5s, extend to 15s if needed
      final loadFuture = controller.initialize();
      final initialTimeout = Future.delayed(const Duration(seconds: 5));
      
      final result = await Future.any([loadFuture, initialTimeout]);
      
      if (result == initialTimeout) {
        // Initial timeout, try extended timeout
        debugPrint('Initial timeout, extending...');
        final extendedTimeout = Future.delayed(const Duration(seconds: 10));
        await Future.any([loadFuture, extendedTimeout]);
      }
      
      if (controller.value.isInitialized) {
        return controller;
      } else {
        await controller.dispose();
        return null;
      }
    } catch (e) {
      debugPrint('Error loading video file: $e');
      return null;
    }
  }

  /// Load original video with extended timeout
  Future<VideoPlayerController?> _loadOriginalVideo() async {
    _updateStage(VideoLoadStage.loadingOriginal, 0.8);
    
    final controller = await _loadVideoFile(videoFile);
    
    if (controller != null) {
      _controller = controller;
      _updateStage(VideoLoadStage.ready, 1.0);
    } else {
      _updateStage(VideoLoadStage.failed, 0);
      onError?.call('Failed to load video after extended timeout');
    }
    
    return controller;
  }

  /// Load original video in background after proxy is loaded
  Future<void> _loadOriginalInBackground() async {
    try {
      await Future.delayed(const Duration(seconds: 2)); // Wait for UI to settle
      
      if (_isDisposed) return;
      
      debugPrint('Loading original video in background...');
      final originalController = await _loadVideoFile(videoFile);
      
      if (originalController != null && !_isDisposed) {
        // Swap controllers
        final oldController = _controller;
        _controller = originalController;
        
        // Cleanup old controller and proxy
        await oldController?.dispose();
        if (_proxyFile != null && await _proxyFile!.exists()) {
          await _proxyFile!.delete();
        }
        
        onProgress?.call(VideoLoadStage.ready, 1.0);
        debugPrint('Swapped to original video');
      }
    } catch (e) {
      debugPrint('Error loading original in background: $e');
      // Keep using proxy if background load fails
    }
  }

  /// Update loading stage and notify listeners
  void _updateStage(VideoLoadStage stage, double progress) {
    _currentStage = stage;
    onProgress?.call(stage, progress);
  }

  /// Get current controller
  VideoPlayerController? get controller => _controller;

  /// Get current loading stage
  VideoLoadStage get currentStage => _currentStage;

  /// Dispose resources
  void dispose() {
    _isDisposed = true;
    _timeoutTimer?.cancel();
    _controller?.dispose();
    
    // Cleanup proxy file
    if (_proxyFile != null && _proxyFile!.existsSync()) {
      _proxyFile!.deleteSync();
    }
  }
}

/// Manager for multiple progressive video loaders
class ProgressiveVideoLoaderManager {
  final Map<String, ProgressiveVideoLoader> _loaders = {};
  
  /// Get or create a loader for a video file
  ProgressiveVideoLoader getLoader(
    File videoFile, {
    Function(VideoLoadStage, double)? onProgress,
    Function(String)? onError,
  }) {
    final key = videoFile.path;
    
    if (!_loaders.containsKey(key)) {
      _loaders[key] = ProgressiveVideoLoader(
        videoFile: videoFile,
        onProgress: onProgress,
        onError: onError,
      );
    }
    
    return _loaders[key]!;
  }

  /// Remove a loader
  void removeLoader(File videoFile) {
    final key = videoFile.path;
    final loader = _loaders.remove(key);
    loader?.dispose();
  }

  /// Clear all loaders
  void clear() {
    for (final loader in _loaders.values) {
      loader.dispose();
    }
    _loaders.clear();
  }

  /// Get loader count
  int get loaderCount => _loaders.length;
}
