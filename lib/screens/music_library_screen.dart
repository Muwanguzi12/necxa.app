import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/music_library_service.dart';
import '../services/distributor_music_service.dart';
import '../models/music_models.dart';
import '../widgets/music_track_tile.dart';
import '../theme.dart';
import '../app_state.dart';
import 'music_detail_screen.dart';

class MusicLibraryScreen extends StatefulWidget {
  /// Pass [state] when the screen is opened from a context where the artist
  /// identity is known (e.g. from the media editor or Upload screen).
  /// When null the "My Releases" tab is hidden.
  final AppState? state;

  const MusicLibraryScreen({super.key, this.state});

  @override
  State<MusicLibraryScreen> createState() => _MusicLibraryScreenState();
}

class _MusicLibraryScreenState extends State<MusicLibraryScreen>
    with SingleTickerProviderStateMixin {
  late final MusicLibraryService _musicService;
  late final TabController _tabController;
  final TextEditingController _searchCtrl = TextEditingController();
  final DistributorMusicService _distributorService = DistributorMusicService();

  List<MusicGenre> _genres = [];
  List<MusicTrack> _platformTracks = [];
  List<MusicTrack> _artistTracks = [];
  List<MusicTrack> _myReleases = [];
  List<MusicTrack> _trendingTracks = [];
  List<MusicTrack> _filteredPlatform = [];
  List<MusicTrack> _filteredArtist = [];
  bool _isLoading = true;
  String? _playingTrackId;

  bool get _isArtist => widget.state?.isArtist == true;
  int get _tabCount => _isArtist ? 4 : 3;

  @override
  void initState() {
    super.initState();
    _musicService = MusicLibraryService();
    _tabController = TabController(length: _tabCount, vsync: this);
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final discovery = await _musicService.getMusicDiscovery();
      final platform =
          await _musicService.searchMusic(licenseType: 'platform_owned');
      final artist =
          await _musicService.searchMusic(licenseType: 'artist_upload');

      List<MusicTrack> myReleases = [];
      if (_isArtist && widget.state?.user?.id != null) {
        try {
          myReleases = await _musicService.getMyReleases(widget.state!.user!.id);
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _genres = discovery['genres'] ?? [];
          _trendingTracks = discovery['trending'] ?? [];
          _platformTracks = platform;
          _artistTracks = artist;
          _filteredPlatform = platform;
          _filteredArtist = artist;
          _myReleases = myReleases;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Music Load Error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _filterMusic(String query) async {
    if (query.isEmpty) {
      setState(() {
        _filteredPlatform = _platformTracks;
        _filteredArtist = _artistTracks;
      });
      return;
    }
    final results = await _musicService.searchMusic(query: query);
    if (mounted) {
      setState(() {
        _filteredPlatform =
            results.where((t) => t.licenseType == 'platform_owned').toList();
        _filteredArtist =
            results.where((t) => t.licenseType == 'artist_upload').toList();
      });
    }
  }

  void _showDetail(MusicTrack track) async {
    HapticFeedback.mediumImpact();
    await _musicService.stopPreview();
    setState(() => _playingTrackId = null);

    if (!mounted) return;
    final selectedTrackId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MusicDetailScreen(track: track),
    );

    if (selectedTrackId != null && mounted) {
      Navigator.pop(context, track);
    }
  }

  // ─── Link Release Sheet ───────────────────────────────────────────────────

  void _openLinkReleaseSheet() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LinkReleaseSheet(
        distributorService: _distributorService,
        artistId: widget.state?.user?.id ?? '',
        onLinked: (track) {
          setState(() => _myReleases = [track, ..._myReleases]);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('🎵 "${track.title}" added to My Releases'),
              backgroundColor: C.brand,
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _musicService.dispose();
    super.dispose();
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Background glow
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: C.brand.withOpacity(0.15),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
                child: Container(),
              ),
            ),
          ),

          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                _buildSearchBar(),
                _buildTabs(),
                Expanded(
                  child: _isLoading
                      ? Center(
                          child: CircularProgressIndicator(color: C.brand))
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildForYouTab(),
                            _buildListTab(_filteredPlatform),
                            _buildListTab(_filteredArtist),
                            if (_isArtist) _buildMyReleasesTab(),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Icon(Icons.arrow_back_ios, color: C.text),
          ),
          const SizedBox(width: 16),
          Text('AUDIO STUDIO',
              style: syne(sz: 20, w: FontWeight.w900, c: C.text, ls: 1)),
          const Spacer(),
          Icon(Icons.history, color: C.sub),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: C.text.withOpacity(0.08),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: C.dim),
      ),
      child: TextField(
        controller: _searchCtrl,
        onChanged: _filterMusic,
        style: dm(c: C.text),
        decoration: InputDecoration(
          hintText: 'Search songs, artists...',
          hintStyle: dm(c: C.dim),
          prefixIcon: Icon(Icons.search, color: C.dim, size: 20),
          border: InputBorder.none,
          suffixIcon: _searchCtrl.text.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear, color: C.dim, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                    _filterMusic('');
                  })
              : null,
        ),
      ),
    );
  }

  Widget _buildTabs() {
    return Container(
      margin: const EdgeInsets.only(top: 20, bottom: 10),
      child: TabBar(
        controller: _tabController,
        dividerColor: Colors.transparent,
        indicatorColor: C.brand,
        labelColor: C.brand,
        unselectedLabelColor: C.dim,
        isScrollable: _isArtist,
        labelStyle: syne(sz: 13, w: FontWeight.bold),
        tabs: [
          const Tab(text: 'Discovery'),
          const Tab(text: 'Platform'),
          const Tab(text: 'Artists'),
          if (_isArtist)
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('My Releases'),
                  if (_myReleases.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: C.brand,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('${_myReleases.length}',
                          style: const TextStyle(
                              fontSize: 10, color: Colors.white)),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildForYouTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            const Icon(Icons.bolt, color: Colors.amber, size: 18),
            const SizedBox(width: 8),
            Text('TRENDING NOW',
                style:
                    syne(sz: 14, w: FontWeight.bold, c: C.text, ls: 1)),
          ],
        ),
        const SizedBox(height: 16),
        ...(_trendingTracks.isNotEmpty ? _trendingTracks : _platformTracks)
            .take(4)
            .map((t) => MusicTrackTile(
                  track: t,
                  isPlaying: _playingTrackId == t.id,
                  onTap: () => _showDetail(t),
                )),
        if (_artistTracks.isNotEmpty) ...[
          const SizedBox(height: 28),
          Row(
            children: [
              const Icon(Icons.mic_external_on_rounded,
                  color: Color(0xFF00E5FF), size: 18),
              const SizedBox(width: 8),
              Text('ARTIST RELEASES',
                  style:
                      syne(sz: 14, w: FontWeight.bold, c: C.text, ls: 1)),
            ],
          ),
          const SizedBox(height: 16),
          ..._artistTracks.take(4).map((t) => MusicTrackTile(
                track: t,
                isPlaying: _playingTrackId == t.id,
                onTap: () => _showDetail(t),
              )),
        ],
        const SizedBox(height: 32),
        Text('GENRES',
            style: syne(sz: 14, w: FontWeight.bold, c: C.text, ls: 1)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: _genres
              .map((g) => Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: C.text.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: C.dim),
                    ),
                    child: Text(g.name, style: dm(sz: 12, c: C.sub)),
                  ))
              .toList(),
        ),
      ],
    );
  }

  Widget _buildListTab(List<MusicTrack> tracks) {
    if (tracks.isEmpty) {
      return Center(
          child: Text('Empty Library', style: TextStyle(color: C.dim)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: tracks.length,
      itemBuilder: (context, index) => MusicTrackTile(
        track: tracks[index],
        isPlaying: _playingTrackId == tracks[index].id,
        onTap: () => _showDetail(tracks[index]),
      ),
    );
  }

  // ─── My Releases tab (artist-only) ────────────────────────────────────────

  Widget _buildMyReleasesTab() {
    return Column(
      children: [
        // "Link a Release" banner
        GestureDetector(
          onTap: _openLinkReleaseSheet,
          child: Container(
            margin: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [C.brand.withOpacity(0.18), Colors.transparent],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: C.brand.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: C.brand.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.link_rounded, color: C.brand, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Link a Release',
                          style: syne(
                              sz: 14, w: FontWeight.bold, c: C.text)),
                      const SizedBox(height: 2),
                      Text(
                          'Paste your Spotify, Apple Music, DistroKid or Audiomack link',
                          style: dm(sz: 11, c: C.dim)),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios, color: C.brand, size: 14),
              ],
            ),
          ),
        ),

        // Releases list
        Expanded(
          child: _myReleases.isEmpty
              ? _buildEmptyReleases()
              : ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  itemCount: _myReleases.length,
                  itemBuilder: (context, index) {
                    final track = _myReleases[index];
                    return Stack(
                      children: [
                        MusicTrackTile(
                          track: track,
                          isPlaying: _playingTrackId == track.id,
                          onTap: () => _showDetail(track),
                        ),
                        // Distributor badge
                        if (track.isDistributorLinked)
                          Positioned(
                            top: 10,
                            right: 12,
                            child: _DistributorBadge(
                                platform: track.distributorPlatform ?? ''),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyReleases() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.library_music_outlined, color: C.dim, size: 56),
          const SizedBox(height: 20),
          Text('No releases linked yet',
              style: syne(sz: 16, w: FontWeight.bold, c: C.sub)),
          const SizedBox(height: 8),
          Text(
            'Paste your song link from Spotify,\nApple Music, DistroKid or Audiomack.',
            style: dm(sz: 13, c: C.dim),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          GestureDetector(
            onTap: _openLinkReleaseSheet,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              decoration: BoxDecoration(
                color: C.brand,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Text('+ Link a Release',
                  style: syne(sz: 14, w: FontWeight.bold, c: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Distributor Platform Badge ───────────────────────────────────────────────

class _DistributorBadge extends StatelessWidget {
  final String platform;
  const _DistributorBadge({required this.platform});

  Color get _color {
    switch (platform) {
      case 'spotify':
        return const Color(0xFF1DB954);
      case 'apple_music':
        return const Color(0xFFFA233B);
      case 'audiomack':
        return const Color(0xFFFF6600);
      case 'soundcloud':
        return const Color(0xFFFF5500);
      case 'distrokid':
        return const Color(0xFF6C63FF);
      default:
        return Colors.grey;
    }
  }

  String get _label {
    switch (platform) {
      case 'spotify':
        return 'Spotify';
      case 'apple_music':
        return 'Apple';
      case 'audiomack':
        return 'Audiomack';
      case 'soundcloud':
        return 'SC';
      case 'distrokid':
        return 'DistroKid';
      default:
        return 'Stream';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _color.withOpacity(0.6)),
      ),
      child: Text(
        _label,
        style: TextStyle(
            fontSize: 9,
            color: _color,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5),
      ),
    );
  }
}

// ─── Link Release Bottom Sheet ────────────────────────────────────────────────

class _LinkReleaseSheet extends StatefulWidget {
  final DistributorMusicService distributorService;
  final String artistId;
  final void Function(MusicTrack track) onLinked;

  const _LinkReleaseSheet({
    required this.distributorService,
    required this.artistId,
    required this.onLinked,
  });

  @override
  State<_LinkReleaseSheet> createState() => _LinkReleaseSheetState();
}

class _LinkReleaseSheetState extends State<_LinkReleaseSheet> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  MusicTrack? _resolved;
  String? _error;

  Future<void> _resolve() async {
    final url = _ctrl.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _resolved = null;
    });
    try {
      final track = await widget.distributorService.resolve(url);
      setState(() => _resolved = track);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _confirm() async {
    if (_resolved == null) return;
    setState(() => _loading = true);
    try {
      final registered = await widget.distributorService.registerInCatalog(
        track: _resolved!,
        artistId: widget.artistId,
      );
      widget.onLinked(registered);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _error = 'Could not save to your catalog. Please try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0D0D0D),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: Colors.white12),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            Text('Link Your Release',
                style: syne(sz: 18, w: FontWeight.w900, c: Colors.white)),
            const SizedBox(height: 6),
            Text(
              'Paste your song link from a major distributor or streaming platform.',
              style: dm(sz: 12, c: Colors.white54),
            ),
            const SizedBox(height: 20),

            // Supported platform chips
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _PlatformChip(label: '🟢 Spotify'),
                _PlatformChip(label: '🔴 Apple Music'),
                _PlatformChip(label: '🟠 Audiomack'),
                _PlatformChip(label: '🟣 DistroKid'),
                _PlatformChip(label: '🟡 SoundCloud'),
              ],
            ),
            const SizedBox(height: 20),

            // URL input
            TextField(
              controller: _ctrl,
              autofocus: true,
              style: dm(c: Colors.white),
              decoration: InputDecoration(
                hintText: 'https://open.spotify.com/track/...',
                hintStyle: dm(sz: 13, c: Colors.white38),
                filled: true,
                fillColor: Colors.white.withOpacity(0.06),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: _ctrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white38, size: 16),
                        onPressed: () {
                          _ctrl.clear();
                          setState(() {
                            _resolved = null;
                            _error = null;
                          });
                        })
                    : null,
              ),
              onSubmitted: (_) => _resolve(),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),

            // Resolve button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _resolve,
                style: ElevatedButton.styleFrom(
                  backgroundColor: C.brand,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: _loading && _resolved == null
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text('Fetch Song Info',
                        style: syne(sz: 14, w: FontWeight.bold, c: Colors.white)),
              ),
            ),

            // Error
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.redAccent, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(_error!,
                            style: dm(sz: 12, c: Colors.redAccent))),
                  ],
                ),
              ),
            ],

            // Resolved track preview
            if (_resolved != null) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    if (_resolved!.albumArtUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          _resolved!.albumArtUrl!,
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 52,
                            height: 52,
                            color: Colors.white10,
                            child: const Icon(Icons.music_note,
                                color: Colors.white38),
                          ),
                        ),
                      )
                    else
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: C.brand.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.music_note, color: C.brand),
                      ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_resolved!.title,
                              style: syne(
                                  sz: 13,
                                  w: FontWeight.bold,
                                  c: Colors.white),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(_resolved!.artistName,
                              style: dm(sz: 11, c: Colors.white54)),
                          const SizedBox(height: 4),
                          _DistributorBadge(
                              platform: _resolved!.distributorPlatform ?? ''),
                        ],
                      ),
                    ),
                    const Icon(Icons.check_circle,
                        color: Colors.greenAccent, size: 20),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _confirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _loading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black))
                      : Text('Add to My Releases ✓',
                          style: syne(
                              sz: 14,
                              w: FontWeight.bold,
                              c: Colors.black)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlatformChip extends StatelessWidget {
  final String label;
  const _PlatformChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 11, color: Colors.white70)),
    );
  }
}
