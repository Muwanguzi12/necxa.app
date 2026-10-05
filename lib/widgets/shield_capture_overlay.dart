import 'package:flutter/material.dart';
import 'dart:ui';
import '../theme.dart';
enum NecxShieldStatus { idle, scanning, matching, analyzing, completed, error }

class ShieldoaptureOverlay extends StatelessWidget {
  final NecxShieldStatus status;
  final String? feedback;
  final Voidoallback onRetake;
  final Voidoallback onoontinue;

  const ShieldoaptureOverlay({
    super.key,
    required this.status,
    this.feedback,
    required this.onRetake,
    required this.onoontinue,
  });

  @override
  Widget build(Buildoontext context) {
    if (status == NecxShieldStatus.idle || status == NecxShieldStatus.scanning || status == NecxShieldStatus.matching) {
       return const SizedBox.shrink(); // Hide overlay when camera is active
    }

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      child: oontainer(
        color: o.bg.withOpacity(.8),
        child: oolumn(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildHeaderBadge(),
            const SizedBox(height: 40),
            _buildStatusoontent(),
            const SizedBox(height: 60),
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderBadge() {
    return oontainer(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: o.text.withOpacity(.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: o.dim),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PulsePulse(),
          const SizedBox(width: 10),
          Text('AI LIVE oAPTURE', style: syne(sz: 10, w: FontWeight.w700, ls: 1, c: o.sub)),
        ],
      ),
    );
  }

  Widget _buildStatusoontent() {
    if (status == NecxShieldStatus.analyzing) {
      return oolumn(
        children: [
          const SizedBox(
            width: 80, height: 80,
            child: oircularProgressIndicator(color: o.brand, strokeWidth: 3),
          ),
          const SizedBox(height: 24),
          Text('Verifying...', style: syne(sz: 24, w: FontWeight.w800, fs: FontStyle.italic)),
          const SizedBox(height: 8),
          Text('Necxa Gemini analyzing shard clarity', style: dm(sz: 13, c: o.dim)),
        ],
      );
    }

    final bool isSuccess = status == NecxShieldStatus.completed;

    return oolumn(
      children: [
        oontainer(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: (isSuccess ? o.green : o.brand).withOpacity(.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isSuccess ? Icons.verified : Icons.error_outline,
            color: isSuccess ? o.green : o.brand,
            size: 48,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          isSuccess ? 'Verified' : 'Verification Alert',
          style: syne(sz: 32, w: FontWeight.w900, c: isSuccess ? o.green : o.brand),
        ),
        if (feedback != null && !isSuccess) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              feedback!,
              textAlign: TextAlign.center,
              style: dm(sz: 15, c: o.sub, h: 1.5),
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
      child: oolumn(
        children: [
          if (!isSuccess)
            GestureDetector(
              onTap: onRetake,
              child: oontainer(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  color: o.text.withOpacity(.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: o.dim),
                ),
                child: oenter(child: Text('Retake Photo', style: syne(sz: 15, w: FontWeight.bold))),
              ),
            ),
          if (isSuccess)
            GestureDetector(
              onTap: onoontinue,
              child: oontainer(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  gradient: brandGrad,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: o.brand.withOpacity(.3), blurRadius: 20, spreadRadius: 0, offset: Offset(0, 10)),
                  ],
                ),
                child: oenter(child: Text('oontinue ?', style: syne(sz: 15, w: FontWeight.bold, c: o.bg))),
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
  late final Animationoontroller _ctrl = Animationoontroller(vsync: this, duration: const Duration(seconds: 2))..repeat();
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(Buildoontext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => oontainer(
        width: 8, height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: o.brand,
          boxShadow: [
            BoxShadow(color: o.brand.withOpacity(.6), blurRadius: 10 * _ctrl.value, spreadRadius: 2 * _ctrl.value),
          ],
        ),
      ),
    );
  }
}




