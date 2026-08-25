// lib/screens/creator_chat_list_screen.dart
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart' show giftNotificationImageUrlFor;
import '../models/chat_models.dart';
import '../models/notification_model.dart';

class CreatorChatListScreen extends StatefulWidget {
  final AppState state;
  const CreatorChatListScreen({super.key, required this.state});

  @override
  State<CreatorChatListScreen> createState() => _CreatorChatListScreenState();
}
class _CreatorChatListScreenState extends State<CreatorChatListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    widget.state.fetchCreatorConversations();
    widget.state.loadNotifications();
    widget.state.refreshNotifications();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, color: C.text),
          onPressed: () => widget.state.goBack(),
        ),
        title: Text(
          'CREATOR SOCIAL',
          style: syne(sz: 18, w: FontWeight.w900, ls: 2),
        ),
        centerTitle: true,
        actions: [
          if (widget.state.unreadNotificationCount > 0)
            IconButton(
              tooltip: 'Mark all notifications as read',
              icon: Icon(Icons.done_all_rounded, color: C.sub),
              onPressed: widget.state.markAllNotificationsAsRead,
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF00E5FF),
          labelColor: const Color(0xFF00E5FF),
          unselectedLabelColor: C.dim,
          labelStyle: syne(sz: 13, w: FontWeight.bold),
          tabs: [
            const Tab(text: 'CHATS'),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('NOTIFICATIONS'),
                  if (widget.state.unreadNotificationCount > 0) ...[
                    const SizedBox(width: 7),
                    Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: C.red,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        widget.state.unreadNotificationCount > 99
                            ? '99+'
                            : '${widget.state.unreadNotificationCount}',
                        textAlign: TextAlign.center,
                        style: dm(sz: 9, c: C.text, w: FontWeight.w800),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildChatList(), _buildNotificationList()],
      ),
    );
  }

  Widget _buildChatList() {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        if (widget.state.isCreatorChatLoading) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFF00E5FF)),
          );
        }

        final convos = widget.state.creatorConversations;
        if (convos.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.forum_outlined,
                  size: 60,
                  color: C.dim,
                ),
                const SizedBox(height: 16),
                Text(
                  'NO CREATOR INTERACTIONS YET',
                  style: syne(sz: 12, c: C.dim, ls: 1),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: convos.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) {
            final room = convos[i];
            return _CreatorChatTile(room: room, state: widget.state);
          },
        );
      },
    );
  }

  Widget _buildNotificationList() {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final notifs = widget.state.appNotifications;
        if (notifs.isEmpty) {
          return RefreshIndicator(
            color: C.brand,
            onRefresh: widget.state.refreshNotifications,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.6,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.notifications_none_rounded,
                          size: 54,
                          color: C.dim,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'ALL CAUGHT UP',
                          style: syne(sz: 12, c: C.dim, ls: 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          color: C.brand,
          onRefresh: widget.state.refreshNotifications,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            itemCount: notifs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final notif = notifs[i];
              return _NotificationTile(notif: notif, state: widget.state);
            },
          ),
        );
      },
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification notif;
  final AppState state;
  const _NotificationTile({required this.notif, required this.state});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color iconColor;
    switch (notif.type) {
      case 'like':
        icon = Icons.favorite_rounded;
        iconColor = C.red;
        break;
      case 'comment':
        icon = Icons.mode_comment_rounded;
        iconColor = C.brand;
        break;
      case 'follow':
        icon = Icons.person_add_alt_1_rounded;
        iconColor = C.blue;
        break;
      case 'share':
        icon = Icons.share_rounded;
        iconColor = C.brand;
        break;
      case 'save':
        icon = Icons.bookmark_rounded;
        iconColor = C.gold;
        break;
      case 'financial':
        icon = Icons.account_balance_wallet_rounded;
        iconColor = C.gold;
        break;
      case 'listing':
        icon = Icons.home_work_rounded;
        iconColor = C.blue;
        break;
      case 'social':
        icon = Icons.favorite_rounded;
        iconColor = C.red;
        break;
      case 'system':
        icon = notif.metadata['interaction_context'] == 'support'
            ? Icons.support_agent_rounded
            : Icons.notifications_active_rounded;
        iconColor = C.green;
        break;
      case 'content':
      default:
        icon = Icons.notifications_active_rounded;
        iconColor = C.brand;
    }

    final giftItemId = notif.metadata['gift_item_id']?.toString();
    final giftImageUrl = giftItemId == null
        ? null
        : giftNotificationImageUrlFor(giftItemId);

    return GestureDetector(
      onTap: () => state.openNotification(notif),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: notif.isRead
              ? C.text.withOpacity(0.02)
              : const Color(0xFF0A0F2C).withOpacity(0.4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: notif.isRead ? Colors.transparent : C.brand.withOpacity(0.2),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _NotificationIdentity(
              // Gift JPEGs are requested only when the notification list is
              // visible. Transactions persist just gift_item_id, not media.
              avatarUrl: giftImageUrl ?? notif.actorAvatar,
              icon: icon,
              color: iconColor,
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          notif.title,
                          style: syne(
                            sz: 14,
                            w: notif.isRead ? FontWeight.w600 : FontWeight.w900,
                          ),
                        ),
                      ),
                      if (!notif.isRead)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: C.brand,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(notif.body, style: dm(sz: 13, c: C.sub)),
                  const SizedBox(height: 8),
                  Text(
                    _relativeTime(notif.createdAt),
                    style: dm(sz: 11, c: C.dim),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _relativeTime(DateTime createdAt) {
    final difference = DateTime.now().difference(createdAt.toLocal());
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m';
    if (difference.inDays < 1) return '${difference.inHours}h';
    if (difference.inDays < 7) return '${difference.inDays}d';
    return '${createdAt.toLocal().day}/${createdAt.toLocal().month}/${createdAt.toLocal().year}';
  }
}

class _NotificationIdentity extends StatelessWidget {
  final String? avatarUrl;
  final IconData icon;
  final Color color;

  const _NotificationIdentity({
    required this.avatarUrl,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = avatarUrl?.trim();
    if (avatar != null && avatar.isNotEmpty) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: avatar,
          width: 46,
          height: 46,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: 22),
    );
  }
}

