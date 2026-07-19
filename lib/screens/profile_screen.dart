import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../widgets/vault_widget.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

const String necxaSupportUrl = 'https://goobox.necxa.uk';
const String necxaTermsUrl = 'https://goobox.necxa.uk/terms';
const String necxaPolicyUrl = 'https://goobox.necxa.uk/policy';
const String necxaCompanyUrl = 'https://www.necxa.uk';

class ProfileScreen extends StatefulWidget {
  final AppState state;
  const ProfileScreen({super.key, required this.state});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> with TickerProviderStateMixin {
  bool _showDetails = false;
  bool _isManageMode = false;
  final Set<String> _selectedPostIds = {};
  final ScrollController _scrollCtrl = ScrollController();

  // High-Tech Colors
  
  
  
  
  

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Stack(
        children: [
          // Background Glow / Ambient Light
          Positioned(
            top: -100, right: -100,
            child: Container(
              width: 300, height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: C.purple.withOpacity(.08),
              ),
              child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80), child: const SizedBox()),
            ),
          ),
          
          CustomScrollView(
            controller: _scrollCtrl,
            physics: const BouncingScrollPhysics(),
            slivers: [
              _buildSliverHeader(),
              SliverToBoxAdapter(child: _buildIdentityRow()),
              SliverToBoxAdapter(child: _buildMetricsBar()),
              SliverToBoxAdapter(child: _buildActionTiles()),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 0).copyWith(bottom: 40),
                  child: VaultWidget(state: widget.state),
                ),
              ),
              SliverToBoxAdapter(child: _buildVendorDashboard()),
              _buildStickyTabs(),
              _buildTabContent(),
              const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
            ],
          ),
          
          // Bottom Navigation (Futuristic)
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: _buildFloatingBottomNav(),
          ),
          
          // Top Nav HUD
          _buildTopHUD(),

          // Manage Action Bar
          if (_isManageMode) _buildManageActionBar(),
        ],
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
              border: const Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _HUDButton(icon: Icons.arrow_back_ios_new, onTap: () => widget.state.go('home')),
                Text('Profile', style: syne(sz: 18, w: FontWeight.w700)),
                _HUDButton(icon: Icons.settings_outlined, onTap: () => _showMoreOptions()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSliverHeader() {
    return const SliverToBoxAdapter(
      child: SizedBox(height: 120), // Placeholder for top HUD spacing
    );
  }

  Widget _buildIdentityRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          // Squircle Avatar
          Stack(
            alignment: Alignment.center,
            children: [
              // Glow Pulse
              _AvatarGlow(),
              // Frame
              Container(
                width: 132, height: 132,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(56),
                  gradient: const LinearGradient(colors: [C.brand, C.purple]),
                ),
                padding: const EdgeInsets.all(2),
                  child: Container(
                    decoration: BoxDecoration(
                      color: C.bg,
                      borderRadius: BorderRadius.circular(54),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: GestureDetector(
                      onTap: () => widget.state.updateAvatar(),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(50),
                        child: Container(
                          color: C.brand.withOpacity(.1),
                          child: ListenableBuilder(
                            listenable: widget.state,
                            builder: (context, _) {
                              final photoUrl = widget.state.myProfile?['photo_url'];
                              return photoUrl != null 
                                ? CachedNetworkImage(
                                    imageUrl: photoUrl,
                                    fit: BoxFit.cover,
                                    placeholder: (_, __) => const Center(
                                      child: CircularProgressIndicator(color: C.brand, strokeWidth: 1.5),
                                    ),
                                    errorWidget: (_, __, ___) => const Icon(Icons.person, color: C.brand, size: 50),
                                  )
                                : const Icon(Icons.person, color: C.brand, size: 50);
                            },
                          ),
                        ),
                  ),
                ),
              ),
            ),
              // Upload Button Overlay
              Positioned(
                bottom: 0, right: 0,
                child: GestureDetector(
                  onTap: () => widget.state.updateAvatar(),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [C.brand, C.purple]),
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: C.brand.withOpacity(.4), blurRadius: 10)],
                      border: Border.all(color: C.bg, width: 2.5),
                    ),
                    child: const Icon(Icons.add_a_photo_rounded, color: Colors.white, size: 18),
                  ),
                ),
              ),
              // Verification Shield
              Positioned(
                bottom: 8, right: 8,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(color: C.brand, shape: BoxShape.circle),
                  child: const Icon(Icons.verified_user, color: Colors.white, size: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ListenableBuilder(
            listenable: widget.state,
            builder: (context, _) {
              final name = widget.state.myProfile?['display_name'] ?? widget.state.user?.email?.split('@')[0].toUpperCase() ?? 'USER';
              return Text(name, style: syne(sz: 32, w: FontWeight.w900, ls: -1, fs: FontStyle.italic));
            }
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: C.brand.withOpacity(.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: C.brand.withOpacity(.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.bolt, color: C.brand, size: 12),
                    const SizedBox(width: 4),
                    Text(widget.state.isAgent ? 'Verified Agent' : 'Verified Member', style: dm(sz: 10, w: FontWeight.w700, c: C.brand)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('"Living my best life with Necxa."', style: dm(sz: 14, c: Colors.white70)),
        ],
      ),
    );
  }

  Widget _buildMetricsBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.03),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withOpacity(.05)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            ListenableBuilder(
              listenable: widget.state,
              builder: (context, _) {
                return _MetricItem(label: 'Earnings', value: '${widget.state.ncxBalance.toStringAsFixed(0)} NCX', color: C.brand);
              }
            ),
            _MetricSeparator(),
            const _MetricItem(label: 'Reputation', value: '98%', color: C.purple, trend: true),
            _MetricSeparator(),
            const _MetricItem(label: 'Posts', value: '01', color: Colors.white),
          ],
        ),
      ),
    );
  }

  Widget _buildActionTiles() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Row(
        children: [
          Expanded(
            child: _ActionTile(
              label: 'Share Profile',
              icon: Icons.share,
              color: Colors.blueAccent,
              onTap: () {
                final user = widget.state.user;
                if (user != null) {
                  final username = user.email?.split('@')[0] ?? user.id.substring(0, 8);
                  Share.share('Check out my space on Necxa: https://necxa.com/@$username');
                }
              },
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _ActionTile(
              label: 'Sync Contacts',
              icon: Icons.sync,
              color: C.purple,
              onTap: () {
                // In future, triggers contact sync.
                widget.state.go('chat');
              },
            ),
          ),
          if (widget.state.isAgent) ...[
            const SizedBox(width: 16),
            Expanded(
              child: _ActionTile(
                label: 'Agent Hub',
                icon: Icons.business_center_outlined,
                color: C.green,
                onTap: () {},
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVendorDashboard() {
    if (widget.state.user == null) return const SizedBox();
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: widget.state.social.fetchUserListings(widget.state.user!.id),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const SizedBox(); // Keep layout quiet while loading
        }
        final listings = snapshot.data ?? [];
        if (listings.isEmpty) return const SizedBox();

        // Vendor Dashboard UI
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [C.brand.withOpacity(.1), C.purple.withOpacity(.05)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: C.brand.withOpacity(.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: C.brand.withOpacity(.2), shape: BoxShape.circle),
                      child: const Icon(Icons.storefront_outlined, color: C.brand, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Text('Vendor Dashboard', style: syne(sz: 18, w: FontWeight.bold, c: Colors.white)),
                    const Spacer(),
                    const Icon(Icons.arrow_forward_ios, color: Colors.white38, size: 12),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _MetricItem(label: 'Listings', value: '${listings.length < 10 ? '0' : ''}${listings.length}', color: C.brand),
                    _MetricSeparator(),
                    const _MetricItem(label: 'Views', value: '1.2K', color: Colors.white),
                    _MetricSeparator(),
                    const _MetricItem(label: 'Sales', value: '00', color: C.green),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => widget.state.go('transport'),
                          child: Container(
                            height: 48,
                            decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white10)),
                            child: Center(
                              child: Text('Manage Orders', style: syne(sz: 14, w: FontWeight.w700, c: Colors.white)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            // Navigate to full inventory manager in future
                          },
                          child: Container(
                            height: 48,
                            decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(16)),
                            child: Center(
                              child: Text('Inventory', style: syne(sz: 14, w: FontWeight.w700, c: Colors.black)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStickyTabs() {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _SliverAppBarDelegate(
        minHeight: 60,
        maxHeight: 60,
        child: ClipRRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              color: C.bg.withOpacity(.8),
              child: Row(
                children: [
                  _ProfileTab(
                    label: 'My Posts',
                    active: !_showDetails,
                    onTap: () => setState(() { _showDetails = false; _isManageMode = false; _selectedPostIds.clear(); }),
                  ),
                  _ProfileTab(
                    label: 'Details',
                    active: _showDetails,
                    onTap: () => setState(() { _showDetails = true; _isManageMode = false; _selectedPostIds.clear(); }),
                  ),
                  if (!_showDetails)
                     Padding(
                       padding: const EdgeInsets.only(right: 16),
                       child: _HUDButton(
                         icon: _isManageMode ? Icons.close : Icons.edit_note, 
                         onTap: () => setState(() { 
                           _isManageMode = !_isManageMode; 
                           if (!_isManageMode) _selectedPostIds.clear(); 
                         }),
                       ),
                     ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    if (_showDetails) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const _DetailRow(icon: Icons.location_on_outlined, label: 'Location', value: 'Kampala, Uganda'),
              const _DetailRow(icon: Icons.shield_moon_outlined, label: 'Member Level', value: 'Trusted Member'),
              const _DetailRow(icon: Icons.sync_problem_outlined, label: 'Status', value: 'Active', statusColor: C.green),
              if (widget.state.isDriver)
                _DetailRow(
                  icon: Icons.local_shipping_outlined, 
                  label: 'Driver Status', 
                  value: widget.state.currentDriverProfile?.isVerified == true ? 'Verified' : 'Pending', 
                  statusColor: widget.state.currentDriverProfile?.isVerified == true ? C.green : Colors.orange,
                ),
              const _DetailRow(icon: Icons.currency_exchange_outlined, label: 'Currency', value: 'UGX (Shilling)'),
              const _DetailRow(icon: Icons.security_outlined, label: 'Security', value: 'Biometrics On'),
            ],
          ),
        ),
      );
    }

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: widget.state.social.fetchUserPosts(widget.state.user?.id ?? ''),
      builder: (context, snapshot) {
        // Show loading only if we have no data at all (neither cache nor network)
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const SliverToBoxAdapter(child: Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: C.brand))));
        }
        
        final list = snapshot.data ?? [];
        if (list.isEmpty && snapshot.connectionState == ConnectionState.done) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Center(child: Text('No posts yet', style: syne(sz: 14, c: Colors.white38))),
            ),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final post = list[index];
                final id = post['id'] as String;
                final isSelected = _selectedPostIds.contains(id);
                
                return _ContentGridItem(
                  data: post,
                  isManageMode: _isManageMode,
                  isSelected: isSelected,
                  onTap: () {
                    if (_isManageMode) {
                      setState(() {
                         if (isSelected) {
                           _selectedPostIds.remove(id);
                         } else {
                           _selectedPostIds.add(id);
                         }
                      });
                    } else {
                      widget.state.go('community', extra: id);
                    }
                  },
                );
              },
              childCount: list.length,
            ),
          ),
        );
      },
    );
  }

  Widget _buildFloatingBottomNav() {
    return Container(
      height: 100,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [C.bg, Colors.transparent],
        ),
      ),
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              height: 64,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.05),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(color: Colors.white.withOpacity(.1)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _NavBtn(icon: Icons.home_filled, onTap: () => widget.state.go('home')),
                  _NavBtn(icon: Icons.bolt, onTap: () => widget.state.go('community')),
                  // Center Pulse
                  _NavCenterBtn(onTap: () => widget.state.go('upload')),
                  _NavBtn(icon: Icons.local_shipping_outlined, onTap: () => widget.state.go('transport')),
                  _NavBtn(icon: Icons.chat_bubble_outline, onTap: () => widget.state.go('chat')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showMoreOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _MoreOptionsSheet(state: widget.state),
    );
  }

  Widget _buildManageActionBar() {
    return Positioned(
      bottom: 120, left: 24, right: 24,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: C.bg.withOpacity(.8),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                Text('${_selectedPostIds.length} selected', style: syne(sz: 12, w: FontWeight.bold)),
                const Spacer(),
                if (_selectedPostIds.isNotEmpty) ...[
                  _ManageAction(
                    icon: Icons.lock_outline, 
                    label: 'Private', 
                    color: C.purple,
                    onTap: () => _handleBatchPrivacy('private'),
                  ),
                  const SizedBox(width: 12),
                  _ManageAction(
                    icon: Icons.public, 
                    label: 'Public', 
                    color: C.brand,
                    onTap: () => _handleBatchPrivacy('public'),
                  ),
                  const SizedBox(width: 12),
                  _ManageAction(
                    icon: Icons.delete_outline, 
                    label: 'Delete', 
                    color: Colors.redAccent,
                    onTap: _handleBatchDelete,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleBatchDelete() async {
    if (_selectedPostIds.isEmpty) return;
    final ids = _selectedPostIds.toList();
    setState(() { _isManageMode = false; _selectedPostIds.clear(); });
    await widget.state.social.bulkDeletePosts(ids);
  }

  void _handleBatchPrivacy(String v) async {
    if (_selectedPostIds.isEmpty) return;
    final ids = _selectedPostIds.toList();
    setState(() { _isManageMode = false; _selectedPostIds.clear(); });
    await widget.state.social.bulkUpdatePostPrivacy(ids, v);
  }
}

// ── Supporting Widgets ──────────────────────────────────────────

class _AvatarGlow extends StatefulWidget {
  @override
  State<_AvatarGlow> createState() => _AvatarGlowState();
}
class _AvatarGlowState extends State<_AvatarGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Container(
        width: 180, height: 180,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Color.lerp(C.brand, C.purple, _ctrl.value)!.withOpacity(.15),
              blurRadius: 40 + (10 * _ctrl.value),
              spreadRadius: 2,
            )
          ],
        ),
      ),
    );
  }
}

