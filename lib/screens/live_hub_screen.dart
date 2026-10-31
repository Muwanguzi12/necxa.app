import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme.dart';
import '../app_state.dart';
import '../widgets/necxa_bottom_nav.dart';
import 'live_studio_screen.dart';

class LiveHubScreen extends StatefulWidget {
  final AppState state;
  const LiveHubScreen({super.key, required this.state});

  @override
  State<LiveHubScreen> createState() => _LiveHubScreenState();
}

class _LiveHubScreenState extends State<LiveHubScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _activeStreams = [];
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _fetchStreams();
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) _fetchStreams(quiet: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchStreams({bool quiet = false}) async {
    if (!quiet && mounted) setState(() => _loading = true);
    try {
      final streams = await widget.state.live.getActiveStreams();
      if (mounted) {
        setState(() {
          _activeStreams = streams;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[LiveHub] Fetch error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startBroadcasting() {
    final hostName = widget.state.myDisplayName ?? 'User';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LiveStudioScreen(
          state: widget.state,
          channelName: '${hostName}_Live',
          isHost: true,
          hostId: widget.state.user?.id,
          hostName: hostName,
          hostAvatar: widget.state.myAvatarUrl,
        ),
      ),
    ).then((_) {
      if (mounted) _fetchStreams();
    });
  }

  void _watchStream(Map<String, dynamic> stream) {
    final channelName = stream['channelName']?.toString() ??
        stream['id']?.toString() ??
        '';
    if (channelName.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LiveStudioScreen(
          state: widget.state,
          channelName: channelName,
          isHost: false,
          hostId: stream['hostId']?.toString(),
          hostName: (stream['hostName'] ??
                  (stream['metadata'] as Map?)?['hostName'])
              ?.toString(),
          hostAvatar: (stream['avatar'] ??
                  (stream['metadata'] as Map?)?['avatar'])
              ?.toString(),
        ),
      ),
    ).then((_) {
      if (mounted) _fetchStreams();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => _fetchStreams(),
                    color: C.brand,
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildGoLiveHero(),
                          const SizedBox(height: 20),
                          _buildSectionTitle(),
                          const SizedBox(height: 12),
                          if (_loading && _activeStreams.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 40),
                              child: Center(
                                child: CircularProgressIndicator(color: C.brand),
                              ),
                            )
                          else if (_activeStreams.isEmpty)
                            _buildEmptyState()
                          else
                            _buildStreamsGrid(),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                ),
                NecxaBottomNav(state: widget.state),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: C.card,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFFFF2D55).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFFFF2D55).withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFF2D55),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'LIVE',
                  style: syne(sz: 10, w: FontWeight.w800, c: const Color(0xFFFF2D55)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Live Studio', style: syne(sz: 17, w: FontWeight.w800)),
                Text(
                  'Broadcast to Uganda & watch creators in real-time',
                  style: dm(sz: 10, c: C.dim),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.refresh, color: C.dim, size: 20),
            onPressed: () => _fetchStreams(),
            tooltip: 'Refresh streams',
          ),
        ],
      ),
    );
  }

  Widget _buildGoLiveHero() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF101B2E),
            const Color(0xFF060F1E),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: C.brand.withValues(alpha: 0.3),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: C.brand.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: C.brand.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: C.brand.withValues(alpha: 0.4)),
                ),
                child: const Icon(
                  Icons.videocam_rounded,
                  color: C.brand,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ready to Broadcast?',
                      style: syne(sz: 15, w: FontWeight.w800),
                    ),
                    Text(
                      'Go live directly from your web browser with real-time video, chat, and gifts.',
                      style: dm(sz: 11, c: C.dim),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _startBroadcasting,
              icon: const Icon(Icons.podcasts_rounded, size: 18),
              label: Text(
                'Go Live Now',
                style: syne(sz: 13, w: FontWeight.w800, c: Colors.black),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: C.brand,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Text('Active Broadcasts', style: syne(sz: 14, w: FontWeight.w700)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: C.card2,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: C.border),
              ),
              child: Text(
                '${_activeStreams.length}',
                style: dm(sz: 10, w: FontWeight.w700, c: C.brand),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: C.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.live_tv_rounded,
              color: C.dim,
              size: 40,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'No Active Live Streams',
            style: syne(sz: 15, w: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Be the first creator to go live right now and share your story.',
            textAlign: TextAlign.center,
            style: dm(sz: 12, c: C.dim),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _startBroadcasting,
            icon: const Icon(Icons.add, size: 16, color: C.brand),
            label: Text(
              'Start Broadcasting',
              style: dm(sz: 12, w: FontWeight.w700, c: C.brand),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: C.brand.withValues(alpha: 0.5)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStreamsGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 500 ? 2 : 1;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.35,
          ),
          itemCount: _activeStreams.length,
          itemBuilder: (context, index) {
            final stream = _activeStreams[index];
            return _buildStreamCard(stream);
          },
        );
      },
    );
  }

  Widget _buildStreamCard(Map<String, dynamic> stream) {
    final hostName = (stream['hostName'] ??
            (stream['metadata'] as Map?)?['hostName'] ??
            'Creator')
        .toString();
    final avatar = (stream['avatar'] ??
            (stream['metadata'] as Map?)?['avatar'])
        ?.toString();
    final viewerCount = (stream['viewerCount'] as num?)?.toInt() ?? 1;
    final topic = (stream['topic'] ?? stream['title'] ?? 'Live Broadcast')
        .toString();

    return GestureDetector(
      onTap: () => _watchStream(stream),
      child: Container(
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: C.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Background gradient
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF1B2838),
                    Color(0xFF090D16),
                  ],
                ),
              ),
            ),
            // Content
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF2D55),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 5,
                              height: 5,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'LIVE',
                              style: syne(
                                sz: 9,
                                w: FontWeight.w900,
                                c: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.visibility_rounded,
                              size: 11,
                              color: Colors.white70,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$viewerCount',
                              style: dm(
                                sz: 10,
                                w: FontWeight.w600,
                                c: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        topic,
                        style: syne(sz: 13, w: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: C.brand, width: 1),
                              image: avatar != null
                                  ? DecorationImage(
                                      image: CachedNetworkImageProvider(avatar),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child: avatar == null
                                ? const Icon(
                                    Icons.person,
                                    size: 12,
                                    color: C.brand,
                                  )
                                : null,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              hostName,
                              style: dm(sz: 11, c: Colors.white70),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
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
}
