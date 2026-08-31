import 'package:flutter/material.dart';
import '../theme.dart';
import '../data.dart';
import '../app_state.dart';
import '../widgets/gift_overlay.dart';

class CreatorScreen extends StatelessWidget {
  final AppState state;
  CreatorScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        _buildAppTabs(),
        _buildCreatorTabs(),
        Expanded(child: _buildTabContent(context)),
        _buildBottomNav(),
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      color: C.card,
      padding: EdgeInsets.fromLTRB(16, 52, 16, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: Row(
        children: [
          NecxaLogo(size: 38, shadow: false),
          SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('NECXA Creator', style: syne(sz: 18)),
              Text('Music � Art � Gifts � Monetize',
                  style: dm(sz: 10, c: C.dim)),
            ],
          ),
          Spacer(),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: C.gold.withOpacity(.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: C.gold.withOpacity(.18)),
            ),
            child: Text('?? ${ugx(state.wallet)}',
                style: dm(sz: 10, w: FontWeight.w700, c: C.gold)),
          ),
          SizedBox(width: 10),
          Container(
            padding:
                EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Color(0xFF7F1D1D),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                _LiveDot(),
                SizedBox(width: 5),
                Text('GO LIVE',
                    style: dm(sz: 10, w: FontWeight.w800,
                        c: Color(0xFFFCA5A5))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppTabs() {
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: Row(
        children: [
          ('home', '🏠', 'Property'),
          ('creator', '🎥', 'Creator'),
          ('list', '📋', 'List'),
          ('profile', '👤', 'Profile'),
        ].map((t) {
          final active = t.$1 == 'creator';
          return Expanded(
            child: GestureDetector(
              onTap: () {
                if (t.$1 == 'home') state.go('home');
                if (t.$1 == 'list') state.go('list');
              },
              child: Container(
                padding: EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active ? C.gold : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Text('${t.$2} ${t.$3}',
                    textAlign: TextAlign.center,
                    style: dm(
                        sz: 10,
                        w: active ? FontWeight.w800 : FontWeight.w600,
                        c: active ? C.gold : C.dim)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCreatorTabs() {
    final List<(String, String)> tabs = [
      ('feed', '🎥 Feed'),
      ('discover', '🔍 Discover'),
      ('live', '🔴 Live'),
      ('studio', '🎬 Studio'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: Row(
        children: tabs.map((t) {
          final active = state.creatorTab == t.$1;
          return Expanded(
            child: GestureDetector(
              onTap: () => state.setCreatorTab(t.$1),
              child: AnimatedContainer(
                duration: Duration(milliseconds: 200),
                padding: EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active ? C.gold : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Text(t.$2,
                    textAlign: TextAlign.center,
                    style: dm(
                        sz: 10,
                        w: active ? FontWeight.w800 : FontWeight.w600,
                        c: active ? C.gold : C.dim)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTabContent(BuildContext context) {
    switch (state.creatorTab) {
      case 'discover': return _buildDiscover();
      case 'live':     return _buildLive();
      case 'studio':   return _buildStudio();
      default:         return _buildFeed(context);
    }
  }

  // -- Feed --------------------------------------------------
  Widget _buildFeed(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          _buildCatFilter(),
          _buildJoinBanner(),
          ...posts.map((p) => _PostCard(post: p, state: state,
              onGift: () => _openGifts(context, p))),
          SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildCatFilter() {
    cats = ['All','Music','Afrobeats','RnB','HipHop','Dance','Art'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: cats.map((c) => Container(
          margin: EdgeInsets.only(right: 8),
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: C.gold.withOpacity(.09),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: C.gold),
          ),
          child: Text(c,
              style: dm(sz: 10, w: FontWeight.w700, c: C.gold)),
        )).toList(),
      ),
    );
  }

  Widget _buildJoinBanner() {
    return GestureDetector(
      onTap: () {},
      child: Container(
        margin: EdgeInsets.fromLTRB(16, 0, 16, 10),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Color(0xFF1a1a0a),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.gold.withOpacity(.25)),
        ),
        child: Row(
          children: [
            const Text('💰', style: TextStyle(fontSize: 20)),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Start earning today!',
                      style: dm(sz: 13, w: FontWeight.w800, c: C.text)),
                  Text('Create account � Post content � Receive gifts',
                      style: dm(sz: 10, c: C.dim)),
                ],
              ),
            ),
            Text('JOIN ?',
                style: dm(sz: 12, w: FontWeight.w800, c: C.gold)),
          ],
        ),
      ),
    );
  }

  void _openGifts(BuildContext context, Post p) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => GiftOverlay(
        state: state,
        receiverId: p.creatorId,
        postId: p.id,
        contextType: p.type == 'live' ? 'live_stream' : 'creator_post',
      ),
    );
  }

  // -- Discover ----------------------------------------------
  Widget _buildDiscover() {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('?? Top Creators in Uganda', style: syne(sz: 16)),
          SizedBox(height: 12),
          ...creators.map((c) => _CreatorCard(creator: c, state: state)),
        ],
      ),
    );
  }

  // -- Live --------------------------------------------------
  Widget _buildLive() {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('?? Live Now', style: syne(sz: 16)),
          SizedBox(height: 12),
          ...[...posts, ...posts.take(2)].map((p) => _LiveCard(p)),
        ],
      ),
    );
  }

  // -- Studio ------------------------------------------------
  Widget _buildStudio() {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('?? My Creator Studio', style: syne(sz: 22)),
          SizedBox(height: 4),
          Text('Track earnings & upload content',
              style: dm(sz: 12, c: C.dim)),
          SizedBox(height: 18),
          _buildRevenueCard(),
          SizedBox(height: 16),
          _buildUploadCard(),
          SizedBox(height: 16),
          _buildAnalyticsCard(),
        ],
      ),
    );
  }

  Widget _buildRevenueCard() {
    final rows = [
      ('Total Gifts Received', 'UGX 3,240,000', C.gold),
      ('Your Earnings (80%)', 'UGX 2,592,000', C.green),
      ('CIMPO Platform Fee (20%)', 'UGX 648,000', C.red),
      ('Pending Withdrawal', 'UGX 892,000', C.blue),
    ];
    return _StudioCard(
      title: '?? Revenue Breakdown',
      child: Column(
        children: [
          ...rows.map((r) => Container(
            padding: EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: C.border,
                    width: r.$1 == 'Pending Withdrawal' ? 0 : 1),
              ),
            ),
            child: Row(
              children: [
                Text(r.$1, style: dm(sz: 12, c: C.sub)),
                Spacer(),
                Text(r.$2,
                    style: syne(sz: 14, c: r.$3)),
              ],
            ),
          )),
          SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: C.green,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text('?? Withdraw to MTN MoMo',
                textAlign: TextAlign.center,
                style: dm(sz: 14, w: FontWeight.w800,
                    c: C.text)),
          ),
        ],
      ),
    );
  }

  Widget _buildUploadCard() {
    final opts = [
      ('??', 'Music Video', 'Upload full HD music video'),
      ('??', 'Short Reel', '15-60 second viral reel'),
      ('??', 'Go Live', 'Start a live stream now'),
      ('???', 'Photo Post', 'Share artwork or photos'),
    ];
    return _StudioCard(
      title: '?? Upload Content',
      child: Column(
        children: opts.map((o) {
          final isLast = o == opts.last;
          return Container(
            padding: EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: isLast ? Colors.transparent : C.border),
              ),
            ),
            child: Row(
              children: [
                Text(o.$1, style: TextStyle(fontSize: 26)),
                SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.$2, style: dm(sz: 14, w: FontWeight.w700)),
                    Text(o.$3, style: dm(sz: 11, c: C.dim)),
                  ],
                ),
                Spacer(),
                Text('�', style: dm(sz: 18, c: C.dim)),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildAnalyticsCard() {
    final items = [
      ('???', '4.2M', 'Total Views'),
      ('??', '184K', 'Total Likes'),
      ('??', '12.4K', 'Gifts Received'),
      ('??', '2.4M', 'Followers'),
    ];
    return _StudioCard(
      title: '?? This Month',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final itemWidth = (constraints.maxWidth - 12) / 2;
          return Wrap(
            spacing: 12, runSpacing: 12,
            children: items.map((i) => SizedBox(
              width: itemWidth,
              child: Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Color(0xFF1F2937),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Text(i.$1, style: TextStyle(fontSize: 22)),
                    SizedBox(height: 4),
                    Text(i.$2, style: syne(sz: 18, c: C.gold)),
                    Text(i.$3, style: dm(sz: 10, c: C.dim)),
                  ],
                ),
              ),
            )).toList(),
          );
        },
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      color: C.card,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: C.border)),
      ),
      padding: EdgeInsets.fromLTRB(0, 12, 0, 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _BotBtn('??', 'Property', false, () => state.go('home')),
          _BotBtn('??', 'Creator', true, () {}),
          _BotBtn('??', 'Saved', false, () {}),
          _BotBtn('??', 'Profile', false, () {}),
        ],
      ),
    );
  }
}

