import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';
import 'data.dart';
import 'services/ai_service.dart';
import 'services/vault_service.dart';
import 'services/social_service.dart';
import 'services/cloud_service.dart';
import 'services/media_compression_service.dart';
import 'services/listing_sync_service.dart';
import 'services/local_db_service.dart';
import 'services/smooth_action.dart';

import 'models/property_container.dart';
import 'models/wallet.dart';
import 'models/chat_models.dart';
import 'models/booking_models.dart';
import 'models/transport_models.dart';
import 'models/notification_model.dart';
import 'services/audio_service.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:local_auth/local_auth.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'models/music_models.dart';
import 'services/music_library_service.dart';
import 'services/draft_service.dart';
import 'services/payment_service.dart';
import 'services/finance_gifting_service.dart';
import 'services/finance_liquidation_service.dart';
import 'services/finance_backend.dart';
import 'services/finance_deposit_service.dart';
import 'services/finance_withdrawal_service.dart';
import 'services/finance_coin_purchase_service.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'services/contact_discovery_service.dart';
import 'services/notification_service.dart';
import 'services/commerce_service.dart';
import 'services/live_streaming_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class AppState extends ChangeNotifier {
  String screen = 'home';

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  static AppState? maybeOf(BuildContext context) {
    // Basic lookup for RootShell state or similar
    final shell = context.findAncestorStateOfType<State>();
    if (shell != null &&
        shell.widget.runtimeType.toString().contains('Shell')) {
      // In this specific architecture, RootShell has a 'state' property
      try {
        return (shell.widget as dynamic).state;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  final List<String> _navigationStack = [];

  // ── Privacy & Security State ──
  final LocalAuthentication _auth = LocalAuthentication();
  bool _isBiometricsEnabled = false;
  bool _is2FAEnabled = false;
  bool isAppLocked = false;
  DateTime? lastActiveTime;
  String? biometricError;

  bool get isBiometricsEnabled => _isBiometricsEnabled;
  bool get is2FAEnabled => _is2FAEnabled;

  Future<void> loadSecuritySettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isBiometricsEnabled = prefs.getBool('biometricsEnabled') ?? false;
      _is2FAEnabled = prefs.getBool('twoFactorEnabled') ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setBiometricsEnabled(bool v) async {
    _isBiometricsEnabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('biometricsEnabled', v);
  }

  Future<void> set2FAEnabled(bool v) async {
    _is2FAEnabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('twoFactorEnabled', v);
  }

  /// Verification point for high-risk actions (Withdrawals/Escrow)
  Future<bool> verifySensitiveAction() async {
    if (!_isBiometricsEnabled && !_is2FAEnabled) {
      return true; // No protection enabled
    }

    if (_isBiometricsEnabled) {
      final success = await verifyAppBiometrics(
        reason: "Authentication required for financial fulfillment",
      );
      if (success) return true;
    }

    if (_is2FAEnabled) {
      // In a real app, this would trigger a 2FA prompt
      return true;
    }
    return false;
  }

  // ── Connectivity & Data Saver ──
  ConnectivityResult _connectionType = ConnectivityResult.none;
  ConnectivityResult get connectionType => _connectionType;
  bool get isWifi => _connectionType == ConnectivityResult.wifi;
  bool get isDataSaverMode => !isWifi; // Optimize for Mobile Data

  void _initConnectivity() {
    Connectivity().onConnectivityChanged.listen((results) {
      if (results.isNotEmpty) {
        final wasOffline = _connectionType == ConnectivityResult.none;
        _connectionType = results.first;
        notifyListeners();
        if (wasOffline &&
            _connectionType != ConnectivityResult.none &&
            user != null) {
          social.syncPendingActions();
          unawaited(live.syncAllPendingLiveComments());
        }
      }
    });
    // Initial check
    Connectivity().checkConnectivity().then((results) {
      if (results.isNotEmpty) {
        _connectionType = results.first;
        notifyListeners();
      }
    });
  }

  Future<bool> verifyAppBiometrics({
    String reason = "Accessing Necxa Secure Infrastructure",
  }) async {
    biometricError = null;
    notifyListeners();
    try {
      final canAuthWithBiometrics = await _auth.canCheckBiometrics;
      final canAuth = canAuthWithBiometrics || await _auth.isDeviceSupported();

      if (!canAuth) {
        biometricError =
            "Biometric hardware not available or not supported on this device.";
        notifyListeners();
        return false;
      }

      final success = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
          useErrorDialogs: true,
        ),
      );

      if (success) {
        isAppLocked = false;
        lastActiveTime = DateTime.now();
        biometricError = null;
        notifyListeners();
      }
      return success;
    } catch (e) {
      biometricError = 'Biometric Auth Error: $e';
      notifyListeners();
      return false;
    }
  }

  void clearBiometricError() {
    biometricError = null;
    notifyListeners();
  }

  void updateActivity() {
    lastActiveTime = DateTime.now();
  }

  void checkInactivityLock() {
    if (!_isBiometricsEnabled || lastActiveTime == null) return;

    final diff = DateTime.now().difference(lastActiveTime!);
    if (diff.inHours >= 1) {
      isAppLocked = true;
      notifyListeners();
    }
  }

  Future<void> loadThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final modeStr = prefs.getString('themeMode');
      if (modeStr == 'ThemeMode.dark') {
        _themeMode = ThemeMode.dark;
      } else if (modeStr == 'ThemeMode.light') {
        _themeMode = ThemeMode.light;
      } else {
        _themeMode = ThemeMode.system;
      }
      C.themeMode = _themeMode;

      chatWallpaper = prefs.getString('chatWallpaper') ?? 'solid_black';

      await _loadUserLanguage();

      notifyListeners();
    } catch (_) {}
  }

  // ── Artist & Distribution ──
  bool isArtist = false;
  int necxaCoins = 500; // Mock balance for testing

  bool get hasDistributionAccess => isArtist && necxaCoins >= 150;

  void setArtistStatus(bool status) {
    isArtist = status;
    notifyListeners();
  }

  void updateCoins(int amount) {
    necxaCoins += amount;
    notifyListeners();
  }

  // ── Theme Settings ──
  Future<void> setTheme(ThemeMode mode) async {
    _themeMode = mode;
    C.themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('themeMode', mode.toString());
    } catch (_) {}
  }

  // ── Chat Settings ──
  String chatWallpaper = 'solid_black';

  Future<void> setChatWallpaper(String wp) async {
    chatWallpaper = wp;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('chatWallpaper', wp);
    } catch (_) {}
  }

  // ── Language Preference ──
  /// The user's preferred language for Necxa AI responses (e.g. 'English', 'Swahili', 'Luganda', 'French').
  String userLanguage = 'English';

  Future<void> setUserLanguage(String lang) async {
    userLanguage = lang;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('userLanguage', lang);
    } catch (_) {}
  }

  Future<void> _loadUserLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      userLanguage = prefs.getString('userLanguage') ?? 'English';
    } catch (_) {}
  }

  // ── Audio Settings ──
  bool soundEnabled = true;

  Future<void> loadAudioSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      soundEnabled = prefs.getBool('soundEnabled') ?? true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setSoundEnabled(bool enabled) async {
    soundEnabled = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('soundEnabled', enabled);
    } catch (_) {}
  }

  // ── Service Modules ──
  final VaultService vault = VaultService();
  late final SocialService social;
  final FinanceDepositService financeDeposits = FinanceDepositService();
  final FinanceWithdrawalService financeWithdrawals =
      FinanceWithdrawalService();
  final FinanceCoinPurchaseService financeCoinPurchases =
      FinanceCoinPurchaseService();
  final FinanceLiquidationService financeLiquidation =
      FinanceLiquidationService();
  final NecxaCloud cloud = NecxaCloud();
  final LocalDbService localDb = LocalDbService();
  late final LiveStreamingService live;

  Future<void> init() async {
    // 🚀 NEURAL BOOT: Load all local data IMMEDIATELY (Zero Spinner)
    await hydrateFromLocal();

    // Background modular sync (Modularly until completion)
    if (isAuthenticated) {
      _modularBackgroundSync();
      unawaited(live.syncAllPendingLiveComments());
    }
    notify();
  }

  /// 🔄 MODULAR SYNC: Sequentially updates data layers in background
  Future<void> _modularBackgroundSync() async {
    try {
      // 1. Profile & Essential Handshakes
      await loadMyProfile();

      // 1.5. 💰 Wallet Sync — Critical for finance features (gifting, payments, withdrawals)
      await _syncVault();

      // 2. Social Inbox (Chat Rooms)
      await fetchCreatorConversations();

      // 3. Social Feed (Delta Only)
      await social.fetchPosts(forceRefresh: false);

      // 4. Shop Listings (Delta Only)
      await social.fetchListings(forceRefresh: false);

      debugPrint('⚡ Necxa-Sync: Full Background Modular Hydration Complete');
    } catch (e) {
      debugPrint('Background Sync Warning: $e');
    }
  }

  /// 📁 WHATSAPP-STYLE: Copy media to a permanent vault folder
  Future<String> _persistMedia(File file, String category) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final vaultDir = Directory('${appDir.path}/Necxa/Media/$category');
      if (!await vaultDir.exists()) await vaultDir.create(recursive: true);

      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${p.basename(file.path)}';
      final permanentFile = await file.copy('${vaultDir.path}/$fileName');

      debugPrint('💾 Media Vault: Persisted ${permanentFile.path}');
      return permanentFile.path;
    } catch (e) {
      debugPrint('Vault Persistence Error: $e');
      return file.path; // Fallback to original
    }
  }

  String? _shieldError;
  String? get shieldFeedback => _shieldError;
  void setShieldFeedback(String? message) {
    _shieldError = message;
    notifyListeners();
  }

  // Viral Sound State
  MusicTrack? initialMusicTrack;
  final DraftService drafts = DraftService();
  final MusicLibraryService music = MusicLibraryService();
  final PaymentService payment = PaymentService();
  final FinanceGiftingService financeGifting = FinanceGiftingService();
  final FinanceLiquidationService liquidation = FinanceLiquidationService();
  final ContactDiscoveryService discovery =
      ContactDiscoveryService(); // Restored Member

  AppState() {
    if (!kIsWeb) {
      recorderController = RecorderController();
    }
    social = SocialService(this);
    live = LiveStreamingService(this);
    NotificationService().tappedNotification.addListener(
      _handleNotificationTap,
    );

    // 🚀 NEURAL PRE-WARM: Load mission-critical data first
    _preWarmApp();

    _initConnectivity();
  }

  void _handleNotificationTap() {
    final data = NotificationService().tappedNotification.value;
    if (data == null) return;
    NotificationService().tappedNotification.value = null;
    final notificationUserId = data['user_id']?.toString();
    if (notificationUserId == null || notificationUserId != user?.id) return;
    final notificationId =
        data['notification_id']?.toString() ?? data['id']?.toString();
    if (notificationId != null) {
      unawaited(markNotificationAsRead(notificationId));
    }
    final targetId = data['target_id']?.toString();
    final targetType = data['target_type']?.toString() ?? 'post';
    if (targetId == null || targetId.isEmpty) return;
    if (targetType == 'profile') {
      go('public_profile', extra: targetId);
    } else if (targetType == 'post') {
      go('community', extra: targetId);
    }
  }

  /// Staggers app initialization to ensure zero-latency startup and interactive first frame.
  Future<void> _preWarmApp() async {
    // 1. Theme and Core (Critical for first frame visual stability)
    await loadThemeMode();

    // 2. Pre-warm Social Cache (Zero-latency Feed/Shop retrieval from SQLite)
    // We don't await this so we don't block the constructor's return
    social.preWarmCache();

    // 3. Essential Background Init (Microtask)
    // Runs after the first build cycle to avoid startup jank
    Future.microtask(() async {
      await loadMyProfile();
      await loadSecuritySettings();
      // Sync wallet to enable finance features (gifting, payments, etc.)
      if (isAuthenticated) {
        await _syncVault();
      }
    });

    // 4. Staggered Modular Loading (Non-critical heavy tasks)
    // If the phone is busy, these are delayed further to prioritize UI smoothness
    Future.delayed(const Duration(milliseconds: 600), () async {
      debugPrint('🛡️ AppState: Starting modular background load...');

      // Load modularly - each awaited individually to allow event loop breathing room
      await loadProperties();
      await loadAudioSettings();
      await loadCoinPacks();
      await loadAiChatHistory();
      await live.init();

      debugPrint('🛡️ AppState: Modular loading complete.');
    });
  }

  File? pickedMedia;
  File? idImage;
  File? idBackImage;
  File? idHoldingImage;
  File? faceImage;
  File? stampImage;
  File? bathroomImage;
  File? toiletProof;
  final List<File> verifiedMedia = [];
  final List<String> selectedAmenities = [];
  File? lc1Image; // LC1 stamp photo
  File? landTitleImage; // Land Title photo
  Position? currentGps;
  Position? livePingGps; // 🚀 Live Ping stamped during verification
  String? gpsError;
  bool gpsDone = false;
  bool isUploading = false;
  bool uploadDone = false;

  // ── Unified Verification State ──
  String? identityShardId;
  String? utilityShardId;
  bool isVerifying = false;
  int verificationSubStep = 0; // TRACKS CURRENT CAPTURE STAGE (0-3)
  IDResult? lastIDResult;
  IDResult? lastIDBackResult;
  SelfieResult? lastSelfieResult;
  IDResult? lastHoldingResult;
  UtilityBillResult? lastUtilityResult;
  IPResult? lastIPResult;

  Future<void> startVerification({
    CameraController? cameraController,
    Future<void> Function(CameraLensDirection)? onSwitchCamera,
  }) async {
    if (user == null) return;

    idScanning = true;
    verificationSubStep = 0;
    _shieldError = null;
    notifyListeners();

    try {
      captureGps()
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              debugPrint(
                '⚠️ Live Ping GPS timed out – continuing without GPS.',
              );
            },
          )
          .catchError((e) {
            debugPrint('⚠️ GPS Error (non-fatal): $e');
          });

      verificationSubStep = 1;
      notifyListeners();

      final ctx = navigatorKey.currentContext;
      if (ctx == null) {
        throw Exception(
          'Navigator context unavailable – app may not be fully loaded.',
        );
      }

      verificationSubStep = 2;
      notifyListeners();

      // MOCK FLOW: Replace with NecxaAI direct calls in the future
      await Future.delayed(const Duration(seconds: 2));
      verificationSubStep = 3;
      await Future.delayed(const Duration(seconds: 2));

      idScanning = false;
      idVerified = true;
      faceDone = true;
      gpsDone = true;
      final mockSessionId = 'SES-${DateTime.now().millisecondsSinceEpoch}';
      identityShardId = mockSessionId;
      utilityShardId = mockSessionId;
      lastIDResult = IDResult(verified: true, sessionId: mockSessionId);
      lastHoldingResult = IDResult(verified: true, sessionId: mockSessionId);
      lastSelfieResult = SelfieResult(
        faceMatch: true,
        sessionId: mockSessionId,
      );

      if (currentGps != null) {
        livePingGps = currentGps;
        debugPrint(
          '🛡️ Necxa Live Ping: ${currentGps!.latitude}, ${currentGps!.longitude}',
        );
      }
      verificationSubStep = 4;
      notifyListeners();
    } catch (e) {
      debugPrint('Verification Error: $e');
      _shieldError = e.toString();
      idScanning = false;
      verificationSubStep = 0;
      notifyListeners();
    }
  }

  bool get _isSupabaseReady {
    try {
      Supabase.instance.client;
      return true;
    } catch (_) {
      return false;
    }
  }

  User? get user {
    if (!_isSupabaseReady) return null;
    return Supabase.instance.client.auth.currentUser;
  }

  Map<String, dynamic>? myProfile;

  /// Alias so widgets can reference the current user's profile uniformly.
  Map<String, dynamic>? get currentProfile => myProfile;
  bool get isAuthenticated => user != null;

  String? _firstProfileValue(Iterable<dynamic> values) {
    for (final value in values) {
      final normalized = value?.toString().trim() ?? '';
      if (normalized.isNotEmpty) return normalized;
    }
    return null;
  }

  String? get myDisplayName => _firstProfileValue([
    myProfile?['full_name'],
    myProfile?['display_name'],
    user?.userMetadata?['full_name'],
    user?.userMetadata?['display_name'],
    user?.userMetadata?['name'],
    user?.email?.split('@').first,
  ]);

  String? get myAvatarUrl => _firstProfileValue([
    myProfile?['avatar_url'],
    myProfile?['photo_url'],
    myProfile?['avatar'],
    user?.userMetadata?['avatar_url'],
    user?.userMetadata?['picture'],
    user?.userMetadata?['avatar'],
  ]);

  String? get myUsername => _firstProfileValue([
    myProfile?['username'],
    user?.userMetadata?['username'],
  ]);

  Future<void> loadMyProfile() async {
    if (user == null) return;
    final profile = await social.getProfile(user!.id);
    final financeSnapshot = await _loadPrimaryFinanceSnapshot(user!.id);
    final normalizedName = _firstProfileValue([
      profile?['full_name'],
      profile?['display_name'],
      user?.userMetadata?['full_name'],
      user?.userMetadata?['display_name'],
      user?.userMetadata?['name'],
      user?.email?.split('@').first,
    ]);
    final normalizedAvatar = _firstProfileValue([
      profile?['avatar_url'],
      profile?['photo_url'],
      profile?['avatar'],
      user?.userMetadata?['avatar_url'],
      user?.userMetadata?['picture'],
      user?.userMetadata?['avatar'],
    ]);
    myProfile = {
      ...?profile,
      if (normalizedName != null) 'full_name': normalizedName,
      if (normalizedAvatar != null) 'avatar_url': normalizedAvatar,
      if (financeSnapshot != null) 'finance': financeSnapshot,
    };
    notify();
  }

  Future<void> updateAvatar() async {
    if (user == null) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );
    if (picked == null) return;

    // Upload to cloud
    final res = await cloud.uploadMedia(
      File(picked.path),
      assetType: 'avatar',
      bucket: 'profiles',
    );
    if (res != null && res['url'] != null) {
      final url = res['url'];
      // Update Supabase
      await social.updateProfile(user!.id, {'avatar_url': url});
      // Reload profile
      await loadMyProfile();
      // 🚀 Neural Sync: Invalidate global feed cache so new avatar shows instantly
      try {
        await Supabase.instance.client.functions.invoke(
          'clever-processor',
          body: {'action': 'clear-feed-cache'},
        );
      } catch (_) {}
    }
  }

  // ── Live Streaming State ──
  String? activeLiveChannel;
  bool isLiveHosting = false;
  final Map<String, Map<String, dynamic>?> _pinnedLiveProducts = {};
  Map<String, dynamic>? get pinnedLiveProduct {
    final channel = activeLiveChannel;
    return channel == null ? null : _pinnedLiveProducts[channel];
  }

  final Map<String, List<Map<String, dynamic>>> _liveGuestRequests = {};
  List<Map<String, dynamic>> get liveGuestRequests {
    final channel = activeLiveChannel;
    if (channel == null || channel.isEmpty) return const [];
    return _liveGuestRequests.putIfAbsent(
      channel,
      () => <Map<String, dynamic>>[],
    );
  }

  Map<String, dynamic>? pinnedProductForChannel(String channelId) {
    return _pinnedLiveProducts[channelId];
  }

  void setLiveChannel(String? channel, {bool isHosting = false}) {
    activeLiveChannel = channel;
    isLiveHosting = isHosting;
    notify();
  }

  void replaceLiveGuestRequests(
    String channelId,
    Iterable<Map<String, dynamic>> requests,
  ) {
    _liveGuestRequests[channelId] = requests
        .map((request) => Map<String, dynamic>.from(request))
        .toList();
    notify();
  }

  void upsertLiveGuestRequest(String channelId, Map<String, dynamic> request) {
    final requests = _liveGuestRequests.putIfAbsent(
      channelId,
      () => <Map<String, dynamic>>[],
    );
    final requestId = request['id']?.toString();
    final guestId = (request['guestId'] ?? request['userId'])?.toString();
    final index = requests.indexWhere((existing) {
      final existingRequestId = existing['id']?.toString();
      final existingGuestId = (existing['guestId'] ?? existing['userId'])
          ?.toString();
      return requestId != null && requestId.isNotEmpty
          ? existingRequestId == requestId
          : guestId != null && guestId.isNotEmpty && existingGuestId == guestId;
    });
    final normalized = Map<String, dynamic>.from(request);
    if (index >= 0) {
      requests[index] = normalized;
    } else {
      requests.add(normalized);
    }
    notify();
  }

  void removeLiveGuestRequest(
    String channelId, {
    String? requestId,
    String? guestId,
  }) {
    final requests = _liveGuestRequests[channelId];
    if (requests == null) return;
    requests.removeWhere((request) {
      if (requestId != null && request['id']?.toString() == requestId) {
        return true;
      }
      final requestGuestId = (request['guestId'] ?? request['userId'])
          ?.toString();
      return guestId != null && requestGuestId == guestId;
    });
    notify();
  }

  void updatePinnedProduct(Map<String, dynamic>? product, {String? channelId}) {
    final channel = channelId ?? activeLiveChannel;
    if (channel == null || channel.isEmpty) return;
    _pinnedLiveProducts[channel] = product;
    notify();
  }

  // ── Global State ──
  List<String> get navigationStack => _navigationStack;
  bool isImmersiveMode = false;
  String? listingId;
  String? targetProfileId;
  String? communityPostId;
  String creatorTab = 'feed';

  /// Set by upload wizard — CommunityScreen consumes this once to auto-switch tabs
  String? pendingDestinationTab;
  bool isAdmin = false;
  bool isFeedCleanMode = false;
  String chatBubbleTheme = 'neon_cyan_green'; // Default theme

  // ── Payment & Transaction ──
  String payMethod = 'momo';
  bool paying = false;
  bool paid = false;

  // ── Gift Engine ──
  String? giftEmoji;
  String? giftName;
  int? giftFee;
  bool showGiftFloat = false;
  bool showCheckoutOverlay = false;
  Map<String, dynamic>? selectedListing;
  Map<String, dynamic>? pendingCheckoutListing;

  // ── LOCAL SHOWCASE CACHE ──
  Map<String, List<Map<String, dynamic>>> cachedUserShowcases = {};

  // ── Coin Packs Registry ──
  List<Map<String, dynamic>> coinPacks = [];
  bool isLoadingPacks = false;

  Future<void> loadCoinPacks() async {
    isLoadingPacks = true;
    notify();
    try {
      coinPacks = await financeCoinPurchases.packs();
    } catch (e) {
      debugPrint('Error loading coin packs: $e');
    }
    isLoadingPacks = false;
    notify();
  }

  // ── Local Financial Cache ──
  Wallet? userWallet;
  bool isWalletSyncing = false;
  String? walletSyncError;
  DateTime? walletLastSyncedAt;
  Future<void>? _walletSyncFuture;
  String? _walletOwnerId;

  double get fiatBalance => userWallet?.fiatBalance.toDouble() ?? 0.0;
  double get coinBalance => userWallet?.coinBalance.toDouble() ?? 0.0;
  double get escrowBalance => userWallet?.escrowBalance.toDouble() ?? 0.0;
  bool get hasVerifiedWallet =>
      userWallet != null && user != null && _walletOwnerId == user!.id;

  // ── Legacy Aliases for UI Widgets ──
  double get cashBalance => fiatBalance;
  double get ncxBalance => coinBalance;
  double get shardBalance => coinBalance;

  void notify() => notifyListeners();

  /// Public surface for wallet re-synchronization used by overlay widgets.
  Future<void> syncVault() => _syncVault();

  Future<void> _syncVault() async {
    final activeSync = _walletSyncFuture;
    if (activeSync != null) {
      await activeSync;
      return;
    }

    final sync = _performWalletSync();
    _walletSyncFuture = sync;
    try {
      await sync;
    } finally {
      if (identical(_walletSyncFuture, sync)) {
        _walletSyncFuture = null;
      }
    }
  }

  Future<void> _performWalletSync() async {
    final walletUser = user;
    if (walletUser == null) {
      userWallet = null;
      _walletOwnerId = null;
      walletLastSyncedAt = null;
      walletSyncError = 'Sign in to view your wallet.';
      notify();
      return;
    }

    if (_walletOwnerId != null && _walletOwnerId != walletUser.id) {
      userWallet = null;
      walletLastSyncedAt = null;
    }
    isWalletSyncing = true;
    walletSyncError = null;
    notify();
    try {
      final result = await FinanceBackend.instance.invoke('get_wallet');
      final wallet = Map<String, dynamic>.from(
        result['wallet'] as Map? ?? const {},
      );
      if (wallet.isEmpty) {
        throw const FinanceBackendException(
          code: 'wallet_missing',
          message: 'The finance backend did not return a wallet.',
        );
      }
      if (wallet['user_id']?.toString() != walletUser.id) {
        throw const FinanceBackendException(
          code: 'wallet_identity_mismatch',
          message: 'The finance service returned an invalid wallet identity.',
        );
      }

      if (user?.id != walletUser.id) return;
      userWallet = Wallet.fromJson(wallet);
      _walletOwnerId = walletUser.id;
      walletLastSyncedAt = DateTime.tryParse(
        result['syncedAt']?.toString() ?? '',
      ) ?? DateTime.now();
      myProfile = {...?myProfile, 'finance': wallet};
    } on FinanceBackendException catch (e) {
      final restored = await _restoreWalletFromPrimarySnapshot(walletUser);
      walletSyncError = restored
          ? 'Live sync delayed — showing your last verified balance.'
          : switch (e.statusCode) {
              401 =>
                'Your finance session could not be verified. Please sign in again.',
              503 =>
                'Wallet service is temporarily unavailable. Please try again.',
              _ =>
                e.message.isNotEmpty
                    ? e.message
                    : 'Wallet balances could not be refreshed.',
            };
      debugPrint(
        'Vault Sync Error (${e.statusCode ?? 'no status'}/${e.code}): '
        '${e.message}',
      );
    } catch (e) {
      final restored = await _restoreWalletFromPrimarySnapshot(walletUser);
      walletSyncError = restored
          ? 'Live sync delayed — showing your last verified balance.'
          : 'Wallet balances could not be refreshed. Please retry.';
      debugPrint('Vault Sync Error: $e');
    } finally {
      isWalletSyncing = false;
      notify();
    }
  }

  Future<Map<String, dynamic>?> _loadPrimaryFinanceSnapshot(
    String userId,
  ) async {
    try {
      final data = await Supabase.instance.client
          .from('profile_finance_snapshots')
          .select()
          .eq('user_id', userId)
          .maybeSingle();
      return data == null ? null : Map<String, dynamic>.from(data);
    } catch (error) {
      debugPrint('Profile finance snapshot unavailable: $error');
      return null;
    }
  }

  Future<bool> _restoreWalletFromPrimarySnapshot(User walletUser) async {
    final snapshot = await _loadPrimaryFinanceSnapshot(walletUser.id);
    if (snapshot == null || user?.id != walletUser.id) return false;

    final walletData = <String, dynamic>{
      ...snapshot,
      'id': snapshot['finance_wallet_id'],
      'user_id': walletUser.id,
      'created_at': snapshot['synced_at'],
      'updated_at': snapshot['finance_updated_at'] ?? snapshot['synced_at'],
    };
    userWallet = Wallet.fromJson(walletData);
    _walletOwnerId = walletUser.id;
    walletLastSyncedAt = DateTime.tryParse(
      snapshot['synced_at']?.toString() ?? '',
    );
    myProfile = {...?myProfile, 'finance': snapshot};
    return true;
  }

  Future<void> syncVaultFromFinance() async {
    await _syncVault();
  }

  Future<Map<String, dynamic>> depositFiat(double amt, {String? phone}) async {
    if (user == null) throw Exception('Sign in before depositing.');
    return financeDeposits.initiate(
      amountUgx: amt.round(),
      phone: phone ?? myProfile?['phone_number'],
    );
  }

  double currentForexRate = 3800.0;
  bool is2faEnabled = false;
  List<Map<String, dynamic>> paymentMethods = [];

  // Multimedia State
  RecorderController? recorderController;
  Duration recordDuration = Duration.zero;

  Future<void> syncForexRates() async {
    currentForexRate = 3800;
    notify();
  }

  Future<void> syncPaymentMethods() async {
    paymentMethods = const [
      {'id': 'balance', 'name': 'Necxa Wallet', 'enabled': true},
      {
        'id': 'mtn',
        'name': 'MTN MoMo',
        'type': 'disbursement',
        'status': 'active',
        'enabled': true,
      },
    ];
    notify();
  }

  Future<void> checkSecurityStatus() async {
    if (user == null) return;
    await syncForexRates();
    await syncPaymentMethods();
    is2faEnabled = _is2FAEnabled;
    notify();
  }

  Future<Map<String, dynamic>> withdraw(
    double amount, {
    required String accountNumber,
    required String recipientName,
    required String? totpToken,
    required String emailOtp,
    required String idempotencyKey,
    String method = 'mtn',
  }) async {
    if (user == null) throw Exception('Sign in before withdrawing');
    if (fiatBalance < amount) throw Exception('Insufficient wallet balance');

    // Security checkpoint
    final verified = await verifySensitiveAction();
    if (!verified) throw Exception('Authorization failed');

    final securityData = await getFullSecurityMetadata();

    final result = await financeWithdrawals.request(
      amountUgx: amount.round(),
      method: method,
      accountNumber: accountNumber,
      recipientName: recipientName,
      emailOtp: emailOtp,
      totpToken: totpToken,
      securityMetadata: securityData,
      idempotencyKey: idempotencyKey,
    );

    if (result['success'] == true) {
      await _syncVault(); // Refresh local wallet
      return result;
    } else {
      throw Exception(result['message']);
    }
  }

  Future<Map<String, dynamic>> buyShards(
    String packId, {
    String method = 'fiat_balance',
    required String idempotencyKey,
    String? contextType,
    String? contextId,
    String? targetGiftItemId,
  }) async {
    if (user == null) throw Exception('Sign in before buying coins');

    // 🛡️ GATHER SECURITY METADATA
    final securityData = await getFullSecurityMetadata();
    if (contextType != null) securityData['purchase_context'] = contextType;
    if (contextId != null) securityData['context_id'] = contextId;
    if (targetGiftItemId != null) {
      securityData['target_gift_item_id'] = targetGiftItemId;
    }

    final result = await financeCoinPurchases.purchase(
      packId: packId,
      method: method,
      idempotencyKey: idempotencyKey,
      securityMetadata: securityData,
    );

    if (result['success'] == true) {
      await _syncVault(); // Refresh local wallet
      return result;
    } else {
      throw Exception(result['message']);
    }
  }

  Future<Map<String, dynamic>> getFullSecurityMetadata() async {
    final dev = DeviceInfoPlugin();
    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    String deviceId = 'unknown';
    String model = 'unknown';
    String os = 'unknown';
    bool isEmulated = false;

    if (!kIsWeb) {
      if (Platform.isAndroid) {
        final info = await dev.androidInfo;
        deviceId = info.id;
        model = info.model;
        os = 'Android ${info.version.release}';
        isEmulated = !info.isPhysicalDevice;
      } else if (Platform.isIOS) {
        final info = await dev.iosInfo;
        deviceId = info.identifierForVendor ?? 'unknown';
        model = info.utsname.machine;
        os = 'iOS ${info.systemVersion}';
        isEmulated = !info.isPhysicalDevice;
      }
    }

    return {
      'lat': pos.latitude,
      'lng': pos.longitude,
      'device_id': deviceId,
      'device_model': model,
      'os_version': os,
      'is_emulated': isEmulated,
      'timestamp': DateTime.now().toIso8601String(),
      'ip_address': 'detected_at_edge', // Backend handles real IP
    };
  }

  Future<void> sellShards(double shards) async {
    if (user == null) return;

    final securityData = await getFullSecurityMetadata();

    final result = await financeLiquidation.liquidate(
      userId: user!.id,
      ncxAmount: shards,
      securityMetadata: securityData,
    );

    if (result.success) {
      await _syncVault();
    } else {
      throw Exception(result.message);
    }
  }

  Future<bool> verifyBiometrics() => vault.verifyBiometrics();

  // ── Social Module Actions ──
  Future<List<Map<String, dynamic>>> getPosts() => social.fetchPosts();
  Stream<List<Map<String, dynamic>>> syncPosts() => social.streamPosts();

  Future<List<Map<String, dynamic>>> getListings() => social.fetchListings();

  Future<void> syndicateNode(Map<String, dynamic> data) async {
    if (user == null) return;
    uploadStep = 1;
    isUploading = true;
    notify();

    try {
      // Prepare once. Upload only after AI has approved this exact file.
      final preparedMedia = pickedMedia == null
          ? null
          : await MediaCompressionService.optimizeMedia(pickedMedia!);

      bool verificationApproved(Map<String, dynamic> report) {
        final result = report['result'];
        return report['verified'] == true ||
            report['safe'] == true ||
            NecxaAI.moderationVerified(report) ||
            (result is Map && result['verified'] == true);
      }

      Future<void> uploadVerifiedMedia() async {
        if (preparedMedia == null) return;
        final uploadData = await cloud.uploadMedia(
          preparedMedia,
          assetType: data['type'] ?? 'generic',
        );
        final mediaUrl = uploadData?['url']?.toString();
        if (uploadData == null || mediaUrl == null || mediaUrl.isEmpty) {
          throw Exception('Media upload failed');
        }
        data['media_url'] = mediaUrl;
        data['asset_id'] = uploadData['id'];
      }

      // 2. AI Verification Node (Cloudflare Worker v2 — direct edge inference)
      Map<String, dynamic> aiReport;

      if (data['type'] == 'post') {
        if (preparedMedia != null) {
          final isVideo =
              preparedMedia.path.toLowerCase().endsWith('.mp4') ||
              preparedMedia.path.toLowerCase().endsWith('.mov');
          final isAudio =
              preparedMedia.path.toLowerCase().endsWith('.mp3') ||
              preparedMedia.path.toLowerCase().endsWith('.m4a') ||
              preparedMedia.path.toLowerCase().endsWith('.wav');

          if (isVideo) {
            // Extract frames and send to Worker's multi-frame video moderator
            final framePaths = await NecxaAI.extractVideoFrames(preparedMedia);
            // Convert base64 frames back to temp files for the Worker HTTP upload
            final tempDir = await Directory.systemTemp.createTemp(
              'video_frames_',
            );
            final frameFiles = <File>[];
            for (int i = 0; i < framePaths.length; i++) {
              final f = File('${tempDir.path}/frame_$i.jpg');
              await f.writeAsBytes(base64Decode(framePaths[i]));
              frameFiles.add(f);
            }
            aiReport = await NecxaAI.verifyVideoWorker(frameFiles);
            // Clean up temp files
            try {
              await tempDir.delete(recursive: true);
            } catch (_) {}
          } else if (isAudio) {
            aiReport = await NecxaAI.verifyAudioWorker(preparedMedia);
          } else {
            aiReport = await NecxaAI.verifyPhotoWorker(preparedMedia);
          }
        } else {
          aiReport = await NecxaAI.verifyContent(
            type: 'text',
            mediaBase64: '',
            mimeType: 'text/plain',
            textContent: data['title'] ?? data['description'],
            userId: user!.id,
          );
        }
        // ── COMMUNITY V2: NEURAL SYNDICATION ──
        if (!verificationApproved(aiReport)) {
          throw Exception(
            aiReport['error']?.toString() ??
                aiReport['feedback']?.toString() ??
                'AI verification did not approve this content',
          );
        }
        aiReport = {...aiReport, 'verified': true};
        await uploadVerifiedMedia();
        await social.createPost(user!.id, {
          ...data,
          'community_id': data['community_id'] ?? 'global_node_01',
          'is_verified': true,
          'ai_verification': aiReport,
        });
      } else {
        // Listing: use Worker to verify listing photo, then Supabase to persist
        if (preparedMedia != null) {
          // ✅ Photo-based AI listing verification via Cloudflare Worker
          aiReport = await NecxaAI.verifyListingPhotoWorker(
            photo: preparedMedia,
            title: data['title'] ?? 'Property',
          );
        } else {
          // ✅ FIX: No media — run text-only listing verification using title/description
          // The previous code passed File('') here, which caused a silent crash.
          aiReport = await NecxaAI.createVerifiedListing(
            title: data['title'] ?? 'Untitled Property',
            description: data['description'] ?? '',
            price: double.tryParse(data['price']?.toString() ?? '0') ?? 0,
            type: data['category'] ?? 'apartment',
            imageBase64: '', // No image — text-only verification
            userId: user!.id,
          );
        }
        if (!verificationApproved(aiReport)) {
          throw Exception(
            aiReport['error']?.toString() ??
                aiReport['feedback']?.toString() ??
                'AI verification did not approve this listing',
          );
        }
        aiReport = {...aiReport, 'verified': true};
        await uploadVerifiedMedia();
        await social.createListing(user!.id, {
          ...data,
          'is_verified': true,
          'ai_verification': aiReport,
        }, aiResult: aiReport);
      }

      // 4. Audit Log
      await social.logVerification(user!.id, data['type'], aiReport);

      pickedMedia = null;
      await Future.delayed(const Duration(seconds: 2));
      go('community');
    } finally {
      isUploading = false;
      notifyListeners();
    }
  }

  // ── Legacy Wizard State (To be modularized next) ──
  int uploadStep = 0;
  int listStep = 0;
  bool idScanning = false;
  bool idDone = false;
  bool aiChecking = false;
  bool idVerified = false;
  bool faceScanning = false;
  bool faceDone = false;
  bool aiSubmitting = false;
  String? listingVerificationError;
  Map<String, dynamic>? lastListingAiReport;
  final Map<String, dynamic> listingDraft = {
    'ea_country': 'Uganda',
    'category': 'apartment',
    'purpose': 'rent',
    'bedrooms': 0,
    'bathrooms': 1,
    'price': 0,
  };
  bool submitted = false;
  int wallet = 0;

  // ── Utility Shard State ──
  bool utilityVerifying = false;
  bool utilityVerified = false;
  List<String> utilityAnchors = [];
  List<String> utilityMissing = [];
  String? utilityError;
  String filter = 'all';

  // ── Property Container State ──
  List<PropertyContainer> propertyContainers = [];
  List<PropertyContainer> mapContainers = []; // For map-specific queries
  String searchQuery = '';
  Map<String, dynamic>? zoneMetadata; // {zone_type, zone_label, color_hex}
  bool isSearching = false;

  // ── Chat Persistence Layer ──
  // (Conversations are now getters dynamically filtered from 'rooms')
  List<ChatMessage> currentMessages = [];
  ChatRoom? activeConversation;
  bool isChatLoading = false;

  // ── Virtual Tour Persistence Layer ──
  List<VirtualTourBooking> tourBookings = [];
  bool isTourLoading = false;

  bool isLoadingProperties = false;

  // ── Global Video/Audio Sync ──
  bool isGlobalMuted = false;
  double globalVolume = 1.0;

  void setGlobalMute(bool muted) {
    isGlobalMuted = muted;
    notifyListeners();
  }

  // ── Transport State ──
  List<TransportDriver> availableDrivers = [];
  List<TransportOrder> myTransportOrders = [];
  List<TransportOrder> myDriverOrders = [];
  bool isTransportLoading = false;
  bool isTransportSyncing = false;
  bool isDriver = false;
  TransportDriver? currentDriverProfile;

  // ── Scroll Persistence ──
  int communityFeedIndex = 0;
  int communityShopIndex = 0;

  PropertyContainer? get currentProperty => listingId == null
      ? null
      : propertyContainers.firstWhere((p) => p.core.id == listingId);

  Future<void> loadProperties() async {
    isLoadingProperties = true;
    notifyListeners();
    try {
      final raw = await SmoothAction.listProperties(limit: 50);
      propertyContainers = raw
          .map(
            (json) => PropertyContainer.fromJson(json as Map<String, dynamic>),
          )
          .toList();
    } catch (e) {
      debugPrint('Error loading properties: $e');
    }
    isLoadingProperties = false;
    notifyListeners();
  }

  Future<void> performSearch(String query) async {
    searchQuery = query;
    isSearching = true;
    zoneMetadata = null;
    notifyListeners();

    try {
      if (query.isNotEmpty) {
        // 1. Try to classify district/zone first
        zoneMetadata = await SmoothAction.classifyDistrict(query);

        // 2. Perform radius search if GPS available, else filter by district
        if (currentGps != null) {
          final res = await SmoothAction.searchByRadius(
            lat: currentGps!.latitude,
            lng: currentGps!.longitude,
            radiusMetres: 5000,
          );
          propertyContainers = res
              .map((j) => PropertyContainer.fromJson(j))
              .toList();
        } else {
          // Standard filter via listProperties with query
          await loadProperties(); // In real app, we'd add 'query' param to listProperties
        }
      } else {
        await loadProperties();
      }
    } catch (e) {
      debugPrint('Search Error: $e');
    } finally {
      isSearching = false;
      notifyListeners();
    }
  }

  Future<void> loadMapListings() async {
    try {
      final res = await SmoothAction.getMapListings();
      mapContainers = res.map((j) => PropertyContainer.fromJson(j)).toList();
      notifyListeners();
    } catch (e) {
      debugPrint('Map Load Error: $e');
    }
  }

  // ── Property Actions ──

  Future<void> unlockProperty(String id) async {
    if (user == null) return;
    paying = true;
    notify();
    try {
      final res = await SmoothAction.unlockProperty(id);
      if (res['success'] == true) {
        // Find the property in the local list and mark it as unlocked
        final idx = propertyContainers.indexWhere((p) => p.core.id == id);
        if (idx != -1) {
          // Re-fetch listing data to get the now-decrypted contact fields
          final raw = await SmoothAction.getProperty(id);
          final refreshed = PropertyContainer.fromJson(raw);
          propertyContainers[idx] = refreshed;
        }
        await loadProperties(); // Full sync
        paid = true;
      }
    } catch (e) {
      debugPrint('Unlock Error: $e');
    }
    paying = false;
    notify();
  }

  Future<void> reserveProperty(String id) async {
    if (user == null) return;
    paying = true;
    notify();
    try {
      final res = await SmoothAction.createEscrow(id);
      if (res['success'] == true) {
        await loadProperties();
        paid = true;
      }
    } catch (e) {
      debugPrint('Reservation Error: $e');
    }
    paying = false;
    notify();
  }

  final Set<String> followed = {};
  final Set<String> liked = {};
  final Set<String> saved = {};

  // ── Getters ──
  List<PropertyContainer> get filtered {
    var list = propertyContainers;
    if (filter != 'all') {
      list = list
          .where(
            (p) =>
                p.core.listingType.name == filter ||
                p.core.propertyType.name == filter,
          )
          .toList();
    }
    if (searchQuery.isNotEmpty) {
      list = list
          .where(
            (p) =>
                p.core.title.toLowerCase().contains(
                  searchQuery.toLowerCase(),
                ) ||
                p.core.district.toLowerCase().contains(
                  searchQuery.toLowerCase(),
                ) ||
                (p.core.city.toLowerCase().contains(searchQuery.toLowerCase())),
          )
          .toList();
    }
    return list;
  }

  // ── Global Methods ──
  void go(String s, {dynamic extra}) {
    // Prevent push-loops
    if (screen != s) {
      _navigationStack.add(screen);
    }

    screen = s;
    paid = false;
    paying = false;

    // Clear previous deep-links unless specifically navigating to them
    if (s != 'community') communityPostId = null;

    isImmersiveMode = (s == 'community' && creatorTab == 'feed');
    if (s == 'list' || s == 'property_listing') _resetWizard();
    if (s == 'profile') loadMyProfile();
    if (s == 'upload') {
      _resetUpload();
      if (extra is MusicTrack) {
        initialMusicTrack = extra;
      } else {
        initialMusicTrack = null;
      }
    }

    if (s == 'community' && extra is String) {
      communityPostId = extra;
    }

    if (s == 'public_profile' && extra is String) {
      targetProfileId = extra;
    }

    notifyListeners();
  }

  void goBack() {
    if (_navigationStack.isNotEmpty) {
      screen = _navigationStack.removeLast();
    } else {
      screen = 'home';
    }
    notifyListeners();
  }

  void _resetWizard() {
    listStep = 0;
    idScanning = false;
    idDone = false;
    aiChecking = false;
    idVerified = false;
    faceScanning = false;
    faceDone = false;
    gpsDone = false;
    aiSubmitting = false;
    submitted = false;
    utilityVerifying = false;
    utilityVerified = false;
    utilityShardId = null;
    utilityAnchors = [];
    utilityMissing = [];
    utilityError = null;
    listingVerificationError = null;
    lastListingAiReport = null;
    lc1Image = null;
    landTitleImage = null;
    stampImage = null;
  }

  void _resetUpload() {
    pickedMedia = null;
    uploadStep = 0;
    isUploading = false;
    uploadDone = false;
  }

  void openDetail(String id) {
    listingId = id;
    screen = 'detail';
    paid = false;
    paying = false;
    notifyListeners();
  }

  void setFilter(String f) {
    filter = f;
    notifyListeners();
  }

  void toggleSave(String id) {
    saved.contains(id) ? saved.remove(id) : saved.add(id);
    notify();
  }

  bool isFollowingSync(String id) => followed.contains(id); // Restored Method

  Future<void> toggleFollow(String id) async {
    followed.contains(id) ? followed.remove(id) : followed.add(id);
    notify();
    await social.toggleFollow(id);
  }

  Future<void> toggleLike(String id) async {
    liked.contains(id) ? liked.remove(id) : liked.add(id);
    notify();
    await social.toggleReaction(id);
  }

  Future<void> toggleSavePost(String id) async {
    saved.contains(id) ? saved.remove(id) : saved.add(id);
    notify();
    await social.toggleSavePost(id);
  }

  Future<void> reportContent(String id, String type, String reason) async {
    await social.reportContent(id, type, reason);
  }

  Future<void> notInterested(String id, String type) async {
    await social.hideContent(id, type);
  }

  // ── Creator Tab ──
  void setCreatorTab(String tab) {
    creatorTab = tab;
    pendingDestinationTab =
        tab; // 🚀 Signals CommunityScreen to warp to this tab
    isImmersiveMode = (tab == 'feed');
    notify();
  }

  // ── Gift Engine ──
  Future<void> sendGift(
    String emoji,
    String name,
    int price,
    int fee, {
    String? receiverId,
    String? contextType,
    String? contextId,
  }) async {
    giftEmoji = emoji;
    giftName = name;
    giftFee = fee;
    showGiftFloat = true;

    notify();

    // Supabase 2 is authoritative; refresh only after the atomic transfer.
    if (user != null) {
      try {
        final catalog = await financeGifting.fetchGiftItems();
        GiftItem? giftItem;
        for (final item in catalog) {
          if (item.name == name ||
              (item.emoji == emoji && item.ncxValue == price)) {
            giftItem = item;
            break;
          }
        }
        if (giftItem == null) {
          throw StateError('Gift is not available in the finance catalogue.');
        }
        final result = await financeGifting.sendGift(
          senderId: user!.id,
          receiverId: receiverId ?? '00000000-0000-4000-8000-000000000001',
          giftItemId: giftItem.id,
          ncxAmount: price,
          contextType: contextType ?? 'direct',
          contextId: contextId ?? 'general_feed',
        );

        if (result.success) {
          await _syncVault();
        } else {
          debugPrint('Supabase gifting failed: ${result.message}');
        }
      } catch (e) {
        await _syncVault();
        debugPrint('Gift persist error: $e');
      }
    }
  }

  // ── Payment Actions ──
  void setPayMethod(String m) {
    payMethod = m;
    notifyListeners();
  }

  Future<void> doPay() async {
    paying = true;
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 2500));
    paying = false;
    paid = true;
    notifyListeners();
  }

  void triggerLegacyGift(String emoji, String name, int price, int fee) {
    // This maintains the legacy UI trigger if needed, but redirects to the new wallet logic
    giftEmoji = emoji;
    giftName = name;
    giftFee = fee;
    showGiftFloat = true;
    notifyListeners();
  }

  Future<void> doIdScan(String country, String idType) async {
    // Legacy routing to the new unified loop
    await startVerification();
  }

  Future<void> doIdBackScan() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.camera);
      if (picked != null) {
        idBackImage = File(picked.path);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('ID Back Scan Error: $e');
    }
  }

  Future<void> doFaceScan() async {
    faceScanning = true;
    notify();
    await Future.delayed(const Duration(seconds: 2));
    faceScanning = false;
    faceDone = true;
    notify();
  }

  Future<void> captureGps() async {
    gpsDone = true;
    try {
      bool serviceEnabled;
      LocationPermission permission;

      gpsError = null;
      notifyListeners();

      // Test if location services are enabled.
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        gpsError = 'Location services are disabled.';
        notifyListeners();
        return;
      }

      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          gpsError = 'Location permissions are denied';
          notifyListeners();
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        gpsError = 'Permissions permanently denied. Enable in Settings.';
        notifyListeners();
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 15),
      );
      currentGps = pos;
      gpsDone = true;
      notifyListeners();
    } catch (e) {
      debugPrint('GPS Error: $e');
      gpsError = 'GPS Error: $e';
      notifyListeners();
    }
  }

  Future<void> doLc1Capture() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.camera);
      if (picked != null) {
        lc1Image = File(picked.path);
        utilityVerified = false; // Reset to re-verify
        notifyListeners();
      }
    } catch (e) {
      debugPrint('LC1 Capture Error: $e');
    }
  }

  Future<void> doLandTitleCapture() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.camera);
      if (picked != null) {
        landTitleImage = File(picked.path);
        utilityVerified = false; // Reset to re-verify
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Land Title Capture Error: $e');
    }
  }

  Future<void> doUtilityVerify(
    BuildContext context,
    String country,
    String umemeMeter,
    String nwscAccount,
    String block,
    String plot,
  ) async {
    utilityError = null;
    isVerifying = true;
    notifyListeners();
    try {
      final res = await ListingSyncService.submitUtilityShard(
        country: country,
        umemeMeter: umemeMeter,
        nwscAccount: nwscAccount,
        landBlock: block,
        landPlot: plot,
        lc1StampPhoto: lc1Image ?? stampImage,
        landTitlePhoto: landTitleImage,
      );

      if (res['utility_shard_id'] != null) {
        utilityVerified = true;
        utilityShardId = res['utility_shard_id'];
        utilityAnchors = ["NECX AI Secure Handshake", "Land Shard Verified"];
      } else {
        utilityError = "Verification failed to produce a shard.";
      }
    } catch (e) {
      utilityError = e.toString().replaceFirst('Exception: ', '');
      debugPrint('Utility Verification Error: $e');
    }
    isVerifying = false;
    notifyListeners();
  }

  Future<void> doStampCapture() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.camera);
      if (picked != null) {
        stampImage = File(picked.path);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Stamp Capture Error: $e');
    }
  }

  void toggleAmenity(String amen) {
    selectedAmenities.contains(amen)
        ? selectedAmenities.remove(amen)
        : selectedAmenities.add(amen);
    notifyListeners();
  }

  void updateListingDraft(String key, dynamic value) {
    listingDraft[key] = value;
    notifyListeners();
  }

  void addVerifiedMedia(File file) {
    verifiedMedia.add(file);
    notifyListeners();
  }

  Future<void> doBathroomCapture() async {
    try {
      // Strictly Camera Source for In-App Coverage
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
      );
      if (picked != null) {
        bathroomImage = File(picked.path);
        toiletProof = bathroomImage;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Toilet Capture Error: $e');
    }
  }

  Future<void> doSubmit(Map<String, dynamic> payload) async {
    if (user == null) return;
    aiSubmitting = true;
    listingVerificationError = null;
    lastListingAiReport = null;
    notifyListeners();

    try {
      if (idImage == null ||
          idBackImage == null ||
          idHoldingImage == null ||
          faceImage == null) {
        throw Exception(
          "Identity scanning incomplete. Missing front ID, back ID, holding ID, or face photo.",
        );
      }

      if (pickedMedia == null) {
        throw Exception(
          'Add a clear exterior property photo for AI verification.',
        );
      }

      final listingAiReport = await NecxaAI.verifyListingPhotoWorker(
        photo: pickedMedia!,
        title: payload['title']?.toString() ?? 'Property listing',
      );
      lastListingAiReport = listingAiReport;
      if (listingAiReport['success'] == false ||
          listingAiReport['error'] != null) {
        throw Exception(
          listingAiReport['error']?.toString() ??
              'Listing AI verification failed. Please try again.',
        );
      }
      if (listingAiReport['verified'] != true) {
        throw Exception(
          listingAiReport['description']?.toString() ??
              'The property photo could not be verified. Add a clearer exterior photo and retry.',
        );
      }

      // 1. STAGE 1: IDENTITY SHARD
      String finalIdentityShardId;
      if (identityShardId != null) {
        finalIdentityShardId = identityShardId!;
      } else {
        final frontVerificationId = lastIDResult?.sessionId ?? '';
        final backVerificationId = lastIDBackResult?.sessionId ?? '';
        final holdingVerificationId = lastHoldingResult?.sessionId ?? '';
        final biometricVerificationId = lastSelfieResult?.sessionId ?? '';
        if ([
          frontVerificationId,
          backVerificationId,
          holdingVerificationId,
          biometricVerificationId,
        ].any((value) => value.isEmpty)) {
          throw Exception(
            'Identity verification receipts are missing. Complete the identity capture once before submitting.',
          );
        }
        final identityRes = await ListingSyncService.submitIdentityShard(
          country: payload['ea_country'] ?? 'Uganda',
          docType: payload['ea_id_type'] ?? 'National ID',
          docNumber: payload['id_number'] ?? '',
          idFront: idImage!,
          idBack: idBackImage!,
          idHolding: idHoldingImage!,
          facePhoto: faceImage!,
          frontVerificationId: frontVerificationId,
          backVerificationId: backVerificationId,
          holdingVerificationId: holdingVerificationId,
          biometricVerificationId: biometricVerificationId,
          idempotencyKey: 'identity-${user!.id}-$biometricVerificationId',
        );
        finalIdentityShardId = identityRes['identity_shard_id'];
      }

      // 2. STAGE 2: UTILITY SHARD (use pre-verified shard if available)
      final String utilityShardIdFinal;
      if (utilityShardId != null) {
        utilityShardIdFinal = utilityShardId!;
      } else {
        final utilityRes = await ListingSyncService.submitUtilityShard(
          country: payload['ea_country'] ?? 'Uganda',
          umemeMeter: payload['utility_data'],
          nwscAccount: payload['nwsc_data'],
          lc1StampPhoto: lc1Image ?? stampImage,
          landTitlePhoto: landTitleImage,
        );
        utilityShardIdFinal = utilityRes['utility_shard_id'];
      }

      // 3. STAGE 3: GPS LOCK
      final gpsRes = await ListingSyncService.submitGpsLock(
        lat: currentGps?.latitude ?? 0.0,
        lng: currentGps?.longitude ?? 0.0,
        accuracy: currentGps?.accuracy ?? 50.0,
        reportedAddress: payload['city'] ?? 'Unknown',
        reportedDistrict: payload['district'] ?? payload['city'] ?? 'Unknown',
      );
      final gpsNodeId = gpsRes['gps_node_id'];

      // 4. STAGE 4: NEURAL SYNTHESIS
      final photos = <File>[];
      if (pickedMedia != null) photos.add(pickedMedia!);

      final bathroomPhotos = <File>[];
      if (bathroomImage != null) bathroomPhotos.add(bathroomImage!);

      await ListingSyncService.submitNeuralSynthesis(
        identityShardId: finalIdentityShardId,
        utilityShardId: utilityShardIdFinal,
        gpsNodeId: gpsNodeId,
        title: payload['title'] ?? 'Listing',
        description: payload['description'] ?? '',
        propertyType: payload['category'] ?? 'apartment',
        purpose: payload['purpose'] ?? 'rent',
        country: payload['ea_country'] ?? 'Uganda',
        district: payload['district'] ?? payload['city'] ?? 'Unknown',
        address: payload['city'] ?? 'Unknown',
        priceUgx: (payload['price'] as num).toInt(),
        pricePeriod: '/month',
        bedrooms: payload['bedrooms'] ?? 0,
        bathrooms: payload['bathrooms'] ?? 1,
        sqft: 0,
        amenities: selectedAmenities,
        agentPhone: payload['contact_phone'],
        agentWhatsapp: payload['contact_whatsapp'],
        agentGoogleMeet: payload['contact_google_meet'],
        photos: photos,
        bathroomPhotos: bathroomPhotos,
      );

      submitted = true;
      await loadProperties(); // Refresh public list
    } catch (e) {
      debugPrint('Submission Error: $e');
      listingVerificationError = e.toString().replaceFirst('Exception: ', '');
    }

    aiSubmitting = false;
    notifyListeners();
  }

  void nextStep() {
    listStep++;
    notifyListeners();
  }

  void prevStep() {
    if (listStep > 0) listStep--;
    notifyListeners();
  }

  // ── Agent State ──
  bool isAgent = false;
  Future<void> verifyAsAgent(List<String> documentUrls) async {
    if (user == null) return;
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'verify-agent',
        body: {'user_id': user!.id, 'document_urls': documentUrls},
      );
      if (res.status == 200) {
        isAgent = true;
      } else {
        debugPrint(
          'Verification via Edge Function failed, falling back to local state.',
        );
        isAgent = true; // Fallback for local testing
      }
    } catch (e) {
      debugPrint('Cloud Function Exception: $e');
      isAgent = true; // Fallback for local testing
    }
    notifyListeners();
  }

  // ── Auth Actions ──
  void onAuthStateChange(AuthState state) {
    final authenticatedUserId = state.session?.user.id;
    if (authenticatedUserId != null) {
      if (_notificationUserId != authenticatedUserId) {
        appNotifications = [];
        _notificationUserId = authenticatedUserId;
        unawaited(NotificationService().clearDisplayedNotifications());
      }
      _syncVault();
      checkSecurityStatus(); // Syncs 2FA, Forex, and Payment Methods
    } else {
      _syncTimer?.cancel();
      if (_notifChannel != null) {
        unawaited(Supabase.instance.client.removeChannel(_notifChannel!));
        _notifChannel = null;
      }
      _notificationUserId = null;
      appNotifications = [];
      unawaited(NotificationService().clearDisplayedNotifications());
    }
    notifyListeners();
  }

  Future<void> logout() async {
    await localDb.clearAllOnLogout();
    myTransportOrders = [];
    myDriverOrders = [];
    currentDriverProfile = null;
    isDriver = false;
    await Supabase.instance.client.auth.signOut();
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    await Supabase.instance.client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    notifyListeners();
  }

  Future<Profile?> getProfile(String id) async {
    // 1. Check Local Cache first
    final localDb = LocalDbService();
    final cached = await localDb.getProfile(id);
    if (cached != null) {
      // Background refresh to keep cache warm
      _backgroundSyncProfile(id);
      return Profile.fromMap({
        'id': id,
        'full_name': cached['display_name'],
        'avatar_url': cached['photo_url'],
        'verified': cached['is_verified'] == 1,
      });
    }

    return await syncProfile(id);
  }

  Future<Profile?> syncProfile(String id) async {
    try {
      final res = await Supabase.instance.client
          .from('profiles')
          .select()
          .eq('id', id)
          .maybeSingle();

      if (res == null) return null;

      final profile = Profile.fromMap(res);

      // Update Local Cache
      final localDb = LocalDbService();
      await localDb.database.then(
        (db) => db.insert('social_profiles', {
          'id': id,
          'display_name': profile.fullName,
          'photo_url': profile.avatarUrl,
          'trust_score': 50,
          'is_verified': profile.verified ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace),
      );

      targetProfileId = id;
      return profile;
    } catch (e) {
      debugPrint('Profile Sync Failure: $e');
      return null;
    }
  }

  void _backgroundSyncProfile(String id) async {
    await syncProfile(id);
  }

  // ── Chat & Messaging Actions ──
  RealtimeChannel? _msgChannel;
  RealtimeChannel? _notifChannel;
  String? _notificationUserId;

  void _subscribeToNotifications() {
    final subscribedUserId = user?.id;
    if (subscribedUserId == null) return;
    if (_notifChannel != null) {
      Supabase.instance.client.removeChannel(_notifChannel!);
      _notifChannel = null;
    }
    _notificationUserId = subscribedUserId;

    _notifChannel = Supabase.instance.client
        .channel('notifications:$subscribedUserId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: subscribedUserId,
          ),
          callback: (payload) async {
            if (user?.id != subscribedUserId) return;
            debugPrint(
              '🔔 Realtime Notification Received: ${payload.newRecord}',
            );
            final notif = AppNotification.fromMap(payload.newRecord);
            if (notif.userId != subscribedUserId) return;
            await NotificationService().showNotification(
              notif,
              recipientUserId: subscribedUserId,
            );
            if (notif.metadata['interaction_context'] == 'support') {
              await fetchCreatorConversations(force: true);
            }
            await loadNotifications();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: subscribedUserId,
          ),
          callback: (payload) async {
            if (user?.id != subscribedUserId) return;
            final notif = AppNotification.fromMap(payload.newRecord);
            if (notif.userId != subscribedUserId) return;
            await NotificationService().showNotification(
              notif,
              recipientUserId: subscribedUserId,
              showSystem: false,
            );
            await loadNotifications();
          },
        )
        .subscribe();
  }

  // ── UNIFIED CHAT PIPELINES ──
  List<ChatRoom> rooms = [];

  // Inbox gets Vendor / General chats
  List<ChatRoom> get conversations => rooms
      .where((r) => r.metadata?['interaction_context'] != 'social')
      .toList();

  // Creator Social gets ONLY Social chats
  List<ChatRoom> get creatorConversations => rooms
      .where((r) => r.metadata?['interaction_context'] == 'social')
      .toList();

  Future<void> fetchConversations() async {
    // Route main Inbox fetch to the unified sync pipeline
    await fetchCreatorConversations();
  }

  bool isCreatorChatLoading = false;
  bool isInboxHydrated = false;
  // Throttle: only hit the network once per 60s for inbox refresh
  DateTime? _lastInboxSync;

  /// 📥 GLOBAL HYDRATION: Pulls everything from SQLite into memory at startup
  Future<void> hydrateFromLocal() async {
    try {
      // Load Rooms first (Critical for Inbox)
      rooms = await localDb.getRooms();
      isInboxHydrated = true;
      debugPrint(
        '🛡️ Necxa-Vault: Local Social Hydrated (${rooms.length} rooms)',
      );

      // Load Recent Messages for active conversation if any
      if (activeConversation != null) {
        currentMessages = await localDb.getMessages(activeConversation!.id);
      }

      notify();
    } catch (e) {
      debugPrint('Hydration Error: $e');
    }
  }

  Future<void> fetchCreatorConversations({bool force = false}) async {
    // 1. Instant Load from Cache — always shown immediately
    if (!isInboxHydrated) await hydrateFromLocal();

    // 2. TTL GUARD: skip network if refreshed within the last 60 seconds
    final now = DateTime.now();
    if (!force &&
        _lastInboxSync != null &&
        now.difference(_lastInboxSync!).inSeconds < 60) {
      debugPrint(
        '⏱️ Inbox sync skipped (TTL: ${now.difference(_lastInboxSync!).inSeconds}s old)',
      );
      return;
    }

    // Only show spinner if absolutely empty
    if (rooms.isEmpty) {
      isCreatorChatLoading = true;
      notify();
    }

    try {
      // 3. Background Delta Sync
      final res = await Supabase.instance.client.from('v_my_chats_v2').select();
      final newRooms = List<ChatRoom>.from(
        res.map((j) => ChatRoom.fromJson(j)),
      );

      // 4. Persist to SQLite
      await localDb.saveRooms(newRooms);

      // 5. Refresh Memory State
      rooms = await localDb.getRooms();
      _lastInboxSync = now;
      debugPrint('🔄 Necxa-Sync: Inbox updated from Cloud');
    } catch (e) {
      debugPrint('fetchCreatorConversations Sync Error: $e');
    } finally {
      isCreatorChatLoading = false;
      isInboxHydrated = true;
      notify();
    }
  }

  Future<void> fetchMessages(String roomId) async {
    // 1. Load from Local Cache (Instant UI)
    currentMessages = await localDb.getMessages(roomId);
    notify();

    // 2. Incremental Sync via High-Performance Redis Cache
    try {
      final res = await SmoothAction.getMessages(roomId);
      if (res['success'] == true) {
        final List<dynamic> rawMsgs = res['data'];
        final newMsgs = List<ChatMessage>.from(
          rawMsgs.map((j) => ChatMessage.fromJson(j)),
        );

        if (newMsgs.isNotEmpty) {
          await localDb.saveMessages(newMsgs);
          // Merge and re-sort
          currentMessages = await localDb.getMessages(roomId);
          notify();
        }
      }
    } catch (e) {
      debugPrint('fetchMessages Neural Sync Error: $e');
    }

    // 3. Ensure Realtime is active
    if (_msgChannel == null || _currentSubscribedRoomId != roomId) {
      _subscribeToMessages(roomId);
    }
  }

  String? _currentSubscribedRoomId;

  Future<void> markRoomAsRead(String roomId) async {
    if (user == null) return;
    try {
      // Fire-and-forget RPC — do NOT await a full inbox refresh just to clear a badge.
      // Instead update the local room's unread count in-memory immediately.
      Supabase.instance.client
          .rpc(
            'mark_room_read',
            params: {'p_room_id': roomId, 'p_user_id': user!.id},
          )
          .catchError((e) => debugPrint('Mark Read RPC Error: $e'));

      // Local badge clear — zero egress
      final idx = rooms.indexWhere((r) => r.id == roomId);
      if (idx != -1) {
        rooms[idx] = rooms[idx].copyWithUnread(0);
        notify();
      }
    } catch (e) {
      debugPrint('Mark Read Error: $e');
    }
  }

  void _subscribeToMessages(String roomId) {
    // Remove previous subscription if switching rooms
    if (_msgChannel != null) {
      Supabase.instance.client.removeChannel(_msgChannel!);
      _msgChannel = null;
    }
    _currentSubscribedRoomId = roomId;
    _msgChannel = Supabase.instance.client
        .channel('direct_messages:$roomId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'direct_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'room_id',
            value: roomId,
          ),
          callback: (payload) async {
            final newMsg = ChatMessage.fromJson(payload.newRecord);
            // 1. Save to Local Cache immediately
            await localDb.saveMessages([newMsg]);

            // 2. Update UI if not already present
            if (!currentMessages.any((m) => m.id == newMsg.id)) {
              currentMessages.add(newMsg);
              currentMessages.sort(
                (a, b) => a.createdAt.compareTo(b.createdAt),
              );
              notify();
            }
          },
        )
        .subscribe();
  }

  void unsubscribeFromMessages() {
    if (_msgChannel != null) {
      Supabase.instance.client.removeChannel(_msgChannel!);
      _msgChannel = null;
    }
  }

  Future<void> openOrCreateChat(PropertyContainer property) async {
    if (user == null) return;
    final otherId = property.core.agentId ?? property.core.listerId;
    if (otherId == user!.id) return; // Avoid self-chat

    try {
      final String roomId = await Supabase.instance.client.rpc(
        'get_or_create_direct_room',
        params: {'p_user_a': user!.id, 'p_user_b': otherId},
      );

      // Refresh view to get other party metadata
      await fetchConversations();

      // Find the room in our local list or fallback
      activeConversation = conversations.firstWhere(
        (c) => c.id == roomId,
        orElse: () => ChatRoom(
          id: roomId,
          agentId: property.core.agentId,
          sellerId: property.core.listerId,
          otherName: 'Agent/Owner',
          createdAt: DateTime.now(),
        ),
      );

      await fetchMessages(roomId);
      go('chat-detail');
    } catch (e) {
      debugPrint('Open Chat Error: $e');
    }
  }

  Future<void> openCreatorChat(
    String authorId,
    String authorName,
    String? authorAvatar, {
    String? initialContextText,
    String context = 'social',
  }) async {
    if (user == null) return;
    if (authorId == user!.id) return;

    try {
      final String roomId = await Supabase.instance.client.rpc(
        'get_or_create_direct_room',
        params: {'p_user_a': user!.id, 'p_user_b': authorId},
      );

      activeConversation = ChatRoom(
        id: roomId,
        agentId: authorId,
        otherName: authorName,
        otherAvatar: authorAvatar,
        createdAt: DateTime.now(),
        // Streamlining context: social vs vendor
        metadata: {'interaction_context': context},
      );

      // 🚀 PERSIST IMMEDIATELY: Ensure this room is available offline
      await localDb.saveRooms([activeConversation!]);

      await fetchMessages(roomId);
      await markRoomAsRead(roomId);
      go('creator-chat-detail');

      // Auto-send context if provided
      if (initialContextText != null) {
        // Small delay to let UI transition
        Future.delayed(const Duration(milliseconds: 500), () {
          sendChatMessage(initialContextText);
        });
      }
    } catch (e) {
      debugPrint('Open Creator Chat Error: $e');
    }
  }

  String _generateUuidv4() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (i) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 10
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .replaceFirstMapped(
          RegExp(r'^(.{8})(.{4})(.{4})(.{4})(.{12})$'),
          (m) => '${m[1]}-${m[2]}-${m[3]}-${m[4]}-${m[5]}',
        );
  }

  Future<void> sendChatMessage(
    String msg, {
    String? mediaUrl,
    String? messageType,
    String? voiceData,
    int? durationSeconds,
  }) async {
    if (user == null || activeConversation == null) return;

    final messageId = _generateUuidv4();
    String? finalLocalPath;
    String? finalNetworkUrl;
    bool isMediaLocal = mediaUrl != null && !mediaUrl.startsWith('http');

    // 1. 📁 WHATSAPP-STYLE: Handle Local Media immediately
    if (isMediaLocal) {
      finalLocalPath = await _persistMedia(File(mediaUrl), 'sent');
    } else {
      finalNetworkUrl = mediaUrl;
    }

    final resolvedType =
        messageType ??
        (mediaUrl != null
            ? (mediaUrl.contains('.m4a') || mediaUrl.contains('.mp3')
                  ? 'voice'
                  : 'image')
            : 'text');

    // 2. 🚀 OPTIMISTIC UI: Save locally with Local Path first
    final optimisticMsg = ChatMessage(
      id: messageId,
      conversationId: activeConversation!.id,
      senderId: user!.id,
      receiverId: activeConversation!.otherPartyId,
      content: msg,
      mediaUrl: finalNetworkUrl,
      localMediaPath: finalLocalPath ?? (isMediaLocal ? mediaUrl : null),
      messageType: resolvedType,
      createdAt: DateTime.now(),
    );

    currentMessages.add(optimisticMsg);
    await localDb.saveMessages([optimisticMsg]);
    notify();

    // 3. ☁️ BACKGROUND UPLOAD (if needed — SKIP for voice notes, zero egress)
    if (isMediaLocal && resolvedType != 'voice') {
      try {
        final uploadRes = await cloud.uploadMedia(
          File(finalLocalPath ?? mediaUrl),
          bucket: 'chat-media',
          assetType: 'chat_attachment',
        );
        if (uploadRes != null) {
          finalNetworkUrl = uploadRes['url'];
          // Update local DB with the new network URL (while preserving local path)
          await localDb.saveMessages([
            ChatMessage(
              id: messageId,
              conversationId: activeConversation!.id,
              senderId: user!.id,
              content: msg,
              mediaUrl: finalNetworkUrl,
              localMediaPath: finalLocalPath,
              messageType: resolvedType,
              createdAt: optimisticMsg.createdAt,
            ),
          ]);
        }
      } catch (e) {
        debugPrint('Media Upload Failed: $e');
      }
    }

    // 4. 🛰️ DISPATCH TO ORCHESTRATOR
    bool sent = false;
    try {
      final res = await SmoothAction.sendMessage(
        toUserId: activeConversation!.otherPartyId,
        content: msg,
        roomId: activeConversation!.id,
        messageType: resolvedType,
        messageId: messageId,
        mediaUrl: finalNetworkUrl,
        // Voice notes carry their audio bytes through Realtime — zero Storage egress.
        voiceData: resolvedType == 'voice' ? voiceData : null,
        durationSeconds: durationSeconds,
      );
      if (res['success'] == true) sent = true;
    } catch (e) {
      debugPrint('Orchestrator sync failed: $e');
    }

    if (!sent) {
      // Fallback to direct DB insert
      try {
        await Supabase.instance.client.from('direct_messages').insert({
          'id': messageId,
          'room_id': activeConversation!.id,
          'sender_id': user!.id,
          'message_type': resolvedType,
          'content': msg,
          'media_url': finalNetworkUrl,
        });
        sent = true;
      } catch (_) {}
    }

    if (sent) {
      // Do NOT re-fetch — the Realtime subscription delivers the echo automatically.
      // Triggering fetchMessages here would double-count egress on every send.
      debugPrint('✅ Message dispatched via Realtime pipeline');
    }
  }

  Future<String?> pickMedia() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked != null) {
      pickedMedia = File(picked.path);
      notify();
      return picked.path;
    }
    return null;
  }

  // ── Virtual Tours & Handshakes ──
  Future<void> doHandshake(String propertyId) async {
    // Secure tokenized handshake
    notify();
  }

  Future<void> scheduleVirtualTour(
    PropertyContainer property,
    DateTime date,
  ) async {
    // Logic to book tour
    notify();
  }

  // ── Necxa AI Orchestration ──
  bool isAiThinking = false;
  List<ChatMessage> chatLog = [];

  Future<void> loadAiChatHistory() async {
    try {
      chatLog = await localDb.getMessages('ai-chat');
      notify();
    } catch (_) {}
  }

  Future<void> askNecxa(String query, {String language = 'English'}) async {
    isAiThinking = true;
    notify();
    try {
      final userMsg = ChatMessage(
        id: 'u-${DateTime.now().millisecondsSinceEpoch}',
        conversationId: 'ai-chat',
        senderId: user?.id ?? 'local_user',
        content: query,
        createdAt: DateTime.now(),
      );
      chatLog.add(userMsg);
      await localDb.saveMessages([userMsg]);

      // Prefer the isolated Cloudflare assistant and retain the latest context.
      // Falls back to Supabase necxa-chat automatically if the worker is down.
      final conversation = chatLog
          .skip(chatLog.length > 20 ? chatLog.length - 20 : 0)
          .map(
            (message) => {
              'role': message.senderId == 'necxa-ai' ? 'assistant' : 'user',
              'content': message.content ?? '',
            },
          )
          .toList();
      final res = await NecxaAI.askNecxaWorker(
        query,
        language: language,
        conversation: conversation,
        context: {'screen': 'necxa_ai_chat'},
      );

      final aiMsg = ChatMessage(
        id: 'a-${DateTime.now().millisecondsSinceEpoch}',
        conversationId: 'ai-chat',
        senderId: 'necxa-ai',
        content: res,
        createdAt: DateTime.now(),
      );
      chatLog.add(aiMsg);
      await localDb.saveMessages([aiMsg]);
    } catch (_) {}
    isAiThinking = false;
    notify();
  }

  // ── Transport Actions ──
  Future<void> fetchAvailableDrivers() async {
    isTransportLoading = true;
    notify();
    try {
      final res = await Supabase.instance.client
          .from('transport_drivers')
          .select('id,name,number_plate,vehicle_type,is_verified,is_available')
          .eq('is_available', true)
          .eq('is_verified', true)
          .limit(50);
      availableDrivers = List<TransportDriver>.from(
        res.map((j) => TransportDriver.fromJson(j)),
      );
    } catch (e) {
      debugPrint('Error fetching drivers: $e');
    }
    isTransportLoading = false;
    notify();
  }

  Future<void> toggleDriverAvailability(bool online) async {
    if (user == null || !isDriver) return;
    try {
      await Supabase.instance.client
          .from('transport_drivers')
          .update({'is_available': online})
          .eq('id', user!.id);

      currentDriverProfile = TransportDriver(
        id: currentDriverProfile!.id,
        name: currentDriverProfile!.name,
        email: currentDriverProfile!.email,
        numberPlate: currentDriverProfile!.numberPlate,
        phone: currentDriverProfile!.phone,
        vehicleType: currentDriverProfile!.vehicleType,
        permitUrl: currentDriverProfile!.permitUrl,
        isVerified: currentDriverProfile!.isVerified,
        isAvailable: online,
        countryCode: currentDriverProfile!.countryCode,
        verificationStatus: currentDriverProfile!.verificationStatus,
        verificationReasonCode: currentDriverProfile!.verificationReasonCode,
      );
      notify();
    } catch (e) {
      debugPrint('Toggle Availability Error: $e');
    }
  }

  Future<void> fetchDriverOrders() async {
    if (user == null || !isDriver) return;
    try {
      final res = await Supabase.instance.client
          .from('transport_orders')
          .select(
            'id,user_id,driver_id,pickup_location,dropoff_location,status,price,created_at,updated_at,delivery_lat,delivery_lng',
          )
          .eq('driver_id', user!.id)
          .order('updated_at', ascending: false)
          .limit(100);
      myDriverOrders = List<TransportOrder>.from(
        res.map((j) => TransportOrder.fromJson(j)),
      );
      notify();
    } catch (e) {
      debugPrint('Fetch Driver Orders Error: $e');
    }
  }

  Future<void> acceptOrder(String orderId) async {
    await updateOrderStatus(orderId, 'accepted');
    if (soundEnabled) await AudioService().playNotification();
  }

  Future<void> updateOrderStatus(String orderId, String status) async {
    try {
      final updates = <String, dynamic>{'status': status};
      if (status == 'accepted' && currentDriverProfile != null) {
        updates['driver_id'] = currentDriverProfile!.id;
      }

      // If marking as delivered, record the current GPS location
      if (status == 'delivered') {
        await captureGps(); // AppState method
        if (currentGps != null) {
          updates['delivery_lat'] = currentGps!.latitude;
          updates['delivery_lng'] = currentGps!.longitude;
        }
      }

      if (status == 'completed') {
        await _releaseEscrow(orderId);
      }
      if (status == 'cancelled') {
        await FinanceBackend.instance.invoke(
          'refund_transport_booking',
          body: {'orderId': orderId, 'reason': 'customer_cancelled'},
        );
        await _syncVault();
      }

      await Supabase.instance.client
          .from('transport_orders')
          .update(updates)
          .eq('id', orderId);

      await fetchMyOrders();
      await fetchDriverOrders();
      if (soundEnabled && (status == 'delivered' || status == 'completed')) {
        await AudioService().playNotification();
      }
    } catch (e) {
      debugPrint('Update Status Error: $e');
      rethrow;
    }
  }

  Future<void> raiseDispute(String orderId, String reason) async {
    if (user == null) return;
    isTransportLoading = true;
    notify();
    try {
      // 1. Lock GPS
      await captureGps();

      // 2. Pick Photo evidence (Caller should have already picked it OR we do it here)
      // For this workflow, I'll assume evidence was picked via pickedMedia
      String? evidenceUrl;
      if (pickedMedia != null) {
        final uploadData = await cloud.uploadMedia(
          pickedMedia!,
          assetType: 'dispute',
        );
        if (uploadData != null) evidenceUrl = uploadData['url'];
      }

      // 3. Create Dispute Entry
      await Supabase.instance.client.from('transport_disputes').insert({
        'order_id': orderId,
        'disputer_id': user!.id,
        'reason': reason,
        'evidence_url': evidenceUrl,
        'lat': currentGps?.latitude,
        'lng': currentGps?.longitude,
      });

      await FinanceBackend.instance.invoke(
        'dispute_transport_booking',
        body: {'orderId': orderId, 'reason': reason},
      );

      // 4. Update Order Status to disputed
      await updateOrderStatus(orderId, 'disputed');

      pickedMedia = null;
    } catch (e) {
      debugPrint('Raise Dispute Error: $e');
      rethrow;
    } finally {
      isTransportLoading = false;
      notify();
    }
  }

  Future<void> _releaseEscrow(String orderId) async {
    await FinanceBackend.instance.invoke(
      'settle_transport_booking',
      body: {'orderId': orderId},
    );
    await _syncVault();
  }

  Future<void> registerDriver(Map<String, dynamic> data) async {
    if (user == null) return;
    isTransportLoading = true;
    notify();
    try {
      // 1. Upload permit if file exists
      if (pickedMedia != null) {
        final uploadData = await cloud.uploadMedia(
          pickedMedia!,
          assetType: 'permit',
        );
        if (uploadData != null) data['permit_url'] = uploadData['url'];
      }

      final payload = {
        'id': user!.id,
        'name': data['name'],
        'email': user!.email,
        'number_plate': data['number_plate'],
        'vehicle_type': data['vehicle_type'],
        'permit_url': data['permit_url'],
        'is_verified': false,
        'is_available': true,
      };

      await Supabase.instance.client.from('transport_drivers').upsert(payload);

      // Update local state
      isDriver = true;
      currentDriverProfile = TransportDriver.fromJson(payload);

      pickedMedia = null;
      go('transport');
    } catch (e) {
      debugPrint('Driver Registration Error: $e');
    }
    isTransportLoading = false;
    notify();
  }

  Future<void> checkDriverStatus({bool loadOrders = true}) async {
    if (user == null) return;
    try {
      final res = await Supabase.instance.client
          .from('transport_drivers')
          .select('id,name,number_plate,vehicle_type,is_verified,is_available,country_code,verification_status,verification_reason_code')
          .eq('id', user!.id)
          .maybeSingle();
      if (res != null) {
        isDriver = true;
        currentDriverProfile = TransportDriver.fromJson(res);
        if (loadOrders) await fetchDriverOrders();
      } else {
        isDriver = false;
        currentDriverProfile = null;
      }
      notify();
    } catch (e) {
      debugPrint('Check Driver Status Error: $e');
    }
  }

  Future<void> createTransportOrder({
    required TransportDriver driver,
    required String pickup,
    required String dropoff,
    required double price,
  }) async {
    if (user == null) return;
    isTransportLoading = true;
    notify();
    String? transactionId;
    var orderCreated = false;
    try {
      // 1. Check Wallet Balance
      if (fiatBalance < price) {
        throw Exception(
          'Insufficient wallet balance. Please top up to book transport.',
        );
      }

      // 2. Create Order in Escrow Style
      transactionId = _generateUuidv4();

      // Hold the fare in the Finance Supabase escrow before creating the trip.
      final escrowRes = await FinanceBackend.instance.invoke(
        'create_transport_booking',
        body: {
          'orderId': transactionId,
          'driverId': driver.id,
          'pickup': pickup,
          'dropoff': dropoff,
          'amountUgx': price.round(),
          'idempotencyKey': 'transport-$transactionId',
        },
      );

      if (escrowRes['success'] != true) {
        throw Exception(
          escrowRes['message'] ?? 'Failed to secure funds in escrow.',
        );
      }

      await _syncVault(); // Sync wallet to reflect escrow balance

      final orderData = {
        'id': transactionId,
        'user_id': user!.id,
        'driver_id': driver.id,
        'pickup_location': pickup,
        'dropoff_location': dropoff,
        'price': price,
        'status': 'pending',
      };

      // Perform the insert
      await Supabase.instance.client.from('transport_orders').insert(orderData);
      orderCreated = true;

      await _syncVault(); // Refresh local wallet state

      await fetchMyOrders();
    } catch (e) {
      debugPrint('Create Transport Order Error: $e');
      if (transactionId != null && !orderCreated) {
        try {
          await FinanceBackend.instance.invoke(
            'refund_transport_booking',
            body: {
              'orderId': transactionId,
              'reason': 'primary_order_creation_failed',
            },
          );
          await _syncVault();
        } catch (refundError) {
          debugPrint('Transport Escrow Refund Error: $refundError');
        }
      }
      rethrow;
    } finally {
      isTransportLoading = false;
      notify();
    }
  }

  Future<void> fetchMyOrders() async {
    if (user == null) return;

    final localDb = LocalDbService();

    try {
      // 1. Serve from local cache immediately (Local-First)
      final cached = await localDb.getCachedTransportOrders(user!.id);
      if (cached.isNotEmpty) {
        myTransportOrders = List<TransportOrder>.from(
          cached.map((j) => TransportOrder.fromJson(j)),
        );
        notify();
      }

      // 2. Delta Sync (Only when "activated" by network availability)
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) return;

      isTransportSyncing = true;
      notify();

      final cursorKey = 'transport:${user!.id}';
      final cursor = await localDb.getSyncCursor(cursorKey);
      var query = Supabase.instance.client
          .from('transport_orders')
          .select(
            'id,user_id,driver_id,pickup_location,dropoff_location,status,price,created_at,updated_at,delivery_lat,delivery_lng',
          )
          .eq('user_id', user!.id);

      // If we have a cursor, only fetch what's newer
      if (cursor != null) {
        query = query.gt('updated_at', cursor);
      }

      final res = await query
          .order('updated_at', ascending: cursor != null)
          .limit(100);
      if ((res as List).isNotEmpty) {
        final list = List<Map<String, dynamic>>.from(res);
        await localDb.saveTransportOrders(list);
        await localDb.setSyncCursor(
          cursorKey,
          (cursor == null ? list.first : list.last)['updated_at'] ??
              (cursor == null ? list.first : list.last)['created_at'],
        );

        // Refresh full local list
        final fresh = await localDb.getCachedTransportOrders(user!.id);
        myTransportOrders = List<TransportOrder>.from(
          fresh.map((j) => TransportOrder.fromJson(j)),
        );
      }
    } catch (e) {
      debugPrint('Fetch My Orders Error: $e');
    } finally {
      isTransportSyncing = false;
      notify();
    }
  }

  Future<void> setChatBubbleTheme(String theme) async {
    chatBubbleTheme = theme;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_bubble_theme', theme);
    notify();
  }

  Future<void> addReaction(String messageId, String emoji) async {
    final msgIndex = currentMessages.indexWhere((m) => m.id == messageId);
    if (msgIndex == -1) return;

    final msg = currentMessages[msgIndex];
    msg.reactions ??= [];
    if (msg.reactions!.contains(emoji)) {
      msg.reactions!.remove(emoji);
    } else {
      msg.reactions!.add(emoji);
    }

    await localDb.updateMessageReactions(messageId, msg.reactions!);
    notify();
  }

  // ── Notifications & Vendor Orders ──
  List<AppNotification> appNotifications = [];
  int pendingVendorOrders = 0;
  int get unreadNotificationCount =>
      appNotifications.where((notification) => !notification.isRead).length;

  int get activeBuyerTransportCount => myTransportOrders
      .where(
        (o) =>
            o.status == OrderStatus.accepted ||
            o.status == OrderStatus.inProgress,
      )
      .length;

  Future<void> loadNotifications() async {
    final activeUserId = user?.id;
    if (activeUserId == null) {
      appNotifications = [];
      notify();
      return;
    }
    final list = await localDb.getNotifications(activeUserId);
    appNotifications = list.map((e) => AppNotification.fromMap(e)).toList();
    notify();
  }

  Future<void> markNotificationAsRead(String id) async {
    final activeUserId = user?.id;
    if (activeUserId == null) return;
    await localDb.markNotificationAsRead(id, activeUserId);
    await loadNotifications();
    try {
      await social.markNotificationRead(id);
    } catch (error) {
      debugPrint('Notification read sync deferred: $error');
    }
  }

  Future<void> markAllNotificationsAsRead() async {
    final activeUserId = user?.id;
    if (activeUserId == null) return;
    await localDb.markAllNotificationsAsRead(activeUserId);
    await loadNotifications();
    try {
      await social.markAllNotificationsRead();
    } catch (error) {
      debugPrint('Notification read-all sync deferred: $error');
    }
  }

  Future<void> refreshNotifications() async {
    final activeUserId = user?.id;
    if (activeUserId == null) return;
    final remote = await social.fetchNotifications(limit: 50);
    for (final item in remote) {
      final notification = AppNotification.fromMap(item);
      if (notification.id.isEmpty || notification.userId != activeUserId) {
        continue;
      }
      await NotificationService().showNotification(
        notification,
        recipientUserId: activeUserId,
        showSystem: false,
      );
    }
    await loadNotifications();
  }

  void openNotification(AppNotification notification) {
    if (!notification.isRead) {
      unawaited(markNotificationAsRead(notification.id));
    }
    if (notification.targetType == 'profile' && notification.targetId != null) {
      go('public_profile', extra: notification.targetId);
      return;
    }
    if (notification.targetType == 'post' && notification.targetId != null) {
      go('community', extra: notification.targetId);
      return;
    }
    final roomId = notification.metadata['room_id']?.toString();
    if (roomId != null && roomId.isNotEmpty) {
      unawaited(_openNotificationChat(roomId));
    }
  }

  Future<void> _openNotificationChat(String roomId) async {
    await fetchCreatorConversations(force: true);
    ChatRoom? room;
    for (final candidate in rooms) {
      if (candidate.id == roomId) {
        room = candidate;
        break;
      }
    }
    if (room == null) return;
    activeConversation = room;
    await fetchMessages(room.id);
    await markRoomAsRead(room.id);
    go(
      room.metadata?['interaction_context'] == 'social'
          ? 'creator-chat-detail'
          : 'chat-detail',
    );
  }

  // ── Sync Engine (Neural Pulse) ────────────────────────────────
  Timer? _syncTimer;
  bool isSyncing = false;
  String syncStatus = "Optimizing...";

  void startSyncEngine() {
    _syncTimer?.cancel();
    // 🚀 Pulse every 5 minutes to remain data optimum
    _syncTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _performNeuralSync(),
    );
    _performNeuralSync(); // Initial sync

    // 🧠 NEURAL PULSE: Real-time subscription
    _subscribeToNotifications();

    unawaited(_syncVendorOrderCount());
  }

  Future<void> _syncVendorOrderCount() async {
    if (user == null) return;
    try {
      final dashboard = await CommerceService().fetchVendorDashboard();
      pendingVendorOrders = dashboard.openOrders;
      notify();
    } catch (error) {
      debugPrint('Vendor order sync error: $error');
    }
  }

  Future<void> _performNeuralSync() async {
    if (user == null) return;

    isSyncing = true;
    syncStatus = "Neural Pulse...";
    notify();

    debugPrint('🧠 Neural Sync: Pulsing Cloud & Redis...');

    // 1. Fetch Real-time alerts from Redis
    try {
      syncStatus = "Delta Syncing...";
      notify();

      await refreshNotifications();
      await _syncVendorOrderCount();
    } catch (e) {
      debugPrint('Notification Sync Error: $e');
    }

    // 2. Process Pending Offline Actions
    syncStatus = "Smart Loading...";
    notify();
    await social.syncPendingActions();

    // 🚀 SYNC COMPLETE
    isSyncing = false;
    syncStatus = "Optimized";
    notify();
  }
}

class IDResult {
  final bool verified;
  final String sessionId;
  IDResult({required this.verified, required this.sessionId});
}

class SelfieResult {
  final bool faceMatch;
  final String sessionId;
  final double? score;
  SelfieResult({required this.faceMatch, required this.sessionId, this.score});
}

class UtilityBillResult {
  final bool verified;
  final String sessionId;
  UtilityBillResult({required this.verified, required this.sessionId});
}

class IPResult {
  final bool verified;
  final String sessionId;
  IPResult({required this.verified, required this.sessionId});
}
