import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../models/music_models.dart';
import '../utils/error_handler.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ArtistAuthScreen — Entry point
// Shows:
//   • If already an artist  → ArtistDashboard (profile + music link)
//   • If not               → enrollment / login chooser
// ─────────────────────────────────────────────────────────────────────────────
class ArtistAuthScreen extends StatelessWidget {
  final AppState state;
  const ArtistAuthScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (state.isArtist) {
          return _ArtistDashboard(state: state);
        }
        return _ArtistGateway(state: state);
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ArtistGateway — Enrollment vs Login chooser
// ─────────────────────────────────────────────────────────────────────────────
class _ArtistGateway extends StatefulWidget {
  final AppState state;
  const _ArtistGateway({required this.state});

  @override
  State<_ArtistGateway> createState() => _ArtistGatewayState();
}

class _ArtistGatewayState extends State<_ArtistGateway> {
  bool _showLogin = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white70),
          onPressed: () {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              widget.state.goBack();
            }
          },
        ),
        title: Text(
          _showLogin ? 'Artist Login' : 'Artist Programme',
          style: syne(sz: 18, w: FontWeight.w900, ls: 0.5),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.black,
              Colors.deepPurple.shade900.withOpacity(0.35),
              Colors.black,
            ],
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _showLogin
              ? _LoginForm(
                  key: const ValueKey('login'),
                  state: widget.state,
                  onSwitchToEnroll: () => setState(() => _showLogin = false),
                )
              : _EnrollForm(
                  key: const ValueKey('enroll'),
                  state: widget.state,
                  onSwitchToLogin: () => setState(() => _showLogin = true),
                ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _EnrollForm — New artist sign-up
// ─────────────────────────────────────────────────────────────────────────────
class _EnrollForm extends StatefulWidget {
  final AppState state;
  final VoidCallback onSwitchToLogin;
  const _EnrollForm({super.key, required this.state, required this.onSwitchToLogin});

  @override
  State<_EnrollForm> createState() => _EnrollFormState();
}

class _EnrollFormState extends State<_EnrollForm> {
  final _formKey = GlobalKey<FormState>();
  String _artistName = '';
  String _legalName = '';
  String _genre = '';
  String _distributorLink = '';
  String _email = '';
  String _password = '';
  bool _loading = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();
    setState(() => _loading = true);
    try {
      // Connect to Supabase auth if credentials are real, else use local state
      if (_email.isNotEmpty && _password.isNotEmpty && widget.state.user == null) {
        try {
          await widget.state.social.signInWithEmail(_email.trim(), _password);
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 400));
      widget.state.setArtistStatus(
        true,
        name: _artistName.isNotEmpty ? _artistName : _legalName,
        genre: _genre,
        distributorLink: _distributorLink,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('🎉 You joined the Artist Programme!'),
          backgroundColor: C.green,
        ));
        // Navigate back and open upload
        Navigator.pop(context);
        widget.state.go('upload');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(getUserFriendlyError(e)),
          backgroundColor: C.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 48),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('🎵', style: TextStyle(fontSize: 56), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              'Join the Artist Programme',
              style: syne(sz: 22, w: FontWeight.w900, ls: 0.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Get verified distribution access and release your music on Necxa.',
              style: dm(sz: 13, c: C.dim),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),

            // ── Benefits strip ──────────────────────────────────────────────
            _BenefitRow(icon: Icons.verified_rounded, label: 'Verified artist badge on your profile'),
            _BenefitRow(icon: Icons.library_music_rounded, label: 'Upload & distribute your music in-app'),
            _BenefitRow(icon: Icons.bar_chart_rounded, label: 'Track streams, plays & earnings'),
            _BenefitRow(icon: Icons.storefront_rounded, label: 'Sell digital releases in the community shop'),
            const SizedBox(height: 28),

            _field('Artist / Stage Name', (v) => _artistName = v!,
                hint: 'e.g. DJ Necxa', validator: (v) => v == null || v.trim().isEmpty ? 'Enter your artist name' : null),
            const SizedBox(height: 14),
            _field('Legal Full Name', (v) => _legalName = v!,
                hint: 'Your real name (private)', validator: (v) => v == null || v.trim().isEmpty ? 'Required for verification' : null),
            const SizedBox(height: 14),
            _field('Primary Genre', (v) => _genre = v!,
                hint: 'e.g. Afrobeats, Hip-Hop, R&B'),
            const SizedBox(height: 14),
            _field('Distributor / Music Link', (v) => _distributorLink = v!,
                hint: 'Spotify, SoundCloud, Boomplay URL…',
                validator: (v) => null), // optional
            const SizedBox(height: 14),
            _field('Email Address', (v) => _email = v!,
                validator: (v) => v == null || !v.contains('@') ? 'Enter a valid email' : null),
            const SizedBox(height: 14),
            _field('Password', (v) => _password = v!, obscure: true,
                validator: (v) => v == null || v.length < 6 ? 'Min 6 characters' : null),
            const SizedBox(height: 32),

            ElevatedButton(
              onPressed: _loading ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7B2FFF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: _loading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text('JOIN PROGRAMME', style: syne(sz: 15, w: FontWeight.w900, ls: 1.5)),
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: widget.onSwitchToLogin,
              child: Text('Already in the programme? Log in', style: dm(sz: 13, c: C.brand)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, Function(String?) onSave,
      {bool obscure = false, String? hint, String? Function(String?)? validator}) {
    return TextFormField(
      obscureText: obscure,
      onSaved: onSave,
      style: dm(sz: 15, c: C.text),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: dm(sz: 13, c: C.dim),
        labelStyle: dm(sz: 14, c: C.sub),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: C.dim)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFF7B2FFF))),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: C.red)),
        focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: C.red)),
        filled: true,
        fillColor: Colors.white.withOpacity(.04),
      ),
      validator: validator ?? (v) => (v == null || v.isEmpty) ? 'Required' : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _LoginForm — Existing artist log-in
