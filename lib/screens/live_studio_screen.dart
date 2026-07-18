import 'package:livekit_client/livekit_client.dart';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import '../widgets/live_studio/live_enforcement_overlay.dart';
import '../utils/error_handler.dart';

class LiveStudioScreen extends StatefulWidget {
  final AppState state;
  final String channelName;
  final bool isHost;
  final String? hostId;

  const LiveStudioScreen({
    super.key,
    required this.state,
    required this.channelName,
    this.isHost = false,
    this.hostId,
  });

  @override
  State<LiveStudioScreen> createState() => _LiveStudioScreenState();
}

class _LiveStudioScreenState extends State<LiveStudioScreen> with WidgetsBindingObserver {
  bool _localUserJoined = false;
  String? _initError;
  bool _isInitializing = false;
  int _automaticAuthRetries = 0;
  static const int _maxAutomaticAuthRetries = 1;

  // Co-Hosting & Guest Interaction State
  bool _isRequestPending = false;
  bool _isCoHosting = false;

  // Live Comments & Gifting Sync State
  final TextEditingController _commentController = TextEditingController();
  List<Map<String, dynamic>> _liveComments = [];
  Timer? _commentsTimer;
  StreamSubscription<Map<String, dynamic>>? _eventsSubscription;
  StreamSubscription<Map<String, dynamic>>? _giftEventsSubscription;
  late final Stream<Map<String, dynamic>> _liveGiftEvents;
  String? _lastHandledEventKey;
  bool _requiresVerification = false;

  // ── Smart Live Verification State ──────────────────────────────────────
  // Silent background face pulse timer — fires every 5 minutes while live as host.
  Timer? _facePulseTimer;
  static const Duration _facePulseInterval = Duration(minutes: 5);
  // Full re-verification is required once every 30 days.
  static const Duration _reverifyPeriod = Duration(days: 30);
  // Pref key is user-scoped to prevent cross-account bleed.
  String get _liveVerifPrefKey => 'live_verified_at_${widget.state.user?.id ?? "anon"}';
  
  // Safety Enforcement State
  int _consecutiveViolations = 0;
  bool _isEnforcementActive = false;
  String? _enforcementReason;
  String? get _hostUserId => widget.hostId ?? (widget.isHost ? widget.state.user?.id : null);
  int get _viewerCount {
    final room = widget.state.live.room;
    if (room == null) return 0;
    return room.remoteParticipants.length + (room.localParticipant != null ? 1 : 0);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Check cached verification state BEFORE calling initAgora.
    // If already verified within 30 days the user goes live with zero friction.
    unawaited(_prepareLiveStudio());

    // Initialize with empty real comments. Sync will fetch existing comments.
    _liveComments = [];

    _liveGiftEvents = widget.state.financeGifting
        .watchLiveGifts(widget.channelName)
        .map((gift) => <String, dynamic>{'type': 'gift', 'data': gift})
        .asBroadcastStream();
    _giftEventsSubscription = _liveGiftEvents.listen((event) {
      final gift = Map<String, dynamic>.from(event['data'] as Map? ?? const {});
      final userId = widget.state.user?.id;
      if (userId != null && (gift['senderId'] == userId || gift['receiverId'] == userId)) {
        widget.state.syncVault();
      }
    });

    _startCommentsSync();

    // Guest requests are driven by live stream events.
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
    _eventsSubscription = widget.state.live.listenToEvents(widget.channelName).listen((event) {
      if (!mounted || event.isEmpty) return;

      final eventKey = (event['_id'] ?? '${event['type']}_${event['userId']}_${event['timestamp']}').toString();
      if (eventKey == _lastHandledEventKey) return;
      _lastHandledEventKey = eventKey;

      final type = event['type']?.toString();
      if (type == 'cohost_request' && widget.isHost) {
        final data = Map<String, dynamic>.from(event['data'] ?? {});
        final guestId = event['userId']?.toString();
        if (guestId == null || guestId.isEmpty) return;

        final exists = widget.state.liveGuestRequests.any((req) => req['userId'] == guestId);
        if (!exists) {
          setState(() {
            widget.state.liveGuestRequests.add({
              'userId': guestId,
              'name': data['name'] ?? 'Viewer',
              'avatar': data['avatar'] ?? '',
            });
          });
        }
      } else if (type == 'cohost_decision' && !widget.isHost) {
        final guestId = event['userId']?.toString();
        if (guestId != widget.state.user?.id || !_isRequestPending) return;

        final data = Map<String, dynamic>.from(event['data'] ?? {});
        final accepted = data['accepted'] == true;
        if (accepted) {
          widget.state.live.switchRoleToBroadcaster().then((_) {
            if (!mounted) return;
            setState(() {
              _isCoHosting = true;
              _isRequestPending = false;
            });
            _showToast('Request approved. You are now co-streaming live!');
          }).catchError((e) {
            if (mounted) _showToast('Could not start co-streaming: $e');
          });
        } else {
          setState(() => _isRequestPending = false);
          _showToast('Co-hosting request declined');
        }
      }
    });
  }


