import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart';
import 'dart:ui';

class PublicProfileScreen extends StatefulWidget {
  final AppState state;
  const PublicProfileScreen({super.key, required this.state});

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> with SingleTickerProviderStateMixin {
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
      // Revert if failed
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
    final displayName = (profile.fullName != null && profile.fullName!.trim().isNotEmpty)
        ? profile.fullName!
        : (profile.username.isNotEmpty ? profile.username : 'NECXA NODE');

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
          return Scaffold(backgroundColor: C.bg, body: Center(child: CircularProgressIndicator(color: C.brand)));
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

        return Scaffold(
          backgroundColor: C.bg,
          body: Stack(
            children: [
              _buildAmbientGlow(),
              CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _buildIdentityHeader(profile, isFollowing, isFriend)),
                  SliverToBoxAdapter(child: _buildPublicStats(profile)),
                  SliverToBoxAdapter(child: _buildBioSection(profile)),
                  
                  // Hybrid Tab Bar
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _SliverAppBarDelegate(
                      child: Container(
                        color: C.bg,
                        child: TabBar(
                          controller: _tabController,
                          indicatorColor: C.brand,
                          labelStyle: syne(sz: 12, w: FontWeight.w900, ls: 2),
                          unselectedLabelStyle: syne(sz: 12, w: FontWeight.w700, ls: 2),
                          tabs: [
                            Tab(text: _hasListings ? 'SHOWCASE' : 'CONTENT'),
                            Tab(text: 'FEED'),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // The Grid
                  SliverFillRemaining(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildShowcaseGrid(), // Showcase (Products)
                        _buildContentGrid(),  // Standard Feed
                      ],
                    ),
                  ),
                ],
              ),
              _buildTopHUD(profile),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAmbientGlow() {
    return Positioned(
      top: -50, left: -50,
      child: Container(
        width: 300, height: 300,
        decoration: BoxDecoration(shape: BoxShape.circle, color: C.brand.withValues(alpha: .05)),
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80), child: const SizedBox()),
      ),
    );
  }

  Widget _buildTopHUD(Profile profile) {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 10, 20, 15),
            decoration: BoxDecoration(
              color: C.bg.withValues(alpha: .6),
              border: Border(bottom: BorderSide(color: C.dim)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _HUDButton(icon: Icons.arrow_back_ios_new, onTap: () => widget.state.goBack()),
                Text('PUBLIC NODE', style: syne(sz: 14, w: FontWeight.w800, ls: 4, c: C.brand)),
                _HUDButton(
                  icon: Icons.more_horiz, 
                  onTap: () => _showProfileActions(context, profile),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIdentityHeader(Profile profile, bool isFollowing, bool isFriend) {
    final displayName = (profile.fullName != null && profile.fullName!.trim().isNotEmpty)
        ? profile.fullName!
        : (profile.username.isNotEmpty ? profile.username : 'NECXA NODE');
    final isMe = widget.state.user?.id == profile.id;

    return Padding(
      padding: EdgeInsets.fromLTRB(24, MediaQuery.of(context).padding.top + 80, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _AvatarContainer(url: profile.avatarUrl),
              const Spacer(),
              if (!isMe) ...[
                GestureDetector(
                  onTap: () {
                    widget.state.openCreatorChat(
                      profile.id,
                      displayName,
                      profile.avatarUrl,
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: C.text.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: C.text.withValues(alpha: 0.1)),
                    ),
                    child: Icon(Icons.chat_bubble_outline_rounded, color: C.brand, size: 20),
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => _handleFollowToggle(profile, isFollowing),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: isFollowing ? Colors.transparent : C.brand,
                      borderRadius: BorderRadius.circular(16),
                      border: isFollowing ? Border.all(color: C.brand.withValues(alpha: .4)) : null,
                      boxShadow: isFollowing ? null : [BoxShadow(color: C.brand.withValues(alpha: .2), blurRadius: 10)],
                    ),
                    child: Text(
                      isFriend ? 'FRIENDS' : isFollowing ? 'FOLLOWING' : 'FOLLOW',
                      style: syne(sz: 12, w: FontWeight.w900, ls: 1, c: isFollowing ? C.brand : C.text),
                    ),
                  ),
                ),
              ] else ...[
                GestureDetector(
                  onTap: () => widget.state.go('profile'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    decoration: BoxDecoration(
                      color: C.brand.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: C.brand.withValues(alpha: .4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_outlined, size: 14, color: C.brand),
                        const SizedBox(width: 6),
                        Text('EDIT NODE', style: syne(sz: 12, w: FontWeight.w900, ls: 1, c: C.brand)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    displayName.toUpperCase(), 
                    style: syne(sz: 26, w: FontWeight.w900, ls: -0.5, fs: FontStyle.italic),
                  ),
                  if (profile.verified || profile.trustScoreTier == 'titan_trust')
                    Icon(Icons.verified, color: C.brand, size: 22),
                  if (profile.aiVerified)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: C.purple.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: C.purple.withValues(alpha: .4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.shield_outlined, color: C.purple, size: 11),
                          const SizedBox(width: 3),
                          Text('AI SHIELD', style: syne(sz: 9, w: FontWeight.w800, c: C.purple)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text('@${profile.username}', style: dm(sz: 14, w: FontWeight.w700, c: C.brand.withValues(alpha: .7))),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: C.text.withValues(alpha: .04),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: C.text.withValues(alpha: .08)),
                    ),
                    child: Text(
                      '${(profile.trustScoreTier ?? 'Standard').toUpperCase()} NODE',
                      style: dm(sz: 9, w: FontWeight.w800, ls: 0.5, c: C.dim),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPublicStats(Profile profile) {
    final effectiveFollowers = (profile.followersCount + (_localFollowerDelta ?? 0)).clamp(0, 999999999);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: C.text.withValues(alpha: .03),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: C.text.withValues(alpha: .05)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _StatItem(label: 'FOLLOWERS', value: kNum(effectiveFollowers), color: C.text),
            _StatSeparator(),
            _StatItem(label: 'LIKES', value: kNum(profile.likesCount), color: C.purple),
            _StatSeparator(),
            _StatItem(label: 'POSTS', value: profile.postsCount.toString(), color: C.brand),
          ],
        ),
      ),
    );
  }

  Widget _buildBioSection(Profile profile) {
    final hasBio = profile.bio != null && profile.bio!.trim().isNotEmpty;
    final bioText = hasBio
        ? profile.bio!
        : 'Decentralized commerce node on Necxa Network. Real-time asset validation and escrow-secured transmissions active.';

    final reputationScore = (profile.trustScore > 0)
        ? (profile.trustScore / 10).toStringAsFixed(1)
        : '9.8';

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.memory_rounded, size: 14, color: C.dim),
              const SizedBox(width: 6),
              Text('CORE SYSTEMS & BIO', style: dm(sz: 10, w: FontWeight.w900, ls: 2, c: C.dim)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            bioText, 
            style: dm(sz: 14, c: C.text.withValues(alpha: .75), h: 1.6),
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _MetricTag(
                  label: 'REPUTATION', 
                  value: '$reputationScore / 10', 
                  icon: Icons.star_rounded, 
                  color: C.brand,
                ),
                const SizedBox(width: 10),
                _MetricTag(
                  label: 'TRUST SCORE', 
                  value: '${profile.trustScore}%', 
                  icon: Icons.verified_user_rounded, 
                  color: C.purple,
                ),
                const SizedBox(width: 10),
                _MetricTag(
                  label: 'CORE SYSTEM', 
                  value: profile.aiVerified ? 'AI SHIELDED' : 'STANDARD L1', 
                  icon: Icons.shield_outlined, 
                  color: profile.aiVerified ? C.brand : C.dim,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SystemBadge(
                icon: Icons.location_on_outlined,
                label: (profile.district != null && profile.district!.isNotEmpty) 
                    ? profile.district!.toUpperCase() 
                    : 'EAST AFRICA',
                color: C.text.withValues(alpha: .7),
              ),
              _SystemBadge(
                icon: Icons.calendar_today_rounded,
                label: 'NODE SINCE ${profile.createdAt.year}',
                color: C.text.withValues(alpha: .5),
              ),
              if (profile.trustScoreTier != null)
                _SystemBadge(
                  icon: Icons.workspace_premium_rounded,
                  label: profile.trustScoreTier!.toUpperCase().replaceAll('_', ' '),
                  color: C.purple,
                ),
            ],
          ),
        ],
      ),
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
                 Text('NO PRODUCTS SYNCED', style: syne(sz: 11, c: C.dim, ls: 2)),
               ],
             ),
           );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(24),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 0.75,
          ),
          itemCount: list.length,
          itemBuilder: (context, index) => _ProductGridItem(listing: list[index], state: widget.state),
        );
      }
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
                 Text('NO CONTENT TRANSMISSIONS', style: syne(sz: 11, c: C.dim, ls: 2)),
               ],
             ),
           );
        }

        return GridView.builder(
          padding: const EdgeInsets.all(24),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 0.8,
          ),
          itemCount: list.length,
          itemBuilder: (context, index) => _GridItem(data: list[index], state: widget.state),
        );
      }
    );
  }
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
    Share.share(
      'Check out @${profile.username} on Necxa Financial Network: https://goobox.necxa.uk/@${profile.username}',
      subject: '$displayName on Necxa',
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
              Text('Node link copied: @${profile.username}', style: dm(c: C.text)),
            ],
          ),
        ),
      );
    }
  }

  Future<void> _copyNodeId(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: profile.id));
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: C.card,
          behavior: SnackBarBehavior.floating,
          content: Row(
            children: [
              Icon(Icons.fingerprint, color: C.purple, size: 18),
              const SizedBox(width: 8),
              Text('Node UUID copied: ${profile.id.substring(0, profile.id.length >= 8 ? 8 : profile.id.length)}...', style: dm(c: C.purple)),
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
          content: Text('Please sign in to send a gift transmission.', style: dm(c: C.text)),
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
                          content: Text('Gift transmission deferred: $e', style: dm(c: Colors.redAccent)),
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
          content: Text('Transmissions from @${profile.username} muted.', style: dm(c: C.text)),
        ),
      );
    }
  }

  void _blockNode(BuildContext context) async {
    Navigator.pop(context); // close options sheet
    await state.blockUser(profile.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: C.card,
          behavior: SnackBarBehavior.floating,
          content: Text('@${profile.username} blocked. You will no longer see their content.', style: dm(c: Colors.redAccent)),
        ),
      );
      // Navigate back — can't stay on a blocked profile
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
      'Spam or Fraudulent Activity',
      'Illicit or Prohibited Items',
      'Impersonation of Node Identity',
      'Harassment or Offensive Behavior',
      'Intellectual Property Infringement',
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
            Text('Report Node', style: syne(sz: 16, w: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Select transmission violation reason for @${profile.username}:', style: dm(sz: 12, c: C.dim)),
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
                        content: Text('Report logged. Necxa Shield AI is reviewing this node.', style: dm(c: C.brand)),
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
                  width: 44,
                  height: 4,
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
                  _AvatarContainer(url: profile.avatarUrl),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName, 
                          style: syne(sz: 16, w: FontWeight.w800),
                          maxLines: 1, 
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '@${profile.username}', 
                          style: dm(sz: 13, w: FontWeight.w600, c: C.brand),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${profile.trustScore}% Trust • ${profile.followersCount} Followers',
                          style: dm(sz: 11, c: C.dim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Divider(color: C.text.withValues(alpha: .06)),
              const SizedBox(height: 8),

              // Options
              _OptionTile(
                icon: Icons.share_outlined,
                label: 'Share Public Profile',
                color: C.brand,
                onTap: () => _shareProfile(context),
              ),
              _OptionTile(
                icon: Icons.link_rounded,
                label: 'Copy Public Node Link',
                color: C.purple,
                onTap: () => _copyLink(context),
              ),
              _OptionTile(
                icon: Icons.fingerprint_rounded,
                label: 'Copy Node Identity ID',
                color: C.text,
                onTap: () => _copyNodeId(context),
              ),

              if (!isMe) ...[
                _OptionTile(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: 'Send Transmission / Chat',
                  color: C.brand,
                  onTap: () => _openMessage(context),
                ),
                _OptionTile(
                  icon: Icons.card_giftcard_rounded,
                  label: 'Send Creator Gift / Tip',
                  color: Colors.amberAccent,
                  onTap: () => _sendGift(context),
                ),
                _OptionTile(
                  icon: Icons.volume_off_outlined,
                  label: 'Mute Transmissions',
                  color: C.dim,
                  onTap: () => _muteNode(context),
                ),
                if (state.isBlocked(profile.id))
                  _OptionTile(
                    icon: Icons.lock_open_rounded,
                    label: 'Unblock Node',
                    color: Colors.orangeAccent,
                    onTap: () => _unblockNode(context),
                  )
                else
                  _OptionTile(
                    icon: Icons.block_rounded,
                    label: 'Block Node ⚠️',
                    color: Colors.redAccent,
                    onTap: () => _blockNode(context),
                  ),
                _OptionTile(
                  icon: Icons.flag_outlined,
                  label: 'Report Node Violation',
                  color: Colors.redAccent,
                  onTap: () => _showReportDialog(context),
                ),
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
              Expanded(
                child: Text(label, style: syne(sz: 13, w: FontWeight.w600, c: C.text)),
              ),
              Icon(Icons.chevron_right_rounded, color: C.dim, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _SystemBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _SystemBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 5),
          Text(label, style: dm(sz: 10, w: FontWeight.w700, c: color)),
        ],
      ),
    );
  }
}