class _MetricItem extends StatelessWidget {
  final String label, value;
  final Color color;
  final bool trend;
  const _MetricItem({required this.label, required this.value, required this.color, this.trend = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: dm(sz: 10, w: FontWeight.w500, c: Colors.white38)),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(value, style: syne(sz: 18, w: FontWeight.w900, fs: FontStyle.italic, c: color)),
            if (trend) ...[
              const SizedBox(width: 4),
              const Icon(Icons.trending_up, color: C.brand, size: 14),
            ],
          ],
        ),
      ],
    );
  }
}

class _MetricSeparator extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(width: 1, height: 24, color: Colors.white10);
}

class _ActionTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ActionTile({required this.label, required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          color: color.withOpacity(.1),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withOpacity(.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Text(label, style: syne(sz: 13, w: FontWeight.w600, c: color)),
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
        color: C.text.withOpacity(.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.text.withOpacity(.1)),
      ),
      child: Icon(icon, color: C.text, size: 18),
    ),
  );
}

class _ProfileTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ProfileTab({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: active ? C.brand : Colors.white10, width: active ? 2 : 1)),
          ),
          child: Center(
            child: Text(label, style: syne(sz: 13, w: FontWeight.w600, c: active ? C.brand : Colors.white38)),
          ),
        ),
      ),
    );
  }
}

