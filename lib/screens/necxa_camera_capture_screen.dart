import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';
import '../theme.dart';

class NecxaCameraCaptureScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const NecxaCameraCaptureScreen({super.key, required this.cameras});

  @override
  State<NecxaCameraCaptureScreen> createState() =>
      _NecxaCameraCaptureScreenState();
}

class _NecxaCameraCaptureScreenState extends State<NecxaCameraCaptureScreen> {
  CameraController? _controller;
  CameraDescription? _activeCamera;
  bool _isRecording = false;
  bool _isStoppingRecording = false;
  bool _isSwitchingCamera = false;
  int _timerSeconds = 0;
  Timer? _recordingTimer;
  final Stopwatch _recordingStopwatch = Stopwatch();
  Timer? _countdownTimer;
  int _countdownSeconds = 0;
  int? _countdownRemaining;
  int _cameraGeneration = 0;

  // Settings
  double _speed = 1.0;
  String _activeFilter = 'Normal';
  bool _isFrontCamera = false;

  // Multi-Segment State
  final List<File> _capturedClips = [];
  final List<Duration> _capturedClipDurations = [];
  double _totalRecordedSeconds = 0;

  final List<String> _filters = ['Normal', 'Cinema', 'Neon', 'Noir', 'Vivid'];
  final List<double> _speeds = [0.5, 1.0, 2.0];

