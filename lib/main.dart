import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';
import 'app_state.dart';
import 'screens/home_screen.dart';
import 'screens/detail_screen.dart';
import 'screens/upload_screen.dart';
import 'screens/login_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/vendor_dashboard_screen.dart';
import 'screens/public_profile_screen.dart';
import 'screens/chat_detail_screen.dart';
import 'screens/new_chat_screen.dart';
import 'screens/payment_screen.dart';
import 'screens/transport_screen.dart';
import 'screens/community_screen.dart';
import 'screens/listing_wizard_screen.dart';
import 'screens/transport_verification_screen.dart';
import 'screens/sound_settings_screen.dart';
import 'screens/privacy_security_screen.dart';
import 'widgets/gift_float.dart';
import 'screens/artist_auth_screen.dart';
import 'screens/creator_chat_list_screen.dart';
import 'screens/creator_chat_detail_screen.dart';
import 'screens/admin/music_management_admin.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui';
import 'services/telemetry_service.dart';
import 'services/notification_service.dart';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:camera/camera.dart';

List<CameraDescription> cameras = [];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera error: $e');
  }
  await Supabase.initialize(
    url: 'https://lzdtrmjcwzalckszdzpt.supabase.co',
    anonKey: 'sb_publishable_lLcn4V9uIIgs3B59cHVXWg_1-PNsUfR',
    authOptions: const FlutterAuthClientOptions(
      // Email clients frequently open web magic links in a fresh tab or
      // browser context where a PKCE verifier is unavailable. The implicit
      // web callback carries the one-time session in the URL fragment, while
      // native apps retain PKCE and the custom deep link.
      authFlowType: kIsWeb ? AuthFlowType.implicit : AuthFlowType.pkce,
      detectSessionInUri: true,
    ),
  );

  // ── CUSTOM ERROR TELEMETRY ────────────────────────────────────────────────
  // Catch UI / Framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    TelemetryService().logCrash(
      details.exception,
      details.stack ?? StackTrace.empty,
      context: 'FlutterError',
    );
  };

  // Catch Background / Silent asynchronous errors (e.g., failed AI scans, unhandled Future errors)
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    TelemetryService().logCrash(error, stack, context: 'PlatformDispatcher');
    return true;
  };
  // ──────────────────────────────────────────────────────────────────────────

  final notifService = NotificationService();
  await notifService.init();
  await notifService.requestPermissions();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const NecxaApp());
}

class NecxaApp extends StatefulWidget {
  const NecxaApp({super.key});

  @override
  State<NecxaApp> createState() => _NecxaAppState();
}

class _NecxaAppState extends State<NecxaApp> with WidgetsBindingObserver {
  final AppState _state = AppState();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.addListener(() => setState(() {}));
    _state.loadThemeMode();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (_state.themeMode == ThemeMode.system) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _state.checkInactivityLock();
      _state.syncVault();
    } else if (state == AppLifecycleState.paused) {
      _state.updateActivity();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 📱 SMART ORIENTATION LOCK:
    // Only lock portrait for phones (shortest side < 600).
    // Tablets, Laptops, and Desktops maintain full rotation freedom.
    final double shortestSide = MediaQuery.of(context).size.shortestSide;
    if (shortestSide < 600) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    C.themeMode = _state.themeMode;
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'NECXA',
      themeMode: _state.themeMode,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      debugShowCheckedModeBanner: false,
      home: RootShell(state: _state),
    );
  }
}

class RootShell extends StatefulWidget {
  final AppState state;
  const RootShell({super.key, required this.state});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  late AppState _state;

  bool get _isSupabaseReady {
    try {
      Supabase.instance.client;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _state = widget.state;
    // Listen to ALL state changes so _buildScreen() rebuilds when screen changes
    _state.addListener(_onStateChanged);

    if (_isSupabaseReady) {
      Supabase.instance.client.auth.onAuthStateChange.listen((e) {
        _state.onAuthStateChange(e);
        if (e.session != null) {
          _state.startSyncEngine();
        }
      });

      // Initial start if already authenticated
      if (_state.isAuthenticated) {
        _state.startSyncEngine();
      }
    }
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Stack(
        children: [
          _buildScreen(),
          if (_state.showGiftFloat) GiftFloat(state: _state),
          if (_state.isAppLocked) _buildLockScreen(),
        ],
      ),
    );
  }

  Widget _buildLockScreen() {
    return Container(
      color: Colors.black.withOpacity(.95),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_person_outlined, color: C.brand, size: 80),
            const SizedBox(height: 32),
            Text(
              'Necxa Vault Locked',
              style: syne(sz: 24, w: FontWeight.w800, c: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              'Biometric authentication required',
              style: dm(sz: 14, c: Colors.white54),
            ),
            const SizedBox(height: 48),
            if (_state.biometricError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _state.biometricError!,
                  style: dm(sz: 12, c: Colors.redAccent),
                  textAlign: TextAlign.center,
                ),
              ),
            ElevatedButton(
              onPressed: () => _state.verifyAppBiometrics(),
              style: ElevatedButton.styleFrom(
                backgroundColor: C.brand,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 16,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text(
                'Unlock with Biometrics',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScreen() {
    if (!_state.isAuthenticated) {
      return LoginScreen(state: _state);
    }

    switch (_state.screen) {
      case 'detail':
        return DetailScreen(state: _state);
      case 'community':
        return CommunityScreen(state: _state);
      case 'list':
      case 'property_listing':
        return ListingWizardScreen(state: _state);
      case 'upload':
        return UploadScreen(
          state: _state,
          initialTrack: _state.initialMusicTrack,
        );
      case 'chat':
      case 'chat-list':
      case 'new-chat':
        return NewChatScreen(state: _state);
      case 'chat-detail':
        return ChatDetailScreen(state: _state);
      case 'profile':
        return ProfileScreen(state: _state);
      case 'vendor-dashboard':
        return VendorDashboardScreen(state: _state);
      case 'public_profile':
        return PublicProfileScreen(state: _state);
      case 'login':
        return LoginScreen(state: _state);
      case 'payment':
        return PaymentScreen(state: _state);
      case 'transport':
        return TransportScreen(state: _state);
      case 'driver-registration':
        return TransportVerificationScreen(state: _state);
      case 'sound-settings':
        return SoundSettingsScreen(state: _state);
      case 'privacy-security':
        return PrivacySecurityScreen(state: _state);
      case 'music-admin':
        return const MusicManagementAdmin();
      case 'artist_auth':
        return ArtistAuthScreen(state: _state);
      case 'creator-chat-list':
        return CreatorChatListScreen(state: _state);
      case 'creator-chat-detail':
        return CreatorChatDetailScreen(state: _state);
      default:
        return HomeScreen(state: _state);
    }
  }
}
