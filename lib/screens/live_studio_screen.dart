import 'package:livekit_client/livekit_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../services/filter_catalogue_service.dart';
import '../effects_engine/necxa_effects_engine.dart';

enum _GuestJoinMode { video, audioOnly }

class LiveStudioScreen extends StatefulWidget {
  final AppState state;
  final String channelName;
  final bool isHost;
  final String? hostId;
  final String? hostName;
  final String? hostAvatar;

  const LiveStudioScreen({
    super.key,
    required this.state,
    required this.channelName,
    this.isHost = false,
    this.hostId,
    this.hostName,
    this.hostAvatar,
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
  bool _greenRoomNormalZoom = true;

  String get _hostDisplayName {
    final backendName = _liveSummary['hostName']?.toString().trim() ?? '';
    if (backendName.isNotEmpty) return backendName;
    final String? candidate;
    if (widget.isHost) {
      candidate = widget.state.myDisplayName;
    } else {
      candidate = widget.hostName;
    }
    final normalized = candidate?.trim() ?? '';
    return normalized.isEmpty ? 'Necxa Creator' : normalized;
  }

  String get _hostAvatar {
    final backendAvatar = _liveSummary['hostAvatar']?.toString().trim() ?? '';
    if (backendAvatar.isNotEmpty) return backendAvatar;
    final String? candidate;
    if (widget.isHost) {
      candidate = widget.state.myAvatarUrl;
    } else {
      candidate = widget.hostAvatar;
    }
    return candidate?.trim() ?? '';
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
  bool _guestJoinChoiceVisible = false;
  bool _guestVideoEnabled = true;
  bool _guestAudioEnabled = true;
  bool _hostInGreenRoom = false;
  bool _startingBroadcast = false;
  bool _faceSymmetryProcessorAttached = false;
  Timer? _faceSymmetryUpdateTimer;
  static const MethodChannel _faceSymmetryChannel =
      MethodChannel('com.necxa/live_beauty');
  bool _isFrontCamera = true; // green room starts front-facing
  // ── Green Room Effects & Smart Filter Catalogue ───────────────────────────
  int _activeFilterIndex = 0; // 0 = Normal (no tint)
  double _beautySmoothing = 0.0; // 0..1
  int _skinSmoothingMode = 0; // 0=Natural, 1=Radiant, 2=Matte
  double _beautyWhitening = 0.0; // 0..1
  int _skinBrighteningTone = 0; // 0=Warm Glow, 1=Cool Porcelain, 2=Natural Fresh
  int _makeupGender = 0; // 0=Off, 1=Women, 2=Men
  int _makeupStyle = 0; // 0=Natural/Groomed, 1=Radiant/Contour, 2=Glam/SunKissed
  double _makeupIntensity = 0.6; // 0..1
  double _faceSymmetry = 0.0; // 0..1
  bool _symmetryMirrorLeft = true; // true = mirror left side onto right, false = right onto left
  bool _showSymmetryGuide = true; // show alignment axis when symmetry > 0
  bool _mirrorMode = false;
  bool _showGrid = false;
  bool _noiseSuppression = true;

  // NECXA Smart Filter Library integration
  List<NecxaFilterMeta> _catalogueFilters = [];
  NecxaFilterMeta? _activeCatalogueFilter;
  double _catalogueFilterIntensity = 1.0;
  bool _loadingCatalogue = false;
  bool _previewOriginal = false; // true during hold to compare
  String _activeCategoryTab = 'All';
  int _effectsPanelTab = 0; // 0 = Smart Filters, 1 = Beauty Retouch
  // ──────────────────────────────────────────────────────────────────────────
  DateTime? _plannedBroadcastTime;
  final TextEditingController _liveTitleController = TextEditingController();
  String _liveGoal = '';
  int _greenRoomModeIndex = 1; // 0=Flip, 1=Camera, 2=Voice, 3=Gaming
  bool _isFlippingCamera = false;
  bool _isFocusingCamera = false;
  bool _isStudioPinned = false;
  bool _isSwitchingMode = false;
  String? _selectedMusicTrack;
  final Set<String> _moderatorGuestIds = <String>{};
  final List<Map<String, dynamic>> _reactionBursts = [];

  // -- Smart Live Verification State --------------------------------------
  // Silent background face pulse timer � fires every 5 minutes while live as host.
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
  String? get _hostUserId {
    final backendHostId = _liveSummary['hostId']?.toString().trim() ?? '';
    if (backendHostId.isNotEmpty) return backendHostId;
    return widget.hostId ?? (widget.isHost ? widget.state.user?.id : null);
  }

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
    unawaited(_loadFilterCatalogue());
    if (mounted) await _initLiveKit();
  }

  Future<void> _loadFilterCatalogue() async {
    if (mounted) setState(() => _loadingCatalogue = true);
    try {
      final filters = await FilterCatalogueService.loadCatalogue();
      if (mounted) {
        setState(() {
          _catalogueFilters = filters;
        });
      }
    } catch (e) {
      debugPrint('[LiveStudio] Catalogue load failed: $e');
    } finally {
      if (mounted) setState(() => _loadingCatalogue = false);
    }
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
    } else if (type == 'guest_moderator_changed') {
      final moderatorIds = (data['moderatorIds'] as List? ?? const [])
          .map((id) => id.toString())
          .toSet();
      if (mounted) setState(() {
        _moderatorGuestIds
          ..clear()
          ..addAll(moderatorIds);
      });
      if (guestId == widget.state.user?.id) {
        _showToast(
          data['isModerator'] == true
              ? 'You are now a live moderator.'
              : 'Your live moderator role was removed.',
        );
      }
    } else if (type == 'guest_removed') {
      if (widget.isHost) {
        widget.state.removeLiveGuestRequest(
          _channelName,
          requestId: data['requestId']?.toString(),
          guestId: guestId,
        );
      }
      if (guestId == widget.state.user?.id) {
        unawaited(_returnToAudienceAfterRemoval());
      }
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
          style: syne(sz: 16, w: FontWeight.bold, c: C.text),
        ),
        content: Text(
          'The host invited you to join this live with your camera and microphone.',
          style: dm(sz: 13, c: C.sub),
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
      _moderatorGuestIds
        ..clear()
        ..addAll(
          (summary['moderatorIds'] as List? ?? const [])
              .map((id) => id.toString()),
        );
    });
  }

