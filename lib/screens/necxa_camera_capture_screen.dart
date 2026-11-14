import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:universal_io/io.dart';
import 'dart:async';
import '../theme.dart';
import '../services/filter_catalogue_service.dart';
import '../effects_engine/necxa_effects_engine.dart';
import '../models/camera_studio_result.dart';

class NecxaCameraCaptureScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final CameraLensDirection initialLensDirection;
  final ValueChanged<CameraLensDirection>? onLensChanged;

  NecxaCameraCaptureScreen({
    super.key,
    required this.cameras,
    this.initialLensDirection = CameraLensDirection.front,
    this.onLensChanged,
  });

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
  NecxaFilterMeta? _activeFilter;
  double _filterIntensity = 1.0;
  bool _previewDisabled = false;
  bool _loadingCatalogue = false;
  String _activeCategoryTab = 'All';
  List<NecxaFilterMeta> _catalogueFilters = [];
  bool _isFrontCamera = false;

  // Multi-Segment State
  final List<File> _capturedClips = [];
  final List<Duration> _capturedClipDurations = [];
  double _totalRecordedSeconds = 0;
  double maxSeconds = 60.0;

  final List<double> _speeds = [0.5, 1.0, 2.0];

  @override
  void initState() {
    super.initState();
    final initialCamera = widget.cameras.firstWhere(
      (camera) => camera.lensDirection == widget.initialLensDirection,
      orElse: () => widget.cameras.first,
    );
    _initCamera(initialCamera);
    unawaited(_loadCatalogue());
  }

  Future<void> _loadCatalogue() async {
    if (mounted) setState(() => _loadingCatalogue = true);
    try {
      final filters = await FilterCatalogueService.loadCatalogue();
      if (mounted) {
        setState(() {
          _catalogueFilters = filters;
        });
      }
    } catch (e) {
      debugPrint('[CameraStudio] Filter load error: $e');
    } finally {
      if (mounted) setState(() => _loadingCatalogue = false);
    }
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
      if (previousController != null && !kIsWeb && Platform.isAndroid) {
        await Future<void>.delayed(Duration(milliseconds: 150));
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
      widget.onLensChanged?.call(description.lensDirection);
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
    _recordingTimer = Timer.periodic(Duration(milliseconds: 100), (t) {
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
    _countdownTimer = Timer.periodic(Duration(seconds: 1), (timer) {
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

      // ??? SAFELY STORE CONTENT
      await Future.delayed(Duration(milliseconds: 300));
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
            '?? NecxaCapture: Segment added (${_capturedClips.length} total)',
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
    Navigator.pop(
      context,
      CameraStudioResult(
        clips: List<File>.from(_capturedClips),
        filter: _activeFilter,
        filterIntensity: _filterIntensity,
      ),
    );
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
              Center(child: CircularProgressIndicator(color: C.brand)),
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  icon: Icon(Icons.close, color: C.text),
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
          // 1. Camera Preview with real GPU ColorFilter matrix
          Center(
            child: (_activeFilter != null &&
                    !_activeFilter!.isNone &&
                    !_previewDisabled)
                ? ColorFiltered(
                    colorFilter: NecxaEffectsEngine.colorFilterForMeta(
                      _activeFilter,
                      intensity: _filterIntensity,
                    )!,
                    child: CameraPreview(_controller!),
                  )
                : CameraPreview(_controller!),
          ),

          // 2. Before / After preview indicator & active filter badge
          if (_activeFilter != null && !_activeFilter!.isNone)
            Positioned(
              top: 70,
              right: 16,
              child: GestureDetector(
                onLongPressStart: (_) => setState(() => _previewDisabled = true),
                onLongPressEnd: (_) => setState(() => _previewDisabled = false),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _previewDisabled ? Colors.white38 : C.brand,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _previewDisabled
                            ? Icons.visibility_off_outlined
                            : Icons.auto_awesome,
                        color: _previewDisabled ? Colors.white70 : C.brand,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _previewDisabled
                            ? 'Original'
                            : '${_activeFilter!.displayName} ${(_filterIntensity * 100).round()}%',
                        style: syne(
                          sz: 11,
                          w: FontWeight.bold,
                          c: _previewDisabled ? Colors.white70 : C.brand,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_countdownRemaining != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black38,
                child: Center(
                  child: Text(
                    '${_countdownRemaining!}',
                    style: syne(sz: 88, w: FontWeight.w900, c: C.text),
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
                Spacer(),
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
    maxSeconds = 60.0;
    double progress = (_totalRecordedSeconds / maxSeconds).clamp(0.0, 1.0);

    return Container(
      width: double.infinity,
      height: 6,
      margin: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: C.dim,
        borderRadius: BorderRadius.circular(3),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            AnimatedContainer(
              duration: Duration(milliseconds: 100),
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


  Widget _topBar() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: Icon(Icons.close, color: C.text, size: 28),
            onPressed: () => Navigator.pop(context),
          ),
          if (_isRecording || _capturedClips.isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                  SizedBox(width: 8),
                  Text(
                    _isRecording
                        ? _formatDuration(_timerSeconds)
                        : '${_capturedClips.length} Clips',
                    style: syne(sz: 14, w: FontWeight.bold, c: C.text),
                  ),
                ],
              ),
            ),
          IconButton(
            icon: Icon(
              _isFrontCamera ? Icons.camera_rear : Icons.camera_front,
              color: C.text,
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
        padding: EdgeInsets.only(right: 16),
        child: Column(
          children: [
            _controlBtn(Icons.zoom_in, 'Zoom', () => _showZoomDialog()),
            SizedBox(height: 20),
            _controlBtn(
              Icons.filter_vintage,
              _activeFilter != null && !_activeFilter!.isNone
                  ? _activeFilter!.displayName
                  : 'Filters',
              () => _showFilterDialog(),
            ),
            SizedBox(height: 20),
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
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black26,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: C.text, size: 24),
          ),
          SizedBox(height: 4),
          Text(
            label,
            style: dm(sz: 10, c: C.text, w: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _bottomControls() {
    return Padding(
      padding: EdgeInsets.only(bottom: 40),
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
                border: Border.all(color: C.text, width: 2),
                borderRadius: BorderRadius.circular(8),
                color: C.dim,
              ),
              child: Icon(
                Icons.photo_library,
                color: C.text,
                size: 24,
              ),
            ),
          ),
          // Delete Last Clip
          if (!_isRecording && _capturedClips.isNotEmpty)
            _controlBtn(Icons.backspace_outlined, 'Undo', _removeLastClip)
          else
            SizedBox(width: 48),

          SizedBox(width: 20),
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
              padding: EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: C.text, width: 4),
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
          SizedBox(width: 20),

          // Done Button
          if (!_isRecording && _capturedClips.isNotEmpty)
            GestureDetector(
              onTap: _finishRecording,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: C.brand,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.check, color: Colors.black, size: 28),
              ),
            )
          else
            SizedBox(width: 48),
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
                    padding: EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _speed == s ? C.brand : C.dim,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${s}x',
                      style: syne(
                        sz: 14,
                        w: FontWeight.bold,
                        c: _speed == s ? Colors.black : C.text,
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
    const categories = [
      'All',
      'beauty',
      'glow',
      'color',
      'creative',
      'super_face',
    ];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.92),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final pool = _catalogueFilters.isNotEmpty
              ? _catalogueFilters
              : FilterCatalogueService.fallbackFilters;

          final filtered = _activeCategoryTab == 'All'
              ? pool
              : pool
                  .where(
                    (f) =>
                        f.isNone ||
                        f.category.toLowerCase() ==
                            _activeCategoryTab.toLowerCase(),
                  )
                  .toList();

          return SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              height: 290,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header: title + reset
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'SMART FILTERS',
                          style: syne(
                            sz: 12,
                            w: FontWeight.w800,
                            ls: 1.2,
                            c: C.brand,
                          ),
                        ),
                        if (_activeFilter != null && !_activeFilter!.isNone)
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _activeFilter = null;
                                _filterIntensity = 1.0;
                              });
                              setSheetState(() {});
                            },
                            child: Text(
                              'Reset',
                              style: dm(
                                sz: 12,
                                w: FontWeight.bold,
                                c: Colors.white70,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Category tabs
                  SizedBox(
                    height: 34,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: categories.length,
                      itemBuilder: (_, i) {
                        final cat = categories[i];
                        final isActive = _activeCategoryTab == cat;
                        final label = cat == 'super_face'
                            ? 'Super Face'
                            : (cat == 'All'
                                ? 'All'
                                : '${cat[0].toUpperCase()}${cat.substring(1)}');
                        return GestureDetector(
                          onTap: () {
                            setState(() => _activeCategoryTab = cat);
                            setSheetState(() {});
                          },
                          child: Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? C.brand
                                  : Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: isActive
                                    ? C.brand
                                    : Colors.white.withValues(alpha: 0.12),
                              ),
                            ),
                            child: Text(
                              label,
                              style: syne(
                                sz: 11,
                                w: FontWeight.bold,
                                c: isActive ? Colors.black : C.text,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Filter Carousel
                  Expanded(
                    child: _loadingCatalogue && pool.isEmpty
                        ? Center(
                            child: CircularProgressIndicator(
                              color: C.brand,
                              strokeWidth: 2,
                            ),
                          )
                        : ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final f = filtered[i];
                              final isSelected = (_activeFilter == null &&
                                      f.isNone) ||
                                  (_activeFilter != null &&
                                      _activeFilter!.id == f.id);

                              return GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _activeFilter = f.isNone ? null : f;
                                  });
                                  setSheetState(() {});
                                },
                                child: Container(
                                  width: 84,
                                  margin: const EdgeInsets.only(right: 12),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? C.brand.withValues(alpha: 0.15)
                                        : Colors.white.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: isSelected
                                          ? C.brand
                                          : Colors.white.withValues(alpha: 0.15),
                                      width: isSelected ? 2 : 1,
                                    ),
                                  ),
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          gradient: LinearGradient(
                                            colors: f.isNone
                                                ? [
                                                    Colors.white24,
                                                    Colors.white10,
                                                  ]
                                                : [
                                                    C.brand.withValues(
                                                      alpha: 0.7,
                                                    ),
                                                    C.brandDk.withValues(
                                                      alpha: 0.4,
                                                    ),
                                                  ],
                                          ),
                                        ),
                                        child: Icon(
                                          f.isNone
                                              ? Icons.block
                                              : (f.category == 'beauty'
                                                  ? Icons.face_retouching_natural
                                                  : (f.category == 'glow'
                                                      ? Icons.light_mode_outlined
                                                      : Icons.auto_awesome)),
                                          color: isSelected
                                              ? C.brand
                                              : Colors.white,
                                          size: 22,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        f.displayName,
                                        style: syne(
                                          sz: 11,
                                          w: isSelected
                                              ? FontWeight.bold
                                              : FontWeight.w500,
                                          c: isSelected ? C.brand : C.text,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),

                  // Intensity Slider (when a filter is active)
                  if (_activeFilter != null && !_activeFilter!.isNone) ...[
                    const Divider(color: Colors.white12, height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Text(
                            'Intensity',
                            style: dm(sz: 11, c: Colors.white70),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                activeTrackColor: C.brand,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: C.brand,
                              ),
                              child: Slider(
                                value: _filterIntensity,
                                min: 0.0,
                                max: 1.0,
                                onChanged: (v) {
                                  setState(() => _filterIntensity = v);
                                  setSheetState(() {});
                                },
                              ),
                            ),
                          ),
                          Text(
                            '${(_filterIntensity * 100).round()}%',
                            style: syne(
                              sz: 11,
                              w: FontWeight.bold,
                              c: C.brand,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
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
                            : C.dim,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _countdownSeconds == seconds
                              ? C.brand
                              : C.dim,
                        ),
                      ),
                      child: Text(
                        seconds == 0 ? 'Off' : '${seconds}s',
                        style: syne(
                          sz: 13,
                          w: FontWeight.bold,
                          c: _countdownSeconds == seconds
                              ? Colors.black
                              : C.text,
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