// ─────────────────────────────────────────────────────────────────────────────
class _LoginForm extends StatefulWidget {
  final AppState state;
  final VoidCallback onSwitchToEnroll;
  const _LoginForm({super.key, required this.state, required this.onSwitchToEnroll});

  @override
  State<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<_LoginForm> {
  final _formKey = GlobalKey<FormState>();
  String _email = '';
  String _password = '';
  bool _loading = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();
    setState(() => _loading = true);
    try {
      if (_email.isNotEmpty && _password.isNotEmpty && widget.state.user == null) {
        try {
          await widget.state.social.signInWithEmail(_email.trim(), _password);
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 400));
      widget.state.setArtistStatus(
        true,
        name: widget.state.artistName.isNotEmpty
            ? widget.state.artistName
            : (_email.contains('@') ? _email.split('@').first : 'Artist'),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Welcome back, Artist! 🎵'),
          backgroundColor: Color(0xFF22C55E),
        ));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(getUserFriendlyError(e)),
          backgroundColor: C.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 48),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('🎙️', style: TextStyle(fontSize: 56), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              'Artist Login',
              style: syne(sz: 22, w: FontWeight.w900, ls: 0.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Log in to access your artist dashboard and music tools.',
              style: dm(sz: 13, c: C.dim),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),

            TextFormField(
              onSaved: (v) => _email = v ?? '',
              style: dm(sz: 15, c: C.text),
              keyboardType: TextInputType.emailAddress,
              decoration: _inputDec('Email Address'),
              validator: (v) => v == null || !v.contains('@') ? 'Enter a valid email' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              onSaved: (v) => _password = v ?? '',
              obscureText: true,
              style: dm(sz: 15, c: C.text),
              decoration: _inputDec('Password'),
              validator: (v) => v == null || v.isEmpty ? 'Enter your password' : null,
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {},
                child: Text('Forgot password?', style: dm(sz: 12, c: C.sub)),
              ),
            ),
            const SizedBox(height: 24),

            ElevatedButton(
              onPressed: _loading ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: C.brand,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: _loading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('LOG IN', style: syne(sz: 15, w: FontWeight.w900, ls: 1.5)),
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: widget.onSwitchToEnroll,
              child: Text("Don't have an artist account? Sign up", style: dm(sz: 13, c: C.brand)),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDec(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: dm(sz: 14, c: C.sub),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: C.dim)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: C.brand)),
      errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: C.red)),
      focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: C.red)),
      filled: true,
      fillColor: Colors.white.withOpacity(.04),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ArtistDashboard — Shown when user is already a verified artist
// ─────────────────────────────────────────────────────────────────────────────
class _ArtistDashboard extends StatelessWidget {
  final AppState state;
  const _ArtistDashboard({required this.state});

