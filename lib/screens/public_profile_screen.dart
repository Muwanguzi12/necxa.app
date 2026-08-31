import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart';
import 'dart:ui';

class PublicProfileScreen extends StatefulWidget {
  final AppState state;
  PublicProfileScreen({super.key, required this.state});

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _hasListings = false;

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
          return Scaffold(backgroundColor: C.bg, body: Center(child: Text('PROFILE NOT FOUND', style: syne(c: C.brand))));
        }

        final isFollowing = widget.state.followed.contains(profile.id);
        final isFriend = widget.state.isFriendSync(profile.id);

        return Scaffold(
          backgroundColor: C.bg,
          body: Stack(
            children: [
              _buildAmbientGlow(),
              CustomScrollView(
                physics: BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _buildIdentityHeader(profile, isFollowing, isFriend)),
                  SliverToBoxAdapter(child: _buildPublicStats()),
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
              _buildTopHUD(),
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
        decoration: BoxDecoration(shape: BoxShape.circle, color: C.brand.withOpacity(.05)),
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80), child: SizedBox()),
      ),
    );
  }

  Widget _buildTopHUD() {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 10, 20, 15),
            decoration: BoxDecoration(
              color: C.bg.withOpacity(.6),
              border: Border(bottom: BorderSide(color: C.dim)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _HUDButton(icon: Icons.arrow_back_ios_new, onTap: () => widget.state.goBack()),
                Text('PUBLIC NODE', style: syne(sz: 14, w: FontWeight.w800, ls: 4, c: C.brand)),
                _HUDButton(icon: Icons.more_horiz, onTap: () {}),
              ],
            ),
          ),
        ),
      ),
    );
  }


  Widget _buildIdentityHeader(Profile profile, bool isFollowing, bool isFriend) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, MediaQuery.of(context).padding.top + 80, 24, 0),
      child: Column(
        children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _AvatarContainer(url: profile.avatarUrl),
                Spacer(),
                GestureDetector(
                  onTap: () {
                    widget.state.openCreatorChat(
                      profile.id,
                      profile.fullName ?? 'Creator',
                      profile.avatarUrl
                    );
                                    },
                  child: Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: C.text.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: C.text.withOpacity(0.1)),
                    ),
                    child: Icon(Icons.chat_bubble_outline_rounded, color: C.brand, size: 20),
                  ),
                ),
                SizedBox(width: 12),
                GestureDetector(
                  onTap: () => setState(() => widget.state.toggleFollow(profile.id)),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: isFollowing ? Colors.transparent : C.brand,
                      borderRadius: BorderRadius.circular(16),
                      border: isFollowing ? Border.all(color: C.brand.withOpacity(.4)) : null,
                      boxShadow: isFollowing ? null : [BoxShadow(color: C.brand.withOpacity(.2), blurRadius: 10)],
                    ),
                    child: Text(
                      isFriend ? 'FRIENDS' : isFollowing ? 'FOLLOWING' : 'FOLLOW',
                      style: syne(sz: 12, w: FontWeight.w900, ls: 1, c: isFollowing ? C.brand : C.text),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 20),
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(profile.fullName ?? 'NECXA USER', style: syne(sz: 28, w: FontWeight.w900, ls: -1, fs: FontStyle.italic)),
                        if (profile.verified) ...[
                          SizedBox(width: 8),
                          Icon(Icons.verified, color: C.brand, size: 24),
                        ],
                      ],
                    ),
                    Text('@${profile.username}', style: dm(sz: 14, w: FontWeight.w700, c: C.brand.withOpacity(.6))),
                  ],
                ),
              ],
            ),
          ],
        ),
    );
  }

  Widget _buildPublicStats() {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 24),
        decoration: BoxDecoration(
          color: C.text.withOpacity(.03),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: C.text.withOpacity(.05)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _StatItem(label: 'FOLLOWERS', value: '2.4M', color: C.text),
            _StatSeparator(),
            const _StatItem(label: 'LIKES', value: '18.2M', color: C.purple),
            _StatSeparator(),
            _StatItem(label: 'EARNINGS', value: '24.5M', color: C.brand),
          ],
        ),
      ),
    );
  }

  Widget _buildBioSection(Profile profile) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CORE SYSTEMS & BIO', style: dm(sz: 9, w: FontWeight.w900, ls: 2, c: C.dim)),
          SizedBox(height: 12),
          Text(profile.bio ?? 'No status transmission available.', style: dm(sz: 14, c: C.text.withOpacity(.7), h: 1.6)),
          SizedBox(height: 24),
          Row(
            children: [
              _MetricTag(label: 'POSTS', value: '1,240'),
              SizedBox(width: 12),
              _MetricTag(label: 'REPUTATION', value: '9.8', icon: Icons.star, color: C.brand),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 32, 24, 16),
      child: Row(
        children: [
          Icon(Icons.grid_view_sharp, color: C.brand, size: 14),
          SizedBox(width: 10),
          Text(title, style: syne(sz: 11, w: FontWeight.w800, ls: 2, c: C.brand)),
          Spacer(),
          Icon(Icons.tune, color: C.dim, size: 16),
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
           return Center(child: CircularProgressIndicator(color: C.brand));
        }
        
        final list = snapshot.data ?? [];
        if (list.isEmpty) {
           return Center(child: Text('NO PRODUCTS SYNCED', style: syne(sz: 11, c: C.dim, ls: 2)));
        }

        return GridView.builder(
          padding: EdgeInsets.all(24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
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
           return Center(child: CircularProgressIndicator(color: C.brand));
        }
        
        final list = snapshot.data ?? [];
        if (list.isEmpty) {
           return Center(child: Text('NO CONTENT TRANSMISSIONS', style: syne(sz: 11, c: C.dim, ls: 2)));
        }

        return GridView.builder(
          padding: EdgeInsets.all(24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
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

// -- Showcase Product Tile (Product as Cover, Content as Engine) --
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
        state.go('community'); // Triggers handoff logic in CommunityScreen
      },
      child: Container(
        decoration: BoxDecoration(
          color: C.text.withOpacity(.05),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: C.text.withOpacity(.1)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              // Product Cover Image
              Positioned.fill(
                child: url != null 
                  ? Image.network(url, fit: BoxFit.cover) 
                  : Container(color: C.dim, child: Icon(Icons.shopping_bag, color: C.dim)),
              ),
              
              // Bottom Price Badge
              Positioned(
                bottom: 12, left: 12, right: 12,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      color: Colors.black26,
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
              
              // Live/Video Indicator
              if (listing['media_url'] != null)
                Positioned(
                  top: 12, right: 12,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      children: [
                        Icon(Icons.play_circle_fill, color: C.text, size: 12),
                        SizedBox(width: 4),
                        Text('STORY', style: syne(sz: 8, w: FontWeight.w900, c: C.text)),
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
    width: 100, height: 100,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(40),
      gradient: LinearGradient(colors: [C.brand, Color(0xFFa855f7)]),
      boxShadow: [BoxShadow(color: C.brand.withOpacity(.3), blurRadius: 20)],
    ),
    padding: EdgeInsets.all(3),
    child: Container(
      decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(38)),
      padding: EdgeInsets.all(4),
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
      SizedBox(height: 6),
      Text(label, style: dm(sz: 8, w: FontWeight.w800, ls: 1, c: C.dim)),
    ],
  );
}

class _StatSeparator extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(width: 1, height: 30, color: C.dim);
}

class _MetricTag extends StatelessWidget {
  final String label, value;
  final IconData? icon;
  final Color? color;
  _MetricTag({required this.label, required this.value, this.icon, this.color});
  @override
  Widget build(BuildContext context) {
    final activeColor = color ?? C.text;
    return Container(
    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: C.text.withOpacity(.03),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: C.text.withOpacity(.05)),
    ),
    child: Row(
      children: [
        if (icon != null) ...[Icon(icon, color: activeColor, size: 12), const SizedBox(width: 6)],
        Text(label, style: dm(sz: 8, w: FontWeight.w800, ls: 1, c: C.dim)),
        const SizedBox(width: 8),
        Text(value, style: syne(sz: 12, w: FontWeight.w900, c: activeColor)),
      ],
    ),
  );
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
          color: C.text.withOpacity(.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: C.text.withOpacity(.1)),
          image: (thumbUrl != null || mediaUrl != null) 
            ? DecorationImage(
                image: NetworkImage(thumbUrl ?? mediaUrl!), 
                fit: BoxFit.cover,
                colorFilter: isVideo ? ColorFilter.mode(Colors.black.withOpacity(0.3), BlendMode.darken) : null,
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
                  SizedBox(width: 4),
                  Text(kNum(likes), style: dm(sz: 10, w: FontWeight.w800, c: C.text)),
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
      padding: EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: C.text.withOpacity(.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.text.withOpacity(.1)),
      ),
      child: Icon(icon, color: C.text, size: 18),
    ),
  );
}




