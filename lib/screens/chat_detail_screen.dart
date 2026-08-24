import 'package:flutter/material.dart';
import 'package:universal_io/io.dart';
import '../theme.dart';
import '../app_state.dart';
import '../models/chat_models.dart';
import '../services/audio_service.dart';
import '../services/voice_note_service.dart';
import '../widgets/necxa_video_player.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';

class ChatDetailScreen extends StatefulWidget {
  final AppState state;
  const ChatDetailScreen({super.key, required this.state});

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final TextEditingController _msg = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final _audio = AudioService();
  final _record = AudioRecorder();
  int _prevMsgCount = 0;
  bool _isRecording = false;
  String? _recordPath;

  @override
  void initState() {
    super.initState();
    _prevMsgCount = widget.state.currentMessages.length;
    widget.state.addListener(_onStateChange);

    // Mark room as read when opened
    final conv = widget.state.activeConversation;
    if (conv != null) {
      widget.state.markRoomAsRead(conv.id);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChange);
    widget.state.unsubscribeFromMessages();
    _msg.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onStateChange() {
    if (!mounted) return;
    final messages = widget.state.currentMessages;
    if (messages.length > _prevMsgCount) {
      final lastMsg = messages.last;
      if (lastMsg.senderId != widget.state.user?.id) {
        _audio.playIncomingMessage(widget.state);
        // Badge clear is handled locally by the state \u2014 no extra network call needed.
      }
      _prevMsgCount = messages.length;
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<bool> _requestMicPermission() async {
    final status = await Permission.microphone.request();
    return status == PermissionStatus.granted;
  }

  Future<void> _startRecording() async {
    if (await _requestMicPermission()) {
      final dir = await getTemporaryDirectory();
      _recordPath =
          '${dir.path}/vn_${DateTime.now().millisecondsSinceEpoch}.m4a';
      // Use compressed config: 16kHz mono 32kbps ≈ 120KB per 30s
      await _record.start(VoiceNoteService.recordConfig, path: _recordPath!);
      setState(() => _isRecording = true);
    }
  }

  Future<void> _stopRecording() async {
    final path = await _record.stop();
    setState(() => _isRecording = false);
    if (path != null) {
      debugPrint('Recording stopped: $path');
      _sendVoiceNote(path);
    }
  }

  Future<void> _sendVoiceNote(String path) async {
    try {
      // Get duration before encoding
      final duration = await VoiceNoteService.getDuration(path);
      final durationSecs = duration?.inSeconds ?? 0;

      // Encode audio bytes as base64 — travels through Realtime, NOT Storage
      final b64 = await VoiceNoteService.encodeForTransport(path);

      // Save permanently to local device storage (sender keeps their own copy)
      final messageId = DateTime.now().millisecondsSinceEpoch.toString();
      final bytes = await File(path).readAsBytes();
      final localPath = await VoiceNoteService.saveToLocal(bytes, messageId);

      widget.state.sendChatMessage(
        '🎤 Voice Note (${VoiceNoteService.formatDuration(duration)})',
        mediaUrl: localPath,
        messageType: 'voice',
        voiceData: b64,
        durationSeconds: durationSecs,
      );
      _scrollToBottom();
    } catch (e) {
      debugPrint('Voice note send error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final conv = s.activeConversation;
    if (conv == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return GestureDetector(
      // Swipe right anywhere on the screen to go back home
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
          s.go('home');
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.black.withOpacity(.85),
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [C.brand.withOpacity(.15), Colors.transparent],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          elevation: 0,
          // Back button returns to the home screen
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => s.goBack(),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white70),
              onPressed: () => _showChatSettings(s),
            ),
          ],
          title: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: C.brand.withOpacity(.4),
                    width: 1.5,
                  ),
                  image: !conv.isSupport && conv.otherAvatar != null
                      ? DecorationImage(
                          image: NetworkImage(conv.otherAvatar!),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: conv.isSupport
                    ? const Icon(
                        Icons.support_agent_rounded,
                        color: C.brand,
                        size: 22,
                      )
                    : (conv.otherAvatar == null)
                    ? Center(
                        child: Text(
                          conv.displayName[0].toUpperCase(),
                          style: syne(sz: 14, w: FontWeight.bold, c: C.brand),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conv.displayName,
                      style: syne(sz: 17, w: FontWeight.w700, c: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: C.brand,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          conv.isSupport ? 'NECXA SUPPORT' : 'Online',
                          style: dm(sz: 12, c: C.brand, w: FontWeight.w600),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: Container(
          decoration: _getWallpaperDecoration(s.chatWallpaper),
          child: Column(
            children: [
              // Spacer for the AppBar height (extendBodyBehindAppBar = true)
              const SizedBox(height: 100),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 20,
                  ),
                  itemCount: s.currentMessages.length,
                  itemBuilder: (context, i) {
                    final m = s.currentMessages[i];
                    final isMe = m.senderId == s.user?.id;
                    return _MsgBubble(msg: m, isMe: isMe);
                  },
                ),
              ),
              _MsgInput(
                controller: _msg,
                hintText: conv.isSupport
                    ? 'Message Necxa Support...'
                    : 'Type a message...',
                onSend: () {
                  if (_msg.text.trim().isEmpty) return;
                  widget.state.sendChatMessage(_msg.text.trim());
                  _audio.playSentMessage(widget.state);
                  _msg.clear();
                  Future.delayed(
                    const Duration(milliseconds: 100),
                    _scrollToBottom,
                  );
                },
                onAttach: () async {
                  final path = await s.pickMedia();
                  if (path != null) {
                    s.sendChatMessage('Sent an attachment', mediaUrl: path);
                    Future.delayed(
                      const Duration(milliseconds: 100),
                      _scrollToBottom,
                    );
                  }
                },
                isRecording: _isRecording,
                onStartRecord: _startRecording,
                onStopRecord: _stopRecording,
              ),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration _getWallpaperDecoration(String wp) {
    if (wp == 'solid_black') return const BoxDecoration(color: Colors.black);
    if (wp == 'dark_blue') return const BoxDecoration(color: Color(0xFF0A1324));
    if (wp == 'green_gradient') return const BoxDecoration(gradient: greenGrad);
    if (wp == 'cyan_brand') return const BoxDecoration(gradient: brandGrad);

    String assetPath;
    if (wp == 'cyber_map') {
      assetPath = 'assets/images/cyber_map_wp.png';
    } else if (wp == 'friends_bubble') {
      assetPath = 'assets/images/friends_bubble_wp.png';
    } else if (wp == 'nature') {
      assetPath = 'assets/images/nature_wp.png';
    } else if (wp == 'cyber_vehicle') {
      assetPath = 'assets/images/cyber_vehicle_wp.png';
    } else if (wp == 'necxa_logo') {
      assetPath = 'assets/images/app_icon_padded.png';
    } else {
      return const BoxDecoration(color: Colors.black);
    }

    try {
      return BoxDecoration(
        color: Colors.black,
        image: DecorationImage(
          image: AssetImage(assetPath),
          fit: BoxFit.cover,
          onError: (e, stack) => debugPrint('Wallpaper Load Error: $e'),
          colorFilter: ColorFilter.mode(
            Colors.black.withOpacity(.6),
            BlendMode.darken,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Decoration Exception: $e');
      return const BoxDecoration(color: Colors.black);
    }
  }

  void _showChatSettings(AppState s) {
    showModalBottomSheet(
      context: context,
      backgroundColor: C.cardDk,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Chat Settings', style: syne(sz: 18, w: FontWeight.w700)),
              const SizedBox(height: 20),
              Text('Background Wallpaper', style: dm(sz: 14, c: C.sub)),
              const SizedBox(height: 12),
              SizedBox(
                height: 90,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _WpOpt(s, 'solid_black', 'Black', color: Colors.black),
                    _WpOpt(
                      s,
                      'dark_blue',
                      'Navy Base',
                      color: const Color(0xFF0A1324),
                    ),
                    _WpOpt(s, 'cyan_brand', 'Brand', grad: brandGrad),
                    _WpOpt(
                      s,
                      'cyber_map',
                      'Cyber Map',
                      img: 'assets/images/cyber_map_wp.png',
                    ),
                    _WpOpt(
                      s,
                      'cyber_vehicle',
                      'Neon Run',
                      img: 'assets/images/cyber_vehicle_wp.png',
                    ),
                    _WpOpt(
                      s,
                      'friends_bubble',
                      'Friends',
                      img: 'assets/images/friends_bubble_wp.png',
                    ),
                    _WpOpt(
                      s,
                      'nature',
                      'Nature',
                      img: 'assets/images/nature_wp.png',
                    ),
                    _WpOpt(
                      s,
                      'necxa_logo',
                      'Necxa Logo',
                      img: 'assets/images/app_icon_padded.png',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text('Bubble Theme', style: dm(sz: 14, c: C.sub)),
              const SizedBox(height: 12),
              SizedBox(
                height: 50,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _BubbleOpt(s, 'default', 'Default', color: C.brand),
                    _BubbleOpt(
                      s,
                      'neon_cyan_green',
                      'Neon Pulse',
                      grad: neonCyanGreen,
                    ),
                    _BubbleOpt(
                      s,
                      'orange_neon_purple',
                      'Cyber Dusk',
                      grad: neonOrangePurple,
                    ),
                    _BubbleOpt(
                      s,
                      'yellow_neon_pink',
                      'Synth Wave',
                      grad: neonYellowPink,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Wipe Chat History', style: dm(sz: 15)),
                trailing: const Icon(Icons.delete_outline, color: C.red),
                onTap: () {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Not implemented in prototype'),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WpOpt extends StatelessWidget {
  final AppState s;
  final String keyName;
  final String label;
  final Color? color;
  final Gradient? grad;
  final String? img;

  const _WpOpt(
    this.s,
    this.keyName,
    this.label, {
    this.color,
    this.grad,
    this.img,
  });

  @override
  Widget build(BuildContext context) {
    final sel = s.chatWallpaper == keyName;
    return GestureDetector(
      onTap: () => s.setChatWallpaper(keyName),
      child: Container(
        width: 70,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          children: [
            Container(
              height: 60,
              width: 60,
              decoration: BoxDecoration(
                color: color ?? Colors.grey[800],
                gradient: grad,
                image: img != null
                    ? DecorationImage(
                        image: AssetImage(img!),
                        fit: BoxFit.cover,
                      )
                    : null,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: sel ? C.brand : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: dm(sz: 10, c: sel ? C.brand : C.dim),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _MsgBubble extends StatelessWidget {
  final ChatMessage msg;
  final bool isMe;
  const _MsgBubble({required this.msg, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final s =
        (context
            .findAncestorStateOfType<_ChatDetailScreenState>()
            ?.widget
            .state) ??
        AppState(); // Simplified for bubble access
    final isSystem = msg.messageType.startsWith('system_');
    final theme = s.chatBubbleTheme;

    Gradient? bubbleGrad;
    if (isMe && !isSystem) {
      if (theme == 'neon_cyan_green') {
        bubbleGrad = neonCyanGreen;
      } else if (theme == 'orange_neon_purple')
        bubbleGrad = neonOrangePurple;
      else if (theme == 'yellow_neon_pink')
        bubbleGrad = neonYellowPink;
      else
        bubbleGrad = LinearGradient(colors: [C.brand, C.brand.withOpacity(.8)]);
    }

    return GestureDetector(
      onLongPress: () => _showReactionPicker(context, s, msg.id),
      child: Align(
        alignment: isSystem
            ? Alignment.center
            : (isMe ? Alignment.centerRight : Alignment.centerLeft),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              decoration: BoxDecoration(
                gradient: bubbleGrad,
                color: (isMe && !isSystem)
                    ? null
                    : Colors.white.withOpacity(.05),
                border: (isMe && !isSystem)
                    ? null
                    : Border.all(color: Colors.white.withOpacity(.1)),
                boxShadow: (isMe && !isSystem)
                    ? [
                        BoxShadow(
                          color: (bubbleGrad?.colors.first ?? C.brand)
                              .withOpacity(.3),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : [],
                borderRadius: isSystem
                    ? BorderRadius.circular(20)
                    : BorderRadius.only(
                        topLeft: const Radius.circular(20),
                        topRight: const Radius.circular(20),
                        bottomLeft: Radius.circular(isMe ? 20 : 4),
                        bottomRight: Radius.circular(isMe ? 4 : 20),
                      ),
              ),
              child: isSystem
                  ? _buildSystemMsg()
                  : _buildNormalMsg(context, isMe),
            ),
            // Reaction Row
            if (msg.reactions != null && msg.reactions!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 4,
                  children: msg.reactions!
                      .map(
                        (r) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(r, style: const TextStyle(fontSize: 10)),
                        ),
                      )
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemMsg() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.shield_outlined, size: 16, color: Colors.white70),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            msg.content ?? '',
            style: dm(
              sz: 14,
              c: C.brand,
              w: FontWeight.w500,
              fs: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNormalMsg(BuildContext context, bool isMe) {
    return Column(
      crossAxisAlignment: isMe
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if ((msg.messageType == 'image' || msg.messageType == 'video') &&
            (msg.mediaUrl != null || msg.localMediaPath != null)) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: msg.messageType == 'video'
                ? SizedBox(
                    height: 250,
                    width: 200,
                    child: NecxaVideoPlayer(
                      url: msg.localMediaPath ?? msg.mediaUrl!,
                    ),
                  )
                : (msg.localMediaPath != null &&
                          File(msg.localMediaPath!).existsSync()
                      ? Image.file(File(msg.localMediaPath!), fit: BoxFit.cover)
                      : (msg.mediaUrl != null &&
                                msg.mediaUrl!.startsWith('http')
                            ? Image.network(msg.mediaUrl!, fit: BoxFit.cover)
                            : const SizedBox(
                                height: 100,
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ))),
          ),
          const SizedBox(height: 8),
        ],
        // Voice Note Support
        if (msg.messageType == 'voice' &&
            (msg.mediaUrl != null || msg.localMediaPath != null)) ...[
          _VoiceBubble(
            url: msg.localMediaPath ?? msg.mediaUrl ?? '',
            messageId: msg.id,
            isMe: isMe,
            durationSeconds: 0,
          ),
          const SizedBox(height: 8),
        ],
        if (msg.content != null && msg.content!.isNotEmpty)
          Text(
            msg.content!,
            style: dm(
              sz: 15,
              c: isMe ? Colors.black : Colors.white,
              w: FontWeight.w500,
            ),
          ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${msg.createdAt.hour}:${msg.createdAt.minute.toString().padLeft(2, '0')}',
              style: dm(sz: 11, c: isMe ? Colors.black54 : Colors.white54),
            ),
            if (isMe) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.done_all,
                size: 14,
                color: msg.isRead ? C.brand : Colors.black38,
              ),
            ],
          ],
        ),
      ],
    );
  }

  void _showReactionPicker(BuildContext context, AppState s, String msgId) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: C.cardDk,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: ['❤️', '😂', '😮', '😢', '🔥', '👍']
              .map(
                (emoji) => GestureDetector(
                  onTap: () {
                    s.addReaction(msgId, emoji);
                    Navigator.pop(ctx);
                  },
                  child: Text(emoji, style: const TextStyle(fontSize: 28)),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _BubbleOpt extends StatelessWidget {
  final AppState s;
  final String keyName;
  final String label;
  final Color? color;
  final Gradient? grad;

  const _BubbleOpt(this.s, this.keyName, this.label, {this.color, this.grad});

  @override
  Widget build(BuildContext context) {
    final sel = s.chatBubbleTheme == keyName;
    return GestureDetector(
      onTap: () => s.setChatBubbleTheme(keyName),
      child: Container(
        margin: const EdgeInsets.only(right: 16),
        child: Column(
          children: [
            Container(
              height: 30,
              width: 60,
              decoration: BoxDecoration(
                color: color,
                gradient: grad,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: sel ? Colors.white : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(label, style: dm(sz: 10, c: sel ? Colors.white : C.dim)),
          ],
        ),
      ),
    );
  }
}

class _VoiceBubble extends StatefulWidget {
  final String url; // local file path on this device
  final String messageId;
  final bool isMe;
  final int durationSeconds;
  const _VoiceBubble({
    required this.url,
    required this.messageId,
    required this.isMe,
    this.durationSeconds = 0,
  });
  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble>
    with SingleTickerProviderStateMixin {
  final _player = AudioPlayer();
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  late AnimationController _pulseCtrl;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;
  String? _localPath;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _total = Duration(seconds: widget.durationSeconds);
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      // Always prefer local file — never re-download from Supabase
      File? local = await VoiceNoteService.loadFromLocal(widget.messageId);
      if (local == null && widget.url.startsWith('/')) {
        local = File(widget.url);
      }
      if (local != null && await local.exists()) {
        _localPath = local.path;
        await _player.setFilePath(local.path);
        final dur = _player.duration;
        if (dur != null) setState(() => _total = dur);
      }
    } catch (e) {
      debugPrint('[VoiceBubble] Init error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }

    _posSub = _player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _stateSub = _player.playerStateStream.listen((s) {
      if (mounted) {
        setState(() => _isPlaying = s.playing);
        if (s.processingState == ProcessingState.completed) {
          _player.seek(Duration.zero);
          _pulseCtrl.stop();
          _pulseCtrl.reset();
        }
      }
    });
  }

  Future<void> _togglePlay() async {
    if (_localPath == null) return;
    if (_isPlaying) {
      await _player.pause();
      _pulseCtrl.stop();
    } else {
      await _player.play();
      _pulseCtrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total.inMilliseconds > 0
        ? (_position.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final accent = widget.isMe ? Colors.black87 : C.brand;
    final trackColor = widget.isMe ? Colors.black26 : Colors.white24;

    return SizedBox(
      width: 200,
      child: Row(
        children: [
          // Play/Pause button with pulse
          GestureDetector(
            onTap: _isLoading ? null : _togglePlay,
            child: AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (_, __) => Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withOpacity(0.15 + _pulseCtrl.value * 0.1),
                  border: Border.all(
                    color: accent.withOpacity(0.5),
                    width: 1.5,
                  ),
                ),
                child: _isLoading
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      )
                    : Icon(
                        _isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: accent,
                        size: 22,
                      ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Waveform + Progress
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Static waveform bars
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(18, (i) {
                    final heights = [
                      3.0,
                      6.0,
                      10.0,
                      14.0,
                      8.0,
                      12.0,
                      5.0,
                      16.0,
                      9.0,
                      13.0,
                      7.0,
                      11.0,
                      4.0,
                      15.0,
                      8.0,
                      6.0,
                      12.0,
                      3.0,
                    ];
                    final filled = progress > (i / 18);
                    return Container(
                      width: 3,
                      height: heights[i],
                      decoration: BoxDecoration(
                        color: filled ? accent : trackColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 4),
                // Duration
                Text(
                  VoiceNoteService.formatDuration(
                    _isPlaying || _position.inSeconds > 0 ? _position : _total,
                  ),
                  style: TextStyle(
                    fontSize: 10,
                    color: accent.withOpacity(0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MsgInput extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final bool isRecording;
  final VoidCallback onStartRecord;
  final VoidCallback onStopRecord;

  const _MsgInput({
    required this.controller,
    required this.hintText,
    required this.onSend,
    required this.onAttach,
    required this.isRecording,
    required this.onStartRecord,
    required this.onStopRecord,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 12, 16, 24),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.8),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(.05))),
      ),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.add_circle_outline, color: C.dim, size: 28),
              onPressed: onAttach,
              splashRadius: 24,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.05),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.white.withOpacity(.1)),
                ),
                child: TextField(
                  controller: controller,
                  style: dm(sz: 15, c: Colors.white),
                  decoration: InputDecoration(
                    hintText: hintText,
                    hintStyle: dm(sz: 15, c: Colors.white54),
                    border: InputBorder.none,
                  ),
                  onSubmitted: (_) => onSend(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Voice Record Button
            GestureDetector(
              onLongPressStart: (_) => onStartRecord(),
              onLongPressEnd: (_) => onStopRecord(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isRecording
                      ? Colors.red.withOpacity(0.2)
                      : Colors.white.withOpacity(.05),
                  shape: BoxShape.circle,
                  border: isRecording
                      ? Border.all(color: Colors.redAccent, width: 2)
                      : null,
                ),
                child: Icon(
                  isRecording ? Icons.mic_rounded : Icons.mic_none_rounded,
                  color: isRecording ? Colors.redAccent : C.dim,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onSend,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [C.brand, C.brand.withOpacity(.8)],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: C.brand.withOpacity(.4), blurRadius: 8),
                  ],
                ),
                child: const Icon(
                  Icons.send_rounded,
                  color: Colors.black,
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
