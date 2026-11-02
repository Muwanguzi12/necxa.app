import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart';
import 'dart:ui';
import 'dart:math' as math;

class PublicProfileScreen extends StatefulWidget {
  final AppState state;
  const PublicProfileScreen({super.key, required this.state});

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

String resolvePublicProfileName(Profile profile, AppState state) {
  final isMe = state.user?.id == profile.id;
  final fn = profile.fullName?.trim();
  if (fn != null && fn.isNotEmpty && fn != 'NECXA NODE' && fn != 'Necxa User' && fn != 'Necxa Member') {
    return fn;
  }
  if (isMe) {
    final myFn = state.myProfile?['full_name']?.toString().trim();
    if (myFn != null && myFn.isNotEmpty && myFn != 'NECXA NODE') return myFn;
    final metaFn = state.user?.userMetadata?['full_name']?.toString().trim() ??
        state.user?.userMetadata?['display_name']?.toString().trim() ??
        state.user?.userMetadata?['name']?.toString().trim();
    if (metaFn != null && metaFn.isNotEmpty) return metaFn;
  }
  final un = profile.username.trim();
  if (un.isNotEmpty && un != 'node' && un != 'user' && un != 'member') {
    return un;
  }
  if (isMe && state.user?.email != null) {
    return state.user!.email!.split('@').first;
  }
  return 'Member';
}

class _PublicProfileScreenState extends State<PublicProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _hasListings = false;
  int? _localFollowerDelta;
  bool? _isLocallyFollowing;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _checkVendorStatus();
  }

  void _checkVendorStatus() async {
    final targetId = widget.state.targetProfileId ?? 'c1';
    final listings = await widget.state.social.fetchUserListings(targetId);
    if (mounted && listings.isNotEmpty) {
      setState(() => _hasListings = true);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _handleFollowToggle(Profile profile, bool currentlyFollowing) async {
    final willFollow = !currentlyFollowing;
    setState(() {
      _isLocallyFollowing = willFollow;
      _localFollowerDelta = (_localFollowerDelta ?? 0) + (willFollow ? 1 : -1);
    });
    try {
      await widget.state.social.toggleFollow(profile.id);
      widget.state.toggleFollow(profile.id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLocallyFollowing = currentlyFollowing;
          _localFollowerDelta = (_localFollowerDelta ?? 0) + (willFollow ? -1 : 1);
        });
      }
    }
  }

  void _showProfileActions(BuildContext context, Profile profile) {
    final isMe = widget.state.user?.id == profile.id;
    final displayName = resolvePublicProfileName(profile, widget.state);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _PublicProfileOptionsSheet(
        profile: profile,
        displayName: displayName,
        isMe: isMe,
        state: widget.state,
        onFollowToggle: () => _handleFollowToggle(
          profile,
          _isLocallyFollowing ?? widget.state.followed.contains(profile.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final targetId = widget.state.targetProfileId ?? 'c1';
    return FutureBuilder<Profile?>(
      future: widget.state.getProfile(targetId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            backgroundColor: C.bg,
            body: Center(child: CircularProgressIndicator(color: C.brand)),
          );
        }
        final profile = snapshot.data;
        if (profile == null) {
          return Scaffold(
            backgroundColor: C.bg,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                onPressed: () => widget.state.goBack(),
              ),
            ),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.person_off_outlined, color: C.dim, size: 48),
                  const SizedBox(height: 12),
                  Text('PROFILE NOT FOUND', style: syne(c: C.brand, sz: 14, w: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('The requested profile could not be loaded.', style: dm(c: C.dim, sz: 12)),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => setState(() {}),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry'),
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

        final isFollowing = _isLocallyFollowing ?? widget.state.followed.contains(profile.id);
        final isFriend = widget.state.isFriendSync(profile.id);
        final isMe = widget.state.user?.id == profile.id;
        final effectiveFollowers = (profile.followersCount + (_localFollowerDelta ?? 0)).clamp(0, 999999999);

        return Scaffold(
          backgroundColor: C.bg,
          body: NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) => [
              SliverToBoxAdapter(
                child: _ProfileHeader(
                  profile: profile,
                  state: widget.state,
                  isFollowing: isFollowing,
                  isFriend: isFriend,
                  isMe: isMe,
                  effectiveFollowers: effectiveFollowers,
                  onBack: () => widget.state.goBack(),
                  onOptions: () => _showProfileActions(context, profile),
                  onFollow: () => _handleFollowToggle(profile, isFollowing),
                  onMessage: () => widget.state.openCreatorChat(
                    profile.id,
                    resolvePublicProfileName(profile, widget.state),
                    profile.avatarUrl,
                  ),
                  onEdit: () => widget.state.go('profile'),
                ),
              ),
            ],
            body: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  color: C.bg,
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFF070E22),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.25)),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: TabBar(
                      controller: _tabController,
                      indicator: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF00E5FF), Color(0xFFD946EF)],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00E5FF).withOpacity(0.35),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      indicatorSize: TabBarIndicatorSize.tab,
                      dividerColor: Colors.transparent,
                      labelStyle: syne(sz: 13, w: FontWeight.w900, ls: 1),
                      unselectedLabelStyle: syne(sz: 13, w: FontWeight.w700, ls: 1),
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white70,
                      tabs: [
                        Tab(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(Icons.play_arrow_rounded, size: 20),
                              SizedBox(width: 6),
                              Text('CONTENT'),
                            ],
                          ),
                        ),
                        Tab(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(Icons.grid_view_rounded, size: 17),
                              SizedBox(width: 6),
                              Text('FEED'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildShowcaseGrid(),
                      _buildContentGrid(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildShowcaseGrid() {
    final targetId = widget.state.targetProfileId ?? 'c1';
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: widget.state.social.fetchUserListings(targetId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: C.brand));
        }
        final list = snapshot.data ?? [];
        if (list.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.inventory_2_outlined, color: C.dim, size: 36),
                const SizedBox(height: 10),
                Text('NO PRODUCTS LISTED', style: syne(sz: 11, c: C.dim, ls: 2)),
              ],
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(20),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 0.75,
          ),
          itemCount: list.length,
          itemBuilder: (context, index) => _ProductGridItem(listing: list[index], state: widget.state),
        );
      },
    );
  }

  Widget _buildContentGrid() {
    final targetId = widget.state.targetProfileId ?? 'c1';
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: widget.state.social.fetchUserPosts(targetId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: C.brand));
        }
        final list = snapshot.data ?? [];
        if (list.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.dynamic_feed_outlined, color: C.dim, size: 36),
                const SizedBox(height: 10),
                Text('NO POSTS YET', style: syne(sz: 11, c: C.dim, ls: 2)),
              ],
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(20),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 0.8,
          ),
          itemCount: list.length,
          itemBuilder: (context, index) => _GridItem(data: list[index], state: widget.state),
        );
      },
    );
  }
}

