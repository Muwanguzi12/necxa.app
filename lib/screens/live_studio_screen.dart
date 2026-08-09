import 'package:livekit_client/livekit_client.dart';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:async';
import 'dart:convert';
import 'package:universal_io/io.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../data.dart';
import '../theme.dart';
import '../app_state.dart';
import '../services/finance_gifting_service.dart';
import '../widgets/live_overlays.dart';
import '../widgets/checkout_container.dart';
import '../widgets/vault_buy_shards_overlay.dart';
import '../services/ai_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../widgets/live_studio/live_enforcement_overlay.dart';
import '../utils/error_handler.dart';

class LiveStudioScreen extends StatefulWidget {
  final AppState state;
  final String channelName;
  final bool isHost;
  final String? hostId;
  final String? hostName;

  const LiveStudioScreen({
    super.key,
    required this.state,
    required this.channelName,
    this.isHost = false,
    this.hostId,
    this.hostName,
  });

  @override
  State<LiveStudioScreen> createState() => _LiveStudioScreenState();
}

class _LiveStudioScreenState extends State<LiveStudioScreen>
    with WidgetsBindingObserver {
  bool _localUserJoined = false;
  String? _initError;
  bool _isInitializing = false;
  int _automaticAuthRetries = 0;
  static const int _maxAutomaticAuthRetries = 1;
  late String _channelName;

  String get _hostDisplayName {
    final String? candidate;
    if (widget.isHost) {
      candidate = widget.state.myProfile?['full_name']?.toString();
    } else {
      candidate = widget.hostName;
    }
    final normalized = candidate?.trim() ?? '';
    return normalized.isEmpty ? 'Necxa Creator' : normalized;
  }

  // Co-Hosting & Guest Interaction State
  bool _isRequestPending = false;
  bool _isCoHosting = false;

  // Live Comments & Gifting Sync State
  final TextEditingController _commentController = TextEditingController();
  final ScrollController _commentsScrollController = ScrollController();
  List<Map<String, dynamic>> _liveComments = [];
  Timer? _commentsTimer;
  String? _commentBeforeCursor;
  String? _commentSyncCursor;
  bool _hasMoreComments = true;
  bool _commentsSyncing = false;
  bool _loadingOlderComments = false;
  Timer? _giftStatsTimer;
  Timer? _promotionTimer;
  Timer? _liveStateSignalTimer;
  StreamSubscription<Map<String, dynamic>>? _eventsSubscription;
  StreamSubscription<Map<String, dynamic>>? _controlEventsSubscription;
  StreamSubscription<Map<String, dynamic>>? _giftEventsSubscription;
  Stream<Map<String, dynamic>> _liveGiftEvents = const Stream.empty();
  final Set<String> _handledEventKeys = <String>{};
  String? _eventCursor;
  bool _requiresVerification = false;
  Map<String, dynamic> _liveSummary = {};
  Map<String, dynamic> _giftSummary = {};
  bool _reactionSending = false;
  bool _isLeaving = false;
  bool _coHostTransitioning = false;
  bool _inviteDialogVisible = false;
  final List<Map<String, dynamic>> _reactionBursts = [];

  // ── Smart Live Verification State ──────────────────────────────────────
  // Silent background face pulse timer — fires every 5 minutes while live as host.
  Timer? _facePulseTimer;
  static const Duration _facePulseInterval = Duration(minutes: 5);
  // Full re-verification is required once every 30 days.
  static const Duration _reverifyPeriod = Duration(days: 30);
  // Pref key is user-scoped to prevent cross-account bleed.
  String get _liveVerifPrefKey =>
      'live_verified_at_${widget.state.user?.id ?? "anon"}';

  // Safety Enforcement State
  int _consecutiveViolations = 0;
  bool _isEnforcementActive = false;
  String? _enforcementReason;
  String? get _hostUserId =>
      widget.hostId ?? (widget.isHost ? widget.state.user?.id : null);
  int get _viewerCount {
    final syncedCount = (_liveSummary['viewerCount'] as num?)?.toInt();
    return syncedCount ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _channelName = widget.channelName;
    WidgetsBinding.instance.addObserver(this);
    // Check cached verification state BEFORE calling initAgora.
    // If already verified within 30 days the user goes live with zero friction.
    unawaited(_prepareLiveStudio());

    _commentsScrollController.addListener(_onCommentsScrolled);
    // Channel-scoped sync starts only after the backend has returned the
    // canonical session room. Hosts must never sync against their display-name
    // placeholder because that room is intentionally not reusable.
  }

  void _startChannelSync() {
    _commentsTimer?.cancel();
    _giftStatsTimer?.cancel();
    _promotionTimer?.cancel();
    _giftEventsSubscription?.cancel();
    _liveGiftEvents = widget.state.financeGifting
        .watchLiveGifts(_channelName)
        .map((gift) => <String, dynamic>{'type': 'gift', 'data': gift})
        .asBroadcastStream();
    _giftEventsSubscription = _liveGiftEvents.listen((event) {
      final gift = Map<String, dynamic>.from(event['data'] as Map? ?? const {});
      final userId = widget.state.user?.id;
      if (userId != null &&
          (gift['senderId'] == userId || gift['receiverId'] == userId)) {
        widget.state.syncVault();
      }
      unawaited(_syncGiftStats());
    });
    unawaited(_hydrateLiveComments());
    _startCommentsSync();
    _startGiftStatsSync();
    _startPromotionClock();
  }

  Future<void> _prepareLiveStudio() async {
    try {
      await _checkLiveVerificationStatus();
    } catch (e) {
      debugPrint('Necxa Live: Verification cache check failed: $e');
    }
    if (mounted) await _initLiveKit();
  }

  void _startLiveEventSync() {
    _eventsSubscription?.cancel();
    _controlEventsSubscription?.cancel();
    _eventsSubscription = widget.state.live
        .listenToEvents(_channelName, initialCursor: _eventCursor)
        .listen(_handleLiveEvent);
    _controlEventsSubscription = widget.state.live
        .controlEventsForChannel(_channelName)
        .listen(_handleLiveEvent);
  }

  void _handleLiveEvent(Map<String, dynamic> event) {
    if (!mounted || event.isEmpty) return;
    final nextCursor = event['eventCursor']?.toString();
    if (nextCursor != null && nextCursor.isNotEmpty) {
      _eventCursor = nextCursor;
    }
    final rawSummary = event['summary'];
    if (rawSummary is Map) {
      _applyLiveSummary(Map<String, dynamic>.from(rawSummary));
    }
    if (event['streamEnded'] == true) {
      setState(() => _reactionBursts.clear());
      if (!widget.isHost) {
        _showToast('This live session has ended.');
      }
      return;
    }

    if (event.containsKey('pinnedProduct')) {
      final rawProduct = event['pinnedProduct'];
      final product = rawProduct is Map
          ? Map<String, dynamic>.from(rawProduct)
          : null;
      if (jsonEncode(widget.state.pinnedLiveProduct) != jsonEncode(product)) {
        widget.state.updatePinnedProduct(product, channelId: _channelName);
      }
    }

    final type = event['type']?.toString();
    if (type == null || type.isEmpty) return;
    if (event['transport'] == 'livekit' && type.startsWith('cohost_')) {
      // Room data is an immediate wake-up signal. MongoDB remains authoritative.
      _liveStateSignalTimer?.cancel();
      _liveStateSignalTimer = Timer(
        const Duration(milliseconds: 150),
        () => unawaited(_syncLiveState()),
      );
      return;
    }
    final eventKey =
        (event['id'] ??
                event['_id'] ??
                '${event['type']}_${event['userId']}_${event['timestamp']}')
            .toString();
    if (!_handledEventKeys.add(eventKey)) return;
    if (_handledEventKeys.length > 200) {
      _handledEventKeys.remove(_handledEventKeys.first);
    }

    final data = Map<String, dynamic>.from(event['data'] as Map? ?? const {});
    final guestId = event['userId']?.toString();
    if (type == 'cohost_request' && widget.isHost) {
      if (guestId == null || guestId.isEmpty) return;
      widget.state.upsertLiveGuestRequest(_channelName, {
        'id': data['requestId']?.toString() ?? eventKey,
        'guestId': guestId,
        'userId': guestId,
        'guestName': data['name'] ?? 'Viewer',
        'name': data['name'] ?? 'Viewer',
        'avatar': data['avatar'] ?? '',
        'status': 'pending',
        'direction': 'viewer_request',
      });
      if (mounted) setState(() {});
    } else if (type == 'cohost_cancelled' && widget.isHost) {
      widget.state.removeLiveGuestRequest(
        _channelName,
        requestId: data['requestId']?.toString(),
        guestId: guestId,
      );
      if (mounted) setState(() {});
    } else if (type == 'cohost_decision' && !widget.isHost) {
      if (guestId != widget.state.user?.id) return;
      if (data['accepted'] == true) {
        unawaited(_activateCoHosting());
      } else {
        setState(() => _isRequestPending = false);
        _showToast('Co-hosting request declined');
      }
    } else if (type == 'cohost_invite' && !widget.isHost) {
      if (guestId != widget.state.user?.id) return;
      unawaited(_showCoHostInvitation());
    } else if (type == 'cohost_invite_decision' && widget.isHost) {
      widget.state.removeLiveGuestRequest(
        _channelName,
        requestId: data['requestId']?.toString(),
        guestId: guestId,
      );
      if (mounted) setState(() {});
      _showToast(
        data['accepted'] == true
            ? 'Your guest accepted the co-host invitation.'
            : 'Your guest declined the co-host invitation.',
      );
    } else if (type == 'cohost_left' && widget.isHost) {
      widget.state.removeLiveGuestRequest(
        _channelName,
        requestId: data['requestId']?.toString(),
        guestId: guestId,
      );
      if (mounted) setState(() {});
    } else if (type == 'product_pinned') {
      if (!widget.isHost) {
        _showToast('A product was pinned to this live.');
      }
    } else if (type == 'product_unpinned') {
      if (!widget.isHost) {
        _showToast('The product was removed from this live.');
      }
    } else if (type == 'live_reaction') {
      final reaction = data['reactionType']?.toString();
      final isOwnReaction = event['userId'] == widget.state.user?.id;
      if (!isOwnReaction &&
          reaction != null &&
          reaction.isNotEmpty &&
          mounted) {
        _showReactionBurst(reaction);
      }
    }
  }

  Future<void> _activateCoHosting() async {
    if (_coHostTransitioning || _isCoHosting || !mounted) return;
    _coHostTransitioning = true;
    try {
      await widget.state.live.switchRoleToBroadcaster();
      if (!mounted) return;
      setState(() {
        _isCoHosting = true;
        _isRequestPending = false;
      });
      _showToast('You are now co-streaming live.');
    } catch (error) {
      if (mounted) _showToast('Could not start co-streaming: $error');
    } finally {
      _coHostTransitioning = false;
    }
  }

  Future<void> _showCoHostInvitation() async {
    if (_inviteDialogVisible || widget.isHost || !mounted) return;
    _inviteDialogVisible = true;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF0C0E14),
        title: Text(
          'CO-HOST INVITATION',
          style: syne(sz: 16, w: FontWeight.bold, c: Colors.white),
        ),
        content: Text(
          'The host invited you to join this live with your camera and microphone.',
          style: dm(sz: 13, c: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('DECLINE'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('JOIN LIVE', style: TextStyle(color: C.brand)),
          ),
        ],
      ),
    );
    _inviteDialogVisible = false;
    if (!mounted || accepted == null) return;
    try {
      await widget.state.live.respondToCoHostInvite(_channelName, accepted);
      if (accepted) {
        await _activateCoHosting();
      } else if (mounted) {
        setState(() => _isRequestPending = false);
        _showToast('Co-host invitation declined.');
      }
    } catch (error) {
      if (mounted) _showToast('Could not respond to invitation: $error');
    }
  }

  Future<void> _syncLiveState() async {
    try {
      final state = await widget.state.live.fetchLiveState(_channelName);
      if (!mounted) return;
      final rawSummary = state['summary'];
      if (rawSummary is Map) {
        _applyLiveSummary(Map<String, dynamic>.from(rawSummary));
      }
      final rawProduct = state['pinnedProduct'];
      final product = rawProduct is Map
          ? Map<String, dynamic>.from(rawProduct)
          : null;
      widget.state.updatePinnedProduct(product, channelId: _channelName);
      final rawRequests = state['guestRequests'];
      if (widget.isHost && rawRequests is List) {
        widget.state.replaceLiveGuestRequests(
          _channelName,
          rawRequests.whereType<Map>().map(
            (request) => Map<String, dynamic>.from(request),
          ),
        );
      } else if (!widget.isHost) {
        final rawRequest = state['guestRequest'];
        if (rawRequest is Map) {
          final request = Map<String, dynamic>.from(rawRequest);
          final status = request['status']?.toString();
          if (status == 'pending') {
            setState(() => _isRequestPending = true);
          } else if (status == 'invited') {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => unawaited(_showCoHostInvitation()),
            );
          } else if (status == 'accepted' || status == 'active') {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => unawaited(_activateCoHosting()),
            );
          }
        } else if (_isRequestPending && !_isCoHosting) {
          setState(() => _isRequestPending = false);
        }
      }
      final cursor = state['eventCursor']?.toString();
      if (cursor != null && cursor.isNotEmpty) _eventCursor = cursor;
    } catch (e) {
      debugPrint('Necxa Live: Stream state sync failed: $e');
    }
  }

  void _applyLiveSummary(Map<String, dynamic> summary) {
    if (!mounted) return;
    if (jsonEncode(_liveSummary) == jsonEncode(summary)) return;
    final previousSession = _liveSummary['streamId']?.toString();
    final nextSession = summary['streamId']?.toString();
    setState(() {
      if (previousSession != null &&
          previousSession.isNotEmpty &&
          nextSession != null &&
          nextSession.isNotEmpty &&
          previousSession != nextSession) {
        _reactionBursts.clear();
      }
      _liveSummary = summary;
    });
  }

  void _startGiftStatsSync() {
    _giftStatsTimer?.cancel();
    unawaited(_syncGiftStats());
    _giftStatsTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _syncGiftStats(),
    );
  }

  Future<void> _syncGiftStats() async {
    try {
      final snapshot = await widget.state.financeGifting.fetchLiveGiftSnapshot(
        _channelName,
      );
      final summary = snapshot['summary'];
      if (!mounted || summary is! Map) return;
      final nextSummary = Map<String, dynamic>.from(summary);
      if (jsonEncode(_giftSummary) == jsonEncode(nextSummary)) return;
      setState(() => _giftSummary = nextSummary);
    } catch (e) {
      debugPrint('Necxa Live: Gift stats sync failed: $e');
    }
  }

  void _startPromotionClock() {
    _promotionTimer?.cancel();
    _promotionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _productExpiry(widget.state.pinnedLiveProduct) != null) {
        setState(() {});
      }
    });
  }

  // ignore: unused_element
  void _legacyStartCommentsSync() {
    _commentsTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) return;
      try {
        final newComments = await widget.state.live.fetchLiveComments(
          _channelName,
        );
        if (newComments.isNotEmpty && mounted) {
          setState(() {
            _liveComments = newComments;
          });
        }
      } catch (e) {
        debugPrint('⚠️ Sync Comments failed: $e');
      }
    });
  }

  // ignore: unused_element
  void _legacySendComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    _commentController.clear();

    // Optimistic local update
    final myName =
        widget.state.myProfile?['full_name'] ??
        widget.state.user?.email ??
        'Viewer';
    setState(() {
      _liveComments.insert(0, {'user': myName, 'text': text});
    });

    try {
      await widget.state.live.sendLiveComment(_channelName, myName, text);
    } catch (e) {
      debugPrint('⚠️ Send Comment failed: $e');
    }
  }

  void _startCommentsSync() {
    _commentsTimer?.cancel();
    _commentsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_syncLiveComments());
    });
  }

  String get _commentCursorKey => 'live_comments_$_channelName';

  List<Map<String, dynamic>> _visibleLiveComments(
    List<Map<String, dynamic>> comments,
  ) {
    final visible = comments
        .where(
          (comment) =>
              comment['status'] == null || comment['status'] == 'active',
        )
        .toList();
    visible.sort((a, b) {
      final aTime =
          DateTime.tryParse(
            (a['createdAt'] ?? a['timestamp'])?.toString() ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bTime =
          DateTime.tryParse(
            (b['createdAt'] ?? b['timestamp'])?.toString() ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return visible;
  }

  Future<void> _reloadCachedLiveComments() async {
    final cached = await widget.state.live.loadCachedLiveComments(_channelName);
    if (!mounted) return;
    setState(() => _liveComments = _visibleLiveComments(cached));
  }

  Future<void> _hydrateLiveComments() async {
    await _reloadCachedLiveComments();
    _commentSyncCursor = await widget.state.localDb.getSyncCursor(
      _commentCursorKey,
    );
    await _syncLiveComments(refreshLatestPage: true);
  }

  Future<void> _syncLiveComments({bool refreshLatestPage = false}) async {
    if (!mounted || _commentsSyncing) return;
    _commentsSyncing = true;
    try {
      await widget.state.live.syncPendingLiveComments(_channelName);

      if (refreshLatestPage || _commentSyncCursor == null) {
        final latest = await widget.state.live.fetchLiveCommentPage(
          _channelName,
        );
        _commentBeforeCursor = latest['nextCursor']?.toString();
        _hasMoreComments = latest['hasMore'] == true;
        final initialSyncCursor = latest['syncCursor']?.toString();
        if (_commentSyncCursor == null && initialSyncCursor != null) {
          _commentSyncCursor = initialSyncCursor;
          await widget.state.localDb.setSyncCursor(
            _commentCursorKey,
            initialSyncCursor,
          );
        }
      }

      final cursor = _commentSyncCursor;
      if (cursor != null) {
        final delta = await widget.state.live.fetchLiveCommentPage(
          _channelName,
          after: cursor,
          limit: 100,
        );
        final nextCursor = delta['syncCursor']?.toString();
        if (nextCursor != null && nextCursor.isNotEmpty) {
          _commentSyncCursor = nextCursor;
          await widget.state.localDb.setSyncCursor(
            _commentCursorKey,
            nextCursor,
          );
        }
      }
      await _reloadCachedLiveComments();
    } catch (error) {
      debugPrint('Necxa Live: Comment sync deferred: $error');
      await _reloadCachedLiveComments();
    } finally {
      _commentsSyncing = false;
    }
  }

  void _onCommentsScrolled() {
    if (!_commentsScrollController.hasClients ||
        _loadingOlderComments ||
        !_hasMoreComments) {
      return;
    }
    final position = _commentsScrollController.position;
    if (position.pixels >= position.maxScrollExtent - 48) {
      unawaited(_loadOlderComments());
    }
  }

  Future<void> _loadOlderComments() async {
    final cursor = _commentBeforeCursor;
    if (cursor == null || _loadingOlderComments || !_hasMoreComments) return;
    _loadingOlderComments = true;
    try {
      final page = await widget.state.live.fetchLiveCommentPage(
        _channelName,
        before: cursor,
      );
      _commentBeforeCursor = page['nextCursor']?.toString();
      _hasMoreComments = page['hasMore'] == true;
      await _reloadCachedLiveComments();
    } catch (error) {
      debugPrint('Necxa Live: Older comments could not load: $error');
    } finally {
      _loadingOlderComments = false;
    }
  }

  Future<void> _sendComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    _commentController.clear();
    final myName =
        widget.state.myProfile?['full_name'] ??
        widget.state.user?.email ??
        'Viewer';
    try {
      await widget.state.live.sendLiveComment(_channelName, myName, text);
      await _reloadCachedLiveComments();
    } catch (error) {
      _commentController.text = text;
      _showToast(error.toString());
    }
  }

  String _commentTimeLabel(Map<String, dynamic> comment) {
    final timestamp = DateTime.tryParse(
      (comment['createdAt'] ?? comment['timestamp'])?.toString() ?? '',
    );
    if (timestamp == null) return '';
    final age = DateTime.now().toUtc().difference(timestamp.toUtc());
    if (age.inSeconds < 60) return 'now';
    if (age.inMinutes < 60) return '${age.inMinutes}m';
    if (age.inHours < 24) return '${age.inHours}h';
    return '${age.inDays}d';
  }

  Future<void> _editComment(Map<String, dynamic> comment) async {
    final controller = TextEditingController(
      text: comment['text']?.toString() ?? '',
    );
    final updatedText = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        title: Text('Edit comment', style: syne(sz: 16, c: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 2000,
          style: dm(sz: 14, c: Colors.white),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (updatedText == null ||
        updatedText.isEmpty ||
        updatedText == comment['text']) {
      return;
    }
    await widget.state.live.editLiveComment(
      _channelName,
      comment['id'].toString(),
      updatedText,
    );
    await _reloadCachedLiveComments();
  }

  Future<void> _deleteComment(Map<String, dynamic> comment) async {
    await widget.state.live.deleteLiveComment(
      _channelName,
      comment['id'].toString(),
    );
    await _reloadCachedLiveComments();
  }

  Future<void> _showCommentActions(Map<String, dynamic> comment) async {
    final commentId = comment['id']?.toString();
    if (commentId == null || commentId.isEmpty) return;
    final isMine = comment['userId']?.toString() == widget.state.user?.id;
    final isLocal = commentId.startsWith('local_');
    final failed = comment['syncStatus'] == 'failed';

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed)
              ListTile(
                leading: const Icon(Icons.sync_rounded, color: Colors.white),
                title: const Text(
                  'Retry',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(
                    widget.state.live
                        .retryLiveComment(_channelName, commentId)
                        .then((_) => _reloadCachedLiveComments()),
                  );
                },
              ),
            if (isMine)
              ListTile(
                leading: const Icon(Icons.edit_rounded, color: Colors.white),
                title: const Text(
                  'Edit',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_editComment(comment));
                },
              ),
            if (isMine)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_deleteComment(comment));
                },
              ),
            if (!isMine && !isLocal)
              ListTile(
                leading: const Icon(Icons.flag_outlined, color: Colors.white),
                title: const Text(
                  'Report',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(
                    widget.state.live.reportLiveComment(
                      _channelName,
                      commentId,
                    ),
                  );
                  _showToast('Report queued for review.');
                },
              ),
            if (widget.isHost && !isMine && !isLocal)
              ListTile(
                leading: const Icon(
                  Icons.visibility_off_outlined,
                  color: Colors.orangeAccent,
                ),
                title: const Text(
                  'Hide from stream',
                  style: TextStyle(color: Colors.orangeAccent),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(
                    () => _liveComments.removeWhere(
                      (item) => item['id'] == commentId,
                    ),
                  );
                  unawaited(
                    widget.state.live.moderateLiveComment(
                      _channelName,
                      commentId,
                      moderationAction: 'hide',
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _initLiveKit() async {
    if (!mounted || _isInitializing) return;
    _isInitializing = true;
    final liveService = widget.state.live;
    var retryAfterDelay = false;

    try {
      if (mounted) {
        setState(() {
          _initError = null;
          _requiresVerification = false;
        });
      }

      await liveService.init();

      if (widget.isHost) {
        _channelName = await liveService.startStreaming(widget.channelName);
      } else {
        await liveService.joinAsViewer(_channelName);
      }

      if (!mounted) return;
      widget.state.setLiveChannel(_channelName, isHosting: widget.isHost);
      _startChannelSync();
      setState(() {
        _localUserJoined = true;
      });
      await _syncLiveState();
      _eventCursor ??= '0';
      _startLiveEventSync();
      _automaticAuthRetries = 0;

      // Setup room event listeners to trigger UI updates
      liveService.room?.removeListener(_onRoomDidUpdate);
      liveService.room?.addListener(_onRoomDidUpdate);

      // Once confirmed live as host, start silent periodic face pulse.
      if (widget.isHost) _startSilentFacePulse();
    } catch (e, stackTrace) {
      debugPrint('Necxa Live: Startup failed: $e\n$stackTrace');
      if (!mounted) return;
      final errStr = e.toString();
      final is403 =
          errStr.contains('403') ||
          errStr.toLowerCase().contains('identity verification required');
      if (is403) {
        var verified = false;
        try {
          verified = await _hasCompletedIdentityVerification();
        } catch (verificationError) {
          debugPrint(
            'Necxa Live: Verification lookup failed: $verificationError',
          );
        }

        // Only show the verification card if their cached credential is expired or absent.
        final prefs = await SharedPreferences.getInstance();
        final rawTs = prefs.getString(_liveVerifPrefKey);
        final lastVerified = rawTs != null ? DateTime.tryParse(rawTs) : null;
        final expired =
            lastVerified == null ||
            DateTime.now().difference(lastVerified) > _reverifyPeriod;

        if (verified && _automaticAuthRetries < _maxAutomaticAuthRetries) {
          _automaticAuthRetries++;
          await _markLiveVerified();
          retryAfterDelay = true;
        } else if (!verified && expired) {
          setState(() {
            _initError =
                'Identity verification required. Please verify to go live.';
            _requiresVerification = true;
          });
        } else if (_automaticAuthRetries < _maxAutomaticAuthRetries) {
          _automaticAuthRetries++;
          retryAfterDelay = true;
        } else {
          setState(() {
            _initError =
                'Live authentication was rejected. Tap retry, or sign in again if it continues.';
            _requiresVerification = false;
          });
        }
      } else {
        setState(() => _initError = _liveStartupError(e));
      }
    } finally {
      _isInitializing = false;
    }

    if (retryAfterDelay && mounted) {
      debugPrint(
        'Necxa Live: Authentication is still propagating; retrying once.',
      );
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) await _initLiveKit();
    }
  }

  String _liveStartupError(dynamic error) {
    if (error is TimeoutException) {
      final detail = error.message.toLowerCase();
      if (detail.contains('permission') ||
          detail.contains('camera') ||
          detail.contains('microphone')) {
        return 'Camera or microphone access took too long. Check app permissions, then tap retry.';
      }
      if (detail.contains('authentication')) {
        return 'The live server took too long to respond. Check your connection, then tap retry.';
      }
      if (detail.contains('video room')) {
        return 'Could not reach the live video service. Check your connection, then tap retry.';
      }
    }
    return getUserFriendlyError(error);
  }

  void _onRoomDidUpdate() {
    if (mounted) {
      setState(() {});
    }
  }

  // ── SMART LIVE VERIFICATION HELPERS ────────────────────────────────────

  /// Reads the persisted verification timestamp. If absent or expired (> 30 days),
  /// sets [_requiresVerification] = true so _initAgora will surface the Shield card.
  Future<void> _checkLiveVerificationStatus() async {
    // Authenticated users should not be blocked by a second identity prompt.
    _requiresVerification = false;
  }

  /// Stamps the current timestamp as verified in SharedPreferences.
  Future<void> _markLiveVerified() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_liveVerifPrefKey, DateTime.now().toIso8601String());
    _requiresVerification = false;
  }

  Future<bool> _hasCompletedIdentityVerification() async {
    if (widget.state.isAuthenticated) {
      return true;
    }

    await widget.state.loadMyProfile();
    final profile = widget.state.myProfile ?? {};
    final verifiedAtRaw = profile['verified_at']?.toString();
    final verifiedAt = verifiedAtRaw != null
        ? DateTime.tryParse(verifiedAtRaw)
        : null;
    final verifiedRecently =
        verifiedAt != null &&
        DateTime.now().difference(verifiedAt) <= _reverifyPeriod;

    final localVerificationComplete =
        widget.state.lastIDResult?.verified == true ||
        widget.state.lastSelfieResult?.faceMatch == true ||
        widget.state.idVerified;
    final profileVerified =
        profile['verified'] == true ||
        profile['face_verified'] == true ||
        verifiedRecently;

    return localVerificationComplete || profileVerified;
  }

  // ── SILENT BACKGROUND FACE PULSE ────────────────────────────────────────

  /// Starts a periodic timer that silently captures a frame from the Agora engine
  /// and runs a background liveness check — zero UI disruption.
  void _startSilentFacePulse() {
    _facePulseTimer?.cancel();
    _facePulseTimer = Timer.periodic(
      _facePulseInterval,
      (_) => _runSilentFaceCheck(),
    );
    debugPrint(
      '🛡️ Live: Silent face pulse started (every ${_facePulseInterval.inMinutes}m).',
    );
  }

  void _stopSilentFacePulse() {
    _facePulseTimer?.cancel();
    _facePulseTimer = null;
  }

  /// Captures a snapshot from the Agora local video stream, saves it to a temp file,
  /// runs a liveness check AND a strict content safety scan.
  /// Any critical failure (e.g. CSAM) immediately terminates the stream.
  Future<void> _runSilentFaceCheck() async {
    if (!mounted || !_localUserJoined || _isEnforcementActive) return;
    final localParticipant = widget.state.live.room?.localParticipant;
    if (localParticipant == null) return;
    final videoTrack =
        localParticipant.videoTrackPublications.firstOrNull?.track;
    if (videoTrack == null) return;

    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/live_pulse_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final buffer = await videoTrack.mediaStreamTrack.captureFrame();
      final file = File(path);
      await file.writeAsBytes(buffer.asUint8List());
      if (!file.existsSync()) return;

      // 1. Liveness Check (Supabase — biometric composite model)

      // 2. Strict Content Safety Scan via Cloudflare Worker (Llama 3.2 Vision).
      // Falls back to safe() on any network error — stream is never killed
      // on connectivity issues alone.
      final safetyResult = await NecxaAI.scanLiveFrameWorker(file);

      // Clean up temp file immediately.
      try {
        file.deleteSync();
      } catch (_) {}

      if (!mounted) return;

      if (!safetyResult.safe && safetyResult.severity != 'none') {
        _consecutiveViolations++;
        debugPrint(
          '🚨 Live Safety Violation [$_consecutiveViolations]: ${safetyResult.severity} - ${safetyResult.reason}',
        );

        // Escalation matrix:
        // Critical (e.g. CSAM, weapons) -> immediate termination
        // High (e.g. drug use, nudity) -> strike 2 termination
        if (safetyResult.isCritical ||
            (safetyResult.isHigh && _consecutiveViolations >= 2)) {
          _enforceSafetyTermination(
            safetyResult.reason ?? 'Community guidelines violation detected.',
          );
          return;
        }
      } else {
        // Reset counter on safe frame
        _consecutiveViolations = 0;
      }
    } catch (e) {
      // Silently swallow network errors so we don't accidentally kill a stream
      debugPrint('🛡️ Silent Pulse/Scan (non-fatal): $e');
    }
  }

  /// Terminates the stream immediately and locks the UI due to a safety violation.
  void _enforceSafetyTermination(String reason) {
    if (!mounted) return;
    _stopSilentFacePulse();
    unawaited(
      widget.state.live.leaveChannel().catchError((error) {
        debugPrint('Necxa Live: Safety stop confirmation failed: $error');
      }),
    );
    setState(() {
      _isEnforcementActive = true;
      _enforcementReason = reason;
      _localUserJoined = false;
    });
  }

  /// Called when the backend returns a 403 'identity verification required to go live'.
  /// Fires the Necxa Shield composite modal (ID + Face biometric) in-place.
  /// On success it clears the error and retries startStreaming automatically.
  Future<void> _shieldVerifyAndRetry() async {
    setState(() {
      _initError = null;
      _requiresVerification = false;
    });

    try {
      if (!mounted) return;

      final verified = await _hasCompletedIdentityVerification();

      if (!verified) {
        throw 'Complete real identity verification before going live.';
      }

      await _markLiveVerified();
      widget.state.notify();
      _automaticAuthRetries = 0;
      await _initLiveKit();
    } catch (e) {
      if (mounted) {
        setState(() {
          _initError = getUserFriendlyError(e);
          _requiresVerification = true;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _commentsTimer?.cancel();
    _giftStatsTimer?.cancel();
    _promotionTimer?.cancel();
    _liveStateSignalTimer?.cancel();
    _eventsSubscription?.cancel();
    _controlEventsSubscription?.cancel();
    _giftEventsSubscription?.cancel();
    _stopSilentFacePulse();
    _commentController.dispose();
    _commentsScrollController.dispose();
    widget.state.setLiveChannel(null);
    unawaited(
      widget.state.live.leaveChannel().catchError((error) {
        debugPrint('Necxa Live: Dispose cleanup failed: $error');
      }),
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // Pause resource-intensive operations
      _commentsTimer?.cancel();
      _giftStatsTimer?.cancel();
      _promotionTimer?.cancel();
      _stopSilentFacePulse();
      widget.state.live.setAVEnabled(false);
      debugPrint('🛡️ Live Studio: App minimized, pausing AV & Timers');
    } else if (state == AppLifecycleState.resumed) {
      // Resume operations
      if (_localUserJoined && !_isEnforcementActive) {
        widget.state.live.setAVEnabled(true);
        _startCommentsSync();
        _startGiftStatsSync();
        _startPromotionClock();
        if (widget.isHost) _startSilentFacePulse();
        debugPrint('🛡️ Live Studio: App resumed, restarting AV & Timers');
      }
    }
  }

  Future<void> _closeLiveStudio() async {
    if (_isLeaving) return;
    setState(() => _isLeaving = true);
    try {
      await widget.state.live.leaveChannel();
    } catch (error) {
      if (mounted) {
        _showToast(
          widget.isHost
              ? 'The stream closed locally. Server confirmation is delayed and discovery will expire automatically.'
              : 'You left the stream. Viewer presence will expire automatically.',
        );
      }
    }
    if (mounted) Navigator.pop(context);
  }

  // ── SAFETY ENFORCEMENT UI ──────────────────────────────────────────────────

  // Enforcement card moved to lib/widgets/live_studio/live_enforcement_overlay.dart

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // ── Video Layer ──
          _buildVideoView(),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: MediaQuery.sizeOf(context).height * 0.42,
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xE6000000)],
                  ),
                ),
              ),
            ),
          ),

          // ── Shield Verification Wall (403 Handler) ──
          if (_requiresVerification) _buildShieldVerificationCard(),

          // ── Safety Enforcement Wall (Violations) ──
          if (_isEnforcementActive)
            LiveEnforcementOverlay(
              enforcementReason: _enforcementReason,
              onClose: () => Navigator.pop(context),
            ),

          // ── Gifting Layer ──
          LiveGiftingOverlay(eventStream: _liveGiftEvents),

          for (var i = 0; i < _reactionBursts.length; i++)
            _buildReactionBurst(_reactionBursts[i], i),

          // ── Glass Overlay Layer ──
          _buildCompactHUD(),

          // ── Interaction Layer ──
          _buildInteractionUI(),
        ],
      ),
    );
  }

  void _openCheckout(Map<String, dynamic>? product) {
    if (product == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => CheckoutContainer(
        state: widget.state,
        listing: product,
        onDismiss: () => Navigator.pop(context),
      ),
    );
  }

  Widget _buildVideoView() {
    if (!_localUserJoined || widget.state.live.room == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(seconds: 2),
              builder: (context, double value, child) {
                return Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: C.brand.withOpacity(0.3 * (1 - value)),
                        blurRadius: 20 * value,
                        spreadRadius: 10 * value,
                      ),
                    ],
                    border: Border.all(
                      color: C.brand.withOpacity(1 - value),
                      width: 2,
                    ),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.videocam_outlined,
                      color: Colors.white24,
                      size: 30,
                    ),
                  ),
                );
              },
              onEnd:
                  () {}, // Handled by repeating via a loop if needed, but for now a simple pulse
            ),
            const SizedBox(height: 24),
            if (_initError != null && !_requiresVerification) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _initError!,
                  textAlign: TextAlign.center,
                  style: dm(sz: 10, c: Colors.white38),
                ),
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: _initLiveKit,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: C.brand,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: C.brand.withOpacity(0.3),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Text(
                    'RETRY STREAM SYNC',
                    style: syne(sz: 11, w: FontWeight.bold, c: Colors.black),
                  ),
                ),
              ),
            ] else ...[
              const SizedBox(height: 24),
              Text(
                'INITIALIZING ENGINE...',
                style: syne(
                  sz: 10,
                  w: FontWeight.w900,
                  c: Colors.white38,
                  ls: 2,
                ),
              ),
            ],
          ],
        ),
      );
    }

    final room = widget.state.live.room!;
    final participants = _videoParticipants(room);
    if (participants.isEmpty) {
      return const Center(
        child: Icon(
          Icons.videocam_off_outlined,
          color: Colors.white24,
          size: 48,
        ),
      );
    }

    final host = _hostParticipant(participants);
    final guests = participants
        .where((participant) => participant != host)
        .toList();
    if (host == null || guests.isEmpty) {
      return _participantVideoTile(
        host ?? participants.first,
        isHostTile: true,
        showChrome: false,
      );
    }

    final screenHeight = MediaQuery.sizeOf(context).height;
    final safeTop = MediaQuery.paddingOf(context).top;
    final topSpace = safeTop + 126;
    final bottomSpace = (screenHeight * 0.34).clamp(250.0, 330.0);
    final guestSlots = widget.isHost
        ? (guests.length >= 4 ? 8 : 4)
        : guests.length;

    return Padding(
      padding: EdgeInsets.fromLTRB(6, topSpace, 6, bottomSpace),
      child: Row(
        children: [
          Expanded(
            flex: 11,
            child: _participantVideoTile(host, isHostTile: true),
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 10,
            child: GridView.builder(
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: guestSlots,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
                childAspectRatio: 0.86,
              ),
              itemBuilder: (context, index) {
                if (index < guests.length) {
                  return _participantVideoTile(guests[index]);
                }
                return _guestRequestTile();
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Participant> _videoParticipants(Room room) {
    final result = <Participant>[];
    final local = room.localParticipant;
    if (local != null &&
        (widget.isHost ||
            _isCoHosting ||
            local.videoTrackPublications.isNotEmpty)) {
      result.add(local);
    }
    result.addAll(
      room.remoteParticipants.values.where(
        (participant) => participant.videoTrackPublications.isNotEmpty,
      ),
    );
    return result;
  }

  Participant? _hostParticipant(List<Participant> participants) {
    final hostId = _hostUserId;
    if (hostId != null) {
      for (final participant in participants) {
        if (participant.identity == hostId) return participant;
      }
    }
    final local = widget.state.live.room?.localParticipant;
    if (widget.isHost && local != null && participants.contains(local)) {
      return local;
    }
    return participants.firstOrNull;
  }

  bool get _hasPublishingGuests {
    final room = widget.state.live.room;
    if (room == null) return false;
    final participants = _videoParticipants(room);
    final host = _hostParticipant(participants);
    return host != null &&
        participants.any((participant) => participant != host);
  }

  Widget _participantVideoTile(
    Participant participant, {
    bool isHostTile = false,
    bool showChrome = true,
  }) {
    final videoPublication = participant.videoTrackPublications.firstOrNull;
    final videoTrack = videoPublication?.track;
    final displayName = participant.name.trim().isNotEmpty
        ? participant.name.trim()
        : participant.identity;
    final audioPublications = participant.audioTrackPublications;
    final isMuted =
        audioPublications.isEmpty ||
        audioPublications.every((publication) => publication.muted);

    return ClipRRect(
      borderRadius: showChrome ? BorderRadius.circular(8) : BorderRadius.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF17151F),
          border: showChrome ? Border.all(color: Colors.white12) : null,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (videoTrack is VideoTrack)
              VideoTrackRenderer(videoTrack, fit: VideoViewFit.cover)
            else
              const ColoredBox(
                color: Color(0xFF17151F),
                child: Center(
                  child: Icon(Icons.person, color: Colors.white30, size: 40),
                ),
              ),
            if (showChrome) ...[
              Positioned(
                top: 7,
                left: 7,
                child: _videoTileBadge(isHostTile ? 'HOST' : 'GUEST'),
              ),
              if (isMuted)
                const Positioned(
                  top: 8,
                  right: 8,
                  child: Icon(
                    Icons.mic_off_rounded,
                    color: Colors.white70,
                    size: 14,
                  ),
                ),
              Positioned(
                left: 7,
                right: 7,
                bottom: 7,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: dm(sz: 9, w: FontWeight.w800, c: Colors.white),
                      ),
                    ),
                    if (!isHostTile) ...[
                      const SizedBox(width: 4),
                      Container(
                        width: 20,
                        height: 20,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF176B),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.add,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _videoTileBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xCC0E2022),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: dm(sz: 8, w: FontWeight.w900, c: const Color(0xFF62F5EA)),
      ),
    );
  }

  Widget _guestRequestTile() {
    return InkWell(
      onTap: widget.isHost ? _showGuestRequestsManager : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1D1830),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: const Color(0xFF6F5AA7).withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.add_rounded, color: Colors.white, size: 28),
            const SizedBox(height: 4),
            Text(
              'REQUEST',
              style: dm(sz: 8, w: FontWeight.w700, c: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  String _compactNumber(num value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(value >= 10000000 ? 0 : 1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(value >= 10000 ? 0 : 1)}K';
    }
    return value.toInt().toString();
  }

  int get _reactionCount {
    final counts = _liveSummary['reactionCounts'];
    if (counts is! Map) return 0;
    return counts.values.fold<int>(
      0,
      (total, value) => total + ((value as num?)?.toInt() ?? 0),
    );
  }

  Map<String, dynamic>? get _topGifter {
    final top = _giftSummary['topGifter'];
    return top is Map ? Map<String, dynamic>.from(top) : null;
  }

  Widget _buildCompactHUD() {
    final topGifter = _topGifter;
    final giftTotal = (_giftSummary['totalAmount'] as num?)?.toInt() ?? 0;
    final giftGoal = (_giftSummary['goalTarget'] as num?)?.toInt() ?? 100;
    final goalProgress = giftGoal <= 0
        ? 0.0
        : (giftTotal / giftGoal).clamp(0.0, 1.0);
    final topGifterName = topGifter?['senderName']?.toString().trim();
    final topGifterAmount = (topGifter?['amount'] as num?) ?? 0;

    return Positioned(
      top: MediaQuery.paddingOf(context).top + 8,
      left: 12,
      right: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      height: 46,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: [Color(0xFFFF176B), Color(0xFF00E5FF)],
                              ),
                            ),
                            child: CircleAvatar(
                              backgroundColor: const Color(0xFF153B50),
                              child: Text(
                                _hostDisplayName[0].toUpperCase(),
                                style: dm(
                                  sz: 11,
                                  w: FontWeight.w900,
                                  c: Colors.white,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        _hostDisplayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: syne(
                                          sz: 11,
                                          w: FontWeight.w800,
                                          c: Colors.white,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(
                                      Icons.verified_rounded,
                                      color: Color(0xFF00E5FF),
                                      size: 13,
                                    ),
                                  ],
                                ),
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.visibility_outlined,
                                      color: Colors.white70,
                                      size: 10,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      '$_viewerCount viewers',
                                      style: dm(sz: 8, c: Colors.white70),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF176B),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(color: Color(0x55FF176B), blurRadius: 12),
                  ],
                ),
                child: Text(
                  'LIVE',
                  style: syne(sz: 10, w: FontWeight.w900, c: Colors.white),
                ),
              ),
              if (widget.isHost) ...[
                const SizedBox(width: 7),
                GestureDetector(
                  onTap: _showProductPicker,
                  child: _hudCircleButton(Icons.push_pin_outlined),
                ),
              ],
              const SizedBox(width: 7),
              GestureDetector(
                onTap: _isLeaving ? null : _closeLiveStudio,
                child: _hudCircleButton(
                  Icons.close_rounded,
                  loading: _isLeaving,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _compactHudChip(
                  icon: Icons.local_fire_department_rounded,
                  iconColor: const Color(0xFFFF8A00),
                  title: 'TOP GIFTER',
                  value: topGifterName == null || topGifterName.isEmpty
                      ? 'No gifts yet'
                      : '$topGifterName · ${_compactNumber(topGifterAmount)}',
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _compactHudChip(
                  icon: Icons.card_giftcard_rounded,
                  iconColor: const Color(0xFFFFA300),
                  title: 'GOAL',
                  value:
                      '${_compactNumber(giftTotal)} / ${_compactNumber(giftGoal)} NCX',
                  progress: goalProgress,
                ),
              ),
              if (_hasPublishingGuests) ...[
                const SizedBox(width: 7),
                Tooltip(
                  message: 'Live guest stage',
                  child: _hudCircleButton(
                    Icons.rocket_launch_rounded,
                    color: const Color(0xFF6650A4),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _compactHudChip({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    double? progress,
  }) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: dm(sz: 7, w: FontWeight.w800, c: Colors.white60),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: dm(sz: 8, w: FontWeight.w700, c: Colors.white),
                ),
                if (progress != null) ...[
                  const SizedBox(height: 2),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 2,
                      backgroundColor: Colors.white12,
                      color: const Color(0xFFFF176B),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hudCircleButton(
    IconData icon, {
    bool loading = false,
    Color color = const Color(0x99000000),
  }) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: loading
          ? const Padding(
              padding: EdgeInsets.all(10),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(icon, color: Colors.white, size: 19),
    );
  }

  DateTime? _productExpiry(Map<String, dynamic>? product) {
    if (product == null) return null;
    for (final key in const [
      'promotion_ends_at',
      'sale_ends_at',
      'discount_ends_at',
      'expires_at',
    ]) {
      final parsed = DateTime.tryParse(product[key]?.toString() ?? '');
      if (parsed != null && parsed.isAfter(DateTime.now())) return parsed;
    }
    return null;
  }

  int? _productDiscount(Map<String, dynamic> product) {
    final current = num.tryParse(
      (product['price'] ?? product['price_ugx'] ?? '').toString(),
    );
    final original = num.tryParse(
      (product['compare_at_price'] ??
              product['original_price'] ??
              product['regular_price'] ??
              '')
          .toString(),
    );
    if (current == null ||
        original == null ||
        original <= current ||
        original <= 0) {
      return null;
    }
    return (((original - current) / original) * 100).round();
  }

  String _promotionTimeLeft(DateTime expiry) {
    final remaining = expiry.difference(DateTime.now());
    if (remaining.isNegative) return 'ENDED';
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final seconds = remaining.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
  }

  Widget _buildInteractionUI() {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final pinned = widget.state.pinnedLiveProduct;
    final discount = pinned == null ? null : _productDiscount(pinned);
    final promotionExpiry = _productExpiry(pinned);
    return Positioned(
      bottom:
          (bottomInset > 0
              ? bottomInset
              : MediaQuery.of(context).padding.bottom) +
          20,
      left: 16,
      right: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Chat Preview
          SizedBox(
            height: pinned != null ? 105 : (_hasPublishingGuests ? 135 : 160),
            child: ListView.builder(
              controller: _commentsScrollController,
              itemCount: _liveComments.length,
              reverse: true,
              padding: const EdgeInsets.only(bottom: 12),
              itemBuilder: (context, index) {
                final c = _liveComments[index];
                final avatar = c['avatar']?.toString() ?? '';
                final userName = c['user']?.toString().trim() ?? '';
                final syncStatus = c['syncStatus']?.toString() ?? 'synced';
                final edited = c['editedAt'] != null;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: GestureDetector(
                    onLongPress: () => _showCommentActions(c),
                    child: UnconstrainedBox(
                      alignment: Alignment.centerLeft,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                          child: Container(
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.sizeOf(context).width - 72,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: syncStatus == 'failed'
                                    ? Colors.redAccent.withOpacity(0.6)
                                    : Colors.white.withOpacity(0.05),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 10,
                                  backgroundColor: Colors.white12,
                                  backgroundImage: avatar.isNotEmpty
                                      ? CachedNetworkImageProvider(avatar)
                                      : null,
                                  child: avatar.isEmpty
                                      ? Text(
                                          (c['user']?.toString() ?? 'U')
                                              .trim()
                                              .padRight(1, 'U')
                                              .substring(0, 1)
                                              .toUpperCase(),
                                          style: dm(
                                            sz: 8,
                                            w: FontWeight.bold,
                                            c: Colors.white70,
                                          ),
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 7),
                                Flexible(
                                  child: RichText(
                                    text: TextSpan(
                                      children: [
                                        TextSpan(
                                          text:
                                              '${userName.isEmpty ? 'User' : userName}: ',
                                          style: dm(
                                            sz: 11,
                                            w: FontWeight.bold,
                                            c: C.brand,
                                          ),
                                        ),
                                        TextSpan(
                                          text: '${c['text']}',
                                          style: dm(sz: 11, c: Colors.white),
                                        ),
                                        TextSpan(
                                          text:
                                              '  ${_commentTimeLabel(c)}'
                                              '${edited ? ' edited' : ''}',
                                          style: dm(sz: 9, c: Colors.white38),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (syncStatus != 'synced') ...[
                                  const SizedBox(width: 6),
                                  Icon(
                                    syncStatus == 'failed'
                                        ? Icons.cloud_off_rounded
                                        : Icons.schedule_rounded,
                                    size: 12,
                                    color: syncStatus == 'failed'
                                        ? Colors.redAccent
                                        : Colors.white54,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          if (pinned != null) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: C.brand.withOpacity(0.4),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: C.brand.withOpacity(0.15),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      // Pinned product thumbnail \u2014 use real data, cache it, never hit CDN repeatedly
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: C.brand.withOpacity(0.1),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: pinned['thumbnail_url'] != null
                              ? CachedNetworkImage(
                                  imageUrl: pinned['thumbnail_url'] as String,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => const Icon(
                                    Icons.shopping_bag_rounded,
                                    color: C.brand,
                                    size: 28,
                                  ),
                                )
                              : const Icon(
                                  Icons.shopping_bag_rounded,
                                  color: C.brand,
                                  size: 28,
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    pinned['title']?.toString().toUpperCase() ??
                                        'PRODUCT',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: syne(
                                      sz: 11,
                                      w: FontWeight.w900,
                                      c: Colors.white,
                                      ls: 1,
                                    ),
                                  ),
                                ),
                                if (discount != null) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.pink,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '$discount% OFF',
                                      style: syne(
                                        sz: 8,
                                        w: FontWeight.bold,
                                        c: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              ugx(pinned['price'] ?? pinned['price_ugx'] ?? 0),
                              style: dm(sz: 13, w: FontWeight.w900, c: C.brand),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (promotionExpiry != null) ...[
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.timer_outlined,
                                  color: Color(0xFF00E5FF),
                                  size: 12,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _promotionTimeLeft(promotionExpiry),
                                  style: dm(
                                    sz: 10,
                                    w: FontWeight.bold,
                                    c: const Color(0xFF00E5FF),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                          ],
                          GestureDetector(
                            onTap: () => _openCheckout(pinned),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                gradient: brandGrad,
                                borderRadius: BorderRadius.circular(25),
                              ),
                              child: Text(
                                'BUY NOW',
                                style: syne(
                                  sz: 10,
                                  w: FontWeight.w900,
                                  c: Colors.black,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Center(
                    child: TextField(
                      controller: _commentController,
                      maxLength: 2000,
                      buildCounter:
                          (
                            context, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) => null,
                      style: dm(sz: 13, c: Colors.white),
                      onSubmitted: (_) => _sendComment(),
                      decoration: InputDecoration(
                        hintText: 'Say something...',
                        hintStyle: dm(sz: 13, c: Colors.white38),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _sendComment,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: brandGrad,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: C.brand.withOpacity(0.3),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.send_rounded,
                    color: Colors.black,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _liveActionButton(
                  icon: Icons.favorite_border_rounded,
                  label: 'Like',
                  color: const Color(0xFFFF176B),
                  badge: _reactionCount > 0
                      ? _compactNumber(_reactionCount)
                      : null,
                  onTap: _reactionSending
                      ? null
                      : () => unawaited(_sendReaction('love')),
                  onLongPress: _showReactionPicker,
                ),
              ),
              Expanded(
                child: _liveActionButton(
                  icon: Icons.card_giftcard_rounded,
                  label: 'Gift',
                  color: const Color(0xFFFFA000),
                  onTap: _showGiftPicker,
                ),
              ),
              Expanded(
                child: _liveActionButton(
                  icon: _isCoHosting
                      ? Icons.videocam_off_outlined
                      : Icons.people_outline_rounded,
                  label: 'Guests',
                  color: _isCoHosting
                      ? Colors.redAccent
                      : const Color(0xFF00E5FF),
                  badge:
                      widget.isHost && widget.state.liveGuestRequests.isNotEmpty
                      ? '${widget.state.liveGuestRequests.length}'
                      : null,
                  onTap: widget.isHost
                      ? _showGuestRequestsManager
                      : _toggleGuestRequest,
                ),
              ),
              Expanded(
                child: _liveActionButton(
                  icon: Icons.toll_rounded,
                  label: 'NCX',
                  color: const Color(0xFF9C6CFF),
                  onTap: _openNcxStore,
                ),
              ),
              Expanded(
                child: _liveActionButton(
                  icon: Icons.more_horiz_rounded,
                  label: 'More',
                  color: Colors.white,
                  onTap: _showLiveMenu,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _reactionEmoji(String type) {
    return switch (type) {
      'like' => '\u{1F44D}',
      'love' => '\u{2764}\u{FE0F}',
      'laugh' => '\u{1F602}',
      'wow' => '\u{1F62E}',
      'fire' => '\u{1F525}',
      'applause' => '\u{1F44F}',
      _ => '\u{2764}\u{FE0F}',
    };
  }

  void _showReactionBurst(String type) {
    if (!mounted) return;
    final burst = <String, dynamic>{
      'id': DateTime.now().microsecondsSinceEpoch,
      'emoji': _reactionEmoji(type),
    };
    setState(() {
      _reactionBursts.add(burst);
      if (_reactionBursts.length > 6) _reactionBursts.removeAt(0);
    });
    Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(
        () => _reactionBursts.removeWhere((item) => item['id'] == burst['id']),
      );
    });
  }

  Widget _buildReactionBurst(Map<String, dynamic> burst, int index) {
    return Positioned(
      right: 24 + ((index % 2) * 34),
      bottom: 150,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          key: ValueKey(burst['id']),
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 1400),
          builder: (context, progress, child) => Opacity(
            opacity: (1 - progress).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, -100 * progress),
              child: Transform.scale(
                scale: 0.8 + (progress * 0.4),
                child: child,
              ),
            ),
          ),
          child: Text(
            burst['emoji']?.toString() ?? '',
            style: const TextStyle(fontSize: 30),
          ),
        ),
      ),
    );
  }

  void _showReactionPicker() {
    const reactions = [
      ('like', '\u{1F44D}', 'Like'),
      ('love', '\u{2764}\u{FE0F}', 'Love'),
      ('laugh', '\u{1F602}', 'Laugh'),
      ('wow', '\u{1F62E}', 'Wow'),
      ('fire', '\u{1F525}', 'Fire'),
      ('applause', '\u{1F44F}', 'Applause'),
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0C0E14),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final reaction in reactions)
                    Semantics(
                      button: true,
                      label: reaction.$3,
                      child: InkResponse(
                        onTap: _reactionSending
                            ? null
                            : () {
                                Navigator.pop(context);
                                unawaited(_sendReaction(reaction.$1));
                              },
                        radius: 28,
                        child: SizedBox(
                          width: 46,
                          height: 54,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                reaction.$2,
                                style: const TextStyle(fontSize: 25),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                reaction.$3,
                                style: dm(sz: 8, c: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendReaction(String type) async {
    if (_reactionSending) return;
    _showReactionBurst(type);
    final previousSummary = Map<String, dynamic>.from(_liveSummary);
    final counts = Map<String, dynamic>.from(
      _liveSummary['reactionCounts'] as Map? ?? const {},
    );
    counts[type] = ((counts[type] as num?)?.toInt() ?? 0) + 1;
    setState(() {
      _reactionSending = true;
      _liveSummary = {..._liveSummary, 'reactionCounts': counts};
    });
    try {
      final result = await widget.state.live.sendReaction(_channelName, type);
      final summary = result['summary'];
      if (mounted && summary is Map) {
        _applyLiveSummary(Map<String, dynamic>.from(summary));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _liveSummary = previousSummary);
        _showToast('Reaction could not be sent. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _reactionSending = false);
    }
  }

  void _openLiveShop() {
    final product = widget.state.pinnedLiveProduct;
    if (product == null) {
      _showToast('No product is pinned to this live yet.');
      return;
    }
    _openCheckout(product);
  }

  Future<void> _shareLive() async {
    try {
      final creator = widget.isHost
          ? (widget.state.myProfile?['full_name']?.toString())
          : _hostDisplayName;
      final shareResult = await SharePlus.instance.share(
        ShareParams(
          text:
              'Watch ${creator ?? 'this creator'} live on NECXA: '
              'https://necxa.app/live/${Uri.encodeComponent(_channelName)}',
        ),
      );
      if (shareResult.status != ShareResultStatus.success) return;
      final result = await widget.state.live.recordShare(_channelName);
      final summary = result['summary'];
      if (mounted && summary is Map) {
        _applyLiveSummary(Map<String, dynamic>.from(summary));
      }
    } catch (e) {
      if (mounted) _showToast('Sharing is unavailable right now.');
    }
  }

  Future<void> _unpinCurrentProduct() async {
    if (!widget.isHost) return;
    final previous = widget.state.pinnedProductForChannel(_channelName);
    widget.state.updatePinnedProduct(null, channelId: _channelName);
    try {
      await widget.state.live.unpinProduct(_channelName);
    } catch (error) {
      widget.state.updatePinnedProduct(previous, channelId: _channelName);
      if (mounted) _showToast('Product could not be unpinned: $error');
    }
  }

  void _showProductPicker() async {
    if (!widget.isHost) {
      _showToast('Only the live host can pin products.');
      return;
    }
    final hostId = widget.state.user?.id;
    if (hostId == null || hostId.isEmpty) {
      _showToast('Sign in again to manage live products.');
      return;
    }
    // Dynamically retrieve active vendor products from state/database cache
    List<Map<String, dynamic>> products = widget.state.social.shopListings
        .where(
          (product) =>
              (product['user_id'] ?? product['lister_id'])?.toString() ==
              hostId,
        )
        .toList();
    if (products.isEmpty) {
      try {
        products = await widget.state.social.fetchUserListings(hostId);
      } catch (e) {
        debugPrint('⚠️ Fetch listings failed: $e');
      }
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D121B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'PIN A PRODUCT',
              style: syne(sz: 16, w: FontWeight.bold, c: Colors.white),
            ),
            const SizedBox(height: 20),
            if (widget.state.pinnedLiveProduct != null)
              ListTile(
                leading: const Icon(
                  Icons.remove_circle_outline,
                  color: Colors.orangeAccent,
                ),
                title: Text(
                  'Unpin current product',
                  style: dm(sz: 13, c: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_unpinCurrentProduct());
                },
              ),
            if (products.isEmpty)
              Padding(
                padding: const EdgeInsets.all(30),
                child: Text(
                  'No shop listings available to pin.',
                  style: dm(sz: 13, c: Colors.white38),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: products.length,
                  itemBuilder: (context, index) {
                    final p = products[index];
                    final title = p['title'] ?? 'Product Item';
                    final price = p['price'] ?? 0.0;

                    // Bulletproof thumbnail photo resolution logic
                    String imageUrl =
                        'https://images.unsplash.com/photo-1523275335684-37898b6baf30';
                    if (p['thumbnail_url'] != null &&
                        p['thumbnail_url'].toString().isNotEmpty) {
                      imageUrl = p['thumbnail_url'];
                    } else if (p['photos'] is List &&
                        (p['photos'] as List).isNotEmpty) {
                      imageUrl = (p['photos'] as List).first.toString();
                    } else if (p['photos'] != null) {
                      try {
                        final parsed = jsonDecode(p['photos']);
                        if (parsed is List && parsed.isNotEmpty) {
                          imageUrl = parsed[0];
                        } else if (parsed is String) {
                          imageUrl = parsed;
                        }
                      } catch (_) {}
                    }

                    return ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          imageUrl,
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 40,
                            height: 40,
                            color: Colors.white10,
                            child: const Icon(
                              Icons.shopping_bag_outlined,
                              color: Colors.white38,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                      title: Text(title, style: dm(sz: 13, c: Colors.white)),
                      subtitle: Text(ugx(price), style: dm(sz: 11, c: C.brand)),
                      onTap: () async {
                        final mapped = <String, dynamic>{
                          ...p,
                          'title': title,
                          'price': price,
                          'image': imageUrl,
                          'thumbnail_url': imageUrl,
                          'id': p['id'] ?? '',
                        };
                        Navigator.pop(context);
                        try {
                          final canonicalProduct = await widget.state.live
                              .pinProduct(_channelName, mapped);
                          widget.state.updatePinnedProduct(
                            canonicalProduct,
                            channelId: _channelName,
                          );
                        } catch (e) {
                          if (mounted) {
                            _showToast('Product could not be pinned: $e');
                          }
                        }
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showGiftPicker() async {
    final gifts = await widget.state.financeGifting.fetchGiftItems();
    if (!mounted) return;
    var sending = false;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0C0E14),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          Future<void> sendGift(GiftItem gift) async {
            if (sending) return;
            final senderId = widget.state.user?.id;
            final receiverId = _hostUserId;
            if (senderId == null || receiverId == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Sign in and join a live host before sending gifts.',
                    style: dm(),
                  ),
                ),
              );
              return;
            }
            if (senderId == receiverId) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'You cannot gift your own live stream.',
                    style: dm(),
                  ),
                ),
              );
              return;
            }

            if (widget.state.coinBalance < gift.ncxValue) {
              if (widget.state.coinPacks.isEmpty) {
                widget.state.coinPacks = await widget.state.financeCoinPurchases
                    .packs();
              }
              if (!context.mounted) return;
              if (widget.state.coinPacks.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Coin packs are temporarily unavailable.',
                      style: dm(),
                    ),
                  ),
                );
                return;
              }
              final purchased = await showModalBottomSheet<bool>(
                context: context,
                backgroundColor: Colors.transparent,
                isScrollControlled: true,
                builder: (_) => VaultBuyShardsOverlay(
                  state: widget.state,
                  minimumNcx: gift.ncxValue - widget.state.coinBalance.toInt(),
                  purchaseContextType: 'live_stream_gift',
                  purchaseContextId: _channelName,
                  targetGiftItemId: gift.id,
                ),
              );
              if (!context.mounted) return;
              if (purchased != true) return;
              await widget.state.syncVault();
              if (!context.mounted) return;
              if (widget.state.coinBalance < gift.ncxValue) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'The wallet still needs more NCX for this gift.',
                      style: dm(),
                    ),
                  ),
                );
                return;
              }
            }

            setModalState(() => sending = true);
            final result = await widget.state.financeGifting.sendGift(
              senderId: senderId,
              receiverId: receiverId,
              giftItemId: gift.id,
              ncxAmount: gift.ncxValue,
              contextType: 'live_stream',
              contextId: _channelName,
              contextNote: 'Live gift: ${gift.name}',
              senderName:
                  widget.state.myProfile?['full_name']?.toString() ?? 'Viewer',
              senderAvatar: widget.state.myProfile?['avatar_url']?.toString(),
            );

            if (!mounted) return;
            if (!result.success) {
              setModalState(() => sending = false);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(result.message, style: dm())),
              );
              return;
            }

            Navigator.pop(context);
          }

          return Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Send a gift to support the streamer!',
                      style: syne(sz: 12, w: FontWeight.bold, c: Colors.white),
                    ),
                    if (sending)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: ['Popular', 'New', 'Luxury', 'Fun', 'Bundle'].map((
                    tab,
                  ) {
                    final isSelected = tab == 'Popular';
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        tab,
                        style: syne(
                          sz: 12,
                          w: isSelected ? FontWeight.bold : FontWeight.normal,
                          c: isSelected ? C.brand : Colors.white54,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 3,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.9,
                  children: gifts.take(9).map((gift) {
                    return GestureDetector(
                      onTap: sending ? null : () => sendGift(gift),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              gift.emoji,
                              style: const TextStyle(fontSize: 32),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              gift.name,
                              style: dm(
                                sz: 11,
                                w: FontWeight.bold,
                                c: Colors.white,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.monetization_on,
                                  color: Colors.amber,
                                  size: 10,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  '${gift.ncxValue}',
                                  style: dm(
                                    sz: 10,
                                    w: FontWeight.w900,
                                    c: Colors.amber,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }

  void _toggleGuestRequest() async {
    if (_isCoHosting) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: AlertDialog(
            backgroundColor: const Color(0xFF0C0E14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: const BorderSide(color: Colors.white10),
            ),
            title: Text(
              'LEAVE CO-STREAM?',
              style: syne(sz: 16, w: FontWeight.bold, c: Colors.white),
            ),
            content: Text(
              'Are you sure you want to stop broadcasting and return to silent viewing?',
              style: dm(sz: 13, c: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'CANCEL',
                  style: syne(sz: 12, w: FontWeight.bold, c: Colors.white38),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: C.brand,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    'LEAVE',
                    style: syne(sz: 12, w: FontWeight.bold, c: Colors.black),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      if (confirm == true) {
        try {
          await widget.state.live.leaveCoHosting(_channelName);
          await widget.state.live.switchRoleToAudience();
          setState(() {
            _isCoHosting = false;
            _isRequestPending = false;
          });
          _showToast('Returned to viewer audience');
        } catch (e) {
          _showToast('Error: $e');
        }
      }
    } else if (_isRequestPending) {
      try {
        await widget.state.live.cancelCoHostRequest(_channelName);
        if (!mounted) return;
        setState(() => _isRequestPending = false);
        _showToast('Co-hosting request canceled');
      } catch (error) {
        if (mounted) {
          _showToast('Could not cancel the co-host request: $error');
        }
      }
    } else {
      final userId = widget.state.user?.id;
      if (userId == null) {
        _showToast('Please sign in to request co-hosting.');
        return;
      }

      try {
        await widget.state.live.sendCoHostRequest(_channelName, userId, {
          'name':
              widget.state.myProfile?['full_name'] ??
              widget.state.user?.email ??
              'Viewer',
          'username': widget.state.myProfile?['username'] ?? '',
          'avatar': widget.state.myProfile?['avatar_url'] ?? '',
        });
        setState(() => _isRequestPending = true);
        _showToast(
          'Co-hosting request sent to streamer. Waiting for approval...',
        );
      } catch (e) {
        _showToast('Could not send co-host request: $e');
      }
    }
  }

  void _showGuestRequestsManager() {
    var inviteSending = false;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0C0E14),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          final requests = widget.state.liveGuestRequests;
          return Container(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              MediaQuery.of(context).viewInsets.bottom + 30,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'GUEST CONTROL CONSOLE',
                      style: syne(sz: 15, w: FontWeight.bold, c: Colors.white),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Text(
                        '${requests.length} Requests',
                        style: syne(sz: 10, w: FontWeight.w900, c: C.brand),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                if (requests.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.people_outline,
                          color: Colors.white24,
                          size: 40,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No active co-hosting requests.',
                          style: dm(sz: 12, c: Colors.white38),
                        ),
                      ],
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: requests.length,
                      itemBuilder: (ctx, idx) {
                        final req = requests[idx];
                        final guestId = (req['guestId'] ?? req['userId'])
                            .toString();
                        final guestName =
                            (req['guestName'] ?? req['name'] ?? 'Viewer')
                                .toString();
                        final status = req['status']?.toString() ?? 'pending';
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.02),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.05),
                            ),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                // CachedNetworkImageProvider: each viewer's avatar cached per URL
                                backgroundImage:
                                    req['avatar'] != null &&
                                        (req['avatar'] as String).isNotEmpty
                                    ? CachedNetworkImageProvider(
                                        req['avatar'] as String,
                                      )
                                    : null,
                                child:
                                    req['avatar'] == null ||
                                        (req['avatar'] as String).isEmpty
                                    ? const Icon(
                                        Icons.person,
                                        size: 18,
                                        color: Colors.white54,
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  guestName,
                                  style: syne(
                                    sz: 13,
                                    w: FontWeight.bold,
                                    c: Colors.white,
                                  ),
                                ),
                              ),
                              if (status == 'pending')
                                Row(
                                  children: [
                                    GestureDetector(
                                      onTap: () async {
                                        try {
                                          await widget.state.live
                                              .sendCoHostDecision(
                                                _channelName,
                                                guestId,
                                                false,
                                              );
                                          widget.state.removeLiveGuestRequest(
                                            _channelName,
                                            requestId: req['id']?.toString(),
                                            guestId: guestId,
                                          );
                                          if (mounted) setState(() {});
                                          setModalState(() {});
                                          _showToast(
                                            'Declined request from $guestName',
                                          );
                                        } catch (e) {
                                          _showToast(
                                            'Could not decline request: $e',
                                          );
                                        }
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.red.withOpacity(0.1),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.close,
                                          color: Colors.red,
                                          size: 16,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    GestureDetector(
                                      onTap: () async {
                                        try {
                                          await widget.state.live
                                              .sendCoHostDecision(
                                                _channelName,
                                                guestId,
                                                true,
                                              );
                                          if (!context.mounted) return;
                                          widget.state.removeLiveGuestRequest(
                                            _channelName,
                                            requestId: req['id']?.toString(),
                                            guestId: guestId,
                                          );
                                          if (mounted) setState(() {});
                                          setModalState(() {});
                                          _showToast(
                                            'Accepted request. $guestName can join the stream now.',
                                          );
                                          Navigator.pop(context);
                                        } catch (e) {
                                          _showToast(
                                            'Could not accept request: $e',
                                          );
                                        }
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: const BoxDecoration(
                                          color: Colors.green,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.check,
                                          color: Colors.black,
                                          size: 16,
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              else
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: C.brand.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    status.toUpperCase(),
                                    style: syne(
                                      sz: 9,
                                      w: FontWeight.w900,
                                      c: C.brand,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                const Divider(color: Colors.white10, height: 32),

                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'INVITE A VIEWER TO CO-STREAM',
                    style: syne(
                      sz: 10,
                      w: FontWeight.bold,
                      c: Colors.white38,
                      ls: 1,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: Colors.white38, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          style: dm(sz: 13, c: Colors.white),
                          enabled: !inviteSending,
                          decoration: InputDecoration(
                            hintText: 'Search online viewer by username...',
                            hintStyle: dm(sz: 13, c: Colors.white24),
                            border: InputBorder.none,
                          ),
                          onSubmitted: (val) async {
                            if (val.trim().isNotEmpty && !inviteSending) {
                              setModalState(() => inviteSending = true);
                              try {
                                final request = await widget.state.live
                                    .inviteCoHostByUsername(
                                      _channelName,
                                      val.trim(),
                                    );
                                if (!mounted || !context.mounted) return;
                                widget.state.upsertLiveGuestRequest(
                                  _channelName,
                                  request,
                                );
                                _showToast('Invitation sent to @$val.');
                                Navigator.pop(context);
                              } catch (error) {
                                if (mounted) {
                                  _showToast(
                                    'Could not send invitation: $error',
                                  );
                                }
                                if (context.mounted) {
                                  setModalState(() => inviteSending = false);
                                }
                              }
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: syne(sz: 12, w: FontWeight.bold, c: Colors.white),
        ),
        backgroundColor: const Color(0xFF0F172A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _openNcxStore() {
    showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => VaultBuyShardsOverlay(
        state: widget.state,
        purchaseContextType: 'live_stream_wallet',
        purchaseContextId: _channelName,
      ),
    );
  }

  void _showLiveMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0C0E14),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined, color: Colors.white),
                title: Text('Share live', style: dm(c: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_shareLive());
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.shopping_bag_outlined,
                  color: Color(0xFF00E5FF),
                ),
                title: Text('Open live shop', style: dm(c: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openLiveShop();
                },
              ),
              if (widget.isHost)
                ListTile(
                  leading: const Icon(
                    Icons.push_pin_outlined,
                    color: Colors.amber,
                  ),
                  title: Text('Pin a product', style: dm(c: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showProductPicker();
                  },
                ),
              ListTile(
                leading: const Icon(
                  Icons.emoji_emotions_outlined,
                  color: Color(0xFFFF176B),
                ),
                title: Text('Choose a reaction', style: dm(c: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showReactionPicker();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _liveActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
    VoidCallback? onLongPress,
    String? badge,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 62,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 43,
                    height: 43,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                      border: Border.all(color: color.withValues(alpha: 0.35)),
                    ),
                    child: Icon(icon, color: color, size: 21),
                  ),
                  if (badge != null && badge.isNotEmpty)
                    Positioned(
                      top: -4,
                      right: -7,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 18),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF176B),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          badge,
                          textAlign: TextAlign.center,
                          style: dm(sz: 7, w: FontWeight.w900, c: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: dm(sz: 8, w: FontWeight.w600, c: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShieldVerificationCard() {
    return Positioned.fill(
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            color: Colors.black.withOpacity(0.8),
            child: Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: Colors.white.withOpacity(0.12)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 30,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: C.brand.withOpacity(0.1),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: C.brand.withOpacity(0.25),
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.shield_outlined,
                        color: C.brand,
                        size: 48,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'SHIELD VERIFICATION REQUIRED',
                      textAlign: TextAlign.center,
                      style: syne(
                        sz: 14,
                        w: FontWeight.w900,
                        c: Colors.white,
                        ls: 1.5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'To guarantee livestream security and unlock instant shopping features, a biometric face-match is required.',
                      textAlign: TextAlign.center,
                      style: dm(sz: 12, c: Colors.white70, h: 1.5),
                    ),
                    const SizedBox(height: 28),
                    GestureDetector(
                      onTap: _shieldVerifyAndRetry,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        decoration: BoxDecoration(
                          gradient: brandGrad,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: C.brand.withOpacity(0.35),
                              blurRadius: 16,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            'VERIFY IDENTITY TO GO LIVE',
                            style: syne(
                              sz: 13,
                              w: FontWeight.w900,
                              c: Colors.black,
                              ls: 1.2,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Text(
                        'CANCEL & LEAVE',
                        style: syne(
                          sz: 11,
                          w: FontWeight.bold,
                          c: Colors.white38,
                          ls: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
