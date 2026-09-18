import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../theme.dart';
import '../app_state.dart';

class NecxaBottomNav extends StatelessWidget {
  final AppState state;
  const NecxaBottomNav({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        border: Border(top: BorderSide(color: C.border)),
      ),
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _BotBtn(
            '🏠',
            'Property',
            state.screen == 'home',
            () => state.go('home'),
          ),
          _BotBtn(
            Opacity(
              opacity: state.screen == 'community' ? 1.0 : 0.5,
              child: Image.asset(
                'assets/images/community_icon_colored.png', 
                width: 24, 
                height: 24,
              ),
            ),
            'Community',
            state.screen == 'community',
            () => state.go('community'),
          ),
          _BotBtn(
            '📋',
            'Listings',
            state.screen == 'list' || state.screen == 'property_listing',
            () => state.go('list'),
          ),
          if (!kIsWeb)
            _BotBtn(
              '💬',
              'Chat',
              state.screen == 'chat' ||
                  state.screen == 'chat-list' ||
                  state.screen == 'new-chat',
              () => state.go('chat'),
            ),
        ],
      ),
    );
  }
}

class _BotBtn extends StatelessWidget {
  final Object icon; // String or Widget
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _BotBtn(this.icon, this.label, this.active, this.onTap);

  @override
  Widget build(BuildContext context) {
    final Widget iconWidget = icon is Widget 
        ? (icon as Widget) 
        : Text(icon.toString(), style: const TextStyle(fontSize: 22));
        
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconWidget,
          const SizedBox(height: 3),
          Text(
            label,
            style: dm(sz: 9, w: FontWeight.w600, c: active ? C.brand : C.dim),
          ),
        ],
      ),
    );
  }
}
