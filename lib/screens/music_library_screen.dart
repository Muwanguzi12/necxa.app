import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/music_library_service.dart';
import '../models/music_models.dart';
import '../widgets/music_track_tile.dart';
import '../theme.dart';
import 'music_detail_screen.dart';

class MusicLibraryScreen extends StatefulWidget {
  const MusicLibraryScreen({super.key});

  @override
  State<MusicLibraryScreen> createState() => _MusicLibraryScreenState();
}

class _MusicLibraryScreenState extends State<MusicLibraryScreen> with SingleTickerProviderStateMixin {
  late final MusicLibraryService _musicService;
  late final TabController _tabController;
  final TextEditingController _searchCtrl = TextEditingController();

  List<MusicGenre> _genres = [];
  List<MusicTrack> _platformTracks = [];
  List<MusicTrack> _artistTracks = [];
  List<MusicTrack> _filteredPlatform = [];
  List<MusicTrack> _filteredArtist = [];
  bool _isLoading = true;
  String? _playingTrackId;

  @override
  void initState() {
    super.initState();
    _musicService = MusicLibraryService();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final discovery = await _musicService.getMusicDiscovery();
      final platform = await _musicService.searchMusic(licenseType: 'platform_owned');
      final artist = await _musicService.searchMusic(licenseType: 'artist_upload');
      
      if (mounted) {
        setState(() {
          _genres = discovery['genres'];
          _platformTracks = platform;
          _artistTracks = artist;
          _filteredPlatform = platform;
          _filteredArtist = artist;
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

    // Remote fuzzy search via Redis for the query
    final results = await _musicService.searchMusic(query: query);
    
    if (mounted) {
      setState(() {
        _filteredPlatform = results.where((t) => t.licenseType == 'platform_owned').toList();
        _filteredArtist = results.where((t) => t.licenseType == 'artist_upload').toList();
      });
    }
  }

  void _onTrackTap(MusicTrack track) async {
    HapticFeedback.lightImpact();
    if (_playingTrackId == track.id) {
      await _musicService.stopPreview();
      setState(() => _playingTrackId = null);
    } else {
      setState(() => _playingTrackId = track.id);
      await _musicService.previewMusic(track.audioUrl);
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
      Navigator.pop(context, track); // Return selected track to editor
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _musicService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Background Gradient Glow
          Positioned(
            top: -100, left: -100,
            child: Container(
              width: 300, height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: C.brand.withOpacity(0.15),
              ),
              child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80), child: Container()),
            ),
          ),

          // 2. Main Content
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                _buildSearchBar(),
                _buildTabs(),
                Expanded(
                  child: _isLoading 
                    ? Center(child: CircularProgressIndicator(color: C.brand))
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildForYouTab(),
                          _buildListTab(_filteredPlatform),
                          _buildListTab(_filteredArtist),
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
          GestureDetector(onTap: () => Navigator.pop(context), child: Icon(Icons.arrow_back_ios, color: C.text)),
          const SizedBox(width: 16),
          Text('MUSIC LIBRARY', style: syne(sz: 20, w: FontWeight.w900, c: C.text, ls: 1)),
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
                onPressed: () { _searchCtrl.clear(); _filterMusic(''); }
              )
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
        labelStyle: syne(sz: 14, w: FontWeight.bold),
        tabs: const [Tab(text: 'Discovery'), Tab(text: 'Platform'), Tab(text: 'Artists')],
      ),
    );
  }

  Widget _buildForYouTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Trending Header
        Row(
          children: [
            const Icon(Icons.bolt, color: Colors.amber, size: 18),
            const SizedBox(width: 8),
            Text('TRENDING NOW', style: syne(sz: 14, w: FontWeight.bold, c: C.text, ls: 1)),
          ],
        ),
        const SizedBox(height: 16),
        
        // Small preview list
        ..._platformTracks.take(3).map((t) => MusicTrackTile(
          track: t, 
          isPlaying: _playingTrackId == t.id,
          onTap: () => _showDetail(t),
        )),

        const SizedBox(height: 32),

        // Genres
        Text('GENRES', style: syne(sz: 14, w: FontWeight.bold, c: C.text, ls: 1)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10, runSpacing: 10,
          children: _genres.map((g) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: C.text.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: C.dim),
            ),
            child: Text(g.name, style: dm(sz: 12, c: C.sub)),
          )).toList(),
        ),
      ],
    );
  }

  Widget _buildListTab(List<MusicTrack> tracks) {
    if (tracks.isEmpty) return Center(child: Text('Empty Library', style: TextStyle(color: C.dim)));
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
}



