import 'package:flutter/material.dart';
import 'dart:ui';
import '../theme.dart';
enum NecxShieldStatus { idle, scanning, matching, analyzing, completed, error }

class ShieldCaptureOverlay extends StatelessWidget {
  final NecxShieldStatus status;
  final String? feedback;
  final VoidCallback onRetake;
  final VoidCallback onContinue;

  const ShieldCaptureOverlay({
    super.key,
    required this.status,
    this.feedback,
    required this.onRetake,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    if (status == NecxShieldStatus.idle || status == NecxShieldStatus.scanning || status == NecxShieldStatus.matching) {
       return const SizedBox.shrink(); // Hide overlay when camera is active
    }

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      child: Container(
        color: C.bg.withOpacity(.8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildHeaderBadge(),
            const SizedBox(height: 40),
            _buildStatusContent(),
            const SizedBox(height: 60),
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: C.text.withOpacity(.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.dim),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PulsePulse(),
          const SizedBox(width: 10),
          Text('AI LIVE CAPTURE', style: syne(sz: 10, w: FontWeight.w700, ls: 1, c: C.sub)),
        ],
      ),
    );
  }

  Widget _buildStatusContent() {
    if (status == NecxShieldStatus.analyzing) {
      return Column(
        children: [
          const SizedBox(
            width: 80, height: 80,
            child: CircularProgressIndicator(color: C.brand, strokeWidth: 3),
          ),
          const SizedBox(height: 24),
          Text('Verifying...', style: syne(sz: 24, w: FontWeight.w800, fs: FontStyle.italic)),
          const SizedBox(height: 8),
          Text('Necxa Gemini analyzing shard clarity', style: dm(sz: 13, c: C.dim)),
        ],
      );
    }

    final bool isSuccess = status == NecxShieldStatus.completed;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: (isSuccess ? C.green : C.brand).withOpacity(.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isSuccess ? Icons.verified : Icons.error_outline,
            color: isSuccess ? C.green : C.brand,
            size: 48,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          isSuccess ? 'Verified' : 'Verification Alert',
          style: syne(sz: 32, w: FontWeight.w900, c: isSuccess ? C.green : C.brand),
        ),
        if (feedback != null && !isSuccess) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              feedback!,
              textAlign: TextAlign.center,
              style: dm(sz: 15, c: C.sub, h: 1.5),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildActionButtons() {
    final bool isSuccess = status == NecxShieldStatus.completed;
    final bool isAnalyzing = status == NecxShieldStatus.analyzing;

    if (isAnalyzing) return const SizedBox(height: 60);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          if (!isSuccess)
            GestureDetector(
              onTap: onRetake,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  color: C.text.withOpacity(.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: C.dim),
                ),
                child: Center(child: Text('Retake Photo', style: syne(sz: 15, w: FontWeight.bold))),
              ),
            ),
          if (isSuccess)
            GestureDetector(
              onTap: onContinue,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  gradient: brandGrad,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: C.brand.withOpacity(.3), blurRadius: 20, spreadRadius: 0, offset: Offset(0, 10)),
                  ],
                ),
                child: Center(child: Text('Continue ?', style: syne(sz: 15, w: FontWeight.bold, c: C.bg))),
              ),
            ),
        ],
      ),
    );
  }
}

class _PulsePulse extends StatefulWidget {
  const _PulsePulse();
  @override
  State<_PulsePulse> createState() => _PulsePulseState();
}

class _PulsePulseState extends State<_PulsePulse> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: C.brand,
          boxShadow: [
            BoxShadow(color: C.brand.withOpacity(.6), blurRadius: 10 * _ctrl.value, spreadRadius: 2 * _ctrl.value),
          ],
        ),
      ),
    );
  }
}


