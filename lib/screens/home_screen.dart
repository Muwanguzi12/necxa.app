import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme.dart';
import '../data.dart';
import '../app_state.dart';
import '../widgets/ai_chat_modal.dart';
import '../models/property_container.dart';

class HomeScreen extends StatelessWidget {
  final AppState state;
  const HomeScreen({super.key, required this.state});

  static final _filters = [
    ('all', 'All'),
    ('rent', 'For Rent'),
    ('shortStay', 'Short Stay'),
    ('lease', 'Lease'),
    ('sale', 'For Sale'),
    ('villa', 'Villas'),
    ('commercial', 'Office'),
  ];

  static Color? _parseZoneColor(dynamic hexValue) {
    if (hexValue == null) return null;
    try {
      final raw = hexValue.toString().trim();
      final hex = raw.startsWith('#') ? raw.replaceFirst('#', '0xFF') : (raw.startsWith('0x') ? raw : '0xFF$raw');
      final val = int.tryParse(hex);
      return val != null ? Color(val) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = state.filtered;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: Column(
          children: [
            _buildNav(context),
            _buildAppTabs(),
            Expanded(
              child: RefreshIndicator(
                color: C.brand,
                backgroundColor: C.card,
                onRefresh: () async {
                  await state.loadProperties();
                },
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildHero(),
                      _buildStats(filtered.length),
                      _buildFilterRow(),
                      _buildListings(filtered),
                    ],
                  ),
                ),
              ),
            ),
            _buildBottomNav(),
          ],
        ),
      ),
    );
  }

  // -- Nav --
  Widget _buildNav(BuildContext context) {
    return Container(
      color: C.card,
      padding: const EdgeInsets.fromLTRB(18, 52, 18, 12),
      child: Row(
        children: [
          const NecxaLogo(size: 44, shadow: false),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('NECXA', style: syne(sz: 20, ls: -.5)),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: C.green.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: C.green.withValues(alpha: .25)),
                  ),
                  child: Text(
                    '🇺🇬 UGX',
                    style: dm(sz: 9, w: FontWeight.w700, c: C.green),
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _showAiChat(context, state),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2631),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.withValues(alpha: .3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/images/logo.png',
                    width: 14,
                    height: 14,
                    color: C.text,
                  ),
                  const SizedBox(width: 6),
                  Text('Necxa AI', style: syne(sz: 11, c: Colors.blue)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => state.go('profile'),
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) {
                final url = state.myProfile?['photo_url'];
                return Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: C.brand, width: 1.5),
                    image: url != null
                        ? DecorationImage(
                            image: NetworkImage(url),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: url == null
                      ? Icon(Icons.person, color: C.brand, size: 20)
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showAiChat(BuildContext context, AppState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => AiChatModal(state: state),
    );
  }

  // -- App Tabs --
  Widget _buildAppTabs() {
    return _AppTabs(
      current: 'home',
      state: state,
      onTap: (t) {
        if (t == 'list') state.go('list');
        if (t == 'transport') state.go('transport');
        if (t == 'upload' && !kIsWeb) state.go('upload');
        if (t == 'live') state.go('live');
        if (t == 'profile') state.go('profile');
      },
    );
  }

  // -- Hero --
  Widget _buildHero() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xFF0c1628), C.bg],
        ),
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: C.brand.withValues(alpha: .07),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: C.brand.withValues(alpha: .17)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PulsingDot(),
                const SizedBox(width: 6),
                Text(
                  "Uganda's Only Biometric-Verified Platform",
                  style: dm(sz: 10, w: FontWeight.w700, c: C.brand),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          RichText(
            text: TextSpan(
              style: syne(sz: 27, h: 1.15),
              children: const [
                TextSpan(text: 'Find Your Perfect\n'),
                TextSpan(
                  text: 'Property in Uganda',
                  style: TextStyle(color: C.brand),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Every listing verified with National ID + Face ID + GPS',
            style: dm(sz: 12, c: C.dim, h: 1.6),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: C.cardDk,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _parseZoneColor(state.zoneMetadata?['color_hex']) ?? C.border,
                width: state.zoneMetadata != null ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Text(state.isSearching ? '⏳' : '🔍', style: dm(sz: 16)),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    onChanged: (v) => state.performSearch(v),
                    style: dm(sz: 13),
                    decoration: InputDecoration(
                      hintText: 'Search Kampala, Entebbe, Jinja...',
                      hintStyle: dm(sz: 13, c: C.dim),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (state.searchQuery.isNotEmpty && !state.isSearching)
                  GestureDetector(
                    onTap: () => state.performSearch(''),
                    child: Icon(Icons.close, size: 14, color: C.dim),
                  ),
              ],
            ),
          ),
          if (state.zoneMetadata != null) ...[
            const SizedBox(height: 8),
            Builder(builder: (context) {
              final zoneColor = _parseZoneColor(state.zoneMetadata!['color_hex']) ?? C.brand;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: zoneColor.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: zoneColor.withValues(alpha: .4),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.map_outlined,
                      size: 12,
                      color: zoneColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      state.zoneMetadata!['zone_label'].toString().toUpperCase(),
                      style: dm(
                        sz: 9,
                        w: FontWeight.w800,
                        c: zoneColor,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
          if (kIsWeb) ...[
            const SizedBox(height: 14),
            GestureDetector(
              onTap: () => state.go('list'),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      C.brand.withValues(alpha: 0.15),
                      C.brand.withValues(alpha: 0.05),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: C.brand.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: C.brand.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.add_home_work_rounded,
                        color: C.brand,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'List a Property on Necxa',
                            style: syne(sz: 13, w: FontWeight.w800, c: C.text),
                          ),
                          Text(
                            'Verify with National ID & publish to thousands of buyers',
                            style: dm(sz: 10, c: C.dim),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 14,
                      color: C.brand,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // -- Stats row --
  Widget _buildStats(int count) {
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: Row(
        children: [
          _StatCell(icon: '🏠', val: '$count+', lab: 'Listings'),
          Container(width: 1, height: 60, color: C.border),
          const _StatCell(icon: '🛡️', val: '100%', lab: 'AI Verified'),
          Container(width: 1, height: 60, color: C.border),
          const _StatCell(icon: '🔐', val: '5%', lab: 'Broker Fee'),
        ],
      ),
    );
  }

  // -- Filters --
  Widget _buildFilterRow() {
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: _filters.map((f) {
            final active = state.filter == f.$1;
            return GestureDetector(
              onTap: () => state.setFilter(f.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: active ? C.brand.withValues(alpha: .09) : C.card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: active ? C.brand : C.border),
                ),
                child: Text(
                  f.$2,
                  style: dm(
                    sz: 11,
                    w: FontWeight.w600,
                    c: active ? C.brand : C.dim,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // -- Listings --
  Widget _buildListings(List<PropertyContainer> filtered) {
    if (state.isLoadingProperties) {
      return const Padding(
        padding: EdgeInsets.all(40.0),
        child: Center(child: CircularProgressIndicator(color: C.green)),
      );
    }
    if (filtered.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.home_work_outlined, size: 40, color: C.dim),
              const SizedBox(height: 12),
              Text('No properties found.', style: dm(sz: 14, c: C.dim)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => state.loadProperties(),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Refresh'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: C.brand,
                  side: BorderSide(color: C.brand.withValues(alpha: .5)),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${filtered.length} Properties Found', style: syne(sz: 16)),
          const SizedBox(height: 14),
          ...filtered.map((p) => _PropertyCard(p: p, state: state)),
        ],
      ),
    );
  }

  // -- Bottom Nav --
  Widget _buildBottomNav() {
    return _BottomNav(
      current: 'home',
      savedCount: state.saved.length,
      onTap: (t) {
        if (t == 'community' && !kIsWeb) state.go('community');
        if (t == 'live') state.go('live');
        if (t == 'chat') state.go('chat');
        if (t == 'home') state.go('home');
        if (t == 'list') state.go('list');
      },
    );
  }
// -- 30-Second Property Video Tour Player ----------------------
class _Property30sVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final VoidCallback onClose;

  const _Property30sVideoPlayer({
    required this.videoUrl,
    required this.onClose,
  });

  @override
  State<_Property30sVideoPlayer> createState() => _Property30sVideoPlayerState();
}

class _Property30sVideoPlayerState extends State<_Property30sVideoPlayer> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _hasError = false;
  bool _isMuted = true;
  Duration _position = Duration.zero;
  static const Duration _maxDuration = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
      await _controller.initialize();
      await _controller.setLooping(false); // Cap & loop at 30s
      await _controller.setVolume(0.0); // Muted by default for fast feed scrolling
      await _controller.play();
      _controller.addListener(_onVideoTick);
      if (mounted) {
        setState(() {
          _initialized = true;
        });
      }
    } catch (e) {
      debugPrint('Property 30s video error: $e');
      if (mounted) {
        setState(() {
          _hasError = true;
        });
      }
    }
  }

  void _onVideoTick() {
    if (!mounted || !_initialized) return;
    final pos = _controller.value.position;
    final dur = _controller.value.duration;
    final limit = dur < _maxDuration ? dur : _maxDuration;
    if (pos >= limit) {
      _controller.seekTo(Duration.zero);
      _controller.play();
    }
    setState(() {
      _position = _controller.value.position;
    });
  }

  Future<void> _toggleMute() async {
    if (!_initialized) return;
    final nextMuted = !_isMuted;
    await _controller.setVolume(nextMuted ? 0.0 : 1.0);
    if (mounted) {
      setState(() {
        _isMuted = nextMuted;
      });
    }
  }

  Future<void> _togglePlay() async {
    if (!_initialized) return;
    if (_controller.value.isPlaying) {
      await _controller.pause();
    } else {
      await _controller.play();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_initialized) {
      _controller.removeListener(_onVideoTick);
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Container(
        color: C.cardDk,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off, color: C.dim, size: 36),
              const SizedBox(height: 6),
              Text('Video tour unavailable', style: dm(sz: 11, c: C.dim)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: widget.onClose,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: C.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: C.border),
                  ),
                  child: Text('View Photos', style: syne(sz: 11, c: C.text)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_initialized) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: C.brand,
                  strokeWidth: 2,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Loading 30s tour...',
                style: dm(sz: 11, c: C.dim),
              ),
            ],
          ),
        ),
      );
    }

    final double progress = (_position.inMilliseconds / 30000.0).clamp(0.0, 1.0);
    final int sec = _position.inSeconds.clamp(0, 30);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePlay,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Video surface
          FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: _controller.value.size.width > 0 ? _controller.value.size.width : 16,
              height: _controller.value.size.height > 0 ? _controller.value.size.height : 9,
              child: VideoPlayer(_controller),
            ),
          ),

          // 2. Play/pause pulse overlay feedback
          if (!_controller.value.isPlaying)
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 36,
                ),
              ),
            ),

          // 3. Top Header: 30s Tour Pill + Close (Photos) button
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: C.brand.withValues(alpha: 0.8), width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: C.brand,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '30s Tour',
                    style: syne(sz: 10, w: FontWeight.w800, c: Colors.white),
                  ),
                ],
              ),
            ),
          ),

          // Close / Return to Photos
          Positioned(
            top: 10,
            right: 10,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24, width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.photo_library, size: 12, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(
                      'Photos',
                      style: syne(sz: 10, w: FontWeight.w700, c: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 4. Bottom Controls: Mute/Unmute & 30s Time indicator
          Positioned(
            bottom: 8,
            left: 10,
            right: 10,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleMute,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24, width: 0.8),
                    ),
                    child: Icon(
                      _isMuted ? Icons.volume_off : Icons.volume_up,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24, width: 0.8),
                  ),
                  child: Text(
                    '0:${sec.toString().padLeft(2, '0')} / 0:30',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 5. 30s Progress Bar Line at the bottom edge
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: 3,
              color: Colors.white12,
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: progress,
                child: Container(
                  color: C.brand,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -- Property Card ---------------------------------------------
class _PropertyCard extends StatefulWidget {
  final PropertyContainer p;
  final AppState state;
  const _PropertyCard({required this.p, required this.state});

  @override
  State<_PropertyCard> createState() => _PropertyCardState();
}

class _PropertyCardState extends State<_PropertyCard> {
  int _currentIndex = 0;
  bool _showVideo = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.p.core.images.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (mounted && !_showVideo) {
          setState(() {
            _currentIndex = (_currentIndex + 1) % widget.p.core.images.length;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _cleanLocation(String district, String city) {
    final d = district.trim();
    final c = city.trim();
    if (d.isEmpty && c.isEmpty) return 'Uganda';
    if (d.isEmpty) return c;
    if (c.isEmpty) return d;
    if (d.toLowerCase() == c.toLowerCase()) return d;
    if (d.toLowerCase().contains(c.toLowerCase())) return d;
    if (c.toLowerCase().contains(d.toLowerCase())) return c;
    return '$d, $c';
  }

  Widget _specItem({required Widget icon, required String label, Color? textColor}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 4),
        Text(label, style: dm(sz: 11, c: textColor ?? Colors.white70, w: FontWeight.w500)),
      ],
    );
  }

  Widget _vDivider() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8),
      child: Text('|', style: TextStyle(color: Colors.white24, fontSize: 11)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final state = widget.state;
    final saved = state.saved.contains(p.core.id);
    final isReserved = p.escrow.status == EscrowStatus.pending_escrow;

    return GestureDetector(
      onTap: () => state.openDetail(p.core.id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isReserved ? C.red.withValues(alpha: .3) : C.border,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. Photo / 30s Video Tour with Badges & Saved Button
              Stack(
                children: [
                  SizedBox(
                    height: 200,
                    width: double.infinity,
                    child: (_showVideo &&
                            p.core.videoUrl != null &&
                            p.core.videoUrl!.isNotEmpty)
                        ? _Property30sVideoPlayer(
                            videoUrl: p.core.videoUrl!,
                            onClose: () => setState(() => _showVideo = false),
                          )
                        : (p.core.images.isNotEmpty
                            ? AnimatedSwitcher(
                                duration: const Duration(milliseconds: 800),
                                child: CachedNetworkImage(
                                  key: ValueKey<String>(p.core.images[_currentIndex]),
                                  imageUrl: p.core.images[_currentIndex],
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  height: double.infinity,
                                  placeholder: (context, url) => Container(color: C.dim.withValues(alpha: 0.1)),
                                  errorWidget: (context, url, error) => Container(
                                    color: C.surface,
                                    child: Icon(Icons.broken_image, color: C.dim),
                                  ),
                                ),
                              )
                            : Container(
                                color: C.surface,
                                child: Center(
                                  child: Text(
                                    p.core.propertyType == PropertyType.apartment ? '🏢' : '🏡',
                                    style: const TextStyle(fontSize: 50),
                                  ),
                                ),
                              )),
                  ),

                  // Top Left: Trust Badge
                  if (!_showVideo)
                    Positioned(
                      top: 10,
                      left: 10,
                      child: _TrustBadge(status: p.financial.trustStatus),
                    ),

                  // Top Right: Purpose Badge
                  if (!_showVideo)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: _PurposeBadge(
                        p.core.listingType.name.toUpperCase(),
                        C.brand,
                      ),
                    ),

                  // If unlocked
                  if (!_showVideo && p.shadow.isUnlockedByCurrentUser)
                    Positioned(
                      top: 10,
                      right: 76,
                      child: _Badge('🔓 Unlocked', C.green, C.text),
                    ),

                  // Heart button (favorite) on the right side of image
                  if (!_showVideo)
                    Positioned(
                      top: 52,
                      right: 12,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => state.toggleSave(p.core.id),
                        child: Text(
                          saved ? '❤️' : '🤍',
                          style: const TextStyle(
                            fontSize: 22,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 6),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // 30s Video Tour Badge / Toggle Button
                  if (p.core.videoUrl != null &&
                      p.core.videoUrl!.isNotEmpty &&
                      !_showVideo)
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _showVideo = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: C.brand.withValues(alpha: 0.8),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.5),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.play_circle_fill, size: 14, color: C.brand),
                              const SizedBox(width: 4),
                              Text(
                                '30s Tour',
                                style: syne(
                                  sz: 10,
                                  w: FontWeight.w700,
                                  c: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Reserved overlay
                  if (isReserved)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black45,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(color: C.red, borderRadius: BorderRadius.circular(8)),
                            child: Text('RESERVED', style: syne(sz: 10, c: C.text, w: FontWeight.w800)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),

              // 2. Info Card Section
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title
                    Text(
                      p.core.title,
                      style: syne(sz: 18, w: FontWeight.bold, c: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),

                    // Clean Location
                    Row(
                      children: [
                        const Icon(Icons.location_on, size: 14, color: Color(0xFFFF4848)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _cleanLocation(p.core.district, p.core.city),
                            style: dm(sz: 12, c: const Color(0xFF8E9BAE)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Specs Row with Dividers
                    Row(
                      children: [
                        _specItem(
                          icon: const Icon(Icons.bed_rounded, size: 15, color: C.brand),
                          label: '${p.core.bedrooms} Bed',
                        ),
                        _vDivider(),
                        _specItem(
                          icon: const Icon(Icons.shower_outlined, size: 15, color: C.brand),
                          label: '${p.core.bathrooms} Bath',
                        ),
                        _vDivider(),
                        _specItem(
                          icon: const Icon(Icons.square_foot_rounded, size: 15, color: C.brand),
                          label: p.core.sizeSqft > 0 ? '${p.core.sizeSqft} m²' : '— m²',
                        ),
                        _vDivider(),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFB800)),
                            const SizedBox(width: 3),
                            Text(
                              '4.8',
                              style: dm(sz: 11, c: C.brand, w: FontWeight.w700),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Horizontal Divider
                    Container(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                    const SizedBox(height: 12),

                    // Pricing and Action
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    ugx(p.financial.price),
                                    style: syne(sz: 18, c: C.brand, w: FontWeight.bold),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    p.financial.priceType == PriceType.monthly ? '/mo' : '/night',
                                    style: dm(sz: 11, c: Colors.white60),
                                  ),
                                ],
                              ),
                              if (!p.shadow.isUnlockedByCurrentUser) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(Icons.lock, size: 12, color: C.gold),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Unlock: ${ugx(p.financial.unlockCost)}',
                                      style: dm(sz: 11, c: C.gold, w: FontWeight.w700),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          decoration: BoxDecoration(
                            color: isReserved ? C.red.withValues(alpha: .1) : Colors.transparent,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isReserved ? C.red : C.brand,
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                isReserved ? 'Reserved' : 'View',
                                style: dm(
                                  sz: 12,
                                  w: FontWeight.w700,
                                  c: isReserved ? C.red : C.brand,
                                ),
                              ),
                              if (!isReserved) ...[
                                const SizedBox(width: 5),
                                const Icon(Icons.arrow_forward_rounded, size: 14, color: C.brand),
                              ],
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
    );
  }
}

// -- Shared Widgets --------------------------------------------
class _TrustBadge extends StatelessWidget {
  final TrustStatus status;
  const _TrustBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg;
    String label;
    switch (status) {
      case TrustStatus.titan_trust:
        bg = const Color(0xFFB8860B);
        label = '💎 TITAN TRUST';
        break;
      case TrustStatus.verified:
        bg = C.green;
        label = '✅ VERIFIED';
        break;
      case TrustStatus.limited:
        bg = Colors.orange;
        label = '⚠️ LIMITED';
        break;
      default:
        bg = const Color(0xFF3B536D);
        label = 'STANDARD';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          if (status == TrustStatus.titan_trust)
            BoxShadow(
              color: bg.withValues(alpha: .4),
              blurRadius: 8,
              spreadRadius: 1,
            ),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w900,
          color: C.text,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color bg, textColor;
  const _Badge(this.text, this.bg, this.textColor);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      ),
    );
  }
}

class _PurposeBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _PurposeBadge(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: C.bg.withValues(alpha: .82),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: .27)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String icon, val, lab;
  const _StatCell({required this.icon, required this.val, required this.lab});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        color: C.card,
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            Text(icon, style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 2),
            Text(val, style: syne(sz: 17, c: C.brand)),
            Text(lab, style: dm(sz: 10, c: C.dim)),
          ],
        ),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);
  late final Animation<double> _anim = Tween(
    begin: 1.0,
    end: 0.4,
  ).animate(_ctrl);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Text('•', style: TextStyle(color: C.brand, fontSize: 10)),
    );
  }
}

// -- App Tabs (shared) -----------------------------------------
class _AppTabs extends StatelessWidget {
  final String current;
  final void Function(String) onTap;
  final AppState state;
  const _AppTabs({
    required this.current,
    required this.onTap,
    required this.state,
  });

  List<(String, String?, String)> get _tabRoutes => [
    ('home', 'assets/images/property_icon.png', 'Property'),
    if (kIsWeb) ('list', 'assets/images/listing_icon.png', 'Property Listing'),
    if (!kIsWeb) ('transport', 'assets/images/transport_icon.png', 'Transport'),
    if (!kIsWeb) ('upload', 'assets/images/upload_icon.png', 'Upload'),
    if (kIsWeb) ('live', null, 'Live Stream'),
    ('profile', null, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: Row(
        children: _tabRoutes.map((t) {
          final active = t.$1 == current;
          final isProfile = t.$1 == 'profile';
          final isLive = t.$1 == 'live';
          final iconAsset = t.$2;

          return Expanded(
            child: GestureDetector(
              onTap: () => onTap(t.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active ? C.brand : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isProfile)
                      ListenableBuilder(
                        listenable: state,
                        builder: (context, _) {
                          final url = state.myProfile?['photo_url'];
                          return Container(
                            width: 14,
                            height: 14,
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: C.dim.withValues(alpha: .2),
                              image: url != null
                                  ? DecorationImage(
                                      image: NetworkImage(url),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child: url == null
                                ? Icon(Icons.person, size: 8, color: C.dim)
                                : null,
                          );
                        },
                      )
                    else if (isLive)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.live_tv_rounded,
                          size: 14,
                          color: Color(0xFFFF2D55),
                        ),
                      )
                    else if (iconAsset != null)
                      Opacity(
                        opacity: active ? 1.0 : 0.6,
                        child: Image.asset(iconAsset, width: 14, height: 14),
                      ),

                    if (!isProfile && !isLive) const SizedBox(width: 4),

                    Text(
                      t.$3,
                      textAlign: TextAlign.center,
                      style: dm(
                        sz: 10,
                        w: active ? FontWeight.w800 : FontWeight.w600,
                        c: active ? C.brand : C.dim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// -- Bottom Nav (shared) ---------------------------------------
class _BottomNav extends StatelessWidget {
  final String current;
  final int savedCount;
  final void Function(String) onTap;
  const _BottomNav({
    required this.current,
    required this.savedCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        border: Border(top: BorderSide(color: C.border)),
      ),
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _BotBtn(
            Opacity(
              opacity: current == 'home' ? 1.0 : 0.5,
              child: Image.asset(
                'assets/images/property_icon.png',
                width: 24,
                height: 24,
              ),
            ),
            'Property', 
            current == 'home', 
            () => onTap('home'),
          ),
          if (!kIsWeb)
            _BotBtn(
              Opacity(
                opacity: current == 'community' ? 1.0 : 0.5,
                child: Image.asset(
                  'assets/images/community_icon_colored.png',
                  width: 24,
                  height: 24,
                ),
              ),
              'Community',
              current == 'community',
              () => onTap('community'),
            ),
          if (kIsWeb)
            _BotBtn(
              Opacity(
                opacity: current == 'live' ? 1.0 : 0.5,
                child: const Icon(
                  Icons.live_tv_rounded,
                  color: Color(0xFFFF2D55),
                  size: 24,
                ),
              ),
              'Live',
              current == 'live',
              () => onTap('live'),
            ),
          _BotBtn(
            Opacity(
              opacity: current == 'list' ? 1.0 : 0.5,
              child: Image.asset(
                'assets/images/listing_icon.png',
                width: 24,
                height: 24,
              ),
            ),
            'Property Listing', 
            current == 'list', 
            () => onTap('list'),
          ),
          _BotBtn(
            Opacity(
              opacity: (current == 'chat' || current == 'chat-list' || current == 'new-chat') ? 1.0 : 0.5,
              child: Image.asset(
                'assets/images/chat_icon.png',
                width: 24,
                height: 24,
              ),
            ),
            'Chat',
            current == 'chat' || current == 'chat-list' || current == 'new-chat',
            () => onTap('chat'),
          ),
        ],
      ),
    );
  }
}

class _BotBtn extends StatelessWidget {
  final Object icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _BotBtn(this.icon, this.label, this.active, this.onTap);
  @override
  Widget build(BuildContext context) {
    final Widget iconWidget = icon is Widget 
        ? (icon as Widget) 
        : Text(icon.toString(), style: const TextStyle(fontSize: 22));

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconWidget,
          const SizedBox(height: 3),
          Text(
            label,
            style: dm(sz: 9, w: FontWeight.w600, c: active ? C.brand : C.dim),
          ),
        ],
      ),
    );
  }
}
