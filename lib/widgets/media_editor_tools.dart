import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/edit_models.dart';
import '../theme.dart';

/// UI for the video trimming tool.
class TrimTool extends StatefulWidget {
  final VideoPlayerController controller;
  final TrimOperation trimOperation;
  final Function(Duration start, Duration end) onTrimChanged;

  const TrimTool({
    super.key,
    required this.controller,
    required this.trimOperation,
    required this.onTrimChanged,
  });

  @override
  State<TrimTool> createState() => _TrimToolState();
}

class _TrimToolState extends State<TrimTool> {
  // In a real app, this would be a proper video trimmer UI package.
  // For this example, we use a RangeSlider to simulate it.
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 80,
      color: const Color(0xFF1A1A1A),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Visual representation of video frames (placeholder)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Row(
              children: List.generate(15, (index) {
                return Expanded(
                  child: Container(
                    height: 40,
                    margin: const EdgeInsets.symmetric(horizontal: 1.0),
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(2),
                    ),
                    // In a real app, you'd use a package like video_thumbnail
                    // to generate and display actual frames from the video.
                    child: const Icon(Icons.movie, color: Colors.black26, size: 16),
                  ),
                );
              }),
            ),
          ),
          // 2. The interactive RangeSlider for trimming
          RangeSlider(
            values: RangeValues(
              widget.trimOperation.start.inMilliseconds.toDouble(),
              widget.trimOperation.end.inMilliseconds.toDouble(),
            ),
            min: 0,
            max: widget.trimOperation.maxDuration.inMilliseconds.toDouble(),
            activeColor: C.brand.withAlpha(128), // Make it semi-transparent
            inactiveColor: Colors.transparent, // Hide the inactive track
            onChanged: (values) => widget.onTrimChanged(
                Duration(milliseconds: values.start.round()), Duration(milliseconds: values.end.round())),
          ),
        ],
      ),
    );
  }
}

// Placeholder widgets for other tools
class TextTool extends StatelessWidget {
  const TextTool({super.key});
  @override
  Widget build(BuildContext context) {
    // A horizontally scrollable toolbar for text editing options.
    return Container(
      height: 80,
      color: const Color(0xFF1A1A1A),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: const [
          _ToolButton(icon: Icons.font_download, label: 'Font'),
          _ToolButton(icon: Icons.format_size, label: 'Size'),
          _ToolButton(icon: Icons.color_lens, label: 'Color'),
          _ToolButton(icon: Icons.text_snippet, label: 'Format'),
          _ToolButton(icon: Icons.animation, label: 'Animation'),
          _ToolButton(icon: Icons.layers, label: 'Stroke'),
          _ToolButton(icon: Icons.space_bar, label: 'Spacing'),
          _ToolButton(icon: Icons.delete, label: 'Delete', color: C.red),
        ],
      ),
    );
  }
}

class FilterTool extends StatelessWidget {
  final String activeFilter;
  final ValueChanged<String> onFilterSelected;

  const FilterTool({
    super.key,
    required this.activeFilter,
    required this.onFilterSelected,
  });
  @override
  Widget build(BuildContext context) {
    // A list of common filter names for demonstration.
    const filters = ['None', 'Sepia', 'Grayscale', 'Vintage', 'Chrome', 'Fade', 'Cold', 'Warm', 'Vivid'];

    return Container(
      height: 80,
      color: const Color(0xFF1A1A1A),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: filters.length,
        itemBuilder: (context, index) {
          final filterName = filters[index];
          final bool isActive = filterName == activeFilter;
          // In a real app, this would be a thumbnail with the filter applied.
          return GestureDetector(
            onTap: () => onFilterSelected(filterName),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                        color: Colors.grey[800],
                        border: Border.all(color: isActive ? C.brand : Colors.white30, width: isActive ? 2.0 : 1.0),
                        borderRadius: BorderRadius.circular(4)),
                    child: const Icon(Icons.videocam, color: Colors.white54, size: 24),
                  ),
                  const SizedBox(height: 6),
                  Text(filterName, style: dm(sz: 10, c: isActive ? C.brand : Colors.white70)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A reusable button for context toolbars.
class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  const _ToolButton({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color ?? Colors.white, size: 28),
          const SizedBox(height: 4),
          Text(label, style: dm(sz: 10, c: color ?? Colors.white70)),
        ],
      ),
    );
  }
}