// -- Post Card -------------------------------------------------
class _PostCard extends StatelessWidget {
  final Post post;
  final AppState state;
  final VoidCallback onGift;
  const _PostCard({required this.post, required this.state, required this.onGift});

  @override
  Widget build(BuildContext context) {
    final p = post;
    final liked = state.liked.contains(p.id);
    final following = state.followed.contains(p.creatorId);
    final isFriend = state.isFriendSync(p.creatorId);

    return Container(
      margin: EdgeInsets.fromLTRB(16, 0, 16, 18),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Thumb
          ClipRRect(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            child: Container(
              height: 200,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: postGrad(p.grad),
                ),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Text(p.avatar,
                        style: TextStyle(fontSize: 64)),
                  ),
                  if (p.type == 'live')
                    Positioned(
                      top: 12, left: 12,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: C.red,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _LiveDot(),
                            SizedBox(width: 5),
                            Text('LIVE',
                                style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    color: C.text)),
                          ],
                        ),
                      ),
                    ),
                  Positioned(
                    top: 12, right: 12,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          Text('??', style: dm(sz: 11)),
                          SizedBox(width: 4),
                          Text(p.views,
                              style: dm(sz: 10, c: C.text)),
                        ],
                      ),
                    ),
                  ),
                  Center(
                    child: Container(
                      width: 52, height: 52,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.6),
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Center(
                        child: Text('?',
                            style: TextStyle(
                                fontSize: 20, color: C.text)),
                      ),
                    ),
                  ),
                  if (p.type != 'live')
                    Positioned(
                      bottom: 10, right: 10,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(.8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(p.duration,
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: C.text)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Body
          Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38, height: 38,
                      decoration: BoxDecoration(
                        color: Color(0xFF1F2937),
                        borderRadius: BorderRadius.circular(19),
                      ),
                      child: Center(
                        child: Text(p.avatar,
                            style: TextStyle(fontSize: 20)),
                      ),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(p.creator,
                                  style: dm(sz: 14, w: FontWeight.w800)),
                              if (p.verified) ...[
                                SizedBox(width: 4),
                                Text('?',
                                    style: dm(sz: 11, c: C.gold,
                                        w: FontWeight.w700)),
                              ],
                            ],
                          ),
                          Text(p.timeAgo,
                              style: dm(sz: 10, c: C.dim)),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () => state.toggleFollow(p.creatorId),
                      child: AnimatedContainer(
                        duration: Duration(milliseconds: 150),
                        padding: EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: following
                              ? C.gold.withOpacity(.25)
                              : C.gold.withOpacity(.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: C.gold.withOpacity(.31)),
                        ),
                        child: Text(
                          isFriend ? 'Friends' : following ? '? Following' : '+ Follow',
                          style: dm(sz: 11, w: FontWeight.w700,
                              c: C.gold),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                Text(p.title,
                    style: dm(sz: 14, w: FontWeight.w700, h: 1.4)),
                SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: p.tags.map((t) => Text(t,
                      style: dm(sz: 11, w: FontWeight.w600,
                          c: C.blue))).toList(),
                ),
                SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: C.border)),
                  ),
                  child: Row(
                    children: [
                      _ActionBtn(
                        icon: liked ? '??' : '??',
                        label: kNum(p.likes + (liked ? 1 : 0)),
                        active: liked,
                        onTap: () => state.toggleLike(p.id),
                      ),
                      _ActionBtn(
                        icon: '??',
                        label: kNum(p.comments),
                        onTap: () {},
                      ),
                      _ActionBtn(
                        icon: '?',
                        label: 'Share',
                        onTap: () {},
                      ),
                      Spacer(),
                      GestureDetector(
                        onTap: onGift,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: C.gold.withOpacity(.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: C.gold.withOpacity(.25)),
                          ),
                          child: Row(
                            children: [
                              Text('??',
                                  style: TextStyle(fontSize: 14)),
                              SizedBox(width: 4),
                              Text(kNum(p.gifts),
                                  style: dm(sz: 12, w: FontWeight.w700,
                                      c: C.gold)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 8),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Color(0xFF0d1f14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Text('?? Creator earned',
                          style: dm(sz: 11, c: C.green)),
                      Spacer(),
                      Text(ugx(p.earned),
                          style: syne(sz: 13, c: C.gold)),
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
}

class _ActionBtn extends StatelessWidget {
  final String icon, label;
  final bool active;
  final VoidCallback onTap;
  const _ActionBtn({required this.icon, required this.label,
      this.active = false, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(right: 4),
        child: Row(
          children: [
            Text(icon, style: TextStyle(fontSize: 16)),
            SizedBox(width: 4),
            Text(label,
                style: dm(sz: 12,
                    c: active ? C.red : C.dim)),
          ],
        ),
      ),
    );
  }
}

// -- Creator Card ----------------------------------------------
class _CreatorCard extends StatelessWidget {
  final Creator creator;
  final AppState state;
  const _CreatorCard({required this.creator, required this.state});

  @override
  Widget build(BuildContext context) {
    final c = creator;
    final following = state.followed.contains(c.id);
    final isFriend = state.isFriendSync(c.id);
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: Color(0xFF1F2937),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Center(
              child: Text(c.avatar,
                  style: TextStyle(fontSize: 32)),
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(c.name,
                        style: dm(sz: 15, w: FontWeight.w800)),
                    if (c.verified) ...[
                      SizedBox(width: 6),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: C.gold.withOpacity(.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: C.gold.withOpacity(.25)),
                        ),
                        child: Text('? PRO',
                            style: dm(sz: 9, w: FontWeight.w800,
                                c: C.gold)),
                      ),
                    ],
                  ],
                ),
                Text(c.username,
                    style: dm(sz: 11, c: C.dim)),
                SizedBox(height: 4),
                Text(c.bio, style: dm(sz: 12, c: C.sub)),
                SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  children: [
                    Text('?? ${c.followers}',
                        style: dm(sz: 11, w: FontWeight.w600,
                            c: C.sub)),
                    Text('?? ${ugx(c.totalEarned)}',
                        style: dm(sz: 11, w: FontWeight.w600,
                            c: C.gold)),
                    Text('?? ${c.category}',
                        style: dm(sz: 11, w: FontWeight.w600,
                            c: C.blue)),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          GestureDetector(
            onTap: () => state.toggleFollow(c.id),
            child: AnimatedContainer(
              duration: Duration(milliseconds: 150),
              padding:
                  EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: following
                    ? C.gold.withOpacity(.25)
                    : C.gold.withOpacity(.12),
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: C.gold.withOpacity(.31)),
              ),
              child: Text(
                isFriend ? 'Friends' : following ? '? Following' : '+ Follow',
                style: dm(sz: 12, w: FontWeight.w700, c: C.gold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -- Live Card -------------------------------------------------
class _LiveCard extends StatelessWidget {
  final Post p;
  const _LiveCard(this.p);
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.red.withOpacity(.19)),
      ),
      child: Row(
        children: [
          Text(p.avatar, style: TextStyle(fontSize: 40)),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: C.red.withOpacity(.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('?? LIVE',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: C.red)),
                    ),
                    SizedBox(width: 6),
                    Text('${p.views} watching',
                        style: dm(sz: 10, c: C.dim)),
                  ],
                ),
                SizedBox(height: 4),
                Text(p.creator,
                    style: dm(sz: 13, w: FontWeight.w800)),
                Text(p.title, style: dm(sz: 11, c: C.dim)),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: C.red,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('Join',
                style: dm(sz: 12, w: FontWeight.w800,
                    c: C.text)),
          ),
        ],
      ),
    );
  }
}

// -- Studio Card -----------------------------------------------
class _StudioCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _StudioCard({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: syne(sz: 15)),
          SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

// -- Live dot animation ----------------------------------------
class _LiveDot extends StatefulWidget {
  @override
  State<_LiveDot> createState() => _LiveDotState();
}
class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: Duration(seconds: 1))
        ..repeat(reverse: true);
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.3, end: 1.0).animate(_ctrl),
      child: Container(
        width: 7, height: 7,
        decoration: BoxDecoration(
          color: C.red, shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _BotBtn extends StatelessWidget {
  final String icon, label;
  final bool active;
  final VoidCallback onTap;
  const _BotBtn(this.icon, this.label, this.active, this.onTap);
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: TextStyle(fontSize: 22)),
          SizedBox(height: 3),
          Text(label,
              style: dm(sz: 9, w: FontWeight.w600,
                  c: active ? C.gold : C.dim)),
        ],
      ),
    );
  }
}


