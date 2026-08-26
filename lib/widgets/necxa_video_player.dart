import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import '../theme.dart';
import '../app_state.dart';
import '../services/video_preload_manager.dart';

class NecxaVideoPlayer extends StatefulWidget {
  final String url;
  final String? audioUrl;
  final bool adaptive;
  final bool lowDataMode;
  final Function(bool)? onToggle;
  final AppState? state;
  const NecxaVideoPlayer({super.key, required this.url, this.audioUrl, this.adaptive = false, this.lowDataMode = false, this.onToggle, this.state});

  @override
  State<NecxaVideoPlayer> createState() => NecxaVideoPlayerState();
}

class NecxaVideoPlayerState extends State<NecxaVideoPlayer> {
  late VideoPlayerController _controller;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _initialized = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _initController();
    // audioplayers has limited web support; secondary audio tracks are only
    // used on native platforms. On web the video element carries audio.
    if (!kIsWeb && widget.audioUrl != null) {
      _initAudio();
    }
    widget.state?.addListener(_onGlobalStateChange);
  }

  void _onGlobalStateChange() {
    if (!mounted || !_initialized) return;
    _updateVolume();
  }

  Future<void> _updateVolume() async {
    final bool muted = widget.state?.isGlobalMuted ?? false;
    if (muted) {
      await _controller.setVolume(0.0);
      if (!kIsWeb) await _audioPlayer.setVolume(0.0);
    } else {
      if (!kIsWeb && widget.audioUrl != null) {
        await _controller.setVolume(0.0); // Keep video muted if separate audio track
        await _audioPlayer.setVolume(1.0);
      } else {
        await _controller.setVolume(1.0);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _initAudio() async {
    try {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.setSourceUrl(widget.audioUrl!);
      // Volume control (if video has sound, we duck one or let both play)
      await _audioPlayer.setVolume(1.0);
    } catch (e) {
      debugPrint('Video Player Audio Error: $e');
    }
  }

  Future<void> _initController() async {
    debugPrint('?? NecxaVideoPlayer: Initializing for URL: ${widget.url}');
    try {
      _controller = await VideoPreloadManager.getController(widget.url);
    } catch (e) {
      debugPrint('Preload controller fetch error, falling back: $e');
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    }

    try {
      if (!_controller.value.isInitialized) {
        await _controller.initialize();
      }
      await _controller.setLooping(true);
      
      await _updateVolume();

      if (!widget.lowDataMode) {
        await _controller.play();
        if (widget.audioUrl != null) {
          await _audioPlayer.resume();
        }
      }
      
      if (mounted) setState(() => _initialized = true);
    } catch (e) {
      debugPrint('? NecxaVideoPlayer Error (${widget.url}): $e');
      if (mounted) setState(() => _error = true);
    }
  }

 
  Future<void> togglePlay() async {
    if (!_initialized) return;
    if (_controller.value.isPlaying) {
      await _controller.pause();
      if (!kIsWeb && widget.audioUrl != null) await _audioPlayer.pause();
    } else {
      await _controller.play();
      if (!kIsWeb && widget.audioUrl != null) await _audioPlayer.resume();
    }
    if (widget.onToggle != null) widget.onToggle!(_controller.value.isPlaying);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.state?.removeListener(_onGlobalStateChange);
    _controller.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return Container(
        color: C.cardDk,
        child: Center(child: Icon(Icons.error_outline, color: C.dim, size: 48)),
      );
    }

    if (!_initialized) {
      return Container(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: C.brand, strokeWidth: 2)),
      );
    }

    return GestureDetector(
      onTap: togglePlay,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FittedBox(
            fit: widget.adaptive ? BoxFit.contain : BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: _controller.value.size.width,
              height: _controller.value.size.height,
              child: VideoPlayer(_controller),
            ),
          ),
          // Play/Pause Overlay Feedback
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _controller.value.isPlaying ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(102),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: C.text.withOpacity(0.1),
                        blurRadius: 20,
                        spreadRadius: 5,
                      )
                    ],
                  ),
                  child: Icon(
                    _controller.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, 
                    color: C.text, 
                    size: 50
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


