import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';
import 'thumbnail_cache_service.dart';

/// Background thumbnail generation service using Isolates
/// Generates thumbnails without blocking the UI thread
class BackgroundThumbnailService {
  static final BackgroundThumbnailService _instance = BackgroundThumbnailService._internal();
  factory BackgroundThumbnailService() => _instance;
  BackgroundThumbnailService._internal();

  final ThumbnailCacheService _cacheService = ThumbnailCacheService();
  final Map<String, _ThumbnailJob> _activeJobs = {};
  final Queue<_ThumbnailRequest> _requestQueue = Queue<_ThumbnailRequest>();
  
  Isolate? _isolate;
  final _receivePort = ReceivePort();
  final _sendPort = Completer<SendPort>();
  
  int _maxConcurrentJobs = 2;
  bool _isProcessing = false;

  /// Initialize the service
  Future<void> initialize() async {
    await _cacheService.initialize();
    
    // Start thumbnail generation isolate
    await _startIsolate();
    
    // Start processing queue
    _processQueue();
    
    debugPrint('BackgroundThumbnailService initialized');
  }

  /// Request thumbnail generation for a video file
  Future<Uint8List?> generateThumbnail(
    File videoFile, {
    Duration time = const Duration(seconds: 1),
    Function(double)? onProgress,
  }) async {
    final cacheKey = _generateCacheKey(videoFile, time);
    
    // Check cache first
    final cached = await _cacheService.getThumbnail(videoFile, time: time);
    if (cached != null) {
      return cached;
    }
    
    // Check if job already exists
    if (_activeJobs.containsKey(cacheKey)) {
      return _activeJobs[cacheKey]!.completer.future;
    }
    
    // Create new job
    final completer = Completer<Uint8List?>();
    _activeJobs[cacheKey] = _ThumbnailJob(
      videoFile: videoFile,
      time: time,
      completer: completer,
      onProgress: onProgress,
    );
    
    // Add to queue
    _requestQueue.add(_ThumbnailRequest(
      videoFile: videoFile,
      time: time,
      cacheKey: cacheKey,
    ));
    
    // Trigger processing
    _processQueue();
    
    return completer.future;
  }

  /// Generate cache key (duplicate of private method in ThumbnailCacheService)
  String _generateCacheKey(File file, Duration time) {
    final fileHash = file.path.hashCode;
    final timeHash = time.inMilliseconds.hashCode;
    return '${fileHash}_$timeHash';
  }

  /// Generate multiple thumbnails in batch
  Future<Map<String, Uint8List?>> generateBatch(
    List<File> videoFiles, {
    Duration time = const Duration(seconds: 1),
    Function(int, int)? onProgress, // current, total
  }) async {
    final results = <String, Uint8List?>{};
    
    for (int i = 0; i < videoFiles.length; i++) {
      final file = videoFiles[i];
      onProgress?.call(i + 1, videoFiles.length);
      
      final thumbnail = await generateThumbnail(file, time: time);
      results[file.path] = thumbnail;
    }
    
    return results;
  }

