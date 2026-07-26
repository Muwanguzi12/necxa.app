import 'package:flutter/material.dart';
import '../../theme.dart';
import '../core/face_engine_controller.dart';
import '../models/face_preset.dart';
import '../presets/face_presets.dart';

class FacePresetSheet extends StatefulWidget {
  final FaceEngineController controller;
  final bool isPro;
  final VoidCallback onApply;
  final ValueChanged<FacePreset>? onLockedPreset;

  const FacePresetSheet({
    super.key,
    required this.controller,
    required this.isPro,
    required this.onApply,
    this.onLockedPreset,
  });

  @override
  State<FacePresetSheet> createState() => _FacePresetSheetState();
}

class _FacePresetSheetState extends State<FacePresetSheet> {
  Color _presetColor(FacePreset preset) {
    return switch (preset.id) {
      'original' => const Color(0xFF747A80),
      'natural' => C.brand,
      'fresh' => const Color(0xFF5BC58A),
      'sharp' => const Color(0xFFB5BEC9),
      'glow' => const Color(0xFFF1C75B),
      'glam' => const Color(0xFFEC6F9E),
      'soft' => const Color(0xFFB49AE8),
      _ => C.brand,
    };
  }

  void _select(FacePreset preset) {
    final selected = widget.controller.selectPreset(
      preset,
      isPro: widget.isPro,
    );
    if (!selected) {
      widget.onLockedPreset?.call(preset);
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final maxIntensity = controller.maxIntensity(widget.isPro);
    final isOriginal = controller.selectedPreset.id == FacePresets.original.id;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.face_retouching_natural, color: C.brand),
                const SizedBox(width: 10),
                Text(
                  'NECXA Face Engine',
                  style: syne(sz: 16, w: FontWeight.w800, c: C.text),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close, color: C.dim),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 94,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: FacePresets.all.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final preset = FacePresets.all[index];
                  final selected = controller.selectedPreset.id == preset.id;
                  final locked = preset.isPro && !widget.isPro;
                  final color = _presetColor(preset);
                  return InkWell(
                    onTap: () => _select(preset),
                    borderRadius: BorderRadius.circular(8),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 74,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: selected
                            ? color.withValues(alpha: 0.17)
                            : C.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected ? color : C.border,
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            locked ? Icons.lock_outline : Icons.face_outlined,
                            size: 20,
                            color: locked ? C.dim : color,
                          ),
                          const SizedBox(height: 7),
                          Text(
                            preset.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: dm(
                              sz: 10.5,
                              w: FontWeight.w700,
                              c: selected ? C.text : C.dim,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            preset.isPro ? 'PRO' : 'FREE',
                            style: dm(
                              sz: 8,
                              w: FontWeight.w800,
                              c: preset.isPro ? C.gold : C.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Text(
                  'Intensity',
                  style: dm(sz: 12, w: FontWeight.w700, c: C.text),
                ),
                const Spacer(),
                Text(
                  '${(controller.intensity * 100).round()}%',
                  style: dm(sz: 12, w: FontWeight.w700, c: C.brand),
                ),
              ],
            ),
            Slider(
              value: controller.intensity.clamp(0.0, maxIntensity),
              min: 0,
              max: maxIntensity,
              divisions: (maxIntensity * 100).round(),
              onChanged: isOriginal
                  ? null
                  : (value) => setState(
                      () => controller.setIntensity(value, isPro: widget.isPro),
                    ),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.onApply,
                style: FilledButton.styleFrom(
                  backgroundColor: C.brand,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.auto_fix_high),
                label: Text(
                  isOriginal ? 'Keep Original' : 'Apply Face Preset',
                  style: syne(sz: 12, w: FontWeight.w800, c: Colors.black),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
