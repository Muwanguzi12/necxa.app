import 'package:flutter/material.dart';
import '../theme.dart';

// ══════════════════════════════════════════════════════════════
// MOBILE EDITOR PANELS
// ══════════════════════════════════════════════════════════════
// Reusable panel components for mobile media editor.

// ────────────────────────────────────────────────────────────
// TEXT EDITING PANEL
// ────────────────────────────────────────────────────────────
class TextEditingPanel extends StatefulWidget {
  final Function(String) onTextChanged;
  final String initialText;
  final VoidCallback onClose;
  
  const TextEditingPanel({
    super.key,
    required this.onTextChanged,
    required this.initialText,
    required this.onClose,
  });
  
  @override
  State<TextEditingPanel> createState() => _TextEditingPanelState();
}

class _TextEditingPanelState extends State<TextEditingPanel> {
  late TextEditingController _textController;
  double _fontSize = 24;
  Color _textColor = Colors.white;
  String _fontFamily = 'Syne';
  TextAlign _alignment = TextAlign.center;
  
  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText);
  }
  
  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Text Editor', style: syne(sz: 14, w: FontWeight.w800)),
              GestureDetector(
                onTap: widget.onClose,
                child: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // Text Input
          TextField(
            controller: _textController,
            textAlign: _alignment,
            style: TextStyle(
              fontSize: _fontSize,
              color: _textColor,
              fontFamily: _fontFamily,
            ),
            maxLines: 3,
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              hintText: 'Enter text...',
              contentPadding: const EdgeInsets.all(12),
            ),
            onChanged: widget.onTextChanged,
          ),
          const SizedBox(height: 12),
          
          // Font Size Slider
          _buildSliderControl('Size', _fontSize, 12, 64, (value) {
            setState(() => _fontSize = value);
          }),
          
          // Font Family Selector
          _buildFontSelector(),
          
          // Text Alignment
          _buildAlignmentButtons(),
          
          // Color Picker
          _buildColorControl('Color', _textColor, (color) {
            setState(() => _textColor = color);
          }),
          
          // Shadow Toggle
          _buildToggleControl('Shadow', false, (value) {}),
          
          // Stroke Toggle
          _buildToggleControl('Stroke', false, (value) {}),
        ],
      ),
    );
  }
  
  Widget _buildSliderControl(
    String label,
    double value,
    double min,
    double max,
    Function(double) onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: dm(sz: 11, w: FontWeight.w600)),
            Text(value.toStringAsFixed(0), style: dm(sz: 11, c: C.brand)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          onChanged: onChanged,
          activeColor: C.brand,
        ),
      ],
    );
  }
  
  Widget _buildFontSelector() {
    final fonts = ['Syne', 'DM Sans', 'Roboto', 'Georgia', 'Comic Sans'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Font', style: dm(sz: 11, w: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: fonts.map((font) {
            final isSelected = font == _fontFamily;
            return Material(
              color: isSelected ? C.brand : C.surface,
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                onTap: () => setState(() => _fontFamily = font),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(
                    font,
                    style: TextStyle(
                      fontSize: 11,
                      color: isSelected ? Colors.white : C.text,
                      fontFamily: font,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
  
  Widget _buildAlignmentButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Align', style: dm(sz: 11, w: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildAlignButton(Icons.format_align_left, TextAlign.left),
            const SizedBox(width: 8),
            _buildAlignButton(Icons.format_align_center, TextAlign.center),
            const SizedBox(width: 8),
            _buildAlignButton(Icons.format_align_right, TextAlign.right),
          ],
        ),
      ],
    );
  }
  
  Widget _buildAlignButton(IconData icon, TextAlign align) {
    final isSelected = align == _alignment;
    return Material(
      color: isSelected ? C.brand : C.surface,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () => setState(() => _alignment = align),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            icon,
            size: 18,
            color: isSelected ? Colors.white : C.dim,
          ),
        ),
      ),
    );
  }
  
  Widget _buildColorControl(String label, Color color, Function(Color) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: dm(sz: 11, w: FontWeight.w600)),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () {
            // Show color picker
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Color picker')),
            );
          },
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: C.border),
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildToggleControl(String label, bool value, Function(bool) onChanged) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: dm(sz: 11, w: FontWeight.w600)),
        Switch(
          value: value,
          onChanged: onChanged,
          activeColor: C.brand,
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────
// AUDIO EDITING PANEL
// ────────────────────────────────────────────────────────────
class AudioEditingPanel extends StatefulWidget {
  final VoidCallback onClose;
  
  const AudioEditingPanel({
    super.key,
    required this.onClose,
  });
  
  @override
  State<AudioEditingPanel> createState() => _AudioEditingPanelState();
}

class _AudioEditingPanelState extends State<AudioEditingPanel> {
  double _volume = 1.0;
  double _treble = 0.5;
  double _bass = 0.5;
  bool _fadeIn = false;
  bool _fadeOut = false;
  double _speed = 1.0;
  
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Audio Editor', style: syne(sz: 14, w: FontWeight.w800)),
              GestureDetector(
                onTap: widget.onClose,
                child: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // Volume
          _buildAudioSlider('🔊 Volume', _volume, 0, 2, (value) {
            setState(() => _volume = value);
          }),
          
          // Speed
          _buildAudioSlider('⚡ Speed', _speed, 0.5, 2, (value) {
            setState(() => _speed = value);
          }),
          
          // Bass
          _buildAudioSlider('🔉 Bass', _bass, 0, 1, (value) {
            setState(() => _bass = value);
          }),
          
          // Treble
          _buildAudioSlider('🔈 Treble', _treble, 0, 1, (value) {
            setState(() => _treble = value);
          }),
          
          const SizedBox(height: 12),
          
          // Fade In/Out
          Row(
            children: [
              Expanded(
                child: _buildToggleButton('Fade In', _fadeIn, (value) {
                  setState(() => _fadeIn = value);
                }),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildToggleButton('Fade Out', _fadeOut, (value) {
                  setState(() => _fadeOut = value);
                }),
              ),
            ],
          ),
          
          const SizedBox(height: 12),
          
          // Noise Removal
          Material(
            color: C.surface,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Applying noise removal...')),
              ),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Noise Removal', style: dm(sz: 12, w: FontWeight.w600)),
                    const Icon(Icons.tune, size: 20),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildAudioSlider(String label, double value, double min, double max, Function(double) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: dm(sz: 11, w: FontWeight.w600)),
            Text('${(value * 100).toStringAsFixed(0)}%', style: dm(sz: 11, c: C.brand, w: FontWeight.w600)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          onChanged: onChanged,
          activeColor: C.brand,
        ),
      ],
    );
  }
  
  Widget _buildToggleButton(String label, bool value, Function(bool) onChanged) {
    return Material(
      color: value ? C.brand : C.surface,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: dm(
              sz: 12,
              w: FontWeight.w600,
              c: value ? Colors.white : C.text,
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// EFFECTS PANEL
// ────────────────────────────────────────────────────────────
class EffectsPanel extends StatefulWidget {
  final VoidCallback onClose;
  
  const EffectsPanel({
    super.key,
    required this.onClose,
  });
  
  @override
  State<EffectsPanel> createState() => _EffectsPanelState();
}

class _EffectsPanelState extends State<EffectsPanel> {
  final effects = [
    ('Blur', '🌫️'),
    ('Brighten', '☀️'),
    ('Contrast', '⚫'),
    ('Grayscale', '⚪'),
    ('Sepia', '🟤'),
    ('Vintage', '📼'),
    ('Neon', '💡'),
    ('Glitch', '📡'),
  ];
  
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Effects', style: syne(sz: 14, w: FontWeight.w800)),
              GestureDetector(
                onTap: widget.onClose,
                child: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: effects.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemBuilder: (context, index) {
              final effect = effects[index];
              return Material(
                color: C.surface,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Applied ${effect.$1}')),
                  ),
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(effect.$2, style: const TextStyle(fontSize: 28)),
                      const SizedBox(height: 4),
                      Text(effect.$1, style: dm(sz: 10, w: FontWeight.w600)),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// TRANSITIONS PANEL
// ────────────────────────────────────────────────────────────
class TransitionsPanel extends StatefulWidget {
  final VoidCallback onClose;
  
  const TransitionsPanel({
    super.key,
    required this.onClose,
  });
  
  @override
  State<TransitionsPanel> createState() => _TransitionsPanelState();
}

class _TransitionsPanelState extends State<TransitionsPanel> {
  final transitions = [
    ('Fade', '⬜'),
    ('Slide', '▶️'),
    ('Zoom', '🔍'),
    ('Rotate', '🔄'),
    ('Wipe', '🧹'),
    ('Blur', '🌫️'),
    ('Bounce', '⛹️'),
    ('Flip', '🪞'),
  ];
  
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Transitions', style: syne(sz: 14, w: FontWeight.w800)),
              GestureDetector(
                onTap: widget.onClose,
                child: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: transitions.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemBuilder: (context, index) {
              final transition = transitions[index];
              return Material(
                color: C.surface,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Added ${transition.$1} transition')),
                  ),
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(transition.$2, style: const TextStyle(fontSize: 28)),
                      const SizedBox(height: 4),
                      Text(transition.$1, style: dm(sz: 10, w: FontWeight.w600)),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