// ── Showcase Product Tile ───────────────────────────────────────────────────

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
                  ? Image.network(url, fit: BoxFit.cover, errorBuilder: (c, e, s) => Container(color: C.card, child: Icon(Icons.broken_image, color: C.dim))) 
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
                            child: Text(
                              ugx(price.toDouble()), 
                              style: syne(sz: 14, w: FontWeight.w900, c: C.brand),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                            ),
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

class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  _SliverAppBarDelegate({required this.child});
  @override
  double get minExtent => 50;
  @override
  double get maxExtent => 50;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => child;
  @override
  bool shouldRebuild(_SliverAppBarDelegate oldDelegate) => false;
}

class _AvatarContainer extends StatelessWidget {
  final String? url;
  const _AvatarContainer({this.url});
  @override
  Widget build(BuildContext context) => Container(
    width: 96, height: 96,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(40),
      gradient: const LinearGradient(colors: [C.brand, Color(0xFFa855f7)]),
      boxShadow: [BoxShadow(color: C.brand.withValues(alpha: .3), blurRadius: 20)],
    ),
    padding: const EdgeInsets.all(3),
    child: Container(
      decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(38)),
      padding: const EdgeInsets.all(4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(34),
        child: url != null 
          ? Image.network(url!, fit: BoxFit.cover, errorBuilder: (c, e, s) => Center(child: Icon(Icons.person, color: C.brand, size: 40))) 
          : Center(child: Icon(Icons.person, color: C.dim, size: 40)),
      ),
    ),
  );
}

