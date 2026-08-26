// lib/screens/creator_chat_detail_screen.dart
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme.dart';
import '../app_state.dart';
import '../models/chat_models.dart';

class CreatorChatDetailScreen extends StatefulWidget {
  final AppState state;
  const CreatorChatDetailScreen({super.key, required this.state});

  @override
  State<CreatorChatDetailScreen> createState() => _CreatorChatDetailScreenState();
}

class _CreatorChatDetailScreenState extends State<CreatorChatDetailScreen> {
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final room = s.activeConversation;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, color: C.text),
          onPressed: () => s.goBack(),
        ),
        actions: [
          if (room?.metadata?['interaction_context'] == 'vendor')
            IconButton(
              icon: const Icon(Icons.shopping_bag_outlined, color: Color(0xFF00E5FF)),
              onPressed: () {
                // Navigate back to Shop Feed or open Product Overlay
                s.go('community'); 
              },
              tooltip: 'View Shop Item',
            ),
          if (room?.metadata?['interaction_context'] == 'social')
            IconButton(
              icon: Icon(Icons.explore_outlined, color: C.sub),
              onPressed: () => s.go('community'),
              tooltip: 'View Social Post',
            ),
        ],
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              // CachedNetworkImageProvider � AppBar rebuilds on every message;
              // caching here prevents re-downloading the avatar per message received.
              backgroundImage: room?.otherAvatar != null
                  ? CachedNetworkImageProvider(room!.otherAvatar!)
                  : null,
              child: room?.otherAvatar == null ? const Icon(Icons.person, size: 20) : null,
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(room?.otherName ?? 'Creator', style: syne(sz: 14, w: FontWeight.bold)),
                Text(
                  room?.metadata?['interaction_context'] == 'vendor' 
                    ? 'VENDOR / SHOP INTERACTION' 
                    : 'SOCIAL / CREATOR INTERACTION', 
                  style: syne(
                    sz: 9, 
                    c: room?.metadata?['interaction_context'] == 'vendor' 
                        ? Colors.amberAccent 
                        : const Color(0xFF00E5FF), 
                    ls: 1
                  )
                ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: s,
              builder: (context, _) {
                final msgs = s.currentMessages;
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(20),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[i];
                    final isMe = m.senderId == s.user?.id;
                    return _CreatorMessageBubble(msg: m, isMe: isMe);
                  },
                );
              },
            ),
          ),
          _buildInput(),
        ],
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(context).padding.bottom + 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F2C),
        border: Border(top: BorderSide(color: C.text.withOpacity(0.05))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: C.text.withOpacity(0.05),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _ctrl,
                style: dm(c: C.text),
                decoration: InputDecoration(
                  hintText: widget.state.activeConversation?.metadata?['interaction_context'] == 'vendor' 
                      ? 'Message the vendor...' 
                      : 'Message the creator...',
                  hintStyle: dm(c: C.dim),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () {
              if (_ctrl.text.trim().isNotEmpty) {
                widget.state.sendChatMessage(_ctrl.text.trim());
                _ctrl.clear();
                _scrollToBottom();
              }
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(color: Color(0xFF00E5FF), shape: BoxShape.circle),
              child: const Icon(Icons.send_rounded, color: Colors.black, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreatorMessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final bool isMe;
  const _CreatorMessageBubble({required this.msg, required this.isMe});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
        decoration: BoxDecoration(
          color: isMe ? Color(0xFF00E5FF).withOpacity(0.1) : C.text.withOpacity(0.05),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(isMe ? 20 : 0),
            bottomRight: Radius.circular(isMe ? 0 : 20),
          ),
          border: Border.all(color: isMe ? Color(0xFF00E5FF).withOpacity(0.2) : C.text.withOpacity(0.05)),
        ),
        child: Text(msg.content ?? '', style: dm(sz: 14, c: isMe ? Color(0xFF00E5FF) : C.text)),
      ),
    );
  }
}