// ── Profile Header (all top content above tabs) ───────────────────────────────

class _ProfileHeader extends StatelessWidget {
  final Profile profile;
  final AppState state;
  final bool isFollowing;
  final bool isFriend;
  final bool isMe;
  final int effectiveFollowers;
  final VoidCallback onBack;
  final VoidCallback onOptions;
  final VoidCallback onFollow;
  final VoidCallback onMessage;
  final VoidCallback onEdit;

  const _ProfileHeader({
    required this.profile,
    required this.state,
    required this.isFollowing,
    required this.isFriend,
    required this.isMe,
    required this.effectiveFollowers,
    required this.onBack,
    required this.onOptions,
    required this.onFollow,
    required this.onMessage,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = resolvePublicProfileName(profile, state);
    final hasBio = profile.bio != null && profile.bio!.trim().isNotEmpty;
    final bioText = hasBio
        ? profile.bio!
        : 'Welcome to my profile! Feel free to connect, message, and explore my listings and posts.';
    final reputationScore = (profile.reputation > 0)
        ? profile.reputation.toStringAsFixed(1)
        : (profile.trustScore > 0 ? (profile.trustScore / 10).toStringAsFixed(1) : '5.0');
    final topPad = MediaQuery.of(context).padding.top;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Banner with HUD and Earth/Network Globe ─────────────────
        Stack(
          clipBehavior: Clip.none,
          children: [
            _NodeBanner(topPad: topPad),
            Positioned(
              top: topPad + 10,
              left: 16,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _HUDButton(icon: Icons.arrow_back_ios_new, onTap: onBack),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Color(0xFF00E5FF), Color(0xFF9D00FF)]),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: const Icon(Icons.view_in_ar_rounded, size: 14, color: Colors.white),
                      ),
                      const SizedBox(width: 8),
                      Text('PUBLIC NODE',
                          style: syne(sz: 13, w: FontWeight.w900, ls: 2, c: C.brand)),
                    ],
                  ),
                  _HUDButton(icon: Icons.more_horiz, onTap: onOptions),
                ],
              ),
            ),
          ],
        ),

        // ── Overlapping Avatar + Adjacent Name & Username Row ───────
        Transform.translate(
          offset: const Offset(0, -36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Avatar on the LEFT with glowing ring and verified badge
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _AvatarContainer(url: profile.avatarUrl, size: 84),
                        if (profile.verified || profile.trustScoreTier == 'titan_trust' || profile.aiVerified)
                          Positioned(
                            bottom: -2,
                            right: -2,
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Color(0xFF030712),
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(2),
                              child: const Icon(
                                Icons.verified,
                                color: Color(0xFF00E5FF),
                                size: 22,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 16),

                    // Adjacent Name + @username + Tier Badge on the RIGHT
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displayName.toUpperCase(),
                            style: syne(sz: 21, w: FontWeight.w900, fs: FontStyle.italic, ls: -0.5),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Text('@', style: dm(sz: 13, c: const Color(0xFF00E5FF))),
                              Flexible(
                                child: Text(
                                  profile.username,
                                  style: dm(sz: 13, w: FontWeight.w700, c: const Color(0xFF00E5FF)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00E5FF).withValues(alpha: .08),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: .3)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.view_in_ar_rounded, size: 10, color: Color(0xFF00E5FF)),
                                    const SizedBox(width: 4),
                                    Text(
                                      (profile.trustScoreTier ?? 'STANDARD NODE').toUpperCase().replaceAll('_', ' '),
                                      style: dm(sz: 9, w: FontWeight.w800, ls: 0.5, c: const Color(0xFF00E5FF)),
                                    ),
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

                const SizedBox(height: 12),

                // ── Bio text (Full width, italic) ──────────────────────
                Text(
                  bioText,
                  style: dm(sz: 12.5, fs: FontStyle.italic, c: C.text.withValues(alpha: .75), h: 1.45),
                ),

                const SizedBox(height: 16),

                // ── Action Buttons ─────────────────────────────────────
                if (!isMe)
                  Row(
                    children: [
                      // Message button
                      Expanded(
                        child: GestureDetector(
                          onTap: onMessage,
                          child: Container(
                            height: 48,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: [Color(0xFF00E5FF), Color(0xFF9D00FF)]),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF00E5FF).withValues(alpha: .25),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.chat_bubble_outline_rounded, color: Colors.white, size: 17),
                                const SizedBox(width: 8),
                                Text('MESSAGE', style: syne(sz: 13, w: FontWeight.w900, ls: 1, c: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Following/Follow button
                      Expanded(
                        child: GestureDetector(
                          onTap: onFollow,
                          child: Container(
                            height: 48,
                            decoration: BoxDecoration(
                              color: isFollowing ? Colors.transparent : const Color(0xFF00E5FF).withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isFollowing ? const Color(0xFF00E5FF) : const Color(0xFF00E5FF).withValues(alpha: .4),
                                width: 1.5,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  isFollowing ? Icons.how_to_reg_rounded : Icons.person_add_outlined,
                                  color: const Color(0xFF00E5FF),
                                  size: 17,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  isFriend ? 'FRIENDS' : isFollowing ? 'FOLLOWING' : 'FOLLOW',
                                  style: syne(sz: 13, w: FontWeight.w900, ls: 1, c: const Color(0xFF00E5FF)),
                                ),
                                if (isFollowing) ...[
                                  const SizedBox(width: 4),
                                  const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF00E5FF), size: 16),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  GestureDetector(
                    onTap: onEdit,
                    child: Container(
                      width: double.infinity,
                      height: 48,
                      decoration: BoxDecoration(
                        color: C.brand.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: C.brand.withValues(alpha: .4)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.edit_outlined, size: 16, color: C.brand),
                          const SizedBox(width: 8),
                          Text('EDIT PROFILE', style: syne(sz: 13, w: FontWeight.w900, ls: 1, c: C.brand)),
                        ],
                      ),
                    ),
                  ),

                const SizedBox(height: 14),

                // ── Stats Row ──────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                  decoration: BoxDecoration(
                    color: C.text.withValues(alpha: .03),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: C.text.withValues(alpha: .06)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _StatItem(
                        icon: Icons.people_alt_rounded,
                        label: 'FOLLOWERS',
                        value: kNum(effectiveFollowers),
                        color: const Color(0xFF00E5FF),
                      ),
                      _StatDivider(),
                      _StatItem(
                        icon: Icons.favorite_rounded,
                        label: 'LIKES',
                        value: kNum(profile.likesCount),
                        color: const Color(0xFFA855F7),
                      ),
                      _StatDivider(),
                      _StatItem(
                        icon: Icons.play_circle_outline_rounded,
                        label: 'POSTS',
                        value: profile.postsCount.toString(),
                        color: const Color(0xFF10B981),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // ── Node Overview Card ─────────────────────────────────
                Container(
                  decoration: BoxDecoration(
                    color: C.text.withValues(alpha: .03),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: C.text.withValues(alpha: .06)),
                  ),
                  child: Column(
                    children: [
                      // Header row
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(7),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00E5FF).withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.view_in_ar_rounded, color: Color(0xFF00E5FF), size: 16),
                            ),
                            const SizedBox(width: 10),
                            Text('NODE OVERVIEW', style: syne(sz: 13, w: FontWeight.w900, ls: 1)),
                            const Spacer(),
                            GestureDetector(
                              onTap: () => _showNodeDetailsSheet(context, profile, bioText, reputationScore),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: C.text.withValues(alpha: .04),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: C.text.withValues(alpha: .08)),
                                ),
                                child: Text('VIEW MORE ›', style: dm(sz: 9, w: FontWeight.w800, ls: 1, c: const Color(0xFF00E5FF))),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Polyhedron + Bio Body
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 58,
                              height: 58,
                              child: CustomPaint(painter: _GeodesicSpherePainter()),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                bioText,
                                style: dm(sz: 12.5, c: C.text.withValues(alpha: .75), h: 1.45),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Reputation + Trust score progress bars
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: _MetricProgressBar(
                                label: 'REPUTATION',
                                value: '$reputationScore / 10',
                                progress: ((double.tryParse(reputationScore) ?? 5.0) / 10.0).clamp(0.0, 1.0),
                                color: const Color(0xFF00E5FF),
                                icon: Icons.star_rounded,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _MetricProgressBar(
                                label: 'TRUST SCORE',
                                value: '${profile.trustScore}%',
                                progress: (profile.trustScore / 100.0).clamp(0.0, 1.0),
                                color: const Color(0xFFA855F7),
                                icon: Icons.verified_user_rounded,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Badges row
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            _SysBadge(
                              icon: Icons.location_on_outlined,
                              label: (profile.district != null && profile.district!.isNotEmpty)
                                  ? profile.district!.toUpperCase()
                                  : 'EAST AFRICA',
                            ),
                            _VertDivider(),
                            _SysBadge(
                              icon: Icons.calendar_today_rounded,
                              label: '${profile.createdAt.year}',
                            ),
                            _VertDivider(),
                            _SysBadge(
                              icon: Icons.workspace_premium_rounded,
                              label: (profile.trustScoreTier ?? 'STANDARD').toUpperCase().replaceAll('_', ' '),
                              color: const Color(0xFFA855F7),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),
                    ],
                  ),
                ),

                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showNodeDetailsSheet(
    BuildContext context,
    Profile profile,
    String bioText,
    String reputationScore,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            decoration: BoxDecoration(
              color: C.bg.withValues(alpha: .94),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(color: C.text.withValues(alpha: .1)),
            ),
            padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(ctx).padding.bottom + 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: C.dim.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: C.brand.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.badge_outlined, color: C.brand, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('PROFILE DETAILS', style: syne(sz: 15, w: FontWeight.w900)),
                        Text('Member overview and account status',
                            style: dm(sz: 11, c: C.dim)),
                      ],
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Divider(color: C.text.withValues(alpha: .06)),
                const SizedBox(height: 12),
                Text('ABOUT', style: dm(sz: 10, w: FontWeight.w800, ls: 1, c: C.dim)),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: C.text.withValues(alpha: .03),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: C.text.withValues(alpha: .06)),
                  ),
                  child: Text(
                    bioText,
                    style: dm(sz: 13, c: C.text.withValues(alpha: .85), h: 1.5),
                  ),
                ),
                const SizedBox(height: 16),
                Text('ACCOUNT METRICS', style: dm(sz: 10, w: FontWeight.w800, ls: 1, c: C.dim)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _MetricDetailBox(
                        title: 'REPUTATION',
                        value: '$reputationScore / 10',
                        color: Colors.amber,
                        icon: Icons.star_rounded,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MetricDetailBox(
                        title: 'TRUST SCORE',
                        value: '${profile.trustScore}%',
                        color: C.purple,
                        icon: Icons.verified_user_rounded,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _MetricDetailBox(
                        title: 'ACCOUNT LEVEL',
                        value: (profile.trustScoreTier ?? 'STANDARD').toUpperCase().replaceAll('_', ' '),
                        color: C.brand,
                        icon: Icons.shield_outlined,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MetricDetailBox(
                        title: 'VERIFICATION',
                        value: profile.aiVerified ? 'VERIFIED' : 'STANDARD',
                        color: profile.aiVerified ? C.purple : C.dim,
                        icon: Icons.lock_outline_rounded,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Node Banner (hero background) ────────────────────────────────────────────

class _NodeBanner extends StatelessWidget {
  final double topPad;
  const _NodeBanner({required this.topPad});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: topPad + 130,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Cyber deep space gradient
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF030712),
                  Color(0xFF081229),
                  Color(0xFF0D1B3E),
                ],
              ),
            ),
          ),
          // Glow orbs
          Positioned(
            right: -20,
            top: -20,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF00E5FF).withValues(alpha: .18),
                    const Color(0xFF1E3A8A).withValues(alpha: .12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          // Earth/Tech globe CustomPaint
          Positioned.fill(
            child: CustomPaint(painter: _EarthGlobePainter()),
          ),
          // Bottom fade to bg
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 50,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, C.bg],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 3D Earth / Tech Globe Banner Painter ─────────────────────────────────────

class _EarthGlobePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * 0.78;
    final cy = size.height * 0.45;
    final r = size.height * 0.55;

    final globeGlow = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF00E5FF).withValues(alpha: .25),
          const Color(0xFF1E3A8A).withValues(alpha: .15),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r * 1.3));
    canvas.drawCircle(Offset(cx, cy), r * 1.25, globeGlow);

    final arcPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: .18)
      ..strokeWidth = 0.9
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: .4)
      ..style = PaintingStyle.fill;

    // Draw latitude ellipses
    for (double i = -0.7; i <= 0.7; i += 0.35) {
      final yOffset = cy + i * r;
      final radAtY = math.sqrt(math.max(0.0, r * r - (yOffset - cy) * (yOffset - cy)));
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, yOffset), width: radAtY * 2, height: radAtY * 0.6),
        arcPaint,
      );
    }

    // Draw longitude ellipses
    for (double i = 0.2; i <= 1.0; i += 0.35) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, cy), width: r * 2 * i, height: r * 2),
        arcPaint,
      );
    }

    // Network node dots & connecting arcs
    final pts = [
      Offset(cx - r * 0.4, cy - r * 0.2),
      Offset(cx - r * 0.1, cy - r * 0.5),
      Offset(cx + r * 0.3, cy - r * 0.3),
      Offset(cx + r * 0.5, cy + r * 0.1),
      Offset(cx + r * 0.2, cy + r * 0.4),
      Offset(cx - r * 0.2, cy + r * 0.3),
    ];
    final linePaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: .22)
      ..strokeWidth = 0.8;
    for (int i = 0; i < pts.length; i++) {
      canvas.drawLine(pts[i], pts[(i + 1) % pts.length], linePaint);
      canvas.drawCircle(pts[i], 2.2, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── 3D Geodesic Polyhedron Sphere Painter ─────────────────────────────────────

class _GeodesicSpherePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.42;

    // Outer glow
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF00E5FF).withValues(alpha: .25),
          const Color(0xFF9D00FF).withValues(alpha: .12),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r * 1.2));
    canvas.drawCircle(Offset(cx, cy), r * 1.15, glowPaint);

    final linePaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: .65)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final innerLinePaint = Paint()
      ..color = const Color(0xFF9D00FF).withValues(alpha: .45)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    final nodePaint = Paint()
      ..color = const Color(0xFF00E5FF)
      ..style = PaintingStyle.fill;

    // 3D vertices of an icosahedron
    final phi = (1.0 + math.sqrt(5.0)) / 2.0;
    final rawVertices = [
      [-1.0,  phi,  0.0],
      [ 1.0,  phi,  0.0],
      [-1.0, -phi,  0.0],
      [ 1.0, -phi,  0.0],
      [ 0.0, -1.0,  phi],
      [ 0.0,  1.0,  phi],
      [ 0.0, -1.0, -phi],
      [ 0.0,  1.0, -phi],
      [ phi,  0.0, -1.0],
      [ phi,  0.0,  1.0],
      [-phi,  0.0, -1.0],
      [-phi,  0.0,  1.0],
    ];

    // Isometric rotation
    const angleX = 0.45;
    const angleY = 0.65;
    final cosX = math.cos(angleX);
    final sinX = math.sin(angleX);
    final cosY = math.cos(angleY);
    final sinY = math.sin(angleY);

    final pts2d = <Offset>[];
    final zVals = <double>[];

    for (final v in rawVertices) {
      final len = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
      final x = v[0] / len;
      final y = v[1] / len;
      final z = v[2] / len;

      final x1 = x * cosY + z * sinY;
      final z1 = -x * sinY + z * cosY;

      final y2 = y * cosX - z1 * sinX;
      final z2 = y * sinX + z1 * cosX;

      pts2d.add(Offset(cx + x1 * r, cy + y2 * r));
      zVals.add(z2);
    }

    // Connect vertices
    for (int i = 0; i < rawVertices.length; i++) {
      for (int j = i + 1; j < rawVertices.length; j++) {
        final dx = rawVertices[i][0] - rawVertices[j][0];
        final dy = rawVertices[i][1] - rawVertices[j][1];
        final dz = rawVertices[i][2] - rawVertices[j][2];
        final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
        if ((dist - 2.0).abs() < 0.2) {
          final isFront = (zVals[i] + zVals[j]) > -0.2;
          canvas.drawLine(pts2d[i], pts2d[j], isFront ? linePaint : innerLinePaint);
        }
      }
    }

    // Draw glowing nodes on front vertices
    for (int i = 0; i < pts2d.length; i++) {
      if (zVals[i] > -0.2) {
        canvas.drawCircle(pts2d[i], 2.2, nodePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Metric Progress Bar ───────────────────────────────────────────────────────

class _MetricProgressBar extends StatelessWidget {
  final String label;
  final String value;
  final double progress;
  final Color color;
  final IconData icon;

  const _MetricProgressBar({
    required this.label,
    required this.value,
    required this.progress,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: C.text.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.text.withValues(alpha: .06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: dm(sz: 9, w: FontWeight.w800, ls: 0.5, c: C.dim),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                value,
                style: syne(sz: 11, w: FontWeight.w800, c: color),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: C.text.withValues(alpha: .08),
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 5,
            ),
          ),
        ],
      ),
    );
  }
}