  void _startCommentsSync() {
    _commentsTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) return;
      try {
        final newComments = await widget.state.live.fetchLiveComments(widget.channelName);
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

  void _sendComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    _commentController.clear();

    // Optimistic local update
    final myName = widget.state.myProfile?['full_name'] ?? widget.state.user?.email ?? 'Viewer';
    setState(() {
      _liveComments.insert(0, {'user': myName, 'text': text});
    });

    try {
      await widget.state.live.sendLiveComment(widget.channelName, myName, text);
    } catch (e) {
      debugPrint('⚠️ Send Comment failed: $e');
    }
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

      // Metadata/chat startup is optional and must never block video.
      await liveService.init();
      _startLiveEventSync();

      if (widget.isHost) {
        await liveService.startStreaming(widget.channelName);
      } else {
        await liveService.joinAsViewer(widget.channelName);
      }

      if (!mounted) return;
      setState(() {
        _localUserJoined = true;
      });
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
      final is403 = errStr.contains('403') || errStr.toLowerCase().contains('identity verification required');
      if (is403) {
        var verified = false;
        try {
          verified = await _hasCompletedIdentityVerification();
        } catch (verificationError) {
          debugPrint('Necxa Live: Verification lookup failed: $verificationError');
        }

        // Only show the verification card if their cached credential is expired or absent.
        final prefs = await SharedPreferences.getInstance();
        final rawTs = prefs.getString(_liveVerifPrefKey);
        final lastVerified = rawTs != null ? DateTime.tryParse(rawTs) : null;
        final expired = lastVerified == null || DateTime.now().difference(lastVerified) > _reverifyPeriod;

        if (verified && _automaticAuthRetries < _maxAutomaticAuthRetries) {
          _automaticAuthRetries++;
          await _markLiveVerified();
          retryAfterDelay = true;
        } else if (!verified && expired) {
          setState(() {
            _initError = 'Identity verification required. Please verify to go live.';
            _requiresVerification = true;
          });
        } else if (_automaticAuthRetries < _maxAutomaticAuthRetries) {
          _automaticAuthRetries++;
          retryAfterDelay = true;
        } else {
          setState(() {
            _initError = 'Live authentication was rejected. Tap retry, or sign in again if it continues.';
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
      debugPrint('Necxa Live: Authentication is still propagating; retrying once.');
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) await _initLiveKit();
    }
  }

  String _liveStartupError(dynamic error) {
    if (error is TimeoutException) {
      final detail = error.message.toLowerCase();
      if (detail.contains('permission') || detail.contains('camera') || detail.contains('microphone')) {
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
    final verifiedAt = verifiedAtRaw != null ? DateTime.tryParse(verifiedAtRaw) : null;
    final verifiedRecently = verifiedAt != null && DateTime.now().difference(verifiedAt) <= _reverifyPeriod;

    final localVerificationComplete = widget.state.lastIDResult?.verified == true ||
        widget.state.lastSelfieResult?.faceMatch == true ||
        widget.state.idVerified;
    final profileVerified = profile['verified'] == true || profile['face_verified'] == true || verifiedRecently;

    return localVerificationComplete || profileVerified;
  }

  // ── SILENT BACKGROUND FACE PULSE ────────────────────────────────────────

  /// Starts a periodic timer that silently captures a frame from the Agora engine
  /// and runs a background liveness check — zero UI disruption.
  void _startSilentFacePulse() {
    _facePulseTimer?.cancel();
    _facePulseTimer = Timer.periodic(_facePulseInterval, (_) => _runSilentFaceCheck());
    debugPrint('🛡️ Live: Silent face pulse started (every ${_facePulseInterval.inMinutes}m).');
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
    final videoTrack = localParticipant.videoTrackPublications.firstOrNull?.track;
    if (videoTrack == null) return;

    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/live_pulse_${DateTime.now().millisecondsSinceEpoch}.jpg';

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
      try { file.deleteSync(); } catch (_) {}

      if (!mounted) return;

      if (!safetyResult.safe && safetyResult.severity != 'none') {
        _consecutiveViolations++;
        debugPrint('🚨 Live Safety Violation [$_consecutiveViolations]: ${safetyResult.severity} - ${safetyResult.reason}');

        // Escalation matrix:
        // Critical (e.g. CSAM, weapons) -> immediate termination
        // High (e.g. drug use, nudity) -> strike 2 termination
        if (safetyResult.isCritical || (safetyResult.isHigh && _consecutiveViolations >= 2)) {
          _enforceSafetyTermination(safetyResult.reason ?? 'Community guidelines violation detected.');
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
    widget.state.live.leaveChannel();
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
    _eventsSubscription?.cancel();
    _giftEventsSubscription?.cancel();
    _stopSilentFacePulse();
    _commentController.dispose();
    widget.state.live.leaveChannel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // Pause resource-intensive operations
      _commentsTimer?.cancel();
      _stopSilentFacePulse();
      widget.state.live.setAVEnabled(false);
      debugPrint('🛡️ Live Studio: App minimized, pausing AV & Timers');
    } else if (state == AppLifecycleState.resumed) {
      // Resume operations
      if (_localUserJoined && !_isEnforcementActive) {
        widget.state.live.setAVEnabled(true);
        _startCommentsSync();
        if (widget.isHost) _startSilentFacePulse();
        debugPrint('🛡️ Live Studio: App resumed, restarting AV & Timers');
      }
    }
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

          // ── Shield Verification Wall (403 Handler) ──
          if (_requiresVerification)
            _buildShieldVerificationCard(),

          // ── Safety Enforcement Wall (Violations) ──
          if (_isEnforcementActive)
            LiveEnforcementOverlay(
              enforcementReason: _enforcementReason,
              onClose: () => Navigator.pop(context),
            ),

          // ── Gifting Layer ──
          LiveGiftingOverlay(
            eventStream: _liveGiftEvents,
          ),

          // ── Glass Overlay Layer ──
          _buildHUD(),

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
                    border: Border.all(color: C.brand.withOpacity(1 - value), width: 2),
                  ),
                  child: const Center(
                    child: Icon(Icons.videocam_outlined, color: Colors.white24, size: 30),
                  ),
                );
              },
              onEnd: () {}, // Handled by repeating via a loop if needed, but for now a simple pulse
            ),
            const SizedBox(height: 24),
            if (_initError != null && !_requiresVerification) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(_initError!, textAlign: TextAlign.center, style: dm(sz: 10, c: Colors.white38)),
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: _initLiveKit,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: C.brand,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(color: C.brand.withOpacity(0.3), blurRadius: 8, spreadRadius: 1),
                    ],
                  ),
                  child: Text('RETRY STREAM SYNC', style: syne(sz: 11, w: FontWeight.bold, c: Colors.black)),
                ),
              ),
            ] else ...[
              const SizedBox(height: 24),
              Text('INITIALIZING ENGINE...', style: syne(sz: 10, w: FontWeight.w900, c: Colors.white38, ls: 2)),
            ],
          ],
        ),
      );
    }

    final room = widget.state.live.room!;
    final participants = <Participant>[];
    if (room.localParticipant != null) {
      participants.add(room.localParticipant!);
    }
    participants.addAll(room.remoteParticipants.values);
    
    return GridView.builder(
      padding: EdgeInsets.zero,
      itemCount: participants.length,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: participants.length > 1 ? 2 : 1,
        childAspectRatio: 9 / 16,
      ),
      itemBuilder: (context, index) {
        final participant = participants[index];
        final videoPub = participant.videoTrackPublications.firstOrNull;
        if (videoPub != null && videoPub.track != null) {
          return Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white10, width: 0.5),
            ),
            child: VideoTrackRenderer(
              videoPub.track as VideoTrack,
            ),
          );
        } else {
          return Container(
            color: Colors.black,
            child: const Center(
              child: Icon(Icons.person, color: Colors.white24, size: 50),
            ),
          );
        }
      },
    );
  }

  Widget _buildHUD() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 10,
      left: 16,
      right: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Creator Header Row ──
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Creator Info & Pinned Product Button Row
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: C.brand,
                          child: Text(widget.channelName[0].toUpperCase(), style: const TextStyle(fontSize: 10, color: Colors.white)),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.isHost ? (widget.state.myProfile?['full_name'] ?? widget.channelName) : widget.channelName, 
                              style: syne(sz: 11, w: FontWeight.bold, c: Colors.white)
                            ),
                            Row(
                              children: [
                                Text('$_viewerCount Viewers', style: dm(sz: 9, c: Colors.white70)),
                                const SizedBox(width: 4),
                                if (widget.state.currentGps != null) ...[
                                  const Icon(Icons.location_on, color: C.brand, size: 8),
                                  Text(
                                    '${widget.state.currentGps!.latitude.toStringAsFixed(2)}, ${widget.state.currentGps!.longitude.toStringAsFixed(2)}',
                                    style: dm(sz: 8, c: C.brand),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(4),
                            boxShadow: [
                              BoxShadow(color: Colors.red.withOpacity(0.5), blurRadius: 8),
                            ],
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.fiber_manual_record, color: Colors.white, size: 8),
                              const SizedBox(width: 4),
                              Text('LIVE', style: syne(sz: 9, w: FontWeight.w900, c: Colors.white)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Identity Shield
                        if (widget.isHost)
                          const Icon(Icons.verified_user, color: Color(0xFF00E5FF), size: 14),
                      ],
                    ),
                  ),
                  if (widget.isHost) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _showProductPicker,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.4),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white10),
                        ),
                        child: const Icon(Icons.push_pin_outlined, color: Colors.yellow, size: 16),
                      ),
                    ),
                  ],
                ],
              ),

              // Close Button
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.4),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 12),

          // ── Stats Sub-Header Row (Missing High-Fidelity Components) ──
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // 1. Top Gifter Card
              Expanded(
                child: _buildHUDCard(
                  title: '🔥 Top Gifter',
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: Colors.white10,
                        // Cached: streamer's own avatar, served from disk after first load
                        backgroundImage: widget.state.myProfile?['avatar_url'] != null
                            ? CachedNetworkImageProvider(widget.state.myProfile!['avatar_url'] as String)
                            : null,
                        child: widget.state.myProfile?['avatar_url'] == null
                            ? const Icon(Icons.person, size: 12, color: Colors.white54)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Jane D.', style: dm(sz: 9, w: FontWeight.bold, c: Colors.white)),
                            Row(
                              children: [
                                const Icon(Icons.monetization_on, color: Colors.amber, size: 10),
                                const SizedBox(width: 2),
                                Text('24.5K', style: dm(sz: 9, w: FontWeight.w900, c: Colors.amber)),
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

              // 2. Goal Card
              Expanded(
                child: _buildHUDCard(
                  title: '🎁 Goal',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Reach 5K Gifts', style: dm(sz: 8, w: FontWeight.bold, c: Colors.white70)),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: const LinearProgressIndicator(
                          value: 3.2 / 5,
                          backgroundColor: Colors.white10,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.pink),
                          minHeight: 6,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text('3.2K / 5K', style: dm(sz: 8, w: FontWeight.w900, c: Colors.pink)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // 3. Viewers Card
              Expanded(
                child: _buildHUDCard(
                  title: '👥 Viewers',
                  child: Row(
                    children: [
                      // Viewer count avatars — local placeholder circles, zero CDN egress
                      SizedBox(
                        width: 45,
                        height: 20,
                        child: Stack(
                          children: [
                            Positioned(left: 0, child: CircleAvatar(radius: 10, backgroundColor: Colors.deepPurple.shade400)),
                            Positioned(left: 10, child: CircleAvatar(radius: 10, backgroundColor: Colors.teal.shade400)),
                            Positioned(left: 20, child: CircleAvatar(radius: 10, backgroundColor: Colors.orange.shade400)),
                          ],
                        ),
                      ),
                      Text('$_viewerCount', style: syne(sz: 10, w: FontWeight.w900, c: Colors.white)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHUDCard({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title.toUpperCase(), style: syne(sz: 8, w: FontWeight.w900, c: Colors.white38, ls: 1)),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  Widget _buildInteractionUI() {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final pinned = widget.state.pinnedLiveProduct;
    return Positioned(
      bottom: (bottomInset > 0 ? bottomInset : MediaQuery.of(context).padding.bottom) + 20,
      left: 16,
      right: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Chat Preview
          SizedBox(
            height: pinned != null ? 120 : 200,
            child: ListView.builder(
              itemCount: _liveComments.length,
              reverse: true,
              padding: const EdgeInsets.only(bottom: 12),
              itemBuilder: (context, index) {
                final c = _liveComments[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: UnconstrainedBox(
                    alignment: Alignment.centerLeft,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white.withOpacity(0.05)),
                          ),
                          child: RichText(
                            text: TextSpan(
                              children: [
                                TextSpan(text: '${c['user']}: ', style: dm(sz: 11, w: FontWeight.bold, c: C.brand)),
                                TextSpan(text: '${c['text']}', style: dm(sz: 11, c: Colors.white)),
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
                    border: Border.all(color: C.brand.withOpacity(0.4), width: 1.5),
                    boxShadow: [
                      BoxShadow(color: C.brand.withOpacity(0.15), blurRadius: 20, spreadRadius: 5),
                    ],
                  ),
                  child: Row(
                    children: [
                      // Pinned product thumbnail \u2014 use real data, cache it, never hit CDN repeatedly
                      Container(
                        width: 54, height: 54,
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
                                  errorWidget: (_, __, ___) => const Icon(Icons.shopping_bag_rounded, color: C.brand, size: 28),
                                )
                              : const Icon(Icons.shopping_bag_rounded, color: C.brand, size: 28),
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
                                Text(pinned['title']?.toUpperCase() ?? 'PRODUCT', style: syne(sz: 11, w: FontWeight.w900, c: Colors.white, ls: 1)),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.pink,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text('20% OFF', style: syne(sz: 8, w: FontWeight.bold, c: Colors.white)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(ugx(pinned['price'] ?? 450000), style: dm(sz: 13, w: FontWeight.w900, c: C.brand)),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.timer_outlined, color: Color(0xFF00E5FF), size: 12),
                              const SizedBox(width: 4),
                              Text('03:15:45', style: dm(sz: 10, w: FontWeight.bold, c: const Color(0xFF00E5FF))),
                            ],
                          ),
                          const SizedBox(height: 6),
                          GestureDetector(
                            onTap: () => _openCheckout(pinned),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                gradient: brandGrad,
                                borderRadius: BorderRadius.circular(25),
                              ),
                              child: Text('BUY NOW', style: syne(sz: 10, w: FontWeight.w900, c: Colors.black)),
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
          // Action Buttons
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
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    gradient: brandGrad,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(color: C.brand.withOpacity(0.3), blurRadius: 8, spreadRadius: 1),
                    ],
                  ),
                  child: const Icon(Icons.send_rounded, color: Colors.black, size: 18),
                ),
              ),
              const SizedBox(width: 12),
              if (widget.isHost) ...[
                GestureDetector(
                  onTap: _showGiftPicker,
                  child: _actionIcon(Icons.card_giftcard, Colors.orange),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: _showGuestRequestsManager,
                  child: Stack(
                    children: [
                      _actionIcon(Icons.people_outline, const Color(0xFF00E5FF)),
                      if (widget.state.liveGuestRequests.isNotEmpty)
                        Positioned(
                          top: 2, right: 2,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                            child: Text(
                              '${widget.state.liveGuestRequests.length}',
                              style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ] else ...[
                GestureDetector(
                  onTap: _showGiftPicker,
                  child: _actionIcon(Icons.card_giftcard, Colors.orange),
                ),
                const SizedBox(width: 12),
                _actionIcon(Icons.shopping_bag_outlined, C.brand),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: _toggleGuestRequest,
                  child: _actionIcon(
                    _isCoHosting
                        ? Icons.videocam_off_outlined
                        : (_isRequestPending ? Icons.ring_volume : Icons.mic_none),
                    _isCoHosting
                        ? Colors.red
                        : (_isRequestPending ? Colors.green : Colors.white),
                  ),
                ),
              ],
              const SizedBox(width: 12),
              _actionIcon(Icons.share_outlined, Colors.white),
            ],
          ),
        ],
      ),
    );
  }

  void _showProductPicker() async {
    // Dynamically retrieve active vendor products from state/database cache
    List<Map<String, dynamic>> products = widget.state.social.shopListings;
    if (products.isEmpty) {
      try {
        products = await widget.state.social.fetchListings(limit: 30);
      } catch (e) {
        debugPrint('⚠️ Fetch listings failed: $e');
      }
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D121B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 16),
            Text('PIN A PRODUCT', style: syne(sz: 16, w: FontWeight.bold, c: Colors.white)),
            const SizedBox(height: 20),
            if (products.isEmpty)
              Padding(
                padding: const EdgeInsets.all(30),
                child: Text('No shop listings available to pin.', style: dm(sz: 13, c: Colors.white38)),
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
                    String imageUrl = 'https://images.unsplash.com/photo-1523275335684-37898b6baf30';
                    if (p['thumbnail_url'] != null && p['thumbnail_url'].toString().isNotEmpty) {
                      imageUrl = p['thumbnail_url'];
                    } else if (p['photos'] is List && (p['photos'] as List).isNotEmpty) {
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
                          width: 40, height: 40,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 40, height: 40,
                            color: Colors.white10,
                            child: const Icon(Icons.shopping_bag_outlined, color: Colors.white38, size: 18),
                          ),
                        ),
                      ),
                      title: Text(title, style: dm(sz: 13, c: Colors.white)),
                      subtitle: Text(ugx(price), style: dm(sz: 11, c: C.brand)),
                      onTap: () {
                        final mapped = {
                          'title': title,
                          'price': price,
                          'image': imageUrl,
                          'thumbnail_url': imageUrl,
                          'id': p['id'] ?? '',
                        };
                        widget.state.updatePinnedProduct(mapped);
                        widget.state.live.pinProduct(widget.channelName, mapped);
                        Navigator.pop(context);
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          Future<void> sendGift(GiftItem gift) async {
            if (sending) return;
            final senderId = widget.state.user?.id;
            final receiverId = _hostUserId;
            if (senderId == null || receiverId == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Sign in and join a live host before sending gifts.', style: dm())),
              );
              return;
            }
            if (senderId == receiverId) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('You cannot gift your own live stream.', style: dm())),
              );
              return;
            }

            if (widget.state.coinBalance < gift.ncxValue) {
              if (widget.state.coinPacks.isEmpty) {
                widget.state.coinPacks = await widget.state.financeCoinPurchases.packs();
              }
              if (!context.mounted) return;
              if (widget.state.coinPacks.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Coin packs are temporarily unavailable.', style: dm())),
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
                  purchaseContextId: widget.channelName,
                  targetGiftItemId: gift.id,
                ),
              );
              if (!context.mounted) return;
              if (purchased != true) return;
              await widget.state.syncVault();
              if (!context.mounted) return;
              if (widget.state.coinBalance < gift.ncxValue) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('The wallet still needs more NCX for this gift.', style: dm())),
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
              contextId: widget.channelName,
              contextNote: 'Live gift: ${gift.name}',
              senderName: widget.state.myProfile?['full_name']?.toString() ?? 'Viewer',
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
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Send a gift to support the streamer!', style: syne(sz: 12, w: FontWeight.bold, c: Colors.white)),
                    if (sending) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: ['Popular', 'New', 'Luxury', 'Fun', 'Bundle'].map((tab) {
                    final isSelected = tab == 'Popular';
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                            Text(gift.emoji, style: const TextStyle(fontSize: 32)),
                            const SizedBox(height: 8),
                            Text(gift.name, style: dm(sz: 11, w: FontWeight.bold, c: Colors.white), textAlign: TextAlign.center),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.monetization_on, color: Colors.amber, size: 10),
                                const SizedBox(width: 2),
                                Text('${gift.ncxValue}', style: dm(sz: 10, w: FontWeight.w900, c: Colors.amber)),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: Colors.white10)),
            title: Text('LEAVE CO-STREAM?', style: syne(sz: 16, w: FontWeight.bold, c: Colors.white)),
            content: Text('Are you sure you want to stop broadcasting and return to silent viewing?', style: dm(sz: 13, c: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('CANCEL', style: syne(sz: 12, w: FontWeight.bold, c: Colors.white38)),
              ),
              Container(
                decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(16)),
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text('LEAVE', style: syne(sz: 12, w: FontWeight.bold, c: Colors.black)),
                ),
              ),
            ],
          ),
        ),
      );

      if (confirm == true) {
        try {
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
      setState(() => _isRequestPending = false);
      _showToast('Co-hosting request canceled');
    } else {
      final userId = widget.state.user?.id;
      if (userId == null) {
        _showToast('Please sign in to request co-hosting.');
        return;
      }

      try {
        await widget.state.live.sendCoHostRequest(
          widget.channelName,
          userId,
          {
            'name': widget.state.myProfile?['full_name'] ?? widget.state.user?.email ?? 'Viewer',
            'avatar': widget.state.myProfile?['avatar_url'] ?? '',
          },
        );
        setState(() => _isRequestPending = true);
        _showToast('Co-hosting request sent to streamer. Waiting for approval...');
      } catch (e) {
        _showToast('Could not send co-host request: $e');
      }
    }
  }

  void _showGuestRequestsManager() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0C0E14),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          final requests = widget.state.liveGuestRequests;
          return Container(
            padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(height: 20),
                
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('GUEST CONTROL CONSOLE', style: syne(sz: 15, w: FontWeight.bold, c: Colors.white)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                        const Icon(Icons.people_outline, color: Colors.white24, size: 40),
                        const SizedBox(height: 12),
                        Text('No active co-hosting requests.', style: dm(sz: 12, c: Colors.white38)),
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
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.02),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withOpacity(0.05)),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                // CachedNetworkImageProvider: each viewer's avatar cached per URL
                                backgroundImage: req['avatar'] != null && (req['avatar'] as String).isNotEmpty
                                    ? CachedNetworkImageProvider(req['avatar'] as String)
                                    : null,
                                child: req['avatar'] == null || (req['avatar'] as String).isEmpty
                                    ? const Icon(Icons.person, size: 18, color: Colors.white54)
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  req['name'] as String,
                                  style: syne(sz: 13, w: FontWeight.bold, c: Colors.white),
                                ),
                              ),
                              Row(
                                children: [
                                  GestureDetector(
                                    onTap: () async {
                                      try {
                                        await widget.state.live.sendCoHostDecision(
                                          widget.channelName,
                                          req['userId'].toString(),
                                          false,
                                        );
                                        setState(() {
                                          widget.state.liveGuestRequests.removeAt(idx);
                                        });
                                        setModalState(() {});
                                        _showToast('Declined request from ${req['name']}');
                                      } catch (e) {
                                        _showToast('Could not decline request: $e');
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.red.withOpacity(0.1),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.close, color: Colors.red, size: 16),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  GestureDetector(
                                    onTap: () async {
                                      try {
                                        await widget.state.live.sendCoHostDecision(
                                          widget.channelName,
                                          req['userId'].toString(),
                                          true,
                                        );
                                        setState(() {
                                          widget.state.liveGuestRequests.removeAt(idx);
                                        });
                                        setModalState(() {});
                                        _showToast('Accepted request. ${req['name']} can join the stream now.');
                                        Navigator.pop(context);
                                      } catch (e) {
                                        _showToast('Could not accept request: $e');
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: const BoxDecoration(
                                        color: Colors.green,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.check, color: Colors.black, size: 16),
                                    ),
                                  ),
                                ],
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
                  child: Text('INVITE A VIEWER TO CO-STREAM', style: syne(sz: 10, w: FontWeight.bold, c: Colors.white38, ls: 1)),
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
                          decoration: InputDecoration(
                            hintText: 'Search online viewer by username...',
                            hintStyle: dm(sz: 13, c: Colors.white24),
                            border: InputBorder.none,
                          ),
                          onSubmitted: (val) {
                            if (val.trim().isNotEmpty) {
                              _showToast('Invitation sent to @$val! 📩');
                              Navigator.pop(context);
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
        content: Text(message, style: syne(sz: 12, w: FontWeight.bold, c: Colors.white)),
        backgroundColor: const Color(0xFF0F172A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _actionIcon(IconData icon, Color color) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white10),
      ),
      child: Icon(icon, color: color, size: 22),
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
                        border: Border.all(color: C.brand.withOpacity(0.25), width: 2),
                      ),
                      child: const Icon(Icons.shield_outlined, color: C.brand, size: 48),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'SHIELD VERIFICATION REQUIRED',
                      textAlign: TextAlign.center,
                      style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 1.5),
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
                            style: syne(sz: 13, w: FontWeight.w900, c: Colors.black, ls: 1.2),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Text(
                        'CANCEL & LEAVE',
                        style: syne(sz: 11, w: FontWeight.bold, c: Colors.white38, ls: 1),
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
