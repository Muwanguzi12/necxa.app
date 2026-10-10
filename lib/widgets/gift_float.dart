import 'package:flutter/material.dart';
import 'dart:ui';
import '../app_state.dart';
import '../screens/community/gift_container.dart';

class GiftFloat extends StatefulWidget {
  final AppState state;
  const GiftFloat({super.key, required this.state});

  @override
  State<GiftFloat> createState() => _GiftFloatState();
}

class _GiftFloatState extends State<GiftFloat> with SingleTickerProviderStateMixin {
  bool _dismissing = false;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  )..forward();

  late final Animation<double> _fade = Tween(begin: 0.0, end: 1.0).animate(
    CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
  );

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    await _ctrl.reverse();
    widget.state.targetProfileId = null;
    widget.state.listingId = null;
    widget.state.giftContextType = null;
    widget.state.showGiftFloat = false;
    widget.state.notify();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            // Backdrop
            GestureDetector(
              onTap: _dismiss,
              child: FadeTransition(
                opacity: _fade,
                child: Container(
                  color: Colors.black.withOpacity(0.6),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(color: Colors.transparent),
                  ),
                ),
              ),
            ),
            
            // Sliding Container
            Align(
              alignment: Alignment.bottomCenter,
              child: SlideTransition(
                position: _slide,
                child: GiftContainer(
                  state: widget.state,
                  receiverId: widget.state.targetProfileId ?? '',
                  postId: widget.state.listingId,
                  contextType: widget.state.giftContextType ?? (widget.state.listingId != null ? 'listing' : 'creator_post'),
                  onDismiss: _dismiss,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