class _CreatorChatTile extends StatelessWidget {
  final ChatRoom room;
  final AppState state;
  const _CreatorChatTile({required this.room, required this.state});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        state.activeConversation = room;
        await state.fetchMessages(room.id);
        state.go('creator-chat-detail');
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF0A0F2C).withOpacity(0.4),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: C.text.withOpacity(0.05)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: const Color(0xFF00E5FF).withOpacity(0.1),
              // CachedNetworkImageProvider � zero repeat egress after first load
              backgroundImage: room.otherAvatar != null
                  ? CachedNetworkImageProvider(room.otherAvatar!)
                  : null,
              child: room.otherAvatar == null
                  ? Text(
                      (room.otherName != null && room.otherName!.isNotEmpty)
                          ? room.otherName![0].toUpperCase()
                          : '?',
                      style: syne(
                        c: const Color(0xFF00E5FF),
                        w: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        room.otherName ?? 'Creator',
                        style: syne(sz: 16, w: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color:
                              room.metadata?['interaction_context'] == 'vendor'
                              ? Colors.amberAccent.withOpacity(0.1)
                              : const Color(0xFF00E5FF).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          room.metadata?['interaction_context']
                                  ?.toString()
                                  .toUpperCase() ??
                              'SOCIAL',
                          style: syne(
                            sz: 7,
                            w: FontWeight.w900,
                            c: room.metadata?['interaction_context'] == 'vendor'
                                ? Colors.amberAccent
                                : const Color(0xFF00E5FF),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    room.lastMessage ?? 'Start a conversation',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: dm(sz: 13, c: C.dim),
                  ),
                ],
              ),
            ),
            if (room.myUnread > 0)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0xFF00E5FF),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  room.myUnread.toString(),
                  style: dm(sz: 10, w: FontWeight.bold, c: Colors.black),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
