import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import '../app_state.dart';
import '../utils/error_handler.dart';

class LoginScreen extends StatefulWidget {
  final AppState state;
  const LoginScreen({super.key, required this.state});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  bool _sent = false;
  String? _error;

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
    if (_emailCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Please enter your email address');
      return;
    }

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
        email: _emailCtrl.text.trim(),
        shouldCreateUser: true, // Handles registration
        emailRedirectTo: _emailRedirectUrl,
      );
      setState(() => _sent = true);
    } catch (e) {
      setState(() => _error = getUserFriendlyError(e));
    } finally {
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
                    child: GestureDetector(
                      onTap: () => setState(() => _sent = false),
                      child: Text(
                        'Wrong email? Change Address',
                        style: dm(sz: 12, c: C.brand, w: FontWeight.w600),
                      ),
                    ),
                  ),
                ],

                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.1),
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
                  onTap: _loading
                      ? null
                      : (_sent ? _handleVerify : _handleSend),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: double.infinity,
                    height: 58,
                    decoration: BoxDecoration(
                      gradient: brandGrad,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        if (!_loading)
                          BoxShadow(
                            color: C.brand.withOpacity(0.25),
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
                              _sent ? 'Verify & Sign In' : 'Send Magic Link',
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
