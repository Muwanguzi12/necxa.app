import 'package:flutter/material.dart';
import '../app_state.dart';
import '../theme.dart';

/// A globally synchronized Follow / Friends / Following button.
/// Automatically listens to [AppState] and updates in real-time when the
/// user follows, unfollows, or reciprocates friendship anywhere in the app.
class FollowSyncButton extends StatefulWidget {
  final AppState state;
  final String targetUserId;
  final bool compact;
  final bool isFollowBackContext;
  final VoidCallback? onToggled;

  const FollowSyncButton({
    super.key,
    required this.state,
    required this.targetUserId,
    this.compact = false,
    this.isFollowBackContext = false,
    this.onToggled,
  });

  @override
  State<FollowSyncButton> createState() => _FollowSyncButtonState();
}

class _FollowSyncButtonState extends State<FollowSyncButton> {
  bool _loading = false;

  Future<void> _handleTap() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await widget.state.toggleFollow(widget.targetUserId);
      widget.onToggled?.call();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final currentUserId = widget.state.user?.id;
        if (widget.targetUserId.isEmpty || widget.targetUserId == currentUserId) {
          return const SizedBox.shrink();
        }

        final isFriend = widget.state.isFriendSync(widget.targetUserId);
        final isFollowing = widget.state.isFollowingSync(widget.targetUserId);

        if (widget.compact) {
          return _buildCompact(isFriend, isFollowing);
        }
        return _buildFull(isFriend, isFollowing);
      },
    );
  }

  Widget _buildCompact(bool isFriend, bool isFollowing) {
    final Color tintColor = isFriend
        ? const Color(0xFF00E5FF)
        : (isFollowing ? Colors.white70 : Colors.black);

    final BoxDecoration decoration = isFriend
        ? BoxDecoration(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: const Color(0xFF00E5FF).withValues(alpha: 0.4),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.2),
                blurRadius: 6,
              ),
            ],
          )
        : (isFollowing
            ? BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.2),
                  width: 1.0,
                ),
              )
            : BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00E5FF), Color(0xFF00B2CC)],
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                    blurRadius: 8,
                  ),
                ],
              ));

    final IconData icon = isFriend
        ? Icons.people_alt_rounded
        : (isFollowing ? Icons.check_rounded : Icons.person_add_alt_1_rounded);

    final String label = isFriend
        ? 'FRIENDS'
        : (isFollowing
            ? 'FOLLOWING'
            : (widget.isFollowBackContext ? 'FOLLOW BACK' : 'FOLLOW'));

    return GestureDetector(
      onTap: _loading ? null : _handleTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
        decoration: decoration,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading)
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: tintColor,
                ),
              )
            else
              Icon(icon, size: 12, color: tintColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: syne(
                sz: 9.5,
                w: FontWeight.w800,
                c: tintColor,
                ls: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFull(bool isFriend, bool isFollowing) {
    final Color tintColor = isFriend
        ? const Color(0xFF00E5FF)
        : (isFollowing ? Colors.white70 : Colors.black);

    final BoxDecoration decoration = isFriend
        ? BoxDecoration(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: const Color(0xFF00E5FF).withValues(alpha: 0.45),
              width: 1.3,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.25),
                blurRadius: 10,
              ),
            ],
          )
        : (isFollowing
            ? BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.22),
                  width: 1.1,
                ),
              )
            : BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00E5FF), Color(0xFF00B2CC)],
                ),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ));

    final IconData icon = isFriend
        ? Icons.people_alt_rounded
        : (isFollowing ? Icons.check_rounded : Icons.person_add_alt_1_rounded);

    final String label = isFriend
        ? 'Friends'
        : (isFollowing
            ? 'Following'
            : (widget.isFollowBackContext ? 'Follow Back' : 'Follow'));

    return GestureDetector(
      onTap: _loading ? null : _handleTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: decoration,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading)
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: tintColor,
                ),
              )
            else
              Icon(icon, size: 14, color: tintColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: syne(
                sz: 11.5,
                w: FontWeight.w800,
                c: tintColor,
                ls: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
