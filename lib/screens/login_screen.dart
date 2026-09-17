import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import '../app_state.dart';
import '../utils/error_handler.dart';
import '../utils/auth_retry.dart';

class LoginScreen extends StatefulWidget {
  final AppState state;
  const LoginScreen({super.key, required this.state});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _cooldownPreferenceKey = 'necxa_auth_magic_link_next_send_at';

  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  // A synchronous guard is kept separately from the rendered loading state.
  // This prevents two gesture callbacks in the same frame from issuing two
  // OTP requests before Flutter has rebuilt the disabled button.
  bool _sendRequestInFlight = false;
  bool _sent = false;
  String? _error;
  DateTime? _nextSendAt;
  Timer? _cooldownTimer;

  int get _cooldownSeconds {
    final nextSendAt = _nextSendAt;
    if (nextSendAt == null) return 0;
    final milliseconds = nextSendAt.difference(DateTime.now()).inMilliseconds;
    if (milliseconds <= 0) return 0;
    return (milliseconds / 1000).ceil();
  }

  bool get _sendAvailable =>
      !_loading && !_sendRequestInFlight && _cooldownSeconds == 0;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreCooldown());
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _restoreCooldown() async {
    final preferences = await SharedPreferences.getInstance();
    final nextSendMilliseconds = preferences.getInt(_cooldownPreferenceKey);
    if (nextSendMilliseconds == null || !mounted) return;

    final nextSendAt = DateTime.fromMillisecondsSinceEpoch(
      nextSendMilliseconds,
    );
    if (!nextSendAt.isAfter(DateTime.now())) {
      await preferences.remove(_cooldownPreferenceKey);
      return;
    }

    setState(() => _nextSendAt = nextSendAt);
    _startCooldownTimer();
  }

  Future<void> _beginCooldown(Duration duration) async {
    final nextSendAt = DateTime.now().add(duration);
    if (mounted) setState(() => _nextSendAt = nextSendAt);
    _startCooldownTimer();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      _cooldownPreferenceKey,
      nextSendAt.millisecondsSinceEpoch,
    );
  }

  void _startCooldownTimer() {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_cooldownSeconds > 0) {
        setState(() {});
        return;
      }

      timer.cancel();
      setState(() => _nextSendAt = null);
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_cooldownPreferenceKey);
    });
  }

  String get _emailRedirectUrl {
    if (!kIsWeb) return 'io.supabase.necxa://login-callback';

    final currentUri = Uri.base;
    if (currentUri.host == 'localhost' || currentUri.host == '127.0.0.1') {
      return currentUri
          .replace(path: '/', queryParameters: null, fragment: '')
          .toString();
    }
    return 'https://app.necxa.uk/';
  }

  Future<void> _handleSend() async {
    if (!_sendAvailable || _sendRequestInFlight) return;

    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Please enter a valid email address');
      return;
    }

    // Set this before setState/network work so rapid taps are coalesced into
    // the one request that is already being processed.
    _sendRequestInFlight = true;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final supabase = Supabase.instance.client;
      // SIGN IN WITH OTP (Magic Link)
      // This sends a magic link or a code depending on Supabase config.
      // Usually, it's a 6-digit code or a clickable link.
      await supabase.auth.signInWithOtp(
        email: email,
        shouldCreateUser: true, // Handles registration
        emailRedirectTo: _emailRedirectUrl,
      );
      await _beginCooldown(defaultMagicLinkCooldown);
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (isAuthRateLimitError(e)) {
        final delay = magicLinkRetryDelay(e);
        await _beginCooldown(delay);
        if (mounted) {
          setState(() {
            _error =
                'A sign-in email was requested recently. Try again in ${formatRetryCountdown(delay.inSeconds)} or use the link already in your inbox.';
          });
        }
      } else if (mounted) {
        setState(() => _error = getUserFriendlyError(e));
      }
    } finally {
      _sendRequestInFlight = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleVerify() async {
    if (_codeCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Please enter the verification code');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final supabase = Supabase.instance.client;
      await supabase.auth.verifyOTP(
        type: OtpType.magiclink,
        token: _codeCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
      );
      // Auth state change will be picked up by RootShell
    } catch (e) {
      setState(() => _error = getUserFriendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 60),
                const NecxaLogo(size: 87),
                const SizedBox(height: 32),
                Text(
                  _sent ? 'Verify Your Email' : 'Welcome to NECXA',
                  style: syne(sz: 32, w: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Text(
                  _sent
                      ? 'We\'ve sent a magic link and a code to ${_emailCtrl.text}. Enter the code below or click the link in your email.'
                      : 'The premier property and creator platform for Africa. Sign in or register with your email.',
                  style: dm(sz: 14, c: C.dim),
                ),
                const SizedBox(height: 48),

                if (!_sent) ...[
                  Text('Email Address', style: dm(sz: 14, w: FontWeight.w600)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    style: dm(sz: 16),
                    decoration: InputDecoration(
                      hintText: 'yourname@email.com',
                      filled: true,
                      fillColor: C.card,
                      contentPadding: const EdgeInsets.all(18),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: Icon(
                        Icons.email_outlined,
                        color: C.dim,
                        size: 22,
                      ),
                    ),
                  ),
                ] else ...[
                  Text(
                    'Verification Code',
                    style: dm(sz: 14, w: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _codeCtrl,
                    keyboardType: TextInputType.number,
                    style: dm(sz: 24, w: FontWeight.w800, ls: 8),
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: '000000',
                      hintStyle: dm(sz: 18, c: C.dim, ls: 8),
                      filled: true,
                      fillColor: C.card,
                      contentPadding: const EdgeInsets.all(18),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 20,
                      runSpacing: 12,
                      children: [
                        TextButton(
                          onPressed: _loading
                              ? null
                              : () => setState(() {
                                  _sent = false;
                                  _error = null;
                                  _codeCtrl.clear();
                                }),
                          child: Text(
                            'Change email',
                            style: dm(sz: 12, c: C.brand, w: FontWeight.w600),
                          ),
                        ),
                        TextButton(
                          onPressed: _sendAvailable ? _handleSend : null,
                          child: Text(
                            _cooldownSeconds > 0
                                ? 'Resend in ${formatRetryCountdown(_cooldownSeconds)}'
                                : 'Resend magic link',
                            style: dm(
                              sz: 12,
                              c: _sendAvailable ? C.brand : C.dim,
                              w: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_cooldownSeconds > 0) ...[
                    const SizedBox(height: 4),
                    Center(
                      child: Text(
                        'You can still use the most recent email while you wait.',
                        textAlign: TextAlign.center,
                        style: dm(sz: 11, c: C.dim),
                      ),
                    ),
                  ],
                ],

                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _error!,
                      style: dm(sz: 12, c: Colors.redAccent),
                    ),
                  ),
                ],

                const SizedBox(height: 40),

                // Button
                GestureDetector(
                  onTap: _loading || (!_sent && !_sendAvailable)
                      ? null
                      : (_sent ? _handleVerify : _handleSend),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: double.infinity,
                    height: 58,
                    decoration: BoxDecoration(
                      gradient: _loading || (!_sent && !_sendAvailable)
                          ? null
                          : brandGrad,
                      color: _loading || (!_sent && !_sendAvailable)
                          ? C.dim.withValues(alpha: 0.25)
                          : null,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        if (!_loading && (_sent || _sendAvailable))
                          BoxShadow(
                            color: C.brand.withValues(alpha: 0.25),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                      ],
                    ),
                    child: Center(
                      child: _loading
                          ? SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: C.bg,
                                strokeWidth: 2.5,
                              ),
                            )
                          : Text(
                              _sent
                                  ? 'Verify & Sign In'
                                  : _cooldownSeconds > 0
                                  ? 'Try again in ${formatRetryCountdown(_cooldownSeconds)}'
                                  : 'Send Magic Link',
                              style: syne(sz: 16, w: FontWeight.w700, c: C.bg),
                            ),
                    ),
                  ),
                ),

                const SizedBox(height: 32),
                Center(
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: dm(sz: 12, c: C.dim),
                      children: const [
                        TextSpan(text: "By continuing, you agree to NECXA's\n"),
                        TextSpan(
                          text: 'Terms of Service',
                          style: TextStyle(
                            color: C.brand,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(text: ' and '),
                        TextSpan(
                          text: 'Privacy Policy',
                          style: TextStyle(
                            color: C.brand,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