  Future<void> _returnToAudienceAfterRemoval() async {
    try {
      await widget.state.live.switchRoleToAudience();
      if (!mounted) return;
      setState(() {
        _isCoHosting = false;
        _isRequestPending = false;
        _moderatorGuestIds.remove(widget.state.user?.id);
      });
      _showToast('The host removed you from the guest stage.');
    } catch (error) {
      debugPrint('Necxa Live: Could not return removed guest to audience: $error');
    }
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
        debugPrint('?? Sync Comments failed: $e');
      }
    });
  }

  // ignore: unused_element
  void _legacySendComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    _commentController.clear();

    // Optimistic local update
    final myName = widget.state.myDisplayName ?? 'Viewer';
    setState(() {
      _liveComments.insert(0, {'user': myName, 'text': text});
    });

    try {
      await widget.state.live.sendLiveComment(_channelName, myName, text);
    } catch (e) {
      debugPrint('?? Send Comment failed: $e');
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
    final myName = widget.state.myDisplayName ?? 'Viewer';
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

  Map<String, dynamic>? _commentOwnerPresence(Map<String, dynamic> comment) {
    final userId = comment['userId']?.toString();
    if (userId == null || userId.isEmpty) return null;
    for (final viewer in _activeViewers) {
      if (viewer['userId']?.toString() == userId) return viewer;
    }
    return null;
  }

  String _commentOwnerName(Map<String, dynamic> comment) {
    final userId = comment['userId']?.toString();
    if (userId != null && userId == widget.state.user?.id) {
      return widget.state.myDisplayName ??
          comment['userName']?.toString().trim() ??
          comment['user']?.toString().trim() ??
          'Necxa User';
    }
    if (userId != null && userId == _hostUserId) return _hostDisplayName;
    final presenceName =
        _commentOwnerPresence(comment)?['userName']?.toString().trim() ?? '';
    if (presenceName.isNotEmpty && presenceName != 'Viewer' && presenceName != 'User') {
      return presenceName;
    }
    final storedName =
        (comment['userName'] ?? comment['user'])?.toString().trim() ?? '';
    return storedName.isEmpty ? 'Necxa User' : storedName;
  }

  String _commentOwnerAvatar(Map<String, dynamic> comment) {
    final storedAvatar =
        (comment['avatar'] ?? comment['userAvatar'])?.toString().trim() ?? '';
    if (storedAvatar.isNotEmpty) return storedAvatar;
    final userId = comment['userId']?.toString();
    if (userId != null && userId == widget.state.user?.id) {
      return widget.state.myAvatarUrl ?? '';
    }
    if (userId != null && userId == _hostUserId) return _hostAvatar;
    return _commentOwnerPresence(comment)?['avatar']?.toString().trim() ?? '';
  }

  Future<void> _editComment(Map<String, dynamic> comment) async {
    final controller = TextEditingController(
      text: comment['text']?.toString() ?? '',
    );
    final updatedText = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        title: Text('Edit comment', style: syne(sz: 16, c: C.text)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 2000,
          style: dm(sz: 14, c: C.text),
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
                leading: Icon(Icons.sync_rounded, color: C.text),
                title: Text(
                  'Retry',
                  style: TextStyle(color: C.text),
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
                leading: Icon(Icons.edit_rounded, color: C.text),
                title: Text(
                  'Edit',
                  style: TextStyle(color: C.text),
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
                leading: Icon(Icons.flag_outlined, color: C.text),
                title: Text(
                  'Report',
                  style: TextStyle(color: C.text),
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
            if (_canModerateLive && !isMine && !isLocal)
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
        _channelName = await liveService.prepareStreaming(widget.channelName);
      } else {
        await liveService.joinAsViewer(_channelName);
      }

      if (!mounted) return;
      widget.state.setLiveChannel(_channelName, isHosting: widget.isHost);
      setState(() {
        _localUserJoined = true;
        _hostInGreenRoom = widget.isHost;
      });
      if (widget.isHost) unawaited(_resetCameraHardwareZoom());
      if (!widget.isHost) {
        _startChannelSync();
        await _syncLiveState();
        _eventCursor ??= '0';
        _startLiveEventSync();
      }
      _automaticAuthRetries = 0;

      // Setup room event listeners to trigger UI updates
      liveService.room?.removeListener(_onRoomDidUpdate);
      liveService.room?.addListener(_onRoomDidUpdate);

      // Once confirmed live as host, start silent periodic face pulse.
      if (widget.isHost && !_hostInGreenRoom) _startSilentFacePulse();
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

  // -- SMART LIVE VERIFICATION HELPERS ------------------------------------

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

  // -- SILENT BACKGROUND FACE PULSE ----------------------------------------

  /// Starts a periodic timer that silently captures a frame from the Agora engine
  /// and runs a background liveness check � zero UI disruption.
  void _startSilentFacePulse() {
    _facePulseTimer?.cancel();
    _facePulseTimer = Timer.periodic(
      _facePulseInterval,
      (_) => _runSilentFaceCheck(),
    );
    debugPrint(
      '??? Live: Silent face pulse started (every ${_facePulseInterval.inMinutes}m).',
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

      // 1. Liveness Check (Supabase � biometric composite model)

      // 2. Strict Content Safety Scan via Cloudflare Worker (Llama 3.2 Vision).
      // Falls back to safe() on any network error � stream is never killed
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
          '?? Live Safety Violation [$_consecutiveViolations]: ${safetyResult.severity} - ${safetyResult.reason}',
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
      debugPrint('??? Silent Pulse/Scan (non-fatal): $e');
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
    _faceSymmetryUpdateTimer?.cancel();
    final symmetryTrack = widget.state.live.room?.localParticipant
        ?.videoTrackPublications.firstOrNull?.track;
    if (_faceSymmetryProcessorAttached && symmetryTrack != null) {
      unawaited(_faceSymmetryChannel.invokeMethod<void>('detach', {
        'trackId': symmetryTrack.mediaStreamTrack.id,
      }).catchError((Object error) {
        debugPrint('Necxa Live: Face processor cleanup failed: $error');
      }));
    }
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
    _liveTitleController.dispose();
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
      debugPrint('??? Live Studio: App minimized, pausing AV & Timers');
    } else if (state == AppLifecycleState.resumed) {
      // Resume operations
      if (_localUserJoined && !_isEnforcementActive) {
        widget.state.live.setAVEnabled(true);
        _startCommentsSync();
        _startGiftStatsSync();
        _startPromotionClock();
        if (widget.isHost) _startSilentFacePulse();
        debugPrint('??? Live Studio: App resumed, restarting AV & Timers');
      }
    }
  }

  /// Flips the camera between front and back during the green room or live with concurrency protection.
  Future<void> _flipCamera() async {
    if (_isFlippingCamera) return;
    final localParticipant = widget.state.live.room?.localParticipant;
    if (localParticipant == null) {
      _showToast('Camera is initializing...');
      return;
    }
    final videoTrack =
        localParticipant.videoTrackPublications.firstOrNull?.track;
    if (videoTrack == null) {
      _showToast('No active camera track available');
      return;
    }
    _isFlippingCamera = true;
    try {
      HapticFeedback.lightImpact();
      final nextPosition =
          _isFrontCamera ? CameraPosition.back : CameraPosition.front;
      await videoTrack.setCameraPosition(nextPosition);
      if (mounted) {
        setState(() => _isFrontCamera = !_isFrontCamera);
        unawaited(_resetCameraHardwareZoom());
      }
    } catch (e) {
      debugPrint('Necxa Live: camera flip failed: $e');
      if (mounted) _showToast('Camera flip unavailable on this hardware');
    } finally {
      if (mounted) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) setState(() => _isFlippingCamera = false);
        });
      } else {
        _isFlippingCamera = false;
      }
    }
  }

  Future<void> _resetCameraHardwareZoom() async {
    try {
      final local = widget.state.live.room?.localParticipant;
      final videoTrack = local?.videoTrackPublications.firstOrNull?.track;
      if (videoTrack != null) {
        final dynamic mst = videoTrack.mediaStreamTrack;
        try {
          await mst.setZoom(1.0);
        } catch (_) {
          // Hardware setZoom unsupported on some devices
        }
      }
    } catch (e) {
      debugPrint('[LiveStudio] setZoom(1.0) failed or unsupported: $e');
    }
  }

  void _triggerFocusCamera() {
    if (_isFocusingCamera) return;
    HapticFeedback.selectionClick();
    setState(() => _isFocusingCamera = true);
    unawaited(_resetCameraHardwareZoom());
    _showToast('Camera focused and calibrated');
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (mounted) setState(() => _isFocusingCamera = false);
    });
  }

  Future<void> _selectGreenRoomMode(int index) async {
    if (_greenRoomModeIndex == index || _isSwitchingMode) return;
    HapticFeedback.selectionClick();
    setState(() {
      _greenRoomModeIndex = index;
      _isSwitchingMode = true;
    });

    try {
      final localParticipant = widget.state.live.room?.localParticipant;
      if (localParticipant != null) {
        final videoPub = localParticipant.videoTrackPublications.firstOrNull;
        if (index == 2) {
          // Voice mode: mute video publication
          await videoPub?.mute();
          _showToast('Voice mode: Camera muted, audio active');
        } else if (index == 1) {
          // Camera mode: unmute video publication
          await videoPub?.unmute();
          unawaited(_resetCameraHardwareZoom());
        } else if (index == 3) {
          // Gaming mode
          _showToast('Gaming mode ready: Audio + game screen ready for live');
        }
      }
    } catch (e) {
      debugPrint('[LiveStudio] Mode switch error: $e');
    } finally {
      if (mounted) setState(() => _isSwitchingMode = false);
    }
  }

  void _togglePinStudio() {
    HapticFeedback.selectionClick();
    setState(() => _isStudioPinned = !_isStudioPinned);
    _showToast(_isStudioPinned ? 'Studio dashboard pinned' : 'Studio dashboard unpinned');
  }

  void _openMusicPickerSheet() {
    HapticFeedback.mediumImpact();

    const tracks = <Map<String, dynamic>>[
      {'title': 'Trending Afrobeats', 'artist': 'Various Artists', 'duration': '3:12', 'icon': Icons.music_note},
      {'title': 'Lo-Fi Chill', 'artist': 'Lo-Fi Hub', 'duration': '4:05', 'icon': Icons.headphones},
      {'title': 'Hip-Hop Vibes', 'artist': 'Urban Collective', 'duration': '2:58', 'icon': Icons.album},
      {'title': 'Pop Hits Mix', 'artist': 'Top Charts', 'duration': '3:44', 'icon': Icons.queue_music},
      {'title': 'Afro Dance', 'artist': 'DJ Necxa', 'duration': '3:20', 'icon': Icons.graphic_eq},
      {'title': 'R&B Smooth', 'artist': 'Soul Station', 'duration': '4:18', 'icon': Icons.piano},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        String? localSelected = _selectedMusicTrack;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              decoration: BoxDecoration(
                color: const Color(0xF20D1017),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border.all(color: Colors.white12, width: 1.2),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Handle bar
                    Center(
                      child: Container(
                        width: 40, height: 4,
                        margin: const EdgeInsets.only(bottom: 18),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),

                    // Header
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color: const Color(0xFF7B2FFF).withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.library_music, color: Color(0xFF00E5FF), size: 20),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Live Music',
                              style: syne(sz: 16, w: FontWeight.w800, c: Colors.white),
                            ),
                            Text(
                              'Background music for your stream',
                              style: dm(sz: 11, c: Colors.white54),
                            ),
                          ],
                        ),
                        const Spacer(),
                        if (localSelected != null)
                          GestureDetector(
                            onTap: () {
                              HapticFeedback.lightImpact();
                              setLocal(() => localSelected = null);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                              ),
                              child: Text(
                                'Remove',
                                style: dm(sz: 11, w: FontWeight.w600, c: Colors.redAccent),
                              ),
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    // Track list
                    ...tracks.map((track) {
                      final title = track['title'] as String;
                      final isActive = localSelected == title;
                      return GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setLocal(() => localSelected = title);
                        },
                        behavior: HitTestBehavior.opaque,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          decoration: BoxDecoration(
                            color: isActive
                                ? const Color(0xFF7B2FFF).withValues(alpha: 0.22)
                                : Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isActive
                                  ? const Color(0xFF00E5FF).withValues(alpha: 0.55)
                                  : Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 38, height: 38,
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? const Color(0xFF7B2FFF).withValues(alpha: 0.35)
                                      : Colors.white.withValues(alpha: 0.08),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  track['icon'] as IconData,
                                  color: isActive ? const Color(0xFF00E5FF) : Colors.white54,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title,
                                      style: dm(
                                        sz: 13,
                                        w: isActive ? FontWeight.w700 : FontWeight.w500,
                                        c: isActive ? Colors.white : Colors.white70,
                                      ),
                                    ),
                                    Text(
                                      '${track['artist']}  •  ${track['duration']}',
                                      style: dm(sz: 10, c: Colors.white38),
                                    ),
                                  ],
                                ),
                              ),
                              if (isActive)
                                const Icon(Icons.check_circle, color: Color(0xFF00E5FF), size: 18),
                            ],
                          ),
                        ),
                      );
                    }),

                    const SizedBox(height: 16),

                    // Confirm button
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        Navigator.pop(ctx);
                        setState(() => _selectedMusicTrack = localSelected);
                        if (localSelected != null) {
                          _showToast('🎵 Now playing: $localSelected');
                        } else {
                          _showToast('Music removed from stream');
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(
                          gradient: localSelected != null
                              ? const LinearGradient(
                                  colors: [Color(0xFF7B2FFF), Color(0xFF00E5FF)],
                                )
                              : null,
                          color: localSelected == null ? Colors.white10 : null,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Center(
                          child: Text(
                            localSelected != null ? 'Set "$localSelected"' : 'No music selected',
                            style: syne(
                              sz: 13,
                              w: FontWeight.w800,
                              c: localSelected != null ? Colors.black : Colors.white38,
                              ls: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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

  String _plannedBroadcastLabel() {
    final scheduled = _plannedBroadcastTime;
    if (scheduled == null) return 'Start whenever you are ready';
    final localizations = MaterialLocalizations.of(context);
    final today = DateUtils.isSameDay(scheduled, DateTime.now());
    return '${today ? 'Today' : localizations.formatMediumDate(scheduled)} at '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(scheduled))}';
  }

  Future<void> _pickBroadcastTime() async {
    final now = DateTime.now();
    final initial = _plannedBroadcastTime?.isAfter(now) == true
        ? _plannedBroadcastTime!
        : now.add(const Duration(minutes: 5));
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 30)),
      initialDate: initial,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final selected = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!selected.isAfter(now) ||
        selected.difference(now) > const Duration(minutes: 30)) {
      _showToast('Choose a start time within the next 30 minutes.');
      return;
    }
    setState(() => _plannedBroadcastTime = selected);
  }

  Future<void> _startBroadcast() async {
    if (_startingBroadcast || !_hostInGreenRoom) return;
    setState(() => _startingBroadcast = true);
    try {
      await widget.state.live.beginBroadcast();
      if (!mounted) return;
      setState(() {
        _hostInGreenRoom = false;
        _plannedBroadcastTime = null;
      });
      _startChannelSync();
      await _syncLiveState();
      _eventCursor ??= '0';
      _startLiveEventSync();
      _startSilentFacePulse();
      _showToast('You are live. Your audience can now join.');
    } catch (error) {
      if (mounted) {
        _showToast('Could not start the broadcast: $error');
      }
    } finally {
      if (mounted) setState(() => _startingBroadcast = false);
    }
  }

  void _scheduleFaceSymmetryProcessing(double intensity) {
    _faceSymmetryUpdateTimer?.cancel();
    _faceSymmetryUpdateTimer = Timer(const Duration(milliseconds: 80), () async {
      final track = widget.state.live.room?.localParticipant
          ?.videoTrackPublications.firstOrNull?.track;
      if (track == null) return;
      final trackId = track.mediaStreamTrack.id;
      try {
        if (intensity <= 0.01) {
          if (!_faceSymmetryProcessorAttached) return;
          await _faceSymmetryChannel.invokeMethod<void>('detach', {
            'trackId': trackId,
          });
          _faceSymmetryProcessorAttached = false;
        } else if (_faceSymmetryProcessorAttached) {
          await _faceSymmetryChannel.invokeMethod<void>('setIntensity', {
            'trackId': trackId,
            'intensity': intensity,
            'mirrorLeft': _symmetryMirrorLeft,
          });
        } else {
          await _faceSymmetryChannel.invokeMethod<void>('attach', {
            'trackId': trackId,
            'intensity': intensity,
            'mirrorLeft': _symmetryMirrorLeft,
          });
          _faceSymmetryProcessorAttached = true;
        }
      } on PlatformException catch (error) {
        debugPrint('Necxa Live: Face symmetry processor unavailable: ${error.message}');
      } on MissingPluginException {
        debugPrint('Necxa Live: Face symmetry processor is not available on this platform.');
      } catch (error) {
        debugPrint('Necxa Live: Could not update face symmetry: $error');
      }
    });
  }

  Widget _buildHostGreenRoom() {
    final avatar = _hostAvatar;
    final topPadding = MediaQuery.paddingOf(context).top;

    final topGifter = _topGifter;
    final giftTotal = (_giftSummary['totalAmount'] as num?)?.toInt() ?? 0;
    final giftGoal = (_giftSummary['goalTarget'] as num?)?.toInt() ?? 100;
    final goalProgress = giftGoal <= 0
        ? 0.0
        : (giftTotal / giftGoal).clamp(0.0, 1.0);
    final topGifterName = topGifter?['senderName']?.toString().trim();
    final topGifterAmount = (topGifter?['amount'] as num?) ?? 0;

    return Positioned.fill(
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            // ── TOP SECTION: Status HUD (Host pill, LIVE, Pin, Close, Top Gifter, Goal, Music) ──
            Container(
              padding: EdgeInsets.fromLTRB(14, topPadding + 6, 14, 10),
              color: const Color(0xFF090D16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Row 1: Host identity capsule | LIVE pill | Pin | Exit X
                  Row(
                    children: [
                      // Host identity capsule
                      Expanded(
                        child: Container(
                          height: 44,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          child: Row(
                            children: [
                              // Avatar with glowing/gradient ring
                              Container(
                                width: 34,
                                height: 34,
                                padding: const EdgeInsets.all(1.5),
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    colors: [Color(0xFFFF176B), Color(0xFF00E5FF)],
                                  ),
                                ),
                                child: CircleAvatar(
                                  backgroundColor: const Color(0xFF242738),
                                  backgroundImage: avatar.isNotEmpty ? CachedNetworkImageProvider(avatar) : null,
                                  child: avatar.isEmpty
                                      ? Text(
                                          _hostDisplayName.isNotEmpty ? _hostDisplayName[0].toUpperCase() : 'H',
                                          style: dm(sz: 11, w: FontWeight.w900, c: Colors.white),
                                        )
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            _hostDisplayName.isNotEmpty ? _hostDisplayName : 'Your Live',
                                            style: syne(sz: 12, w: FontWeight.w800, c: Colors.white),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
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
                                    const SizedBox(height: 1),
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.visibility_outlined,
                                          color: Colors.white54,
                                          size: 11,
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          '$_viewerCount viewers',
                                          style: dm(sz: 9, c: Colors.white54),
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
                      const SizedBox(width: 8),

                      // Pink LIVE pill button
                      GestureDetector(
                        onTap: _startingBroadcast ? null : _startBroadcast,
                        child: Container(
                          height: 44,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF176B),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFFFF176B).withValues(alpha: 0.35),
                                blurRadius: 10,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'LIVE',
                            style: syne(sz: 13, w: FontWeight.w900, c: Colors.white, ls: 0.5),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Pin Button
                      GestureDetector(
                        onTap: _togglePinStudio,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _isStudioPinned
                                ? const Color(0xFF00E5FF).withValues(alpha: 0.18)
                                : Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: _isStudioPinned
                                  ? const Color(0xFF00E5FF)
                                  : Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            _isStudioPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                            color: _isStudioPinned ? const Color(0xFF00E5FF) : Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Exit X Button
                      GestureDetector(
                        onTap: _startingBroadcast ? null : _closeLiveStudio,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(Icons.close, color: Colors.white, size: 22),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Row 2: Top Gifter Pill & Goal Pill
                  Row(
                    children: [
                      // Top Gifter Pill
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            if (topGifterName == null || topGifterName.isEmpty) {
                              _showToast('Top supporter will be highlighted here in real-time');
                            } else {
                              _showLiveAudience();
                            }
                          },
                          child: Container(
                            height: 48,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.local_fire_department_rounded, color: Color(0xFFFF9100), size: 22),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        'TOP GIFTER',
                                        style: dm(sz: 8.5, w: FontWeight.w700, c: Colors.white54, ls: 0.4),
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        topGifterName != null && topGifterName.isNotEmpty
                                            ? '$topGifterName ($topGifterAmount)'
                                            : 'No gifts yet',
                                        style: syne(sz: 11, w: FontWeight.w600, c: Colors.white),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Goal Pill
                      Expanded(
                        child: GestureDetector(
                          onTap: _openGoalDialog,
                          child: Container(
                            height: 48,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.card_giftcard_rounded, color: Color(0xFFFFD700), size: 17),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'GOAL',
                                            style: dm(sz: 8.5, w: FontWeight.w700, c: Colors.white54, ls: 0.4),
                                          ),
                                          Text(
                                            '$giftTotal / $giftGoal NCX',
                                            style: syne(sz: 10.5, w: FontWeight.w700, c: Colors.white),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right_rounded, color: Colors.white54, size: 16),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: LinearProgressIndicator(
                                    value: goalProgress,
                                    minHeight: 2.5,
                                    backgroundColor: Colors.white12,
                                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF7B2FFF)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Row 3: Add music & get gifts banner
                  GestureDetector(
                    onTap: _openMusicPickerSheet,
                    child: Container(
                      height: 50,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _selectedMusicTrack != null
                            ? const Color(0xFF7B2FFF).withValues(alpha: 0.2)
                            : Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: _selectedMusicTrack != null
                              ? const Color(0xFF00E5FF).withValues(alpha: 0.5)
                              : Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: _selectedMusicTrack != null
                                    ? [const Color(0xFF00E5FF), const Color(0xFFFF176B)]
                                    : [const Color(0xFF7B2FFF), const Color(0xFF00E5FF)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                            ),
                            child: Icon(
                              _selectedMusicTrack != null
                                  ? Icons.graphic_eq_rounded
                                  : Icons.music_note_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _selectedMusicTrack ?? 'Add music & get gifts',
                                  style: syne(sz: 12, w: FontWeight.w700, c: Colors.white),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  _selectedMusicTrack != null
                                      ? 'Background track active • Tap to change'
                                      : 'Trending sounds. More viewers. Bigger rewards.',
                                  style: dm(sz: 9.5, c: Colors.white60),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            _selectedMusicTrack != null ? Icons.tune_rounded : Icons.chevron_right_rounded,
                            color: Colors.white60,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── MAIN VIEWPORT CARD (Camera Preview Window + Overlay Controls) ──
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: const Color(0xFF2979FF).withValues(alpha: 0.35),
                    width: 1.2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(25),
                  child: Stack(
                    children: [
                      // Camera focus touch target
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _triggerFocusCamera,
                          child: const SizedBox.expand(),
                        ),
                      ),

                      // Card Top Row: Top-left 'X' & Top-right 'Your Live' Capsule
                      Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Top-left 'X' inside card
                            GestureDetector(
                              onTap: _startingBroadcast ? null : _closeLiveStudio,
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.45),
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: const Icon(Icons.close, color: Colors.white, size: 22),
                              ),
                            ),

                            // Top-right 'Your Live ✏️ ⌵' capsule card
                            GestureDetector(
                              onTap: _openTitleEditSheet,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: const Color(0xFF2979FF).withValues(alpha: 0.45),
                                    width: 1.1,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF2979FF).withValues(alpha: 0.16),
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Avatar / Gradient orb
                                    Container(
                                      width: 22,
                                      height: 22,
                                      padding: const EdgeInsets.all(1.5),
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: LinearGradient(
                                          colors: [Color(0xFF7B2FFF), Color(0xFF00E5FF)],
                                        ),
                                      ),
                                      child: CircleAvatar(
                                        backgroundColor: const Color(0xFF242738),
                                        backgroundImage: avatar.isNotEmpty ? CachedNetworkImageProvider(avatar) : null,
                                        child: avatar.isEmpty
                                            ? const Icon(Icons.person, size: 12, color: Colors.white70)
                                            : null,
                                      ),
                                    ),
                                    const SizedBox(width: 7),
                                    Text(
                                      _liveTitleController.text.trim().isNotEmpty
                                          ? _liveTitleController.text.trim()
                                          : 'Your Live',
                                      style: syne(sz: 12, w: FontWeight.w700, c: Colors.white),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(width: 6),
                                    const Icon(Icons.edit_outlined, size: 12, color: Colors.white70),
                                    const SizedBox(width: 4),
                                    const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70, size: 18),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Center Reticle Viewfinder
                      Center(
                        child: GestureDetector(
                          onTap: _triggerFocusCamera,
                          child: _ReticleViewfinder(isFocusing: _isFocusingCamera),
                        ),
                      ),

                      // Right Vertical Rail: Camera Flip (kept where it is!), Filters, Beauty, More
                      Positioned(
                        top: 70,
                        right: 12,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 1. Camera Flip (user specifically mandated: keep flip button where it is!)
                            _buildImageRailButton(
                              icon: Icons.cameraswitch_outlined,
                              label: 'Camera\nFlip',
                              hasGlow: true,
                              onTap: _flipCamera,
                            ),
                            const SizedBox(height: 12),

                            // 2. Filters
                            _buildImageRailButton(
                              icon: Icons.auto_fix_high_rounded,
                              label: 'Filters',
                              onTap: () => _openLiveEffectsSheet(initialTab: 0),
                            ),
                            const SizedBox(height: 12),

                            // 3. Beauty
                            _buildImageRailButton(
                              icon: Icons.face_retouching_natural,
                              label: 'Beauty',
                              onTap: () => _openLiveEffectsSheet(initialTab: 1),
                            ),
                            const SizedBox(height: 12),

                            // 4. More
                            _buildImageRailButton(
                              icon: Icons.more_horiz_rounded,
                              label: 'More',
                              onTap: _openMoreSheet,
                            ),
                          ],
                        ),
                      ),

                      // Bottom Controls: Mode Switcher, Go LIVE, Quick Bar
                      Positioned(
                        left: 14,
                        right: 14,
                        bottom: 12,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Mode Switcher Capsule (Camera | Voice | Gaming Beta)
                            Container(
                              height: 48,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1),
                                boxShadow: const [
                                  BoxShadow(color: Colors.black45, blurRadius: 14, offset: Offset(0, 3)),
                                ],
                              ),
                              child: Row(
                                children: [
                                  // Camera
                                  Expanded(
                                    child: _modeCapsuleItem(
                                      index: 1,
                                      icon: Icons.videocam_outlined,
                                      label: 'Camera',
                                      onTap: () => _selectGreenRoomMode(1),
                                    ),
                                  ),

                                  // Voice
                                  Expanded(
                                    child: _modeCapsuleItem(
                                      index: 2,
                                      icon: Icons.mic_none_outlined,
                                      label: 'Voice',
                                      onTap: () => _selectGreenRoomMode(2),
                                    ),
                                  ),

                                  // Divider
                                  Container(
                                    width: 1,
                                    height: 20,
                                    color: Colors.white24,
                                    margin: const EdgeInsets.symmetric(horizontal: 4),
                                  ),

                                  // Gaming
                                  Expanded(
                                    child: _modeCapsuleItem(
                                      index: 3,
                                      icon: Icons.sports_esports_outlined,
                                      label: 'Gaming',
                                      badge: 'Beta',
                                      onTap: () => _selectGreenRoomMode(3),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 10),

                            // Prominent Gradient "Go LIVE" Button
                            GestureDetector(
                              onTap: _startingBroadcast ? null : _startBroadcast,
                              child: Container(
                                height: 50,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: _startingBroadcast
                                        ? [Colors.grey.shade700, Colors.grey.shade600]
                                        : [const Color(0xFF7B2FFF), const Color(0xFF00E5FF)],
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                  ),
                                  borderRadius: BorderRadius.circular(25),
                                  boxShadow: [
                                    if (!_startingBroadcast)
                                      BoxShadow(
                                        color: const Color(0xFF00E5FF).withValues(alpha: 0.4),
                                        blurRadius: 18,
                                        spreadRadius: 1,
                                        offset: const Offset(0, 4),
                                      ),
                                  ],
                                ),
                                child: Center(
                                  child: _startingBroadcast
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                                        )
                                      : Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.wifi_tethering_rounded, color: Colors.white, size: 22),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Go LIVE',
                                              style: syne(sz: 16, w: FontWeight.w900, c: Colors.white, ls: 0.8),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ),

                            const SizedBox(height: 8),

                            // Bottom Quick Bar: Effects > | Schedule >
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.keyboard_arrow_up_rounded, color: Colors.white60, size: 18),
                                const SizedBox(height: 2),
                                Container(
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.65),
                                    borderRadius: BorderRadius.circular(21),
                                    border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1),
                                  ),
                                  child: Row(
                                    children: [
                                      // Effects >
                                      Expanded(
                                        child: InkWell(
                                          onTap: () => _openLiveEffectsSheet(),
                                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(21)),
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              const Icon(Icons.auto_awesome, color: C.brand, size: 15),
                                              const SizedBox(width: 6),
                                              Text('Effects', style: dm(sz: 12, w: FontWeight.w600, c: Colors.white)),
                                              const SizedBox(width: 4),
                                              const Icon(Icons.chevron_right_rounded, color: Colors.white54, size: 16),
                                            ],
                                          ),
                                        ),
                                      ),

                                      Container(width: 1, height: 20, color: Colors.white24),

                                      // Schedule >
                                      Expanded(
                                        child: InkWell(
                                          onTap: _pickBroadcastTime,
                                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(21)),
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              const Icon(Icons.calendar_month_outlined, color: Colors.white, size: 15),
                                              const SizedBox(width: 6),
                                              Text(
                                                _plannedBroadcastTime != null ? _plannedBroadcastLabel() : 'Schedule',
                                                style: dm(sz: 12, w: FontWeight.w600, c: Colors.white),
                                              ),
                                              const SizedBox(width: 4),
                                              const Icon(Icons.chevron_right_rounded, color: Colors.white54, size: 16),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
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
          ],
        ),
      ),
    );
  }

  Widget _buildImageRailButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool hasGlow = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              shape: BoxShape.circle,
              border: Border.all(
                color: hasGlow ? const Color(0xFF00E5FF) : Colors.white.withValues(alpha: 0.18),
                width: 1.2,
              ),
              boxShadow: [
                if (hasGlow)
                  BoxShadow(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.4),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: dm(sz: 10, w: FontWeight.w500, c: Colors.white),
            textAlign: TextAlign.center,
            maxLines: 2,
          ),
        ],
      ),
    );
  }

  Widget _modeCapsuleItem({
    required int index,
    required IconData icon,
    required String label,
    String? badge,
    VoidCallback? onTap,
  }) {
    final active = _greenRoomModeIndex == index;
    return GestureDetector(
      onTap: onTap ?? () => setState(() => _greenRoomModeIndex = index),
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: active ? Colors.white : Colors.white60),
              const SizedBox(width: 5),
              Text(
                label,
                style: dm(
                  sz: 11,
                  w: active ? FontWeight.w700 : FontWeight.w500,
                  c: active ? Colors.white : Colors.white60,
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7B2FFF),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    badge,
                    style: dm(sz: 7, w: FontWeight.w900, c: Colors.white),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 3),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: active ? 20 : 0,
            height: 2.5,
            decoration: BoxDecoration(
              color: C.brand,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  void _openTitleEditSheet() {
    final titleCtrl = TextEditingController(text: _liveTitleController.text);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xF50D1017),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white12, width: 1.2),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text('Stream Title', style: syne(sz: 16, w: FontWeight.bold, c: Colors.white)),
                const SizedBox(height: 12),
                TextField(
                  controller: titleCtrl,
                  autofocus: true,
                  maxLength: 60,
                  style: dm(sz: 14, c: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Add a catchy title...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.black.withValues(alpha: 0.4),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    prefixIcon: const Icon(Icons.edit_note_rounded, color: C.brand),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      setState(() => _liveTitleController.text = titleCtrl.text.trim());
                      Navigator.pop(ctx);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: C.brand,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text('Done', style: syne(sz: 14, w: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openMoreSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          decoration: BoxDecoration(
            color: const Color(0xF50D1017),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white12, width: 1.2),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const Icon(Icons.tune_rounded, color: C.brand, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'More Studio Settings',
                      style: syne(sz: 16, w: FontWeight.bold, c: Colors.white),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                      onPressed: () => Navigator.pop(sheetCtx),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // 1. Mirror Mode
                _moreSettingTile(
                  icon: Icons.flip_rounded,
                  title: 'Mirror Camera',
                  subtitle: _mirrorMode ? 'Flipped horizontally' : 'Standard view',
                  value: _mirrorMode,
                  onChanged: (val) {
                    setState(() => _mirrorMode = val);
                    setSheet(() {});
                  },
                ),

                // 2. Framing Grid
                _moreSettingTile(
                  icon: Icons.grid_on_rounded,
                  title: 'Rule of Thirds Grid',
                  subtitle: _showGrid ? 'Grid lines visible' : 'Hidden',
                  value: _showGrid,
                  onChanged: (val) {
                    setState(() => _showGrid = val);
                    setSheet(() {});
                  },
                ),

                // 3. Normal 1x Viewport Zoom vs Full Screen Cover
                _moreSettingTile(
                  icon: Icons.aspect_ratio_rounded,
                  title: '1x Normal Sensor Size',
                  subtitle: _greenRoomNormalZoom
                      ? 'True 1x uncropped camera view'
                      : 'Fill full screen (cover mode)',
                  value: _greenRoomNormalZoom,
                  onChanged: (val) {
                    setState(() => _greenRoomNormalZoom = val);
                    _resetCameraHardwareZoom();
                    setSheet(() {});
                  },
                ),

                // 4. Live Goal
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.flag_rounded, color: _liveGoal.isNotEmpty ? C.brand : Colors.white70, size: 20),
                  ),
                  title: Text('Live Goal', style: dm(sz: 14, w: FontWeight.w600, c: Colors.white)),
                  subtitle: Text(_liveGoal.isNotEmpty ? _liveGoal : 'Set a target for viewers', style: dm(sz: 11, c: C.dim)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _openGoalDialog();
                  },
                ),

                // 5. Schedule Broadcast
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.calendar_month_outlined, color: _plannedBroadcastTime != null ? C.brand : Colors.white70, size: 20),
                  ),
                  title: Text('Schedule Broadcast', style: dm(sz: 14, w: FontWeight.w600, c: Colors.white)),
                  subtitle: Text(_plannedBroadcastTime != null ? _plannedBroadcastLabel() : 'Not scheduled', style: dm(sz: 11, c: C.dim)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _pickBroadcastTime();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _moreSettingTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: value ? C.brand : Colors.white70, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: dm(sz: 14, w: FontWeight.w600, c: Colors.white)),
                Text(subtitle, style: dm(sz: 11, c: C.dim)),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeColor: C.brand,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildEffectsAndBeautyTray({StateSetter? setSheetState, bool Function()? isSheetMounted}) {
    final categories = ['All', 'beauty', 'super_face', 'symmetry', 'glow', 'color', 'creative'];
    final filteredCatalogue = _activeCategoryTab == 'All'
        ? _catalogueFilters
        : _catalogueFilters.where((f) => f.category == _activeCategoryTab).toList();

    void update(VoidCallback fn) {
      if (mounted) setState(fn);
      // Guard: only call setSheetState if the sheet is still mounted to prevent
      // "setState() called after dispose()" crashes when the user moves the
      // Facial Symmetry (or any beauty) slider while the sheet is animating closed.
      if (setSheetState != null && (isSheetMounted == null || isSheetMounted())) {
        try {
          setSheetState(fn);
        } catch (_) {
          // Sheet was disposed mid-animation – silently swallow.
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sub-tabs: Smart Filters vs Beauty Retouch
          Row(
            children: [
              GestureDetector(
                onTap: () => update(() => _effectsPanelTab = 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: _effectsPanelTab == 0 ? C.brand.withValues(alpha: 0.25) : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _effectsPanelTab == 0 ? C.brand : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 13, color: _effectsPanelTab == 0 ? C.brand : Colors.white60),
                      const SizedBox(width: 6),
                      Text(
                        'Smart Filters',
                        style: syne(
                          sz: 11,
                          w: FontWeight.w700,
                          c: _effectsPanelTab == 0 ? C.brand : Colors.white60,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => update(() => _effectsPanelTab = 1),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: _effectsPanelTab == 1 ? C.brand.withValues(alpha: 0.25) : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _effectsPanelTab == 1 ? C.brand : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.face_retouching_natural, size: 13, color: _effectsPanelTab == 1 ? C.brand : Colors.white60),
                      const SizedBox(width: 6),
                      Text(
                        'Beauty Retouch',
                        style: syne(
                          sz: 11,
                          w: FontWeight.w700,
                          c: _effectsPanelTab == 1 ? C.brand : Colors.white60,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              if (_activeCatalogueFilter != null || _beautySmoothing > 0 || _beautyWhitening > 0 || _faceSymmetry > 0 || _makeupGender > 0)
                GestureDetector(
                  onTap: () {
                    update(() {
                      _activeCatalogueFilter = null;
                      _activeFilterIndex = 0;
                      _beautySmoothing = 0;
                      _skinSmoothingMode = 0;
                      _beautyWhitening = 0;
                      _skinBrighteningTone = 0;
                      _faceSymmetry = 0;
                      _symmetryMirrorLeft = true;
                      _showSymmetryGuide = true;
                      _makeupGender = 0;
                      _makeupStyle = 0;
                      _makeupIntensity = 0.6;
                    });
                    _scheduleFaceSymmetryProcessing(0);
                  },
                  child: Text('Reset', style: dm(sz: 11, c: Colors.redAccent, w: FontWeight.w600)),
                ),
            ],
          ),

          const SizedBox(height: 10),

          // Content of Tab 0: Smart Filters
          if (_effectsPanelTab == 0) ...[
            // Category pills
            SizedBox(
              height: 32,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: categories.length,
                itemBuilder: (_, i) {
                  final cat = categories[i];
                  final isCatActive = _activeCategoryTab == cat;
                  final label = cat == 'super_face'
                      ? 'Super Face'
                      : (cat == 'All' ? 'All' : cat[0].toUpperCase() + cat.substring(1));
                  return GestureDetector(
                    onTap: () => update(() => _activeCategoryTab = cat),
                    child: Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: isCatActive ? C.brand : Colors.white10,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: Text(
                          label,
                          style: syne(
                            sz: 10,
                            w: FontWeight.w700,
                            c: isCatActive ? Colors.black : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 10),

            // Horizontal Filter Carousel
            SizedBox(
              height: 96,
              child: _loadingCatalogue && _catalogueFilters.isEmpty
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: C.brand))
                  : ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        // None / Original Card
                        _buildFilterCardItem(
                          displayName: 'Original',
                          isSelected: _activeCatalogueFilter == null && _activeFilterIndex == 0,
                          icon: Icons.block,
                          onTap: () {
                            update(() {
                              _activeCatalogueFilter = null;
                              _activeFilterIndex = 0;
                            });
                          },
                        ),
                        // Dynamic Catalogue Filter Cards
                        ...filteredCatalogue.map((filter) {
                          if (filter.isNone) return const SizedBox.shrink();
                          final isSelected = _activeCatalogueFilter?.id == filter.id;
                          return _buildFilterCardItem(
                            displayName: filter.displayName,
                            isSelected: isSelected,
                            icon: Icons.auto_awesome,
                            meta: filter,
                            onTap: () {
                              update(() {
                                _activeCatalogueFilter = filter;
                              });
                            },
                          );
                        }),
                      ],
                    ),
            ),

            // Intensity Slider (when a catalogue filter is active)
            if (_activeCatalogueFilter != null && !_activeCatalogueFilter!.isNone) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Intensity', style: dm(sz: 11, c: Colors.white70)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: C.brand,
                        inactiveTrackColor: Colors.white12,
                        thumbColor: Colors.white,
                        overlayColor: C.brand.withValues(alpha: 0.2),
                        trackHeight: 2,
                      ),
                      child: Slider(
                        value: _catalogueFilterIntensity,
                        min: 0,
                        max: 1,
                        onChanged: (v) => update(() => _catalogueFilterIntensity = v),
                      ),
                    ),
                  ),
                  Text(
                    '${(_catalogueFilterIntensity * 100).round()}%',
                    style: dm(sz: 11, c: C.brand, w: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ] else ...[
            // Content of Tab 1: Beauty Retouch & Face Shaping
            _beautySliderRow(
              icon: Icons.face_retouching_natural,
              label: 'Skin Smoothing',
              value: _beautySmoothing,
              onChanged: (v) => update(() => _beautySmoothing = v),
            ),
            if (_beautySmoothing > 0) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Row(
                  children: [
                    Text('Finish: ', style: dm(sz: 10, c: Colors.white60)),
                    for (final item in [(0, 'Natural'), (1, 'Radiant'), (2, 'Matte')]) ...[
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          update(() => _skinSmoothingMode = item.$1);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: _skinSmoothingMode == item.$1 ? C.brand : Colors.white10,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            item.$2,
                            style: dm(
                              sz: 9,
                              w: FontWeight.w700,
                              c: _skinSmoothingMode == item.$1 ? Colors.black : Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            _beautySliderRow(
              icon: Icons.wb_sunny_outlined,
              label: 'Skin Brightening',
              value: _beautyWhitening,
              onChanged: (v) => update(() => _beautyWhitening = v),
            ),
            if (_beautyWhitening > 0) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Row(
                  children: [
                    Text('Tone: ', style: dm(sz: 10, c: Colors.white60)),
                    for (final item in [(0, 'Warm Glow'), (1, 'Porcelain'), (2, 'Natural')]) ...[
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          update(() => _skinBrighteningTone = item.$1);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: _skinBrighteningTone == item.$1 ? C.brand : Colors.white10,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            item.$2,
                            style: dm(
                              sz: 9,
                              w: FontWeight.w700,
                              c: _skinBrighteningTone == item.$1 ? Colors.black : Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            _beautySliderRow(
              icon: Icons.center_focus_strong_outlined,
              label: 'Facial Symmetry',
              value: _faceSymmetry,
              onChanged: (v) {
                update(() => _faceSymmetry = v);
                _scheduleFaceSymmetryProcessing(v);
              },
            ),
            if (_faceSymmetry > 0) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Row(
                  children: [
                    Text('Balance: ', style: dm(sz: 10, c: Colors.white60)),
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        update(() => _symmetryMirrorLeft = true);
                        if (_faceSymmetry > 0.01) {
                          _scheduleFaceSymmetryProcessing(_faceSymmetry);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _symmetryMirrorLeft ? C.brand : Colors.white10,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Left Side',
                          style: dm(
                            sz: 9,
                            w: FontWeight.w700,
                            c: _symmetryMirrorLeft ? Colors.black : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        update(() => _symmetryMirrorLeft = false);
                        if (_faceSymmetry > 0.01) {
                          _scheduleFaceSymmetryProcessing(_faceSymmetry);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: !_symmetryMirrorLeft ? C.brand : Colors.white10,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Right Side',
                          style: dm(
                            sz: 9,
                            w: FontWeight.w700,
                            c: !_symmetryMirrorLeft ? Colors.black : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        update(() => _showSymmetryGuide = !_showSymmetryGuide);
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _showSymmetryGuide ? Icons.visibility : Icons.visibility_off,
                            size: 13,
                            color: _showSymmetryGuide ? C.brand : Colors.white38,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Guide',
                            style: dm(
                              sz: 10,
                              c: _showSymmetryGuide ? C.brand : Colors.white38,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(height: 1, color: Colors.white10),
            const SizedBox(height: 10),

            // Studio Makeup (Women & Men)
            Row(
              children: [
                const Icon(Icons.auto_awesome, color: Color(0xFF00E5FF), size: 16),
                const SizedBox(width: 8),
                Text('Studio Makeup', style: syne(sz: 12, w: FontWeight.w800, c: Colors.white)),
                const Spacer(),
                for (final item in [(0, 'None'), (1, 'Women'), (2, 'Men')]) ...[
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      update(() {
                        _makeupGender = item.$1;
                        if (_makeupGender > 0 && _makeupIntensity <= 0.05) {
                          _makeupIntensity = 0.6;
                        }
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      margin: const EdgeInsets.only(left: 5),
                      decoration: BoxDecoration(
                        color: _makeupGender == item.$1 ? C.brand : Colors.white10,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        item.$2,
                        style: dm(
                          sz: 10,
                          w: FontWeight.w700,
                          c: _makeupGender == item.$1 ? Colors.black : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),

            if (_makeupGender > 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(width: 24),
                  Text('Look: ', style: dm(sz: 10, c: Colors.white60)),
                  for (final item in (_makeupGender == 1
                      ? [(0, 'Rosy Glow'), (1, 'Natural Nude'), (2, 'Sunset Glam')]
                      : [(0, 'Clean Groomed'), (1, 'Sharp Contour'), (2, 'Sun-Kissed')])) ...[
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        update(() => _makeupStyle = item.$1);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: _makeupStyle == item.$1
                              ? (_makeupGender == 1 ? const Color(0xFFFF4081) : const Color(0xFF00E5FF))
                              : Colors.white10,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          item.$2,
                          style: dm(
                            sz: 9,
                            w: FontWeight.w700,
                            c: _makeupStyle == item.$1 ? Colors.black : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Row(
                  children: [
                    Text('Intensity', style: dm(sz: 11, c: Colors.white70)),
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          activeTrackColor: _makeupGender == 1 ? const Color(0xFFFF4081) : const Color(0xFF00E5FF),
                          inactiveTrackColor: Colors.white12,
                          thumbColor: Colors.white,
                          overlayColor: C.brand.withValues(alpha: 0.2),
                          trackHeight: 2,
                        ),
                        child: Slider(
                          value: _makeupIntensity,
                          min: 0,
                          max: 1,
                          onChanged: (v) => update(() => _makeupIntensity = v),
                        ),
                      ),
                    ),
                    Text(
                      '${(_makeupIntensity * 100).round()}%',
                      style: dm(
                        sz: 11,
                        c: _makeupGender == 1 ? const Color(0xFFFF4081) : const Color(0xFF00E5FF),
                        w: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildFilterCardItem({
    required String displayName,
    required bool isSelected,
    required IconData icon,
    NecxaFilterMeta? meta,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: isSelected ? C.brand.withValues(alpha: 0.15) : Colors.black45,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? C.brand : Colors.white24,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isSelected
                          ? [const Color(0xFF7B2FFF), const Color(0xFF00E5FF)]
                          : [Colors.white12, Colors.white10],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      icon,
                      color: isSelected ? Colors.white : Colors.white60,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: Text(
                displayName,
                style: syne(
                  sz: 9,
                  w: isSelected ? FontWeight.w800 : FontWeight.w600,
                  c: isSelected ? C.brand : Colors.white70,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the 3-quarters Effects & Beauty modal while live streaming.
  void _openLiveEffectsSheet({int initialTab = 0}) {
    setState(() => _effectsPanelTab = initialTab);
    // Tracks whether the sheet's StatefulBuilder is still alive.
    // Prevents "setState() called after dispose()" when a beauty/symmetry
    // slider is still being dragged as the sheet animates closed.
    bool sheetAlive = true;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          return PopScope(
            onPopInvokedWithResult: (_, __) => sheetAlive = false,
            child: Container(
              // Use sheetCtx (not outer context) to avoid stale BuildContext.
              height: MediaQuery.sizeOf(sheetCtx).height * 0.75,
              decoration: BoxDecoration(
                color: const Color(0xF20D1017),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border.all(color: Colors.white12, width: 1.2),
              ),
              child: Column(
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      margin: const EdgeInsets.only(top: 10, bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.auto_awesome, color: C.brand, size: 20),
                        const SizedBox(width: 8),
                        Text('Studio Effects & Beauty', style: syne(sz: 16, w: FontWeight.bold, c: Colors.white)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.check, color: C.brand),
                          onPressed: () {
                            sheetAlive = false;
                            Navigator.pop(sheetCtx);
                          },
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: _buildEffectsAndBeautyTray(
                        setSheetState: setSheet,
                        isSheetMounted: () => sheetAlive,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() => sheetAlive = false);
  }



  // Enforcement card moved to lib/widgets/live_studio/live_enforcement_overlay.dart

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // -- Video Layer (with filter, mirror, grid) --
          _buildFilteredVideoView(),
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

          // -- Shield Verification Wall (403 Handler) --
          if (_requiresVerification) _buildShieldVerificationCard(),

          // -- Safety Enforcement Wall (Violations) --
          if (_isEnforcementActive)
            LiveEnforcementOverlay(
              enforcementReason: _enforcementReason,
              onClose: () => Navigator.pop(context),
            ),

          // -- Gifting Layer --
          LiveGiftingOverlay(eventStream: _liveGiftEvents),

          for (var i = 0; i < _reactionBursts.length; i++)
            _buildReactionBurst(_reactionBursts[i], i),

          // -- Glass Overlay Layer --
          if (!_hostInGreenRoom) _buildCompactHUD(),

          if (widget.isHost && _hostInGreenRoom) _buildHostGreenRoom(),

          // -- Interaction Layer --
          if (!_hostInGreenRoom) _buildInteractionUI(),
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


  // ── Filter color matrices ──────────────────────────────────────────────────
  // Each row is [R,G,B,A,Offset] × 4 rows (RGBA)
  static const List<(String, List<double>)> _filterPresets = [
    ('Normal', [
      1,0,0,0,0, 0,1,0,0,0, 0,0,1,0,0, 0,0,0,1,0,
    ]),
    ('Warm', [
      1.2,0,0,0,0.05, 0,1.05,0,0,0, 0,0,0.85,0,0, 0,0,0,1,0,
    ]),
    ('Cool', [
      0.85,0,0,0,0, 0,1.0,0,0,0, 0,0,1.25,0,0.05, 0,0,0,1,0,
    ]),
    ('Vivid', [
      1.3,0,0,0,-0.1, 0,1.3,0,0,-0.1, 0,0,1.3,0,-0.1, 0,0,0,1,0,
    ]),
    ('Soft', [
      0.9,0.05,0.05,0,0.02, 0.05,0.9,0.05,0,0.02, 0.05,0.05,0.9,0,0.02, 0,0,0,1,0,
    ]),
    ('B&W', [
      0.33,0.59,0.11,0,0, 0.33,0.59,0.11,0,0, 0.33,0.59,0.11,0,0, 0,0,0,1,0,
    ]),
  ];

  // Build a combined ColorMatrix for beauty (whitening/brightening = tone-adaptive luminance lift,
  // smoothing = micro-contrast softening and warm skin-tone lift, makeup = gender-adaptive palette)
  List<double> _beautyMatrix() {
    final w = _beautyWhitening * 0.25; // max +0.25 brightness offset
    final s = _beautySmoothing.clamp(0.0, 1.0);

    // Tone-adaptive Skin Brightening:
    // 0 = Warm Glow (golden sunny warmth, lifts R and G)
    // 1 = Cool Porcelain (bright, clears yellowish sallowness, lifts B and R)
    // 2 = Natural Fresh (balanced studio daylight)
    final double rBright;
    final double gBright;
    final double bBright;
    switch (_skinBrighteningTone) {
      case 0:
        rBright = w * 1.14;
        gBright = w * 1.04;
        bBright = w * 0.88;
      case 1:
        rBright = w * 1.06;
        gBright = w * 0.98;
        bBright = w * 1.18;
      default:
        rBright = w;
        gBright = w;
        bBright = w;
    }

    // Micro-contrast softening: gently compresses blemish contrast in skin midtones
    double contrast = 1.0 - (s * 0.06);
    double contrastOffset = 0.5 * (1.0 - contrast);
    final skinToneLift = s * 0.02;

    double rScale = contrast;
    double gScale = contrast;
    double bScale = contrast;
    double rOffset = rBright + contrastOffset + skinToneLift;
    double gOffset = gBright + contrastOffset + (skinToneLift * 0.6);
    double bOffset = bBright + contrastOffset;

    // Studio Makeup Palette (Women & Men):
    if (_makeupGender > 0 && _makeupIntensity > 0.01) {
      final m = _makeupIntensity.clamp(0.0, 1.0);
      if (_makeupGender == 1) {
        // Women (Feminine):
        switch (_makeupStyle) {
          case 0: // Rosy Glow (petal pink lip & cheek radiance)
            rScale += m * 0.06;
            gScale -= m * 0.02;
            bScale += m * 0.03;
            rOffset += m * 0.035;
            bOffset += m * 0.012;
          case 1: // Natural Nude (soft peach warmth, luminous skin)
            rScale += m * 0.05;
            gScale += m * 0.02;
            bScale -= m * 0.02;
            rOffset += m * 0.028;
            gOffset += m * 0.014;
          case 2: // Sunset Glam (rich berry lips & contoured cheek warmth)
            rScale += m * 0.08;
            gScale -= m * 0.03;
            bScale += m * 0.04;
            rOffset += m * 0.045;
            bOffset += m * 0.018;
            contrast += m * 0.03;
        }
      } else {
        // Men (Masculine):
        switch (_makeupStyle) {
          case 0: // Clean Groomed (evens complexion, conceals under-eye shadows, sharpens brows)
            contrast += m * 0.04;
            contrastOffset = 0.5 * (1.0 - contrast);
            rScale = contrast + (m * 0.02);
            gScale = contrast + (m * 0.02);
            bScale = contrast - (m * 0.02);
            rOffset += m * 0.018;
            gOffset += m * 0.018;
          case 1: // Sharp Contour (chisels jawline & cheekbone structure, reduces oily glare)
            contrast += m * 0.07;
            contrastOffset = 0.5 * (1.0 - contrast);
            rScale = contrast + (m * 0.03);
            gScale = contrast - (m * 0.02);
            bScale = contrast - (m * 0.02);
            rOffset += m * 0.012;
          case 2: // Sun-Kissed (athletic, healthy bronzed vitality)
            rScale += m * 0.07;
            gScale += m * 0.03;
            bScale -= m * 0.05;
            rOffset += m * 0.032;
            gOffset += m * 0.018;
        }
      }
    }

    return [
      rScale, 0, 0, 0, rOffset,
      0, gScale, 0, 0, gOffset,
      0, 0, bScale, 0, bOffset,
      0, 0, 0, 1, 0,
    ];
  }

  /// Wraps _buildVideoView() with ColorFiltered (tint/catalogue), Transform (mirror),
  /// optional smoothing BackdropFilter (beauty), and grid overlay.
  Widget _buildFilteredVideoView() {
    List<double> filterMatrix;
    if (_previewOriginal) {
      filterMatrix = const [
        1,0,0,0,0, 0,1,0,0,0, 0,0,1,0,0, 0,0,0,1,0,
      ];
    } else if (_activeCatalogueFilter != null && !_activeCatalogueFilter!.isNone) {
      filterMatrix = NecxaEffectsEngine.buildMatrixForMeta(
        _activeCatalogueFilter!,
        intensity: _catalogueFilterIntensity,
      );
    } else {
      final idx = _activeFilterIndex.clamp(0, _filterPresets.length - 1);
      final (_, legacyMatrix) = _filterPresets[idx];
      filterMatrix = legacyMatrix;
    }

    final hasActiveFilter = (_activeCatalogueFilter != null && !_activeCatalogueFilter!.isNone) ||
        _activeFilterIndex != 0 ||
        _beautyWhitening > 0 ||
        _beautySmoothing > 0 ||
        (_makeupGender > 0 && _makeupIntensity > 0.01);

    final combinedMatrix = _previewOriginal
        ? filterMatrix
        : _mergeColorMatrices(filterMatrix, _beautyMatrix());

    Widget video = _buildBaseVideoLayer(
      combinedMatrix: combinedMatrix,
      hasActiveFilter: hasActiveFilter,
    );

    // Facial Symmetry: bilateral balance guide overlay
    // NOTE: We intentionally do NOT call _buildBaseVideoLayer() a second time
    // here. Mounting two VideoTrackRenderer widgets for the same camera track
    // causes a WebRTC native hardware-texture collision (EGL_BAD_ACCESS on
    // Android, RTCCVPixelBuffer double-sink on iOS), which blacks out the feed
    // and crashes LiveKit track management. The symmetry effect is therefore
    // achieved via a pure-Flutter overlay (guide lines + shimmer tint) with
    // zero additional native renderer allocations.
    if (!_previewOriginal && _faceSymmetry > 0.01) {
      final mirrorLeft = _symmetryMirrorLeft;
      video = LayoutBuilder(
        builder: (context, constraints) {
          final halfWidth = constraints.maxWidth / 2;
          // Clamp so we never request infinite size in unconstrained parents
          final safeW = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 300.0;
          return Stack(
            fit: StackFit.expand,
            children: [
              video,
              // Symmetry balance shimmer tint on the weaker half
              Positioned(
                top: 0,
                bottom: 0,
                left: mirrorLeft ? halfWidth : 0,
                right: mirrorLeft ? 0 : halfWidth,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: (_faceSymmetry * 0.18).clamp(0.0, 0.18),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: mirrorLeft
                              ? Alignment.centerLeft
                              : Alignment.centerRight,
                          end: mirrorLeft
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          colors: const [
                            Color(0xFF00E5FF),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Vertical centre axis
              Positioned(
                top: 0,
                bottom: 0,
                left: safeW / 2 - 0.5,
                width: 1,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: (_faceSymmetry * 0.6).clamp(0.0, 0.6),
                    child: Container(color: const Color(0xFF00E5FF)),
                  ),
                ),
              ),

              // Facial Symmetry alignment guide overlay
              if (_showSymmetryGuide && _faceSymmetry > 0.05)
                Positioned.fill(
                  child: _FacialSymmetryGuideOverlay(
                    intensity: _faceSymmetry,
                    mirrorLeft: mirrorLeft,
                  ),
                ),
            ],
          );
        },
      );
    }


    // Beauty skin smoothing: multi-pass edge-preserving porcelain diffusion
    if (!_previewOriginal && _beautySmoothing > 0.01) {
      final intensity = _beautySmoothing.clamp(0.0, 1.0);
      final glowColor = _skinSmoothingMode == 1
          ? const Color(0xFFFFF6EB) // Radiant / porcelain glow
          : _skinSmoothingMode == 2
              ? const Color(0xFFEFE9DE) // Matte studio finish
              : const Color(0xFFFFF2E2); // Natural warm diffusion

      video = Stack(
        fit: StackFit.expand,
        children: [
          video,
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: (intensity * 0.52).clamp(0.0, 0.65),
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: 1.5 + (intensity * 5.0),
                    sigmaY: 1.5 + (intensity * 5.0),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 0.82,
                        colors: [
                          glowColor.withValues(
                            alpha: (_skinSmoothingMode == 1 ? 0.12 : 0.07) * intensity,
                          ),
                          Colors.transparent,
                        ],
                        stops: const [0.35, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Studio Makeup (Women & Men): subtle blush, lip tint, contour, and brow definition
    if (!_previewOriginal && _makeupGender > 0 && _makeupIntensity > 0.05) {
      video = Stack(
        fit: StackFit.expand,
        children: [
          video,
          Positioned.fill(
            child: _StudioMakeupOverlay(
              gender: _makeupGender,
              style: _makeupStyle,
              intensity: _makeupIntensity,
            ),
          ),
        ],
      );
    }

    // Grid overlay
    if (_showGrid) {
      video = Stack(
        fit: StackFit.expand,
        children: [
          video,
          const Positioned.fill(child: _GridOverlay()),
        ],
      );
    }

    return video;
  }

  /// Builds base video with mirror and active color/catalogue filters applied.
  Widget _buildBaseVideoLayer({
    required List<double> combinedMatrix,
    required bool hasActiveFilter,
  }) {
    Widget video = _buildVideoView();

    // Mirror
    if (_mirrorMode) {
      video = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: video,
      );
    }

    // Colour filter (Normal/none = identity so free when inactive)
    if (!_previewOriginal && hasActiveFilter) {
      video = ColorFiltered(
        colorFilter: ColorFilter.matrix(combinedMatrix),
        child: video,
      );
    }

    return video;
  }

  /// Multiplies two 4×5 colour matrices together (element-wise approximation
  /// sufficient for simple stacking of whitening on top of a LUT tint).
  static List<double> _mergeColorMatrices(List<double> a, List<double> b) {
    // a and b are both 20-element lists (4 rows × 5 columns)
    final out = List<double>.filled(20, 0);
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 5; col++) {
        double sum = 0;
        for (int k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        if (col == 4) sum += a[row * 5 + 4]; // offset passthrough
        out[row * 5 + col] = sum;
      }
    }
    return out;
  }

  // ── Filters bottom sheet ──────────────────────────────────────────────────
  void _openFiltersSheet() {
    _effectsPanelTab = 0;
    _openLiveEffectsSheet();
  }

  void _openBeautySheet() {
    _effectsPanelTab = 1;
    _openLiveEffectsSheet();
  }

  Widget _beautySliderRow({
    required IconData icon,
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        Icon(icon, color: C.brand, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label, style: dm(sz: 13, c: Colors.white)),
                  Text('${(value * 100).round()}%', style: dm(sz: 12, c: Colors.white54)),
                ],
              ),
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: C.brand,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: Colors.white,
                  overlayColor: C.brand.withValues(alpha: 0.2),
                  trackHeight: 2,
                ),
                child: Slider(value: value, onChanged: onChanged),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // (More sheet is defined above in the studio green room controls)

  void _openGoalDialog() {
    final goals = ['100 Coins', '500 Coins', '1,000 Coins', '5,000 Coins', '10,000 Coins'];
    final customCtrl = TextEditingController(text: _liveGoal);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1D2A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Live Goal', style: syne(sz: 16, w: FontWeight.bold, c: Colors.white)),
                  if (_liveGoal.isNotEmpty)
                    TextButton(
                      onPressed: () {
                        setState(() => _liveGoal = '');
                        Navigator.pop(ctx);
                      },
                      child: Text('Clear', style: dm(sz: 12, c: Colors.redAccent)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: goals.map((g) {
                  final sel = _liveGoal == g;
                  return ChoiceChip(
                    label: Text(g, style: dm(sz: 12, c: sel ? Colors.black : Colors.white)),
                    selected: sel,
                    selectedColor: C.brand,
                    backgroundColor: Colors.white10,
                    onSelected: (val) {
                      setState(() => _liveGoal = val ? g : '');
                      Navigator.pop(ctx);
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: customCtrl,
                      style: dm(sz: 13, c: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Or enter custom goal...',
                        hintStyle: dm(sz: 13, c: Colors.white38),
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.08),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      final text = customCtrl.text.trim();
                      setState(() => _liveGoal = text);
                      Navigator.pop(ctx);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: C.brand,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Set'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openTitleDialog() {
    final ctrl = TextEditingController(text: _liveTitleController.text);
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D2A),
        title: Text('Stream Title', style: syne(sz: 16, w: FontWeight.bold, c: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 60,
          style: dm(c: Colors.white),
          decoration: InputDecoration(
            hintText: 'Add a catchy title…',
            hintStyle: dm(c: Colors.white38),
            enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: C.brand)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text('Cancel', style: dm(c: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: C.brand, foregroundColor: Colors.black),
            onPressed: () {
              setState(() => _liveTitleController.text = ctrl.text.trim());
              Navigator.pop(c);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _moreActionTile({
    required IconData icon,
    required String label,
    required String subtitle,
    required Widget trailing,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white70, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: dm(sz: 14, c: Colors.white)),
                  Text(subtitle, style: dm(sz: 11, c: Colors.white38), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }

  Widget _moreToggleTile({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white70, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: dm(sz: 14, c: Colors.white)),
                Text(subtitle, style: dm(sz: 11, c: Colors.white38)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: C.brand,
            inactiveTrackColor: Colors.white24,
          ),
        ],
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
                  child: Center(
                    child: Icon(
                      Icons.videocam_outlined,
                      color: C.dim,
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
                  style: dm(sz: 10, c: C.dim),
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
                  c: C.dim,
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
      return Center(
        child: Icon(
          Icons.videocam_off_outlined,
          color: C.dim,
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

  bool _isUserId(String value) =>
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$')
          .hasMatch(value);

  bool get _canModerateLive =>
      widget.isHost || _moderatorGuestIds.contains(widget.state.user?.id);

  Future<void> _toggleGuestFollow(String guestId, String displayName) async {
    if (!_isUserId(guestId) || guestId == widget.state.user?.id) return;
    final updated = await widget.state.toggleFollow(guestId);
    if (!updated) return;
    if (!mounted) return;
    final isFriend = widget.state.isFriendSync(guestId);
    final isFollowing = widget.state.isFollowingSync(guestId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isFriend
              ? 'You and $displayName are now friends.'
              : isFollowing
              ? 'Following $displayName.'
              : 'Unfollowed $displayName.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showGuestActions(Participant participant) async {
    final guestId = participant.identity;
    if (guestId.isEmpty || guestId == _hostUserId) return;
    final displayName = participant.name.trim().isNotEmpty
        ? participant.name.trim()
        : guestId;
    final canFollow = guestId != widget.state.user?.id && _isUserId(guestId);
    final isModerator = _moderatorGuestIds.contains(guestId);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0C0E14),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(displayName, style: syne(sz: 16, w: FontWeight.w900, c: C.text)),
              const SizedBox(height: 12),
              if (guestId != widget.state.user?.id)
                ListTile(
                  leading: const Icon(Icons.card_giftcard_rounded, color: Color(0xFFFFA000)),
                  title: Text('Gift $displayName', style: dm(sz: 14, c: C.text)),
                  subtitle: Text('Send NCX directly to this guest', style: dm(sz: 11, c: C.sub)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_showGiftPicker(receiverId: guestId, receiverName: displayName));
                  },
                ),
              if (canFollow)
                ListTile(
                  leading: Icon(
                    widget.state.isFollowingSync(guestId)
                        ? Icons.person_remove_alt_1_rounded
                        : Icons.person_add_alt_1_rounded,
                    color: C.brand,
                  ),
                  title: Text(
                    widget.state.isFollowingSync(guestId) ? 'Unfollow' : 'Follow',
                    style: dm(sz: 14, c: C.text),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_toggleGuestFollow(guestId, displayName));
                  },
                ),
              if (widget.isHost && _isUserId(guestId)) ...[
                Divider(color: C.dim),
                ListTile(
                  leading: Icon(
                    isModerator
                        ? Icons.admin_panel_settings_outlined
                        : Icons.admin_panel_settings_rounded,
                    color: const Color(0xFF62F5EA),
                  ),
                  title: Text(
                    isModerator ? 'Remove live moderator' : 'Make live moderator',
                    style: dm(sz: 14, c: C.text),
                  ),
                  subtitle: Text(
                    isModerator
                        ? 'Revokes moderation controls for this guest'
                        : 'Lets this active guest moderate the live chat',
                    style: dm(sz: 11, c: C.sub),
                  ),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    try {
                      await widget.state.live.setGuestModerator(
                        _channelName,
                        guestId,
                        isModerator: !isModerator,
                      );
                      if (!mounted) return;
                      setState(() {
                        if (isModerator) {
                          _moderatorGuestIds.remove(guestId);
                        } else {
                          _moderatorGuestIds.add(guestId);
                        }
                      });
                      _showToast(
                        isModerator
                            ? '$displayName is no longer a moderator.'
                            : '$displayName is now a live moderator.',
                      );
                    } catch (error) {
                      _showToast('Could not update moderator: $error');
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.person_remove_rounded, color: Colors.redAccent),
                  title: Text('Remove from live', style: dm(sz: 14, c: Colors.redAccent)),
                  subtitle: Text('Returns this guest to the audience', style: dm(sz: 11, c: C.sub)),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    try {
                      await widget.state.live.removeGuest(_channelName, guestId);
                      if (!mounted) return;
                      setState(() => _moderatorGuestIds.remove(guestId));
                      _showToast('$displayName was removed from the live.');
                    } catch (error) {
                      _showToast('Could not remove guest: $error');
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
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
    final guestId = participant.identity;
    final canFollowGuest = !isHostTile &&
        guestId != widget.state.user?.id &&
        _isUserId(guestId);
    final isFriend = canFollowGuest && widget.state.isFriendSync(guestId);
    final isFollowing = canFollowGuest && widget.state.isFollowingSync(guestId);

    final tile = ClipRRect(
      borderRadius: showChrome ? BorderRadius.circular(8) : BorderRadius.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF17151F),
          border: showChrome ? Border.all(color: C.dim) : null,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (videoTrack is VideoTrack)
              VideoTrackRenderer(
                videoTrack,
                fit: (_hostInGreenRoom && _greenRoomNormalZoom)
                    ? VideoViewFit.contain
                    : VideoViewFit.cover,
              )
            else
              ColoredBox(
                color: Color(0xFF17151F),
                child: Center(
                  child: Icon(Icons.person, color: C.dim, size: 40),
                ),
              ),
            if (showChrome) ...[
              Positioned(
                top: 7,
                left: 7,
                child: _videoTileBadge(
                  isHostTile
                      ? 'HOST'
                      : _moderatorGuestIds.contains(guestId)
                      ? 'MOD'
                      : 'GUEST',
                ),
              ),
              if (isMuted)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Icon(
                    Icons.mic_off_rounded,
                    color: C.sub,
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
                        style: dm(sz: 9, w: FontWeight.w800, c: C.text),
                      ),
                    ),
                    if (canFollowGuest) ...[
                      const SizedBox(width: 4),
                      Semantics(
                        button: true,
                        label: isFriend
                            ? '$displayName is your friend'
                            : isFollowing
                            ? 'Unfollow $displayName'
                            : 'Follow $displayName',
                        child: GestureDetector(
                          onTap: () => unawaited(
                            _toggleGuestFollow(guestId, displayName),
                          ),
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: isFriend
                                  ? const Color(0xFF00C853)
                                  : isFollowing
                                  ? const Color(0xFF00AEEF)
                                  : const Color(0xFFFF176B),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              isFriend
                                  ? Icons.people_alt_rounded
                                  : isFollowing
                                  ? Icons.check_rounded
                                  : Icons.add,
                              color: C.text,
                              size: 14,
                            ),
                          ),
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
    return isHostTile
        ? tile
        : GestureDetector(
            onTap: () => unawaited(_showGuestActions(participant)),
            child: tile,
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
            Icon(Icons.add_rounded, color: C.text, size: 28),
            const SizedBox(height: 4),
            Text(
              'REQUEST',
              style: dm(sz: 8, w: FontWeight.w700, c: C.sub),
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

  List<Map<String, dynamic>> get _giftLeaderboard {
    final raw = _giftSummary['leaderboard'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
    }
    final top = _topGifter;
    return top == null ? const [] : [top];
  }

  List<Map<String, dynamic>> get _activeViewers {
    final raw = _liveSummary['viewers'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Widget _liveSheetHandle() => Center(
    child: Container(
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: C.dim,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  void _showLiveAudience() {
    final viewers = _activeViewers;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0C0E14),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _liveSheetHandle(),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.groups_2_rounded, color: Color(0xFF00E5FF)),
                  const SizedBox(width: 9),
                  Text(
                    'LIVE AUDIENCE',
                    style: syne(sz: 15, w: FontWeight.w900, c: C.text),
                  ),
                  const Spacer(),
                  Text(
                    _compactNumber(_viewerCount),
                    style: dm(sz: 13, w: FontWeight.w800, c: C.sub),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (viewers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Text(
                    _viewerCount == 0
                        ? 'Waiting for viewers to join.'
                        : 'Audience details are refreshing.',
                    style: dm(sz: 12, c: C.dim),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.48,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: viewers.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: C.dim),
                    itemBuilder: (_, index) {
                      final viewer = viewers[index];
                      final rawName = viewer['userName']?.toString().trim();
                      final name = rawName == null || rawName.isEmpty
                          ? 'Viewer'
                          : rawName;
                      final username = viewer['username']?.toString().trim();
                      final avatar = viewer['avatar']?.toString().trim() ?? '';
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: C.dim,
                          backgroundImage: avatar.isEmpty
                              ? null
                              : CachedNetworkImageProvider(avatar),
                          child: avatar.isEmpty
                              ? Text(
                                  name[0].toUpperCase(),
                                  style: dm(
                                    sz: 11,
                                    w: FontWeight.w900,
                                    c: C.text,
                                  ),
                                )
                              : null,
                        ),
                        title: Text(
                          name,
                          style: dm(
                            sz: 12,
                            w: FontWeight.w700,
                            c: C.text,
                          ),
                        ),
                        subtitle: username == null || username.isEmpty
                            ? null
                            : Text(
                                '@$username',
                                style: dm(sz: 10, c: C.dim),
                              ),
                      );
                    },
                  ),
                ),
              if (_viewerCount > viewers.length && viewers.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Showing the ${viewers.length} most recently active viewers.',
                  style: dm(sz: 9, c: C.dim),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showGiftLeaderboard() {
    final leaders = _giftLeaderboard;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0C0E14),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _liveSheetHandle(),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(
                    Icons.rocket_launch_rounded,
                    color: Color(0xFFA78BFA),
                  ),
                  const SizedBox(width: 9),
                  Text(
                    'LIVE GIFT RANKING',
                    style: syne(sz: 15, w: FontWeight.w900, c: C.text),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (leaders.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Text(
                    'The first gift will start the ranking.',
                    style: dm(sz: 12, c: C.dim),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.5,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: leaders.length,
                    itemBuilder: (_, index) {
                      final leader = leaders[index];
                      final rawName = leader['senderName']?.toString().trim();
                      final name = rawName == null || rawName.isEmpty
                          ? 'Anonymous'
                          : rawName;
                      final avatar =
                          leader['senderAvatar']?.toString().trim() ?? '';
                      final amount = (leader['amount'] as num?) ?? 0;
                      final rank =
                          (leader['rank'] as num?)?.toInt() ?? index + 1;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: C.dim,
                          backgroundImage: avatar.isEmpty
                              ? null
                              : CachedNetworkImageProvider(avatar),
                          child: avatar.isEmpty
                              ? Text(
                                  '#$rank',
                                  style: dm(
                                    sz: 10,
                                    w: FontWeight.w900,
                                    c: rank == 1
                                        ? const Color(0xFFFFA300)
                                        : C.text,
                                  ),
                                )
                              : null,
                        ),
                        title: Text(
                          name,
                          style: dm(
                            sz: 12,
                            w: FontWeight.w700,
                            c: C.text,
                          ),
                        ),
                        subtitle: Text(
                          'Rank #$rank',
                          style: dm(sz: 9, c: C.dim),
                        ),
                        trailing: Text(
                          '${_compactNumber(amount)} NCX',
                          style: dm(
                            sz: 11,
                            w: FontWeight.w900,
                            c: const Color(0xFFFFA300),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showGiftGoalDetails() {
    final total = (_giftSummary['totalAmount'] as num?)?.toInt() ?? 0;
    final target = (_giftSummary['goalTarget'] as num?)?.toInt() ?? 100;
    final remaining = (target - total).clamp(0, target);
    final progress = target <= 0
        ? 0.0
        : (total / target).clamp(0.0, 1.0).toDouble();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0C0E14),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LIVE GIFT GOAL',
                style: syne(sz: 15, w: FontWeight.w900, c: C.text),
              ),
              const SizedBox(height: 8),
              Text(
                '${_compactNumber(total)} / ${_compactNumber(target)} NCX',
                style: dm(
                  sz: 22,
                  w: FontWeight.w900,
                  c: const Color(0xFFFFA300),
                ),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: C.dim,
                  color: const Color(0xFFFF176B),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                remaining == 0
                    ? 'Goal reached. The next milestone is refreshing.'
                    : '${_compactNumber(remaining)} NCX to the next milestone.',
                style: dm(sz: 11, c: C.sub),
              ),
            ],
          ),
        ),
      ),
    );
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
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _showLiveAudience,
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
                          border: Border.all(color: C.dim),
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
                                  colors: [
                                    Color(0xFFFF176B),
                                    Color(0xFF00E5FF),
                                  ],
                                ),
                              ),
                              child: CircleAvatar(
                                backgroundColor: const Color(0xFF153B50),
                                backgroundImage: _hostAvatar.isEmpty
                                    ? null
                                    : CachedNetworkImageProvider(_hostAvatar),
                                child: _hostAvatar.isEmpty
                                    ? Text(
                                        _hostDisplayName[0].toUpperCase(),
                                        style: dm(
                                          sz: 11,
                                          w: FontWeight.w900,
                                          c: C.text,
                                        ),
                                      )
                                    : null,
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
                                            c: C.text,
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
                                      Icon(
                                        Icons.visibility_outlined,
                                        color: C.sub,
                                        size: 10,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        '$_viewerCount viewers',
                                        style: dm(sz: 8, c: C.sub),
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
                  style: syne(sz: 10, w: FontWeight.w900, c: C.text),
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
                      : '$topGifterName � ${_compactNumber(topGifterAmount)}',
                  onTap: _showGiftLeaderboard,
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
                  onTap: _showGiftGoalDetails,
                ),
              ),
              if (_hasPublishingGuests) ...[
                const SizedBox(width: 7),
                Expanded(
                  child: _compactHudChip(
                    icon: Icons.rocket_launch_rounded,
                    iconColor: const Color(0xFFA78BFA),
                    title: 'RANKING',
                    value: _giftLeaderboard.isEmpty
                        ? 'No gifts yet'
                        : 'Top ${_giftLeaderboard.length}',
                    onTap: _showGiftLeaderboard,
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
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.52),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: C.dim),
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
                    style: dm(sz: 7, w: FontWeight.w800, c: C.sub),
                  ),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: dm(sz: 8, w: FontWeight.w700, c: C.text),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 2),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 2,
                        backgroundColor: C.dim,
                        color: const Color(0xFFFF176B),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
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
        border: Border.all(color: C.dim),
      ),
      child: loading
          ? Padding(
              padding: EdgeInsets.all(10),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: C.text,
              ),
            )
          : Icon(icon, color: C.text, size: 19),
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
                final avatar = _commentOwnerAvatar(c);
                final userName = _commentOwnerName(c);
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
                              color: C.text.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: syncStatus == 'failed'
                                    ? Colors.redAccent.withOpacity(0.6)
                                    : C.text.withOpacity(0.05),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 10,
                                  backgroundColor: C.dim,
                                  backgroundImage: avatar.isNotEmpty
                                      ? CachedNetworkImageProvider(avatar)
                                      : null,
                                  child: avatar.isEmpty
                                      ? Text(
                                          userName[0].toUpperCase(),
                                          style: dm(
                                            sz: 8,
                                            w: FontWeight.bold,
                                            c: C.sub,
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
                                          text: '$userName: ',
                                          style: dm(
                                            sz: 11,
                                            w: FontWeight.bold,
                                            c: C.brand,
                                          ),
                                        ),
                                        TextSpan(
                                          text: '${c['text']}',
                                          style: dm(sz: 11, c: C.text),
                                        ),
                                        TextSpan(
                                          text:
                                              '  ${_commentTimeLabel(c)}'
                                              '${edited ? ' edited' : ''}',
                                          style: dm(sz: 9, c: C.dim),
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
                                        : C.dim,
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
                                      c: C.text,
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
                                        c: C.text,
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
                    color: C.text.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: C.dim),
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
                      style: dm(sz: 13, c: C.text),
                      onSubmitted: (_) => _sendComment(),
                      decoration: InputDecoration(
                        hintText: 'Say something...',
                        hintStyle: dm(sz: 13, c: C.dim),
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
                  color: C.text,
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
                  color: C.dim,
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
                                style: dm(sz: 8, c: C.sub),
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
          ? widget.state.myDisplayName
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
        debugPrint('?? Fetch listings failed: $e');
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
                color: C.dim,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'PIN A PRODUCT',
              style: syne(sz: 16, w: FontWeight.bold, c: C.text),
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
                  style: dm(sz: 13, c: C.text),
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
                  style: dm(sz: 13, c: C.dim),
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
                            color: C.dim,
                            child: Icon(
                              Icons.shopping_bag_outlined,
                              color: C.dim,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                      title: Text(title, style: dm(sz: 13, c: C.text)),
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

  Future<void> _showGiftPicker({
    String? receiverId,
    String? receiverName,
  }) async {
    final gifts = await widget.state.financeGifting.fetchGiftItems();
    if (!mounted) return;
    var sending = false;
    final giftReceiverName = receiverName ?? _hostDisplayName;

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
            final giftReceiverId = receiverId ?? _hostUserId;
            if (senderId == null || giftReceiverId == null) {
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
            if (senderId == giftReceiverId) {
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
              receiverId: giftReceiverId,
              giftItemId: gift.id,
              ncxAmount: gift.ncxValue,
              contextType: 'live_stream',
              contextId: _channelName,
              contextNote: 'Live gift for $giftReceiverName: ${gift.name}',
              senderName: widget.state.myDisplayName ?? 'Viewer',
              senderAvatar: widget.state.myAvatarUrl,
              currentBalance: widget.state.coinBalance,
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
                    color: C.dim,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Send a gift to support $giftReceiverName!',
                      style: syne(sz: 12, w: FontWeight.bold, c: C.text),
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
                          c: isSelected ? C.brand : C.dim,
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
                          color: C.text.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: C.dim),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 40,
                              height: 40,
                              child: () {
                                final url = gift.imageUrl ?? 'https://anregykcgolpgxecfxej.supabase.co/storage/v1/object/public/gift-icons/${gift.id}.jpeg';
                                return ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: CachedNetworkImage(
                                    imageUrl: url,
                                    fit: BoxFit.cover,
                                    placeholder: (_, __) => Center(child: Text(gift.emoji, style: const TextStyle(fontSize: 32))),
                                    errorWidget: (_, __, ___) => Center(child: Text(gift.emoji, style: const TextStyle(fontSize: 32))),
                                  ),
                                );
                              }(),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              gift.name,
                              style: dm(
                                sz: 11,
                                w: FontWeight.bold,
                                c: C.text,
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
              side: BorderSide(color: C.dim),
            ),
            title: Text(
              'LEAVE CO-STREAM?',
              style: syne(sz: 16, w: FontWeight.bold, c: C.text),
            ),
            content: Text(
              'Are you sure you want to stop broadcasting and return to silent viewing?',
              style: dm(sz: 13, c: C.sub),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  'CANCEL',
                  style: syne(sz: 12, w: FontWeight.bold, c: C.dim),
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
          'name': widget.state.myDisplayName ?? 'Viewer',
          'username': widget.state.myUsername ?? '',
          'avatar': widget.state.myAvatarUrl ?? '',
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
                    color: C.dim,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'GUEST CONTROL CONSOLE',
                      style: syne(sz: 15, w: FontWeight.bold, c: C.text),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: C.text.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: C.dim),
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
                        Icon(
                          Icons.people_outline,
                          color: C.dim,
                          size: 40,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No active co-hosting requests.',
                          style: dm(sz: 12, c: C.dim),
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
                            color: C.text.withOpacity(0.02),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: C.text.withOpacity(0.05),
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
                                    ? Icon(
                                        Icons.person,
                                        size: 18,
                                        color: C.dim,
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
                                    c: C.text,
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

                Divider(color: C.dim, height: 32),

                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'INVITE A VIEWER TO CO-STREAM',
                    style: syne(
                      sz: 10,
                      w: FontWeight.bold,
                      c: C.dim,
                      ls: 1,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: C.text.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: C.dim),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search, color: C.dim, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          style: dm(sz: 13, c: C.text),
                          enabled: !inviteSending,
                          decoration: InputDecoration(
                            hintText: 'Search online viewer by username...',
                            hintStyle: dm(sz: 13, c: C.dim),
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
          style: syne(sz: 12, w: FontWeight.bold, c: C.text),
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
                  color: C.dim,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Icon(Icons.share_outlined, color: C.text),
                title: Text('Share live', style: dm(c: C.text)),
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
                title: Text('Open live shop', style: dm(c: C.text)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openLiveShop();
                },
              ),
              if (widget.isHost) ...[
                ListTile(
                  leading: const Icon(
                    Icons.auto_awesome,
                    color: Color(0xFF00E5FF),
                  ),
                  title: Text('Studio Effects & Beauty', style: dm(c: C.text)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openLiveEffectsSheet();
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.push_pin_outlined,
                    color: Colors.amber,
                  ),
                  title: Text('Pin a product', style: dm(c: C.text)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showProductPicker();
                  },
                ),
              ],
              ListTile(
                leading: const Icon(
                  Icons.emoji_emotions_outlined,
                  color: Color(0xFFFF176B),
                ),
                title: Text('Choose a reaction', style: dm(c: C.text)),
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
                          style: dm(sz: 7, w: FontWeight.w900, c: C.text),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: dm(sz: 8, w: FontWeight.w600, c: C.text),
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
                  color: C.text.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: C.text.withOpacity(0.12)),
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
                        c: C.text,
                        ls: 1.5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'To guarantee livestream security and unlock instant shopping features, a biometric face-match is required.',
                      textAlign: TextAlign.center,
                      style: dm(sz: 12, c: C.sub, h: 1.5),
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
                          c: C.dim,
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

/// Simple rule-of-thirds composition grid overlay.
class _GridOverlay extends StatelessWidget {
  const _GridOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(painter: _GridPainter()),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 0.7;
    // Two vertical lines (rule of thirds)
    canvas.drawLine(Offset(size.width / 3, 0), Offset(size.width / 3, size.height), paint);
    canvas.drawLine(Offset(size.width * 2 / 3, 0), Offset(size.width * 2 / 3, size.height), paint);
    // Two horizontal lines
    canvas.drawLine(Offset(0, size.height / 3), Offset(size.width, size.height / 3), paint);
    canvas.drawLine(Offset(0, size.height * 2 / 3), Offset(size.width, size.height * 2 / 3), paint);
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

/// Bilateral Facial Symmetry alignment guide and landmark balance overlay.
class _FacialSymmetryGuideOverlay extends StatelessWidget {
  final double intensity;
  final bool mirrorLeft;

  const _FacialSymmetryGuideOverlay({
    required this.intensity,
    required this.mirrorLeft,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _FacialSymmetryPainter(
          intensity: intensity,
          mirrorLeft: mirrorLeft,
        ),
      ),
    );
  }
}

class _FacialSymmetryPainter extends CustomPainter {
  final double intensity;
  final bool mirrorLeft;

  _FacialSymmetryPainter({
    required this.intensity,
    required this.mirrorLeft,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final alpha = (intensity * 0.7).clamp(0.18, 0.75);

    // Glowing vertical center axis
    final glowPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: alpha * 0.35)
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: alpha)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Dashed center line
    const dashHeight = 8.0;
    const dashSpace = 6.0;
    double startY = size.height * 0.12;
    final endY = size.height * 0.88;

    while (startY < endY) {
      final segEnd = (startY + dashHeight).clamp(0.0, endY);
      canvas.drawLine(Offset(cx, startY), Offset(cx, segEnd), glowPaint);
      canvas.drawLine(Offset(cx, startY), Offset(cx, segEnd), linePaint);
      startY += dashHeight + dashSpace;
    }

    // Facial landmark reference cross-ticks
    final markerPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: alpha)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    // Eye level tick & balance dots (y = 0.38)
    final eyeY = size.height * 0.38;
    canvas.drawLine(Offset(cx - 24, eyeY), Offset(cx + 24, eyeY), markerPaint);
    final dotPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: alpha * 0.85)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx - 55, eyeY), 2.5, dotPaint);
    canvas.drawCircle(Offset(cx + 55, eyeY), 2.5, dotPaint);

    // Nose level tick (y = 0.48)
    final noseY = size.height * 0.48;
    canvas.drawLine(Offset(cx - 10, noseY), Offset(cx + 10, noseY), markerPaint);

    // Lip level tick (y = 0.58)
    final lipY = size.height * 0.58;
    canvas.drawLine(Offset(cx - 18, lipY), Offset(cx + 18, lipY), markerPaint);

    // Chin level tick (y = 0.68)
    final chinY = size.height * 0.68;
    canvas.drawLine(Offset(cx - 12, chinY), Offset(cx + 12, chinY), markerPaint);

    // Direction indicator near upper axis (L ➔ R or R ➔ L)
    final textPainter = TextPainter(
      text: TextSpan(
        text: mirrorLeft ? 'L ➔ R' : 'R ➔ L',
        style: TextStyle(
          color: const Color(0xFF00E5FF).withValues(alpha: alpha),
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, Offset(cx - textPainter.width / 2, size.height * 0.26));
  }

  @override
  bool shouldRepaint(_FacialSymmetryPainter old) =>
      old.intensity != intensity || old.mirrorLeft != mirrorLeft;
}

/// Real-time Studio Makeup overlay for women and men.
class _StudioMakeupOverlay extends StatelessWidget {
  final int gender; // 1 = Women, 2 = Men
  final int style;
  final double intensity;

  const _StudioMakeupOverlay({
    required this.gender,
    required this.style,
    required this.intensity,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _StudioMakeupPainter(
          gender: gender,
          style: style,
          intensity: intensity,
        ),
      ),
    );
  }
}

class _StudioMakeupPainter extends CustomPainter {
  final int gender;
  final int style;
  final double intensity;

  _StudioMakeupPainter({
    required this.gender,
    required this.style,
    required this.intensity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final m = intensity.clamp(0.0, 1.0);

    if (gender == 1) {
      // ── Women: Soft Cheek Blush & Hydrating Lip Tint ─────────
      final blushColor = style == 0
          ? const Color(0xFFFF5277) // Rosy Glow (petal rose)
          : style == 1
              ? const Color(0xFFFF8A65) // Natural Nude (soft peach)
              : const Color(0xFFE91E63); // Sunset Glam (berry blush)

      final blushAlpha = (m * 0.17).clamp(0.0, 0.22);
      final blushRadius = size.width * 0.22;

      // Left cheek blush
      final leftCheek = Offset(cx - (size.width * 0.20), size.height * 0.44);
      final leftBlushPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            blushColor.withValues(alpha: blushAlpha),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: leftCheek, radius: blushRadius));
      canvas.drawCircle(leftCheek, blushRadius, leftBlushPaint);

      // Right cheek blush
      final rightCheek = Offset(cx + (size.width * 0.20), size.height * 0.44);
      final rightBlushPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            blushColor.withValues(alpha: blushAlpha),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: rightCheek, radius: blushRadius));
      canvas.drawCircle(rightCheek, blushRadius, rightBlushPaint);

      // Lip hydration & tint
      final lipCenter = Offset(cx, size.height * 0.58);
      final lipRadius = size.width * 0.11;
      final lipAlpha = (m * 0.15).clamp(0.0, 0.20);
      final lipPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            blushColor.withValues(alpha: lipAlpha),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: lipCenter, radius: lipRadius));
      canvas.drawCircle(lipCenter, lipRadius, lipPaint);
    } else if (gender == 2) {
      // ── Men: Groomed Jaw Contour & Brow Framing ───────────────
      final contourAlpha = (m * 0.14).clamp(0.0, 0.18);
      final contourColor = style == 2
          ? const Color(0xFF6D4C41) // Sun-Kissed bronze
          : const Color(0xFF37474F); // Clean / Sharp sculpted contour

      // Jawline shading: subtle shadow gradient along jaw contour
      final jawPath = Path()
        ..moveTo(cx - (size.width * 0.35), size.height * 0.56)
        ..quadraticBezierTo(
          cx - (size.width * 0.26), size.height * 0.70,
          cx, size.height * 0.73,
        )
        ..quadraticBezierTo(
          cx + (size.width * 0.26), size.height * 0.70,
          cx + (size.width * 0.35), size.height * 0.56,
        );

      final jawPaint = Paint()
        ..color = contourColor.withValues(alpha: contourAlpha)
        ..strokeWidth = size.width * 0.08
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);

      canvas.drawPath(jawPath, jawPaint);

      // Brow definition accent: subtle contrast enhancement
      final browPaint = Paint()
        ..color = Colors.black.withValues(alpha: contourAlpha * 0.6)
        ..strokeWidth = size.width * 0.04
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

      canvas.drawLine(
        Offset(cx - (size.width * 0.22), size.height * 0.35),
        Offset(cx - (size.width * 0.06), size.height * 0.34),
        browPaint,
      );
      canvas.drawLine(
        Offset(cx + (size.width * 0.06), size.height * 0.34),
        Offset(cx + (size.width * 0.22), size.height * 0.35),
        browPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_StudioMakeupPainter old) =>
      old.gender != gender || old.style != style || old.intensity != intensity;
}

class _ReticleViewfinder extends StatelessWidget {
  const _ReticleViewfinder({this.isFocusing = false});

  final bool isFocusing;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: isFocusing ? 0.4 : 1.0),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      builder: (_, opacity, child) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: isFocusing ? 145 : 175,
          height: isFocusing ? 130 : 160,
          decoration: const BoxDecoration(color: Colors.transparent),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 4 corner L-brackets — cyan when focusing
              Positioned(
                top: 0, left: 0,
                child: _corner(top: true, left: true, isFocusing: isFocusing),
              ),
              Positioned(
                top: 0, right: 0,
                child: _corner(top: true, left: false, isFocusing: isFocusing),
              ),
              Positioned(
                bottom: 0, left: 0,
                child: _corner(top: false, left: true, isFocusing: isFocusing),
              ),
              Positioned(
                bottom: 0, right: 0,
                child: _corner(top: false, left: false, isFocusing: isFocusing),
              ),

              // Center content
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: isFocusing
                    ? Column(
                        key: const ValueKey('focusing'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.center_focus_strong_outlined,
                            color: Color(0xFF00E5FF),
                            size: 28,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Focusing...',
                            style: dm(
                              sz: 12,
                              w: FontWeight.w700,
                              c: const Color(0xFF00E5FF),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        key: const ValueKey('ready'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.camera_alt_outlined,
                            color: Colors.white,
                            size: 28,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Camera ready',
                            style: dm(sz: 12, w: FontWeight.w700, c: Colors.white),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Tap to focus',
                            style: dm(sz: 10, c: Colors.white70),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _corner({required bool top, required bool left, required bool isFocusing}) {
    final color = isFocusing ? const Color(0xFF00E5FF) : Colors.white;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        border: Border(
          top: top ? BorderSide(color: color, width: 2.2) : BorderSide.none,
          bottom: !top ? BorderSide(color: color, width: 2.2) : BorderSide.none,
          left: left ? BorderSide(color: color, width: 2.2) : BorderSide.none,
          right: !left ? BorderSide(color: color, width: 2.2) : BorderSide.none,
        ),
        borderRadius: BorderRadius.only(
          topLeft: top && left ? const Radius.circular(8) : Radius.zero,
          topRight: top && !left ? const Radius.circular(8) : Radius.zero,
          bottomLeft: !top && left ? const Radius.circular(8) : Radius.zero,
          bottomRight: !top && !left ? const Radius.circular(8) : Radius.zero,
        ),
      ),
    );
  }
}