  @override
  void initState() {
    super.initState();
    final initialCamera = widget.cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );
    _initCamera(initialCamera);
  }

  Future<bool> _initCamera(CameraDescription description) async {
    final generation = ++_cameraGeneration;
    final previousController = _controller;
    _controller = null;
    if (mounted) setState(() => _isSwitchingCamera = true);

    // Android devices generally allow only one active CameraController. The
    // previous lens must release the hardware before the next one initializes.
    try {
      await previousController?.dispose();
      if (previousController != null && Platform.isAndroid) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      CameraController? nextController;
      Object? lastError;
      for (final preset in const [
        ResolutionPreset.high,
        ResolutionPreset.medium,
      ]) {
        final candidate = CameraController(
          description,
          preset,
          enableAudio: true,
        );
        try {
          await candidate.initialize();
          nextController = candidate;
          break;
        } catch (error) {
          lastError = error;
          await candidate.dispose();
        }
      }

      if (!mounted || generation != _cameraGeneration) {
        await nextController?.dispose();
        return false;
      }
      if (nextController == null) {
        throw lastError ?? StateError('Camera failed');
      }

      _controller = nextController;
      _activeCamera = description;
      _isFrontCamera = description.lensDirection == CameraLensDirection.front;
      setState(() => _isSwitchingCamera = false);
      return true;
    } catch (error) {
      debugPrint('Camera Init Error: $error');
      if (mounted && generation == _cameraGeneration) {
        setState(() => _isSwitchingCamera = false);
        _showMessage('Unable to open this camera');
      }
      return false;
    }
  }

  Future<void> _toggleCamera() async {
    if (_isRecording || _isSwitchingCamera || _countdownRemaining != null) {
      return;
    }
    final previousCamera = _activeCamera;
    final targetDirection = _isFrontCamera
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    final matchingCameras = widget.cameras.where(
      (camera) => camera.lensDirection == targetDirection,
    );
    if (matchingCameras.isEmpty) {
      _showMessage(
        targetDirection == CameraLensDirection.front
            ? 'Front camera is not available'
            : 'Back camera is not available',
      );
      return;
    }

    var switched = false;
    for (final camera in matchingCameras) {
      switched = await _initCamera(camera);
      if (switched) break;
    }
    if (!switched && previousCamera != null && mounted) {
      await _initCamera(previousCamera);
    }
  }

  void _startTimer() {
    _timerSeconds = 0;
    _recordingStopwatch
      ..reset()
      ..start();
    final completedSeconds = _capturedClipDurations.fold<double>(
      0,
      (total, duration) => total + duration.inMilliseconds / 1000,
    );
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (mounted) {
        final elapsed = _recordingStopwatch.elapsed;
        setState(() {
          _timerSeconds = elapsed.inMilliseconds ~/ 100;
          _totalRecordedSeconds =
              completedSeconds + elapsed.inMilliseconds / 1000;
        });
        if (_totalRecordedSeconds >= 60 && !_isStoppingRecording) {
          unawaited(_stopRecording());
        }
      }
    });
  }

  Duration _stopTimer() {
    final elapsed = _recordingStopwatch.elapsed;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingStopwatch.stop();
    return elapsed;
  }

  Future<void> _startRecording() async {
    if (_countdownSeconds > 0) {
      _startCountdown();
      return;
    }
    await _beginRecording();
  }

  void _startCountdown() {
    if (_isRecording || _countdownRemaining != null || _controller == null) {
      return;
    }
    _countdownTimer?.cancel();
    setState(() => _countdownRemaining = _countdownSeconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final next = (_countdownRemaining ?? 1) - 1;
      if (next <= 0) {
        timer.cancel();
        setState(() => _countdownRemaining = null);
        unawaited(_beginRecording());
      } else {
        setState(() => _countdownRemaining = next);
      }
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    if (mounted) setState(() => _countdownRemaining = null);
  }

  Future<void> _beginRecording() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isRecording ||
        _isSwitchingCamera) {
      return;
    }

    try {
      await controller.startVideoRecording();
      _startTimer();
      if (mounted) setState(() => _isRecording = true);
    } catch (error) {
      debugPrint('Start Rec Error: $error');
      if (mounted) _showMessage('Unable to start recording');
    }
  }

  Future<void> _stopRecording() async {
    final controller = _controller;
    if (controller == null || !_isRecording || _isStoppingRecording) return;
    _isStoppingRecording = true;
    final recordedDuration = _stopTimer();

    try {
      final XFile rawFile = await controller.stopVideoRecording();
      if (mounted) setState(() => _isRecording = false);

      // 🛡️ SAFELY STORE CONTENT
      await Future.delayed(const Duration(milliseconds: 300));
      final directory = await getApplicationDocumentsDirectory();
      final String fileName =
          'necxa_clip_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final File savedFile = File('${directory.path}/$fileName');

      try {
        await File(rawFile.path).copy(savedFile.path);
        final int size = await savedFile.length();
        if (size > 0 && mounted) {
          setState(() {
            _capturedClips.add(savedFile);
            _capturedClipDurations.add(recordedDuration);
            _totalRecordedSeconds = _capturedClipDurations.fold<double>(
              0,
              (total, duration) => total + duration.inMilliseconds / 1000,
            );
          });
          debugPrint(
            '🎬 NecxaCapture: Segment added (${_capturedClips.length} total)',
          );
        }
      } catch (e) {
        debugPrint('File Save Error: $e');
        if (mounted) _showMessage('Unable to store this recording');
      }
    } catch (error) {
      debugPrint('Stop Rec Error: $error');
      if (mounted) {
        setState(() => _isRecording = false);
        _showMessage('Unable to save this recording');
      }
    } finally {
      _isStoppingRecording = false;
    }
  }

  void _finishRecording() {
    if (_capturedClips.isEmpty) return;
    Navigator.pop(context, _capturedClips);
  }

  void _removeLastClip() {
    if (_capturedClips.isNotEmpty) {
      setState(() {
        _capturedClips.removeLast();
        if (_capturedClipDurations.isNotEmpty) {
          _capturedClipDurations.removeLast();
        }
        _totalRecordedSeconds = _capturedClipDurations.fold<double>(
          0,
          (total, duration) => total + duration.inMilliseconds / 1000,
        );
      });
    }
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _countdownTimer?.cancel();
    _recordingStopwatch.stop();
    _cameraGeneration++;
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              const Center(child: CircularProgressIndicator(color: C.brand)),
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Camera Preview
          Center(child: CameraPreview(_controller!)),

          // 2. Filter Layer (Visual Only Simulation)
          if (_activeFilter != 'Normal') _buildFilterOverlay(),

          if (_countdownRemaining != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black38,
                child: Center(
                  child: Text(
                    '${_countdownRemaining!}',
                    style: syne(sz: 88, w: FontWeight.w900, c: Colors.white),
                  ),
                ),
              ),
            ),

          // 3. UI Layer
          SafeArea(
            child: Column(
              children: [
                _topBar(),
                _buildTimeline(),
                const Spacer(),
                _sideControls(),
                _bottomControls(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    const maxSeconds = 60.0;
    double progress = (_totalRecordedSeconds / maxSeconds).clamp(0.0, 1.0);

    return Container(
      width: double.infinity,
      height: 6,
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(3),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: constraints.maxWidth * progress,
              decoration: BoxDecoration(
                color: C.brand,
                borderRadius: BorderRadius.circular(3),
                boxShadow: [
                  BoxShadow(
                    color: C.brand.withValues(alpha: 0.4),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
            ...List.generate(_capturedClipDurations.length, (index) {
              final segmentEndSeconds = _capturedClipDurations
                  .take(index + 1)
                  .fold<double>(
                    0,
                    (total, duration) => total + duration.inMilliseconds / 1000,
                  );
              return Positioned(
                left:
                    constraints.maxWidth *
                    (segmentEndSeconds / maxSeconds).clamp(0.0, 1.0),
                child: Container(width: 2, height: 6, color: Colors.black),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterOverlay() {
    Color filterColor = Colors.transparent;

    if (_activeFilter == 'Cinema') {
      filterColor = Colors.orange.withValues(alpha: 0.1);
    }
    if (_activeFilter == 'Neon') {
      filterColor = Colors.purple.withValues(alpha: 0.2);
    }
    if (_activeFilter == 'Noir') {
      return ColorFiltered(
        colorFilter: const ColorFilter.matrix([
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]),
        child: CameraPreview(_controller!),
      );
    }

    return Container(color: filterColor);
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 28),
            onPressed: () => Navigator.pop(context),
          ),
          if (_isRecording || _capturedClips.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Icon(
                    _isRecording ? Icons.circle : Icons.movie,
                    color: _isRecording ? Colors.red : C.brand,
                    size: 12,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isRecording
                        ? _formatDuration(_timerSeconds)
                        : '${_capturedClips.length} Clips',
                    style: syne(sz: 14, w: FontWeight.bold, c: Colors.white),
                  ),
                ],
              ),
            ),
          IconButton(
            icon: Icon(
              _isFrontCamera ? Icons.camera_rear : Icons.camera_front,
              color: Colors.white,
              size: 28,
            ),
            onPressed:
                _isRecording ||
                    _isSwitchingCamera ||
                    _countdownRemaining != null
                ? null
                : _toggleCamera,
          ),
        ],
      ),
    );
  }

  Widget _sideControls() {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Column(
          children: [
            _controlBtn(Icons.zoom_in, 'Zoom', () => _showZoomDialog()),
            const SizedBox(height: 20),
            _controlBtn(
              Icons.filter_vintage,
              'Filters',
              () => _showFilterDialog(),
            ),
            const SizedBox(height: 20),
            _controlBtn(
              Icons.timer_outlined,
              _countdownSeconds == 0 ? 'Timer' : '${_countdownSeconds}s',
              _isRecording || _countdownRemaining != null
                  ? () {}
                  : _showTimerDialog,
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlBtn(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: Colors.black26,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: dm(sz: 10, c: Colors.white, w: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _bottomControls() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Gallery Button
          GestureDetector(
            onTap: () async {
              if (_isRecording) return;
              // Pass a signal back to UploadScreen to open gallery
              Navigator.pop(context, 'OPEN_GALLERY');
            },
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(8),
                color: Colors.white10,
              ),
              child: const Icon(
                Icons.photo_library,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
          // Delete Last Clip
          if (!_isRecording && _capturedClips.isNotEmpty)
            _controlBtn(Icons.backspace_outlined, 'Undo', _removeLastClip)
          else
            const SizedBox(width: 48),

          const SizedBox(width: 20),
          // Record Button
          GestureDetector(
            onTap: () {
              if (_countdownRemaining != null) {
                _cancelCountdown();
              } else if (_isRecording) {
                unawaited(_stopRecording());
              } else {
                unawaited(_startRecording());
              }
            },
            child: Container(
              width: 80,
              height: 80,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 4),
              ),
              child: Container(
                decoration: BoxDecoration(
                  shape: _isRecording || _countdownRemaining != null
                      ? BoxShape.rectangle
                      : BoxShape.circle,
                  color: Colors.red,
                  borderRadius: _isRecording || _countdownRemaining != null
                      ? BorderRadius.circular(8)
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 20),

          // Done Button
          if (!_isRecording && _capturedClips.isNotEmpty)
            GestureDetector(
              onTap: _finishRecording,
              child: Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  color: C.brand,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, color: Colors.black, size: 28),
              ),
            )
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }

  void _showZoomDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      builder: (sheetContext) => SizedBox(
        height: 120,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: _speeds
              .map(
                (s) => GestureDetector(
                  onTap: () async {
                    setState(() => _speed = s);
                    await _controller?.setZoomLevel(
                      s == 0.5 ? 1.0 : (s == 1.0 ? 1.0 : 2.0),
                    ); // Note: 0.5 is usually just 1x on mobile cameras unless it's ultra-wide
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _speed == s ? C.brand : Colors.white10,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${s}x',
                      style: syne(
                        sz: 14,
                        w: FontWeight.bold,
                        c: _speed == s ? Colors.black : Colors.white,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  void _showFilterDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      builder: (context) => SizedBox(
        height: 150,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(20),
          children: _filters
              .map(
                (f) => GestureDetector(
                  onTap: () {
                    setState(() => _activeFilter = f);
                    Navigator.pop(context);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 16),
                    width: 80,
                    decoration: BoxDecoration(
                      color: _activeFilter == f ? C.brand : Colors.white10,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _activeFilter == f ? C.brand : Colors.white24,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        f,
                        style: syne(
                          sz: 12,
                          w: FontWeight.bold,
                          c: _activeFilter == f ? Colors.black : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  void _showTimerDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: 132,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: const <int>[0, 3, 5, 10]
                .map(
                  (seconds) => GestureDetector(
                    onTap: () {
                      setState(() => _countdownSeconds = seconds);
                      Navigator.pop(sheetContext);
                    },
                    child: Container(
                      width: 64,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _countdownSeconds == seconds
                            ? C.brand
                            : Colors.white10,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _countdownSeconds == seconds
                              ? C.brand
                              : Colors.white24,
                        ),
                      ),
                      child: Text(
                        seconds == 0 ? 'Off' : '${seconds}s',
                        style: syne(
                          sz: 13,
                          w: FontWeight.bold,
                          c: _countdownSeconds == seconds
                              ? Colors.black
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDuration(int deciSeconds) {
    final totalSeconds = (deciSeconds / 10).floor();
    final min = (totalSeconds / 60).floor();
    final sec = totalSeconds % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}
