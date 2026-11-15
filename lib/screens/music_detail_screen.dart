import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/music_models.dart';
import '../services/music_library_service.dart';
import '../theme.dart';

class MusicDetailScreen extends StatefulWidget {
  final MusicTrack track;
  const MusicDetailScreen({super.key, required this.track});

  @override
  State<MusicDetailScreen> createState() => _MusicDetailScreenState();
}

class _MusicDetailScreenState extends State<MusicDetailScreen> with SingleTickerProviderStateMixin {
  late final MusicLibraryService _musicService;
  late final AnimationController _visualizerCtrl;
  bool _isPlaying = false;
  bool _isSaved = false;

  @override
  void initState() {
    super.initState();
    _musicService = MusicLibraryService();
    _visualizerCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500))..repeat(reverse: true);
    _checkSaved();
  }

  Future<void> _checkSaved() async {
    // Mock check for now
    setState(() => _isSaved = false);
  }

  Future<void> _togglePreview() async {
    HapticFeedback.mediumImpact();
    if (_isPlaying) {
      await _musicService.stopPreview();
      _visualizerCtrl.stop();
    } else {
      await _musicService.previewMusic(widget.track.audioUrl);
      _visualizerCtrl.repeat(reverse: true);
    }
    setState(() => _isPlaying = !_isPlaying);
  }

  void _onSelect() {
    HapticFeedback.heavyImpact();
    Navigator.pop(context, widget.track.id);
  }

  @override
  void dispose() {
    _visualizerCtrl.dispose();
    _musicService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.75,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.85),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          border: Border.all(color: C.dim),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            // 1. Handle
            Container(width: 40, height: 4, decoration: BoxDecoration(color: C.dim, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 32),

            // 2. Album art (Animated)
            Hero(
              tag: 'track_${widget.track.id}',
              child: Container(
                width: 180, height: 180,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [BoxShadow(color: C.brand.withOpacity(0.2), blurRadius: 40)],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: widget.track.albumArtUrl != null 
                    ? Image.network(widget.track.albumArtUrl!, fit: BoxFit.cover)
                    : Container(color: C.text.withOpacity(0.05), child: Icon(Icons.music_note, color: C.dim, size: 60)),
                ),
              ),
            ),
            
            const SizedBox(height: 32),

            // 3. Info
            Text(widget.track.title, style: syne(sz: 24, w: FontWeight.w900, c: C.text), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(widget.track.artistName, style: dm(sz: 16, c: C.dim)),
            
            const SizedBox(height: 40),

            // 4. Micro-Visualizer (Better than TikTok)
            if (_isPlaying)
              _buildVisualizer()
            else
              Text('PREVIEW SOUND', style: syne(sz: 12, w: FontWeight.bold, c: C.dim, ls: 2)),

            const Spacer(),

            // 5. Action Hub
            Row(
              children: [
                // Preview Button
                Expanded(
                  child: GestureDetector(
                    onTap: _togglePreview,
                    child: Container(
                      height: 56,
                      decoration: BoxDecoration(
                        color: _isPlaying ? C.text : C.text.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: C.dim),
                      ),
                      child: Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: _isPlaying ? Colors.black : C.text),
                            const SizedBox(width: 12),
                            Text(_isPlaying ? 'PAUSE' : 'PLAY', style: syne(sz: 14, w: FontWeight.w900, c: _isPlaying ? Colors.black : C.text)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                
                // Select Button
                Expanded(
                  child: GestureDetector(
                    onTap: _onSelect,
                    child: Container(
                      height: 56,
                      decoration: BoxDecoration(
                        color: C.brand,
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [BoxShadow(color: C.brand.withOpacity(0.3), blurRadius: 15)],
                      ),
                      child: Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.check, color: Colors.black),
                            const SizedBox(width: 12),
                            Text('ADD SOUND', style: syne(sz: 14, w: FontWeight.w900, c: Colors.black)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVisualizer() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(10, (index) {
        return AnimatedBuilder(
          animation: _visualizerCtrl,
          builder: (context, child) {
            double h = 5 + (index % 3 == 0 ? 25 : 15) * _visualizerCtrl.value;
            return Container(
              width: 3, height: h,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(2)),
            );
          },
        );
      }),
    );
  }
}


