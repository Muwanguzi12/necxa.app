import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../app_state.dart';
import '../models/music_models.dart';
import '../widgets/necxa_video_player.dart';
import 'dart:ui';

class SoundHubScreen extends StatefulWidget {
  final MusicTrack track;
  final AppState state;

  const SoundHubScreen({super.key, required this.track, required this.state});

  @override
  State<SoundHubScreen> createState() => _SoundHubScreenState();
}

class _SoundHubScreenState extends State<SoundHubScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. DYNAMIC BACKGROUND BLUR
          if (widget.track.albumArtUrl != null)
            Positioned.fill(
              child: Opacity(
                opacity: 0.3,
                child: Image.network(widget.track.albumArtUrl!, fit: BoxFit.cover),
              ),
            ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
              child: Container(color: Colors.black54),
            ),
          ),

          // 2. SCROLLABLE CONTENT
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              _buildHeader(),
              _buildControlBar(),
              _buildContentGrid(),
              const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
            ],
          ),

          // 3. TOP NAV
          _buildTopHUD(),

          // 4. FLOATING "USE THIS SOUND" BUTTON
          _buildUseSoundFAB(),
        ],
      ),
    );
  }

  Widget _buildTopHUD() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 10,
      left: 16,
      child: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
          child: Icon(Icons.arrow_back_ios_new, color: C.text, size: 16),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 100, 24, 24),
        child: Row(
          children: [
            // Track Art
            Hero(
              tag: 'track_art_${widget.track.id}',
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 20)],
                  image: widget.track.albumArtUrl != null
                      ? DecorationImage(image: NetworkImage(widget.track.albumArtUrl!), fit: BoxFit.cover)
                      : null,
                ),
                child: widget.track.albumArtUrl == null
                    ? Icon(Icons.music_note, color: C.dim, size: 48)
                    : null,
              ),
            ),
            const SizedBox(width: 24),
            // Track Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.track.title, style: syne(sz: 24, w: FontWeight.w900, c: C.text)),
                  const SizedBox(height: 6),
                  Text(widget.track.artistName, style: dm(sz: 16, c: C.brand, w: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.video_library, color: C.dim, size: 14),
                      const SizedBox(width: 6),
                      Text('${widget.track.usageCount} videos', style: dm(sz: 13, c: C.dim)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlBar() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _actionBtn(Icons.play_arrow_rounded, 'Play Preview', () {}),
                const SizedBox(width: 12),
                _actionBtn(Icons.bookmark_border, 'Save Sound', () {}),
                const SizedBox(width: 12),
                _actionBtn(Icons.share_outlined, 'Share', () {}),
              ],
            ),

            // ── Distributor outbound button (only for linked releases) ──────
            if (widget.track.isDistributorLinked &&
                widget.track.distributorUrl != null) ...[
              const SizedBox(height: 14),
              GestureDetector(
                onTap: () async {
                  final uri = Uri.tryParse(widget.track.distributorUrl!);
                  if (uri != null) {
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 13),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _platformColor(widget.track.distributorPlatform)
                            .withOpacity(0.15),
                        Colors.transparent,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _platformColor(widget.track.distributorPlatform)
                          .withOpacity(0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.open_in_new_rounded,
                          color: _platformColor(
                              widget.track.distributorPlatform),
                          size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Listen Full Song on ${widget.track.distributorLabel}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: _platformColor(
                                    widget.track.distributorPlatform),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Support the artist — stream the full track',
                              style: TextStyle(
                                  fontSize: 10, color: Colors.white38),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.arrow_forward_ios,
                          size: 12,
                          color: _platformColor(
                              widget.track.distributorPlatform)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _platformColor(String? platform) {
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
        return Colors.white70;
    }
  }

  Widget _actionBtn(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: C.text.withOpacity(.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.text.withOpacity(.1)),
          ),
          child: Column(
            children: [
              Icon(icon, color: C.text, size: 20),
              const SizedBox(height: 4),
              Text(label, style: dm(sz: 9, c: C.dim, w: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContentGrid() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: widget.state.social.streamPostsByMusic(widget.track.id),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: C.brand)));
        }
        final posts = snapshot.data!;
        if (posts.isEmpty) {
          return SliverFillRemaining(
            child: Center(child: Text('Be the first to use this sound!', style: syne(sz: 14, c: C.dim))),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.all(1),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 1,
              mainAxisSpacing: 1,
              childAspectRatio: 0.7,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => _GridItem(post: posts[i]),
              childCount: posts.length,
            ),
          ),
        );
      },
    );
  }

  Widget _buildUseSoundFAB() {
    return Positioned(
      bottom: 40,
      left: 40,
      right: 40,
      child: GestureDetector(
        onTap: () {
          // NAVIGATE TO UPLOAD WITH PRE-SELECTED TRACK
          // We pop first so the Sound Hub is removed from the navigator stack
          Navigator.pop(context);
          widget.state.go('upload', extra: widget.track);
        },
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [C.brand, C.purple]),
            borderRadius: BorderRadius.circular(30),
            boxShadow: [BoxShadow(color: C.brand.withOpacity(.4), blurRadius: 20, offset: Offset(0, 8))],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.videocam_rounded, color: Colors.black, size: 24),
              const SizedBox(width: 12),
              Text('USE THIS SOUND', style: syne(sz: 15, w: FontWeight.w900, ls: 1, c: Colors.black)),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridItem extends StatelessWidget {
  final Map<String, dynamic> post;
  const _GridItem({required this.post});

  @override
  Widget build(BuildContext context) {
    final mediaUrl = post['media_url'];
    return Container(
      decoration: BoxDecoration(
        color: C.dim,
        image: mediaUrl != null ? DecorationImage(image: NetworkImage(mediaUrl), fit: BoxFit.cover) : null,
      ),
      child: Center(child: Icon(Icons.play_arrow_outlined, color: C.dim, size: 32)),
    );
  }
}


