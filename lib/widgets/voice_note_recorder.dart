import 'package:flutter/material.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import '../theme.dart';
import '../app_state.dart';

class VoiceNoteRecorder extends StatefulWidget {
  final AppState state;
  const VoiceNoteRecorder({super.key, required this.state});

  @override
  State<VoiceNoteRecorder> createState() => _VoiceNoteRecorderState();
}

class _VoiceNoteRecorderState extends State<VoiceNoteRecorder> {
  @override
  Widget build(BuildContext context) {
    final recorderController = widget.state.recorderController;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.9),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: C.brand.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: C.brand.withOpacity(0.1),
            blurRadius: 20,
            spreadRadius: 5,
          )
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const Icon(Icons.mic, color: C.red, size: 24),
            const SizedBox(width: 12),
            Text(
              _formatDuration(widget.state.recordDuration),
              style: syne(sz: 14, w: FontWeight.w700, c: C.red),
            ),
            const SizedBox(width: 16),
            if (recorderController != null)
              Expanded(
                child: AudioWaveforms(
                  size: const Size(double.infinity, 40),
                  recorderController: recorderController,
                  enableGesture: false,
                  waveStyle: const WaveStyle(
                    waveColor: C.brand,
                    showMiddleLine: false,
                    spacing: 4,
                  ),
                ),
              )
            else
              Expanded(child: Divider(color: C.brand, thickness: 2)),
            const SizedBox(width: 16),
            Text(
              'Slide to cancel',
              style: dm(sz: 12, c: C.dim),
            ),
            Icon(Icons.chevron_left, color: C.dim, size: 20),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    String m = d.inMinutes.toString().padLeft(2, '0');
    String s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}