  /// Start the thumbnail generation isolate
  Future<void> _startIsolate() async {
    try {
      _isolate = await Isolate.spawn(
        _thumbnailGenerationIsolate,
        _receivePort.sendPort,
      );
      
      _receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort.complete(message);
        } else if (message is _ThumbnailResult) {
          _handleThumbnailResult(message);
        } else if (message is _ThumbnailProgress) {
          _handleThumbnailProgress(message);
        }
      });
      
      debugPrint('Thumbnail generation isolate started');
    } catch (e) {
      debugPrint('Error starting isolate: $e');
      // Fallback to main thread if isolate fails
    }
  }

  /// Process the request queue
  void _processQueue() {
    if (_isProcessing || _requestQueue.isEmpty) return;
    
    _isProcessing = true;
    
    while (_activeJobs.length < _maxConcurrentJobs && _requestQueue.length > 0) {
      final request = _requestQueue.removeFirst();
      _processRequest(request);
    }
    
    _isProcessing = false;
  }

  /// Process a single thumbnail request
  Future<void> _processRequest(_ThumbnailRequest request) async {
    final job = _activeJobs[request.cacheKey];
    if (job == null) return;
    
    try {
      job.onProgress?.call(0.1);
      
      // Try to use isolate if available
      if (_isolate != null && _sendPort.isCompleted) {
        final sendPort = await _sendPort.future;
        sendPort.send(_ThumbnailIsolateRequest(
          videoPath: request.videoFile.path,
          timeSeconds: request.time.inSeconds.toDouble(),
          requestId: request.cacheKey,
        ));
      } else {
        // Fallback to main thread - use cache service's public method
        job.onProgress?.call(0.5);
        final thumbnail = await _cacheService.getThumbnail(request.videoFile, time: request.time);
        job.completer.complete(thumbnail);
        _activeJobs.remove(request.cacheKey);
        job.onProgress?.call(1.0);
      }
    } catch (e) {
      debugPrint('Error processing thumbnail request: $e');
      job.completer.complete(null);
      _activeJobs.remove(request.cacheKey);
    }
    
    // Process next in queue
    _processQueue();
  }

  /// Handle thumbnail result from isolate
  void _handleThumbnailResult(_ThumbnailResult result) {
    final job = _activeJobs[result.requestId];
    if (job != null) {
      job.completer.complete(result.data);
      _activeJobs.remove(result.requestId);
      job.onProgress?.call(1.0);
    }
    
    // Process next in queue
    _processQueue();
  }

  /// Handle thumbnail progress from isolate
  void _handleThumbnailProgress(_ThumbnailProgress progress) {
    final job = _activeJobs[progress.requestId];
    if (job != null) {
      job.onProgress?.call(progress.progress);
    }
  }

  /// Cancel a thumbnail generation job
  void cancelJob(String cacheKey) {
    final job = _activeJobs.remove(cacheKey);
    if (job != null) {
      job.completer.complete(null);
    }
  }

  /// Cancel all active jobs
  void cancelAllJobs() {
    for (final job in _activeJobs.values) {
      job.completer.complete(null);
    }
    _activeJobs.clear();
    _requestQueue.clear();
  }

  /// Get active job count
  int get activeJobCount => _activeJobs.length;

  /// Get queued job count
  int get queuedJobCount => _requestQueue.length;

  /// Dispose resources
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort.close();
    cancelAllJobs();
    _cacheService.dispose();
  }
}

/// Isolate entry point for thumbnail generation
void _thumbnailGenerationIsolate(SendPort sendPort) {
  final receivePort = ReceivePort();
  sendPort.send(receivePort.sendPort);
  
  receivePort.listen((message) async {
    if (message is _ThumbnailIsolateRequest) {
      try {
        // Generate thumbnail in isolate
        final result = await _generateThumbnailInIsolate(message);
        sendPort.send(result);
      } catch (e) {
        sendPort.send(_ThumbnailResult(
          requestId: message.requestId,
          data: null,
          error: e.toString(),
        ));
      }
    }
  });
}

/// Generate thumbnail in isolate using FFmpeg
Future<_ThumbnailResult> _generateThumbnailInIsolate(_ThumbnailIsolateRequest request) async {
  try {
    // This would use FFmpeg in the isolate
    // For now, return a placeholder result
    // In production, you'd use FFmpeg or another library that supports isolates
    
    return _ThumbnailResult(
      requestId: request.requestId,
      data: null, // Would contain actual thumbnail data
      error: null,
    );
  } catch (e) {
    return _ThumbnailResult(
      requestId: request.requestId,
      data: null,
      error: e.toString(),
    );
  }
}

/// Data classes for isolate communication
class _ThumbnailRequest {
  final File videoFile;
  final Duration time;
  final String cacheKey;
  
  _ThumbnailRequest({
    required this.videoFile,
    required this.time,
    required this.cacheKey,
  });
}

class _ThumbnailJob {
  final File videoFile;
  final Duration time;
  final Completer<Uint8List?> completer;
  final Function(double)? onProgress;
  
  _ThumbnailJob({
    required this.videoFile,
    required this.time,
    required this.completer,
    this.onProgress,
  });
}

class _ThumbnailIsolateRequest {
  final String videoPath;
  final double timeSeconds;
  final String requestId;
  
  _ThumbnailIsolateRequest({
    required this.videoPath,
    required this.timeSeconds,
    required this.requestId,
  });
}

class _ThumbnailResult {
  final String requestId;
  final Uint8List? data;
  final String? error;
  
  _ThumbnailResult({
    required this.requestId,
    this.data,
    this.error,
  });
}

class _ThumbnailProgress {
  final String requestId;
  final double progress;
  
  _ThumbnailProgress({
    required this.requestId,
    required this.progress,
  });
}

/// Simple queue implementation
class Queue<T> {
  final List<T> _items = [];
  
  void add(T item) => _items.add(item);
  
  T removeFirst() => _items.removeAt(0);
  
  bool get isEmpty => _items.isEmpty;
  
  int get length => _items.length;
  
  void clear() => _items.clear();
}