class _MetricDetailBox extends StatelessWidget {
  final String title;
  final String value;
  final Color color;
  final IconData icon;

  const _MetricDetailBox({
    required this.title,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: C.text.withValues(alpha: .03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.text.withValues(alpha: .06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(title, style: dm(sz: 9, w: FontWeight.w800, c: C.dim)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: syne(sz: 13, w: FontWeight.w900, c: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ── System badge (location / date / tier) ─────────────────────────────────────

class _SysBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _SysBadge({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? C.dim;
    return Expanded(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 11, color: c),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: dm(sz: 9, w: FontWeight.w700, c: c),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _VertDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 24, color: C.text.withValues(alpha: .06));
}

// ── Three-Dots Actions Bottom Sheet ──────────────────────────────────────────

class _PublicProfileOptionsSheet extends StatelessWidget {
  final Profile profile;
  final String displayName;
  final bool isMe;
  final AppState state;
  final VoidCallback onFollowToggle;

  const _PublicProfileOptionsSheet({
    required this.profile,
    required this.displayName,
    required this.isMe,
    required this.state,
    required this.onFollowToggle,
  });

  void _shareProfile(BuildContext context) {
    Navigator.pop(context);
    SharePlus.instance.share(
      ShareParams(
        text: 'Check out @${profile.username} on Necxa Financial Network: https://goobox.necxa.uk/@${profile.username}',
        subject: '$displayName on Necxa',
      ),
    );
  }

  Future<void> _copyLink(BuildContext context) async {
    final link = 'https://goobox.necxa.uk/@${profile.username}';
    await Clipboard.setData(ClipboardData(text: link));
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: C.card,
          behavior: SnackBarBehavior.floating,
          content: Row(
            children: [
              Icon(Icons.link, color: C.brand, size: 18),
              const SizedBox(width: 8),
              Text('Profile link copied!', style: dm(c: C.text)),
            ],
          ),
        ),
      );
    }
  }

  void _openMessage(BuildContext context) {
    Navigator.pop(context);
    state.openCreatorChat(profile.id, displayName, profile.avatarUrl);
  }

  void _sendGift(BuildContext context) {
    Navigator.pop(context);
    final senderId = state.user?.id;
    if (senderId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: C.card,
          content: Text('Please sign in to send a gift.', style: dm(c: C.text)),
        ),
      );
      return;
    }
    _showGiftSelectionSheet(context);
  }

  void _showGiftSelectionSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: C.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: C.text.withValues(alpha: .1)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.card_giftcard, color: Colors.amberAccent, size: 20),
                const SizedBox(width: 8),
                Text('Send Gift to @${profile.username}', style: syne(sz: 16, w: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ('💎', 'Diamond', 100),
                ('🚀', 'Rocket', 500),
                ('👑', 'Crown', 1000),
                ('⭐', 'Star', 50),
                ('⚡', 'Spark', 20),
              ].map((g) => GestureDetector(
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await state.sendGift(
                      g.$1, g.$2, g.$3, (g.$3 * 0.05).round(),
                      receiverId: profile.id,
                      contextType: 'public_profile',
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          backgroundColor: C.card,
                          content: Text('Sent ${g.$1} ${g.$2} to @${profile.username}!', style: dm(c: C.brand)),
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          backgroundColor: C.card,
                          content: Text('Could not send gift: $e', style: dm(c: Colors.redAccent)),
                        ),
                      );
                    }
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: C.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: C.dim.withValues(alpha: .3)),
                  ),
                  child: Column(
                    children: [
                      Text(g.$1, style: const TextStyle(fontSize: 28)),
                      const SizedBox(height: 4),
                      Text(g.$2, style: syne(sz: 11, w: FontWeight.w600)),
                      Text('${g.$3} NCX', style: dm(sz: 10, c: C.brand)),
                    ],
                  ),
                ),
              )).toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _muteNode(BuildContext context) async {
    Navigator.pop(context);
    await state.social.hideContent(profile.id, 'profile');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: C.card,
          behavior: SnackBarBehavior.floating,
          content: Text('Posts from @${profile.username} muted.', style: dm(c: C.text)),
        ),
      );
    }
  }

  void _blockNode(BuildContext context) async {
    Navigator.pop(context);
    await state.blockUser(profile.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: C.card,
          behavior: SnackBarBehavior.floating,
          content: Text('@${profile.username} blocked. You will no longer see their content.', style: dm(c: Colors.redAccent)),
        ),
      );
      state.goBack();
    }
  }

  void _unblockNode(BuildContext context) async {
    await state.unblockUser(profile.id);
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: C.card,
          behavior: SnackBarBehavior.floating,
          content: Text('@${profile.username} unblocked.', style: dm(c: C.brand)),
        ),
      );
    }
  }

  void _showReportDialog(BuildContext context) {
    Navigator.pop(context);
    final reasons = [
      'Spam or Scam',
      'Inappropriate Content',
      'Fake Account or Impersonation',
      'Harassment or Offensive Behavior',
      'Other Violation',
    ];
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: C.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: C.dim),
        ),
        title: Row(
          children: [
            Icon(Icons.flag_outlined, color: Colors.redAccent, size: 20),
            const SizedBox(width: 8),
            Text('Report Account', style: syne(sz: 16, w: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Select a reason for reporting @${profile.username}:', style: dm(sz: 12, c: C.dim)),
            const SizedBox(height: 12),
            ...reasons.map(
              (r) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(r, style: dm(sz: 13, c: C.text)),
                onTap: () async {
                  Navigator.pop(dialogCtx);
                  await state.social.reportContent(profile.id, 'profile', r);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: C.card,
                        behavior: SnackBarBehavior.floating,
                        content: Text('Report submitted. Our team is reviewing this account.', style: dm(c: C.brand)),
                      ),
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: C.bg.withValues(alpha: .92),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: C.text.withValues(alpha: .1)),
          ),
          padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle pill
              Center(
                child: Container(
                  width: 44, height: 4,
                  decoration: BoxDecoration(
                    color: C.dim.withValues(alpha: .5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // Header summary
              Row(
                children: [
                  _AvatarContainer(url: profile.avatarUrl, size: 48),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(displayName, style: syne(sz: 16, w: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text('@${profile.username}', style: dm(sz: 13, w: FontWeight.w600, c: C.brand)),
                        const SizedBox(height: 4),
                        Text('${profile.trustScore}% Trust • ${profile.followersCount} Followers', style: dm(sz: 11, c: C.dim)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Divider(color: C.text.withValues(alpha: .06)),
              const SizedBox(height: 8),

              // Options
              _OptionTile(icon: Icons.share_outlined, label: 'Share Profile', color: C.brand, onTap: () => _shareProfile(context)),
              _OptionTile(icon: Icons.link_rounded, label: 'Copy Profile Link', color: C.purple, onTap: () => _copyLink(context)),

              if (!isMe) ...[
                _OptionTile(icon: Icons.chat_bubble_outline_rounded, label: 'Send Message', color: C.brand, onTap: () => _openMessage(context)),
                _OptionTile(icon: Icons.card_giftcard_rounded, label: 'Send Gift', color: Colors.amberAccent, onTap: () => _sendGift(context)),
                _OptionTile(icon: Icons.volume_off_outlined, label: 'Mute Posts', color: C.dim, onTap: () => _muteNode(context)),
                if (state.isBlocked(profile.id))
                  _OptionTile(icon: Icons.lock_open_rounded, label: 'Unblock User', color: Colors.orangeAccent, onTap: () => _unblockNode(context))
                else
                  _OptionTile(icon: Icons.block_rounded, label: 'Block User', color: Colors.redAccent, onTap: () => _blockNode(context)),
                _OptionTile(icon: Icons.flag_outlined, label: 'Report Account', color: Colors.redAccent, onTap: () => _showReportDialog(context)),
              ] else ...[
                _OptionTile(
                  icon: Icons.edit_note_rounded,
                  label: 'Edit Profile Settings',
                  color: C.brand,
                  onTap: () {
                    Navigator.pop(context);
                    state.go('profile');
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}


// ── Option Tile ───────────────────────────────────────────────────────────────

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _OptionTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(label, style: syne(sz: 13, w: FontWeight.w600, c: C.text))),
              Icon(Icons.chevron_right_rounded, color: C.dim, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Showcase Product Tile ─────────────────────────────────────────────────────

class _ProductGridItem extends StatelessWidget {
  final Map<String, dynamic> listing;
  final AppState state;
  const _ProductGridItem({required this.listing, required this.state});

  @override
  Widget build(BuildContext context) {
    final photos = listing['photos'] as List? ?? [];
    final url = photos.isNotEmpty ? photos[0] : listing['media_url'];
    final price = listing['price'] ?? 0;

    return GestureDetector(
      onTap: () {
        state.pendingCheckoutListing = listing;
        state.go('community');
      },
      child: Container(
        decoration: BoxDecoration(
          color: C.text.withValues(alpha: .05),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: C.text.withValues(alpha: .1)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              Positioned.fill(
                child: url != null
                    ? Image.network(url, fit: BoxFit.cover,
                        errorBuilder: (c, e, s) =>
                            Container(color: C.card, child: Icon(Icons.broken_image, color: C.dim)))
                    : Container(color: C.dim, child: Icon(Icons.shopping_bag, color: C.dim)),
              ),
              Positioned(
                bottom: 12, left: 12, right: 12,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      color: Colors.black45,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(ugx(price.toDouble()),
                                style: syne(sz: 14, w: FontWeight.w900, c: C.brand),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          Icon(Icons.bolt, color: C.brand, size: 14),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (listing['media_url'] != null)
                Positioned(
                  top: 12, right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      children: [
                        Icon(Icons.play_circle_fill, color: C.text, size: 12),
                        const SizedBox(width: 4),
                        Text('VIDEO', style: syne(sz: 8, w: FontWeight.w900, c: C.text)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Avatar ────────────────────────────────────────────────────────────────────

class _AvatarContainer extends StatelessWidget {
  final String? url;
  final double size;
  const _AvatarContainer({this.url, this.size = 84});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF00E5FF), Color(0xFF9D00FF)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withValues(alpha: .4),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      padding: const EdgeInsets.all(3),
      child: Container(
        decoration: BoxDecoration(
          color: C.bg,
          shape: BoxShape.circle,
        ),
        padding: const EdgeInsets.all(3),
        child: ClipOval(
          child: url != null
              ? Image.network(
                  url!,
                  fit: BoxFit.cover,
                  errorBuilder: (c, e, s) => Center(child: Icon(Icons.person, color: C.brand, size: size * .45)),
                )
              : Center(child: Icon(Icons.person, color: C.dim, size: size * .45)),
        ),
      ),
    );
  }
}

// ── Stat Item ─────────────────────────────────────────────────────────────────

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final Color color;
  const _StatItem({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(icon, color: color, size: 18),
      const SizedBox(height: 6),
      Text(value, style: syne(sz: 17, w: FontWeight.w900, fs: FontStyle.italic, c: color)),
      const SizedBox(height: 4),
      Text(label, style: dm(sz: 9, w: FontWeight.w800, ls: 1, c: C.dim)),
    ],
  );
}

class _StatDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 36, color: C.dim.withValues(alpha: .2));
}

// ── Grid item ─────────────────────────────────────────────────────────────────

class _GridItem extends StatelessWidget {
  final Map<String, dynamic> data;
  final AppState state;
  const _GridItem({required this.data, required this.state});

  @override
  Widget build(BuildContext context) {
    final isVideo = data['media_type'] == 'video';
    final mediaUrl = data['media_url'] as String?;
    final thumbUrl = data['thumbnail_url'] as String?;
    final likes = data['likes_count'] ?? 0;

    return GestureDetector(
      onTap: () => state.go('community', extra: data['id']),
      child: Container(
        decoration: BoxDecoration(
          color: C.text.withValues(alpha: .05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: C.text.withValues(alpha: .1)),
          image: (thumbUrl != null || mediaUrl != null)
              ? DecorationImage(
                  image: NetworkImage(thumbUrl ?? mediaUrl!),
                  fit: BoxFit.cover,
                  colorFilter: isVideo
                      ? ColorFilter.mode(Colors.black.withValues(alpha: 0.3), BlendMode.darken)
                      : null,
                )
              : null,
        ),
        child: Stack(
          children: [
            if (isVideo) Center(child: Icon(Icons.play_arrow_rounded, color: C.sub, size: 40)),
            Positioned(
              bottom: 12, left: 12,
              child: Row(
                children: [
                  Icon(Icons.favorite, color: C.text, size: 12),
                  const SizedBox(width: 4),
                  Text(kNum(likes is num ? likes.toInt() : 0), style: dm(sz: 10, w: FontWeight.w800, c: C.text)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── HUD Button ───────────────────────────────────────────────────────────────

class _HUDButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _HUDButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: .12)),
      ),
      child: Icon(icon, color: Colors.white, size: 18),
    ),
  );
}