class _ContentGridItem extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isManageMode;
  final bool isSelected;
  final VoidCallback onTap;
  
  const _ContentGridItem({
    required this.data, 
    this.isManageMode = false, 
    this.isSelected = false, 
    required this.onTap
  });

  @override
  Widget build(BuildContext context) {
    final isPrivate = data['visibility'] == 'private';
    final isVideo = data['media_type'] == 'video';
    final mediaUrl = data['media_url'] as String?;
    final thumbUrl = data['thumbnail_url'] as String?;
    
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isSelected ? C.brand : Colors.white.withOpacity(.1)),
              image: (thumbUrl != null || mediaUrl != null) 
                ? DecorationImage(
                    image: NetworkImage(thumbUrl ?? mediaUrl!), 
                    fit: BoxFit.cover,
                    colorFilter: isVideo ? ColorFilter.mode(Colors.black.withOpacity(0.3), BlendMode.darken) : null,
                  )
                : null,
            ),
            child: (thumbUrl == null && mediaUrl == null) 
              ? const Center(child: Icon(Icons.bolt, color: Colors.white24))
              : isVideo 
                  ? const Center(child: Icon(Icons.play_arrow_rounded, color: Colors.white70, size: 32))
                  : null,
          ),
          
          if (isPrivate)
            Positioned(
              top: 8, left: 8,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.lock, color: Colors.white70, size: 10),
              ),
            ),
            
          if (isManageMode) ...[
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: isSelected ? C.brand.withOpacity(.3) : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            Positioned(
              top: 8, right: 8,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: isSelected ? C.brand : Colors.black26,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24),
                ),
                child: Icon(isSelected ? Icons.check : Icons.circle_outlined, color: Colors.white, size: 14),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ManageAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  
  const _ManageAction({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: color.withOpacity(.1), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 4),
          Text(label, style: dm(sz: 9, w: FontWeight.bold, c: color)),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final Color? statusColor;
  const _DetailRow({required this.icon, required this.label, required this.value, this.statusColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(.05)),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white38, size: 20),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: dm(sz: 10, w: FontWeight.w500, c: Colors.white38)),
              const SizedBox(height: 4),
              Text(value, style: syne(sz: 13, w: FontWeight.w700, c: statusColor ?? Colors.white70)),
            ],
          ),
        ],
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _NavBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Icon(icon, color: Colors.white38, size: 26),
  );
}