  @override
  Widget build(BuildContext context) {
    final name = state.artistName.isNotEmpty ? state.artistName : 'Your Artist Name';
    final genre = state.artistGenre.isNotEmpty ? state.artistGenre : 'Music';
    final link = state.artistDistributorLink;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white70),
          onPressed: () {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              state.goBack();
            }
          },
        ),
        title: Text('Artist Studio', style: syne(sz: 18, w: FontWeight.w900, ls: 0.5)),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.deepPurple.shade900.withOpacity(0.4), Colors.black],
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Artist identity card ──────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF7B2FFF), Color(0xFFA855F7)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFF7B2FFF).withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 8)),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 56, height: 56,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.mic_rounded, color: Colors.white, size: 28),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(child: Text(name, style: syne(sz: 20, w: FontWeight.w900))),
                                  const SizedBox(width: 6),
                                  const Icon(Icons.verified_rounded, color: Colors.white, size: 18),
                                ],
                              ),
                              Text(genre, style: dm(sz: 13, c: Colors.white70)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (link.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(link, style: dm(sz: 12, c: Colors.white60), overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('VERIFIED ARTIST', style: syne(sz: 10, w: FontWeight.w900, ls: 1.5)),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('YOUR MUSIC RELEASES', style: syne(sz: 11, w: FontWeight.w900, c: C.dim, ls: 2)),
                  Text('GOOBOX CLOUD', style: syne(sz: 9, w: FontWeight.w800, c: const Color(0xFF00E5FF), ls: 1)),
                ],
              ),
              const SizedBox(height: 12),
              FutureBuilder<List<MusicTrack>>(
                future: state.artistMusic.fetchArtistTracks(state.user?.id ?? ''),
                builder: (context, snapshot) {
                  final tracks = snapshot.data ?? [];
                  if (snapshot.connectionState == ConnectionState.waiting && tracks.isEmpty) {
                    return const Center(child: Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF7B2FFF)),
                    ));
                  }
                  if (tracks.isEmpty) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.library_music_rounded, color: C.dim, size: 24),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('No tracks uploaded yet', style: dm(sz: 13, w: FontWeight.w600, c: Colors.white)),
                                Text('Upload to distribute your music across Necxa.', style: dm(sz: 11, c: C.dim)),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              if (Navigator.canPop(context)) Navigator.pop(context);
                              state.go('upload');
                            },
                            child: Text('Upload', style: syne(sz: 12, w: FontWeight.w900, c: const Color(0xFFA855F7))),
                          ),
                        ],
                      ),
                    );
                  }

                  return Column(
                    children: tracks.take(3).map((t) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7B2FFF).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF7B2FFF).withOpacity(0.2)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.music_note_rounded, color: Color(0xFFA855F7), size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t.title, style: syne(sz: 13, w: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  Text('${t.genre ?? 'Music'} • ${t.formattedDuration}', style: dm(sz: 11, c: C.dim)),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.play_circle_fill_rounded, color: Color(0xFF7B2FFF), size: 28),
                              onPressed: () => state.artistMusic.togglePlay(t),
                            ),
                          ],
                        ),
                      ),
                    )).toList(),
                  );
                },
              ),

              const SizedBox(height: 28),
              Text('WHAT YOU CAN DO', style: syne(sz: 11, w: FontWeight.w900, c: C.dim, ls: 2)),
              const SizedBox(height: 14),

              // ── Action tiles ─────────────────────────────────────────────
              _ArtistActionTile(
                icon: Icons.cloud_upload_rounded,
                color: const Color(0xFF7B2FFF),
                title: 'Upload Your Music',
                subtitle: 'Release tracks, albums & audio content',
                onTap: () {
                  if (Navigator.canPop(context)) Navigator.pop(context);
                  state.go('upload');
                },
              ),
              const SizedBox(height: 10),
              _ArtistActionTile(
                icon: Icons.explore_rounded,
                color: const Color(0xFF00E5FF),
                title: 'Music Discovery',
                subtitle: 'See how your tracks appear in the feed',
                onTap: () {
                  if (Navigator.canPop(context)) Navigator.pop(context);
                  state.go('community');
                },
              ),
              const SizedBox(height: 10),
              _ArtistActionTile(
                icon: Icons.person_pin_rounded,
                color: const Color(0xFFF59E0B),
                title: 'Your Public Profile',
                subtitle: 'View your artist showcase as fans see it',
                onTap: () {
                  if (Navigator.canPop(context)) Navigator.pop(context);
                  state.go('public_profile');
                },
              ),
              const SizedBox(height: 10),
              _ArtistActionTile(
                icon: Icons.bar_chart_rounded,
                color: const Color(0xFF22C55E),
                title: 'Stats & Earnings',
                subtitle: 'Track plays, streams & NCX coins earned',
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Artist analytics — coming soon!'),
                  ));
                },
              ),

              const SizedBox(height: 32),
              OutlinedButton.icon(
                icon: const Icon(Icons.logout_rounded, size: 18, color: Colors.redAccent),
                label: Text('Leave Artist Programme', style: dm(sz: 14, c: Colors.redAccent, w: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.redAccent),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () => _confirmLeave(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmLeave(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 20),
            Text('Leave Artist Programme?', style: syne(sz: 18, w: FontWeight.w900)),
            const SizedBox(height: 10),
            Text('Your uploaded music will stay, but you lose your verified badge and artist tools.', style: dm(sz: 13, c: C.dim), textAlign: TextAlign.center),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                child: Text('Cancel', style: dm(sz: 14, c: C.text)),
              )),
              const SizedBox(width: 12),
              Expanded(child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  state.setArtistStatus(false);
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                child: Text('Leave', style: syne(sz: 14, w: FontWeight.w900)),
              )),
            ]),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper widgets
// ─────────────────────────────────────────────────────────────────────────────
class _BenefitRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _BenefitRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFFA855F7), size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: dm(sz: 13, c: C.sub))),
        ],
      ),
    );
  }
}

class _ArtistActionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ArtistActionTile({required this.icon, required this.color, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: syne(sz: 15, w: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: dm(sz: 12, c: C.dim)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: C.dim, size: 20),
          ],
        ),
      ),
    );
  }
}