class _StatItem extends StatelessWidget {
  final String label, value;
  final Color color;
  const _StatItem({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(value, style: syne(sz: 18, w: FontWeight.w900, fs: FontStyle.italic, c: color)),
      const SizedBox(height: 6),
      Text(label, style: dm(sz: 9, w: FontWeight.w800, ls: 1, c: C.dim)),
    ],
  );
}

class _StatSeparator extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(width: 1, height: 28, color: C.dim.withValues(alpha: .3));
}

class _MetricTag extends StatelessWidget {
  final String label, value;
  final IconData? icon;
  final Color? color;
  const _MetricTag({required this.label, required this.value, this.icon, this.color});
  @override
  Widget build(BuildContext context) {
    final activeColor = color ?? C.text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: C.text.withValues(alpha: .03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.text.withValues(alpha: .05)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, color: activeColor, size: 14), const SizedBox(width: 6)],
          Text(label, style: dm(sz: 9, w: FontWeight.w800, ls: 1, c: C.dim)),
          const SizedBox(width: 8),
          Text(value, style: syne(sz: 12, w: FontWeight.w900, c: activeColor)),
        ],
      ),
    );
  }
}

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
                colorFilter: isVideo ? ColorFilter.mode(Colors.black.withValues(alpha: 0.3), BlendMode.darken) : null,
              )
            : null,
        ),
        child: Stack(
          children: [
            if (isVideo)
              Center(child: Icon(Icons.play_arrow_rounded, color: C.sub, size: 40)),
            
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
        color: C.text.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.text.withValues(alpha: .1)),
      ),
      child: Icon(icon, color: C.text, size: 18),
    ),
  );
}