class _NavCenterBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _NavCenterBtn({required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 48, height: 48,
      decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [C.brand, C.purple])),
      child: Icon(Icons.add, color: C.bg, size: 28),
    ),
  );
}

class _MoreOptionsSheet extends StatelessWidget {
  final AppState state;
  const _MoreOptionsSheet({required this.state});

  Future<void> _openExternalLink(BuildContext context, String url) async {
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open this link right now.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open this link right now.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .9,
        ),
        decoration: BoxDecoration(
          color: C.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
          border: const Border(top: BorderSide(color: Colors.white10)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
          GestureDetector(
            onTap: () {
              final user = state.user;
              if (user != null) {
                final username = user.email?.split('@')[0] ?? user.id.substring(0, 8);
                Share.share('Check out my space on Necxa: https://necxa.com/@$username');
              }
            },
            child: const _SheetBtn(label: 'Share Profile', icon: Icons.share_outlined, color: C.brand),
          ),
          const SizedBox(height: 16),
          // Theme Switcher Segment
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.03),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(.05)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Display Theme', style: syne(sz: 13, w: FontWeight.bold, c: Colors.white70)),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _ThemeToggleBtn(
                      label: 'Light',
                      icon: Icons.light_mode,
                      activeColor: Colors.yellow,
                      isActive: state.themeMode == ThemeMode.light,
                      onTap: () { state.setTheme(ThemeMode.light); Navigator.pop(context); },
                    ),
                    _ThemeToggleBtn(
                      label: 'System',
                      icon: Icons.settings_suggest,
                      activeColor: Colors.cyan,
                      isActive: state.themeMode == ThemeMode.system,
                      onTap: () { state.setTheme(ThemeMode.system); Navigator.pop(context); },
                    ),
                    _ThemeToggleBtn(
                      label: 'Dark',
                      icon: Icons.dark_mode,
                      activeColor: Colors.black,
                      isActive: state.themeMode == ThemeMode.dark,
                      onTap: () { state.setTheme(ThemeMode.dark); Navigator.pop(context); },
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () {
              Navigator.pop(context);
              state.go('sound-settings');
            },
            child: const _SheetBtn(label: 'Sounds & Ringtones', icon: Icons.volume_up_outlined, color: Colors.orangeAccent),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () {
              Navigator.pop(context);
              state.go('privacy-security');
            },
            child: const _SheetBtn(label: 'Privacy & Security', icon: Icons.lock_outline, color: C.purple),
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'NECXA SUPPORT & LEGAL',
              style: syne(sz: 11, w: FontWeight.w800, c: C.dim, ls: 1.2),
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => _openExternalLink(context, necxaSupportUrl),
            child: const _SheetBtn(
              label: 'Necxa Support',
              subtitle: 'goobox.necxa.uk',
              icon: Icons.help_outline,
              color: C.green,
              opensExternally: true,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => _openExternalLink(context, necxaTermsUrl),
            child: const _SheetBtn(
              label: 'Necxa Terms',
              subtitle: 'goobox.necxa.uk/terms',
              icon: Icons.description_outlined,
              color: C.brand,
              opensExternally: true,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => _openExternalLink(context, necxaPolicyUrl),
            child: const _SheetBtn(
              label: 'Privacy Policy',
              subtitle: 'goobox.necxa.uk/policy',
              icon: Icons.policy_outlined,
              color: C.purple,
              opensExternally: true,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => _openExternalLink(context, necxaCompanyUrl),
            child: const _SheetBtn(
              label: 'Necxa Technology Ltd',
              subtitle: 'Necxa is a product of Necxa Technology Ltd • www.necxa.uk',
              icon: Icons.business_outlined,
              color: Colors.blueAccent,
              opensExternally: true,
            ),
          ),
          const SizedBox(height: 32),
          GestureDetector(
            onTap: () async {
              Navigator.pop(context);
              await Supabase.instance.client.auth.signOut();
              state.go('login');
            },
            child: const _SheetBtn(label: 'Log Out', icon: Icons.logout, color: Colors.redAccent),
          ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeToggleBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;

  const _ThemeToggleBtn({required this.label, required this.icon, required this.isActive, required this.activeColor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isActive ? activeColor.withOpacity(.2) : C.text.withOpacity(.05),
              shape: BoxShape.circle,
              border: Border.all(color: isActive ? activeColor : Colors.transparent),
            ),
            child: Icon(icon, color: isActive ? activeColor : C.dim, size: 24),
          ),
          const SizedBox(height: 8),
          Text(label, style: dm(sz: 11, w: isActive ? FontWeight.bold : FontWeight.normal, c: isActive ? activeColor : C.dim)),
        ],
      ),
    );
  }
}

class _SheetBtn extends StatelessWidget {
  final String label;
  final String? subtitle;
  final IconData icon;
  final Color color;
  final bool opensExternally;
  const _SheetBtn({
    required this.label,
    required this.icon,
    required this.color,
    this.subtitle,
    this.opensExternally = false,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(.03),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withOpacity(.05)),
    ),
    child: Row(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: syne(sz: 15, w: FontWeight.w600)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: dm(sz: 10, c: C.dim)),
              ],
            ],
          ),
        ),
        if (opensExternally)
          const Icon(Icons.open_in_new_rounded, color: Colors.white24, size: 16),
      ],
    ),
  );
}

class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  _SliverAppBarDelegate({ required this.minHeight, required this.maxHeight, required this.child });
  final double minHeight;
  final double maxHeight;
  final Widget child;
  @override double get minExtent => minHeight;
  @override double get maxExtent => maxHeight;
  @override Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => SizedBox.expand(child: child);
  @override bool shouldRebuild(_SliverAppBarDelegate oldDelegate) => maxHeight != oldDelegate.maxHeight || minHeight != oldDelegate.minHeight || child != oldDelegate.child;
}
