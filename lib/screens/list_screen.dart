import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';

class ListScreen extends StatelessWidget {
  final AppState state;
  const ListScreen({super.key, required this.state});

  static const _steps = [
    'National ID',
    'Face ID',
    'Details',
    'Photos',
    'GPS',
    'Review',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildNav(),
        _buildProgress(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
            child: _buildStep(),
          ),
        ),
      ],
    );
  }

  Widget _buildNav() {
    return Container(
      color: C.card,
      padding: const EdgeInsets.fromLTRB(18, 52, 18, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => state.go('home'),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: C.border,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text('←', style: TextStyle(color: C.text, fontSize: 18)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('List Your Property', style: syne(sz: 15)),
                Text(
                  'Step ${state.listStep + 1}/${_steps.length}: ${_steps[state.listStep]}',
                  style: dm(sz: 10, c: C.dim),
                ),
              ],
            ),
          ),
          const NecxaLogo(size: 32, shadow: false),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      child: Row(
        children: List.generate(_steps.length, (i) {
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 4,
              margin: EdgeInsets.only(right: i < _steps.length - 1 ? 4 : 0),
              decoration: BoxDecoration(
                color: i <= state.listStep ? C.gold : C.border,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildStep() {
    switch (state.listStep) {
      case 0:
        return _buildIdStep();
      case 1:
        return _buildFaceStep();
      case 2:
        return _buildDetailsStep();
      case 3:
        return _buildPhotosStep();
      case 4:
        return _buildGpsStep();
      case 5:
        return _buildReviewStep();
      default:
        return const SizedBox();
    }
  }

  // ── Step 0: National ID ──────────────────────────────────────
  Widget _buildIdStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('National ID Scan', style: syne(sz: 22)),
        const SizedBox(height: 6),
        Text(
          'NECXA requires Uganda National ID verification for all agents. Your data is encrypted.',
          style: dm(sz: 12, c: C.dim, h: 1.6),
        ),
        const SizedBox(height: 20),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          height: 210,
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: state.idVerified ? C.green.withOpacity(.25) : C.border,
            ),
          ),
          child: Stack(
            children: [
              if (state.idScanning) const _ScanLine(color: C.green),
              Center(child: _buildIdContent()),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (!state.idVerified)
          _PrimaryBtn(
            label: state.idScanning
                ? null
                : state.idDone
                ? null
                : '📸 Scan National ID',
            loading: state.idScanning || state.idDone,
            loadingLabel: state.aiChecking
                ? 'AI verifying identity...'
                : state.idScanning
                ? 'Scanning ID document...'
                : 'Cross-checking NIRA database...',
            onTap: state.idScanning || state.idDone
                ? null
                : () => state.doIdScan('Uganda', 'National ID'),
          )
        else
          _SuccessBtn(label: 'Next: Face ID →', onTap: state.nextStep),
      ],
    );
  }

  Widget _buildIdContent() {
    if (state.idVerified) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('✅', style: TextStyle(fontSize: 54)),
          const SizedBox(height: 8),
          Text('ID Verified!', style: syne(sz: 16, c: C.green)),
          const SizedBox(height: 4),
          Text('Nakato Sarah · NIN: CM123456ABCD', style: dm(sz: 11, c: C.dim)),
        ],
      );
    } else if (state.aiChecking) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SpinningEmoji('🤖', size: 40),
          const SizedBox(height: 8),
          Text('AI verifying identity...', style: dm(sz: 13, c: C.gold)),
        ],
      );
    } else if (state.idDone) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('⏳', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 8),
          Text('Cross-checking NIRA database...', style: dm(sz: 13, c: C.gold)),
        ],
      );
    } else if (state.idScanning) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PulsingText('📷', size: 40),
          const SizedBox(height: 8),
          Text('Scanning ID document...', style: dm(sz: 13, c: C.gold)),
        ],
      );
    } else {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🪪', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 8),
          Text(
            'Position your Uganda National ID here',
            style: dm(sz: 13, c: C.dim),
          ),
        ],
      );
    }
  }

  // ── Step 1: Face ID ──────────────────────────────────────────
  Widget _buildFaceStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Face ID Verification', style: syne(sz: 22)),
        const SizedBox(height: 6),
        Text(
          'Take a live selfie. AI biometrics will match your face against your National ID photo.',
          style: dm(sz: 12, c: C.dim, h: 1.6),
        ),
        const SizedBox(height: 20),
        Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              color: state.faceDone ? const Color(0xFF0d1f14) : C.card,
              shape: BoxShape.circle,
              border: Border.all(
                color: state.faceDone ? C.green.withOpacity(.25) : C.border,
                width: 1,
              ),
            ),
            child: Stack(
              children: [
                if (state.faceScanning)
                  const ClipOval(
                    child: _ScanLine(color: C.gold, width: double.infinity),
                  ),
                Center(
                  child: state.faceDone
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('😊', style: TextStyle(fontSize: 64)),
                            Text(
                              '✓ Face Matched!',
                              style: dm(sz: 12, c: C.green, w: FontWeight.w700),
                            ),
                          ],
                        )
                      : state.faceScanning
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _PulsingText('📷', size: 64),
                            Text(
                              'Scanning face...',
                              style: dm(sz: 10, c: C.gold),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('🤳', style: TextStyle(fontSize: 64)),
                            Text(
                              'Position your face',
                              style: dm(sz: 10, c: C.dim),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (!state.faceDone)
          _PrimaryBtn(
            label: state.faceScanning ? null : '🤳 Take Selfie',
            loading: state.faceScanning,
            loadingLabel: 'Scanning face...',
            onTap: state.faceScanning ? null : () => state.doFaceScan(),
          )
        else
          _SuccessBtn(label: 'Next: Property Details →', onTap: state.nextStep),
      ],
    );
  }

  // ── Step 2: Details ──────────────────────────────────────────
  Widget _buildDetailsStep() {
    const fields = [
      ('Property Title', 'text', 'title'),
      ('Monthly Price (UGX)', 'number', 'price'),
      ('City / District', 'text', 'city'),
      ('Bedrooms', 'number', 'bedrooms'),
      ('Bathrooms', 'number', 'bathrooms'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Property Details', style: syne(sz: 22)),
        const SizedBox(height: 20),
        ...fields.map(
          (f) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                f.$1,
                style: dm(sz: 11, c: C.dim, w: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              TextField(
                keyboardType: f.$2 == 'number'
                    ? TextInputType.number
                    : TextInputType.text,
                onChanged: (value) {
                  final parsed = f.$2 == 'number'
                      ? num.tryParse(value) ?? 0
                      : value.trim();
                  state.updateListingDraft(f.$3, parsed);
                  if (f.$3 == 'city') {
                    state.updateListingDraft('district', value.trim());
                  }
                },
                style: dm(sz: 13),
                decoration: InputDecoration(
                  hintText: 'Enter ${f.$1}...',
                  hintStyle: dm(sz: 13, c: C.dim),
                  filled: true,
                  fillColor: C.border,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: C.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: C.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: C.gold),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
        Text(
          'Description',
          style: dm(sz: 11, c: C.dim, w: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        TextField(
          maxLines: 3,
          onChanged: (value) =>
              state.updateListingDraft('description', value.trim()),
          style: dm(sz: 13),
          decoration: InputDecoration(
            hintText: 'Describe the property...',
            hintStyle: dm(sz: 13, c: C.dim),
            filled: true,
            fillColor: C.border,
            contentPadding: const EdgeInsets.all(14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: C.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: C.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: C.gold),
            ),
          ),
        ),
        const SizedBox(height: 18),
        _PrimaryBtn(label: 'Next: Photos & Docs →', onTap: state.nextStep),
      ],
    );
  }

  // ── Step 3: Photos ───────────────────────────────────────────
  Widget _buildPhotosStep() {
    final docs = [
      ('🏠', 'Exterior Photos (min 3)', 'Required'),
      ('🛋️', 'Interior Photos (min 4)', 'Required'),
      ('📄', 'Title Deed / Land Certificate', 'Required'),
      ('📋', 'Other Ownership Documents', 'Optional'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Photos & Documents', style: syne(sz: 22)),
        const SizedBox(height: 6),
        Text(
          'AI will cross-verify photos match GPS location. All docs are encrypted and securely stored.',
          style: dm(sz: 12, c: C.dim, h: 1.6),
        ),
        const SizedBox(height: 20),
        ...docs.map(
          (d) => Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: C.border.withOpacity(.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: C.border, style: BorderStyle.solid),
            ),
            child: Row(
              children: [
                Text(d.$1, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.$2, style: dm(sz: 13, w: FontWeight.w600)),
                      Text(
                        '${d.$3} · Tap to capture',
                        style: dm(
                          sz: 10,
                          c: d.$3 == 'Required' ? C.gold : C.dim,
                        ),
                      ),
                    ],
                  ),
                ),
                Text('📷', style: TextStyle(fontSize: 22, color: C.dim)),
              ],
            ),
          ),
        ),
        if (state.pickedMedia != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.file(
              state.pickedMedia!,
              height: 180,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 10),
        ],
        _PrimaryBtn(
          label: state.pickedMedia == null
              ? 'Add Exterior Verification Photo'
              : 'Replace Exterior Verification Photo',
          onTap: state.pickMedia,
        ),
        const SizedBox(height: 6),
        _PrimaryBtn(label: 'Next: GPS Location →', onTap: state.nextStep),
      ],
    );
  }

  // ── Step 4: GPS ──────────────────────────────────────────────
  Widget _buildGpsStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('GPS Location', style: syne(sz: 22)),
        const SizedBox(height: 6),
        Text(
          'You must be physically at the property. NECXA captures GPS to prevent fraudulent listings.',
          style: dm(sz: 12, c: C.dim, h: 1.6),
        ),
        const SizedBox(height: 20),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          height: 180,
          decoration: BoxDecoration(
            color: state.gpsDone ? const Color(0xFF0d1f14) : C.card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: state.gpsDone ? C.green.withOpacity(.25) : C.border,
            ),
          ),
          child: Center(
            child: state.gpsDone
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('📍', style: TextStyle(fontSize: 50)),
                      const SizedBox(height: 8),
                      Text('GPS Captured!', style: syne(sz: 14, c: C.green)),
                      const SizedBox(height: 4),
                      Text(
                        '0.3476° N, 32.5825° E · Kololo, Kampala',
                        style: dm(sz: 11, c: C.dim),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _PulsingText('🌐', size: 50),
                      const SizedBox(height: 8),
                      Text(
                        'Stand at the property, then tap capture',
                        style: dm(sz: 13, c: C.dim),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 18),
        if (!state.gpsDone)
          _PrimaryBtn(label: '📍 Capture GPS Now', onTap: state.captureGps)
        else
          _SuccessBtn(label: 'Next: Review & Submit →', onTap: state.nextStep),
      ],
    );
  }

  // ── Step 5: Review ───────────────────────────────────────────
  Widget _buildReviewStep() {
    final items = [
      ('✅', 'National ID', 'Verified — Nakato Sarah'),
      ('✅', 'Face ID Biometrics', 'Matched 97.4% confidence'),
      ('✅', 'Property Photos', '7 photos uploaded'),
      ('✅', 'Legal Documents', 'Title Deed + Land Cert'),
      ('✅', 'GPS Location', '0.3476° N, 32.5825° E'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Review & Submit', style: syne(sz: 22)),
        const SizedBox(height: 6),
        Text(
          'AI will review your listing before it goes live (within 24 hours).',
          style: dm(sz: 12, c: C.dim, h: 1.6),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF0d1f14),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: C.green.withOpacity(.12)),
          ),
          child: Column(
            children: items.map((item) {
              final isLast = item == items.last;
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isLast
                          ? Colors.transparent
                          : C.border.withOpacity(.4),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Text(item.$1, style: const TextStyle(fontSize: 16)),
                    const SizedBox(width: 10),
                    Text(item.$2, style: dm(sz: 12, w: FontWeight.w600)),
                    const Spacer(),
                    Text(
                      item.$3,
                      style: dm(sz: 10, c: C.green, w: FontWeight.w700),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 16),
        if (state.submitted)
          _buildSubmittedSuccess()
        else ...[
          _PrimaryBtn(
            label: state.aiSubmitting ? null : '🚀 Submit for AI Review',
            loading: state.aiSubmitting,
            loadingLabel: 'AI Verifying Listing...',
            onTap: state.aiSubmitting
                ? null
                : () => state.doSubmit(state.listingDraft),
          ),
          if (state.listingVerificationError != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: C.red.withOpacity(.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: C.red.withOpacity(.3)),
              ),
              child: Text(
                state.listingVerificationError!,
                style: dm(sz: 11, c: C.red, h: 1.5),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildSubmittedSuccess() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: C.green.withOpacity(.07),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: C.green.withOpacity(.25)),
          ),
          child: Column(
            children: [
              const Text('🎉', style: TextStyle(fontSize: 52)),
              const SizedBox(height: 10),
              Text('Listing Submitted!', style: syne(sz: 20, c: C.green)),
              const SizedBox(height: 6),
              Text(
                'AI verification in progress. Your listing will be live on NECXA within 24 hours.',
                style: dm(sz: 12, c: C.dim, h: 1.6),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              GestureDetector(
                onTap: () => state.go('home'),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: C.gold,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('← Back to Home', style: syne(sz: 14, c: C.bg)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Shared step widgets ───────────────────────────────────────
class _PrimaryBtn extends StatelessWidget {
  final String? label;
  final bool loading;
  final String? loadingLabel;
  final VoidCallback? onTap;
  const _PrimaryBtn({
    this.label,
    this.loading = false,
    this.loadingLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          gradient: onTap == null ? null : goldGrad,
          color: onTap == null ? C.gold.withOpacity(.4) : null,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: loading
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: C.bg,
                        strokeWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      loadingLabel ?? 'Loading...',
                      style: syne(sz: 15, c: C.bg),
                    ),
                  ],
                )
              : Text(label ?? '', style: syne(sz: 15, c: C.bg)),
        ),
      ),
    );
  }
}

class _SuccessBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SuccessBtn({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          gradient: greenGrad,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Text(label, style: syne(sz: 15, c: Colors.white)),
        ),
      ),
    );
  }
}

// ── Scan line animation ───────────────────────────────────────
class _ScanLine extends StatefulWidget {
  final Color color;
  final double? width;
  const _ScanLine({required this.color, this.width});
  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        return Positioned(
          top: _ctrl.value * 180,
          left: 0,
          right: 0,
          child: Container(
            height: 3,
            width: widget.width,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, widget.color, Colors.transparent],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Pulsing emoji ─────────────────────────────────────────────
class _PulsingText extends StatefulWidget {
  final String text;
  final double size;
  const _PulsingText(this.text, {required this.size});
  @override
  State<_PulsingText> createState() => _PulsingTextState();
}

class _PulsingTextState extends State<_PulsingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 1.0).animate(_ctrl),
      child: Text(widget.text, style: TextStyle(fontSize: widget.size)),
    );
  }
}

// ── Spinning emoji ────────────────────────────────────────────
class _SpinningEmoji extends StatefulWidget {
  final String emoji;
  final double size;
  const _SpinningEmoji(this.emoji, {required this.size});
  @override
  State<_SpinningEmoji> createState() => _SpinningEmojiState();
}

class _SpinningEmojiState extends State<_SpinningEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) =>
          Transform.rotate(angle: _ctrl.value * 6.28, child: child),
      child: Text(widget.emoji, style: TextStyle(fontSize: widget.size)),
    );
  }
}
