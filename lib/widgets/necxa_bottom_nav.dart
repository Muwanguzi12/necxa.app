import 'package:flutter/material.dart';
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
          _BotBtn('🏠', 'Property', state.screen == 'home', () => state.go('home')),
          _BotBtn('⚡', 'Community', state.screen == 'community', () => state.go('community')),
          _BotBtn('📋', 'Listings', state.screen == 'list' || state.screen == 'property_listing', () => state.go('list')),
          _BotBtn('💬', 'Chat', state.screen == 'chat' || state.screen == 'chat-list' || state.screen == 'new-chat', () => state.go('chat')),
        ],
      ),
    );
  }
}

class _BotBtn extends StatelessWidget {
  final String icon, label;
  final bool active;
  final VoidCallback onTap;
  const _BotBtn(this.icon, this.label, this.active, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 22)),
          const SizedBox(height: 3),
          Text(label,
              style: dm(sz: 9, w: FontWeight.w600,
                  c: active ? C.brand : C.dim)),
        ],
      ),
    );
  }
}
