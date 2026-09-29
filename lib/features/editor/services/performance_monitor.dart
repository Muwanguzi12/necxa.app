import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Performance monitoring service for tracking editor performance metrics
class PerformanceMonitor {
  static final PerformanceMonitor _instance = PerformanceMonitor._internal();
  factory PerformanceMonitor() => _instance;
  PerformanceMonitor._internal();

  final Map<String, _MetricData> _metrics = {};
  final List<_FrameTime> _frameTimes = [];
  final List<double> _memoryUsage = [];
  
  Timer? _reportingTimer;
  int _frameCount = 0;
  
  static const int maxFrameSamples = 300; // Keep last 5 seconds at 60fps
  static const int maxMemorySamples = 60; // Keep last 60 samples
  
  /// Initialize the monitor
  void initialize() {
    // Start periodic reporting
    _reportingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _reportMetrics();
    });
    
    // Start frame time tracking
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    
    debugPrint('PerformanceMonitor initialized');
  }

  /// Track a metric
  void trackMetric(String name, double value, {String? unit}) {
    if (!_metrics.containsKey(name)) {
      _metrics[name] = _MetricData(name: name, unit: unit);
    }
    
    _metrics[name]!.addValue(value);
  }

  /// Track a duration
  void trackDuration(String name, Duration duration) {
    trackMetric(name, duration.inMicroseconds / 1000.0, unit: 'ms');
  }

  /// Start a performance operation
  _PerformanceOperation startOperation(String name) {
    return _PerformanceOperation(
      name: name,
      startTime: DateTime.now(),
      monitor: this,
    );
  }

  /// Record frame timing
  void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final frameDuration = timing.totalSpan.inMicroseconds / 1000.0;
      _frameTimes.add(_FrameTime(
        timestamp: DateTime.now(),
        duration: frameDuration,
      ));
      
      // Keep only recent samples
      if (_frameTimes.length > maxFrameSamples) {
        _frameTimes.removeAt(0);
      }
    }
    
    _frameCount++;
  }

  /// Get current FPS
  double get currentFPS {
    if (_frameTimes.length < 2) return 0;
    
    final recentFrames = _frameTimes.take(60).toList();
    if (recentFrames.length < 2) return 0;
    
    final totalDuration = recentFrames.last.timestamp.difference(recentFrames.first.timestamp).inMicroseconds / 1000.0;
    if (totalDuration == 0) return 0;
    
    return (recentFrames.length / totalDuration) * 1000;
  }

  /// Get average frame time
  double get averageFrameTime {
    if (_frameTimes.isEmpty) return 0;
    
    final recentFrames = _frameTimes.take(60).toList();
    final total = recentFrames.fold<double>(0, (sum, frame) => sum + frame.duration);
    return total / recentFrames.length;
  }

  /// Get p95 frame time
  double get p95FrameTime {
    if (_frameTimes.length < 2) return 0;
    
    final recentFrames = _frameTimes.take(60).toList();
    final sorted = List<double>.from(recentFrames.map((f) => f.duration))..sort();
    final index = (sorted.length * 0.95).floor().clamp(0, sorted.length - 1);
    return sorted[index];
  }

  /// Get dropped frames count
  int get droppedFrames {
    if (_frameTimes.isEmpty) return 0;
    
    final recentFrames = _frameTimes.take(60).toList();
    return recentFrames.where((f) => f.duration > 16.67).length; // > 60fps threshold
  }

  /// Record memory usage
  void recordMemoryUsage(double usageMB) {
    _memoryUsage.add(usageMB);
    
    if (_memoryUsage.length > maxMemorySamples) {
      _memoryUsage.removeAt(0);
    }
  }

  /// Get average memory usage
  double get averageMemoryUsage {
    if (_memoryUsage.isEmpty) return 0;
    return _memoryUsage.reduce((a, b) => a + b) / _memoryUsage.length;
  }

  /// Get peak memory usage
  double get peakMemoryUsage {
    if (_memoryUsage.isEmpty) return 0;
    return _memoryUsage.reduce((a, b) => a > b ? a : b);
  }

  /// Get all metrics
  Map<String, _MetricData> get metrics => Map.from(_metrics);

  /// Get performance report
  Map<String, dynamic> getPerformanceReport() {
    return {
      'fps': currentFPS,
      'averageFrameTime': averageFrameTime,
      'p95FrameTime': p95FrameTime,
      'droppedFrames': droppedFrames,
      'averageMemoryMB': averageMemoryUsage,
      'peakMemoryMB': peakMemoryUsage,
      'totalFrames': _frameCount,
      'customMetrics': _metrics.map((name, data) => MapEntry(
        name,
        {
          'average': data.average,
          'min': data.min,
          'max': data.max,
          'count': data.count,
          'unit': data.unit,
        },
      )),
    };
  }

  /// Report metrics periodically
  void _reportMetrics() {
    final report = getPerformanceReport();
    
    // Log if performance is poor
    if (report['fps'] < 30) {
      debugPrint('⚠️ Low FPS: ${report['fps'].toStringAsFixed(1)}');
    }
    
    if (report['droppedFrames'] > 5) {
      debugPrint('⚠️ High dropped frames: ${report['droppedFrames']}');
    }
    
    if (report['p95FrameTime'] > 33.0) {
      debugPrint('⚠️ High p95 frame time: ${report['p95FrameTime'].toStringAsFixed(2)}ms');
    }
  }

  /// Clear all metrics
  void clear() {
    _metrics.clear();
    _frameTimes.clear();
    _memoryUsage.clear();
    _frameCount = 0;
  }

  /// Dispose resources
  void dispose() {
    _reportingTimer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    clear();
  }
}

/// Data class for metric tracking
class _MetricData {
  final String name;
  final String? unit;
  final List<double> values = [];
  
  _MetricData({required this.name, this.unit});
  
  void addValue(double value) {
    values.add(value);
    if (values.length > 100) {
      values.removeAt(0);
    }
  }
  
  double get average {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }
  
  double get min {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a < b ? a : b);
  }
  
  double get max {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a > b ? a : b);
  }
  
  int get count => values.length;
}

/// Data class for frame time tracking
class _FrameTime {
  final DateTime timestamp;
  final double duration;
  
  _FrameTime({required this.timestamp, required this.duration});
}

/// Helper class for tracking operation duration
class _PerformanceOperation {
  final String name;
  final DateTime startTime;
  final PerformanceMonitor monitor;
  
  _PerformanceOperation({
    required this.name,
    required this.startTime,
    required this.monitor,
  });
  
  void complete() {
    final duration = DateTime.now().difference(startTime);
    monitor.trackDuration(name, duration);
  }
  
  T completeWith<T>(T result) {
    complete();
    return result;
  }
}

/// Extension for easy performance tracking
extension PerformanceTracking on PerformanceMonitor {
  Future<T> trackAsync<T>(
    String name,
    Future<T> Function() operation,
  ) async {
    final op = startOperation(name);
    try {
      final result = await operation();
      op.complete();
      return result;
    } catch (e) {
      op.complete();
      rethrow;
    }
  }
  
  T track<T>(
    String name,
    T Function() operation,
  ) {
    final op = startOperation(name);
    try {
      final result = operation();
      op.complete();
      return result;
    } catch (e) {
      op.complete();
      rethrow;
    }
  }
}
