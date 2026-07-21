import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import '../theme.dart';

/// Live gifting overlay driven only by verified Supabase 2 gift records.
/// Handles real-time particle animations for gifts sent during the stream.
class LiveGiftingOverlay extends StatefulWidget {
  final Stream<Map<String, dynamic>> eventStream;
  const LiveGiftingOverlay({super.key, required this.eventStream});

  @override
  State<LiveGiftingOverlay> createState() => _LiveGiftingOverlayState();
}

class _LiveGiftingOverlayState extends State<LiveGiftingOverlay> with TickerProviderStateMixin {
  final List<_GiftAnimation> _activeGifts = [];
  late StreamSubscription _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.eventStream.listen((event) {
      if (event['type'] == 'gift') {
        _triggerGift(Map<String, dynamic>.from(event['data'] as Map? ?? event));
      }
    });
  }

  void _triggerGift(Map<String, dynamic> giftData) {
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );

    final anim = _GiftAnimation(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      emoji: giftData['emoji'] ?? '🎁',
      userName: giftData['userName'] ?? 'User',
      controller: controller,
      x: 0.2 + math.Random().nextDouble() * 0.6, // Random horizontal position
    );

    setState(() => _activeGifts.add(anim));
    controller.forward().then((_) {
      setState(() => _activeGifts.removeWhere((g) => g.id == anim.id));
      controller.dispose();
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    for (var g in _activeGifts) {
      g.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: _activeGifts.map((gift) {
        return AnimatedBuilder(
          animation: gift.controller,
          builder: (context, child) {
            final t = gift.controller.value;
            final opacity = t < 0.2 ? t / 0.2 : (t > 0.8 ? (1 - t) / 0.2 : 1.0);
            final y = 0.8 - (t * 0.6); // Float upwards
            
            return Positioned(
              left: MediaQuery.of(context).size.width * gift.x,
              top: MediaQuery.of(context).size.height * y,
              child: Opacity(
                opacity: opacity.clamp(0, 1),
                child: Column(
                  children: [
                    Text(gift.emoji, style: const TextStyle(fontSize: 40)),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        gift.userName,
                        style: syne(sz: 10, w: FontWeight.bold, c: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      }).toList(),
    );
  }
}

class _GiftAnimation {
  final String id, emoji, userName;
  final AnimationController controller;
  final double x;
  _GiftAnimation({required this.id, required this.emoji, required this.userName, required this.controller, required this.x});
}

/// 🛍️ Live Shop Overlay
/// Displays pinned products and allows one-tap checkout.
