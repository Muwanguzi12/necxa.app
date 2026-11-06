import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../widgets/necxa_avatar.dart';
import 'dart:ui';

class ContactSyncScreen extends StatefulWidget {
  final AppState state;
  const ContactSyncScreen({super.key, required this.state});

  @override
  State<ContactSyncScreen> createState() => _ContactSyncScreenState();
}

class _ContactSyncScreenState extends State<ContactSyncScreen> {
  List<Map<String, dynamic>> _matches = [];
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _performSync();
  }

  Future<void> _performSync() async {
    setState(() { _isLoading = true; _hasError = false; });
    try {
      final results = await widget.state.discovery.discoverFriends();
      if (mounted) {
        setState(() {
          _matches = results;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Stack(
        children: [
          // Background Glow
          Positioned(
            top: -50, left: -50,
            child: Container(
              width: 200, height: 200,
              decoration: BoxDecoration(color: C.purple.withOpacity(0.1), shape: BoxShape.circle),
              child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50), child: const SizedBox()),
            ),
          ),
          
          CustomScrollView(
            slivers: [
              _buildHeader(),
              if (_isLoading)
                SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: C.brand))),
              if (!_isLoading && _matches.isEmpty)
                _buildEmptyState(),
              if (!_isLoading && _matches.isNotEmpty)
                _buildMatchesList(),
            ],
          ),

          // Bottom Back Button
          Positioned(
            bottom: 40, left: 24, right: 24,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: C.text.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: C.dim),
                ),
                child: Center(child: Text('RETURN TO PROFILE', style: syne(sz: 13, w: FontWeight.w900, ls: 1.5))),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 80, 24, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('DISCOVER FRIENDS', style: syne(sz: 12, w: FontWeight.w900, c: C.purple, ls: 2)),
            const SizedBox(height: 8),
            Text('People you know are already here.', style: syne(sz: 24, w: FontWeight.w800, ls: -0.5)),
            const SizedBox(height: 12),
            Text('We matched your contacts by email to find your friends on Necxa.', style: dm(sz: 14, c: C.sub)),
          ],
        ),
      ),
    );
  }

  Widget _buildMatchesList() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) {
            final friend = _matches[i];
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: C.text.withOpacity(0.03),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: C.text.withOpacity(0.05)),
              ),
              child: Row(
                children: [
                  NecxaAvatar(
                    userId: friend['id'],
                    name: friend['display_name'],
                    size: 50,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(friend['display_name'] ?? 'Necxa User', style: syne(sz: 15, w: FontWeight.w700)),
                        Text(friend['email'] ?? '', style: dm(sz: 12, c: C.sub)),
                      ],
                    ),
                  ),
                  _followBtn(friend['id']),
                ],
              ),
            );
          },
          childCount: _matches.length,
        ),
      ),
    );
  }

  Widget _followBtn(String userId) {
    bool isFollowing = widget.state.isFollowingSync(userId);
    bool isFriend = widget.state.isFriendSync(userId);
    return GestureDetector(
      onTap: () => widget.state.toggleFollow(userId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isFollowing ? Colors.transparent : C.brand,
          borderRadius: BorderRadius.circular(20),
          border: isFollowing ? Border.all(color: C.dim) : null,
        ),
        child: Text(
          isFriend ? 'FRIENDS' : isFollowing ? 'FOLLOWING' : 'FOLLOW',
          style: syne(sz: 10, w: FontWeight.w900, c: isFollowing ? C.sub : Colors.black),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_search_outlined, color: C.dim, size: 80),
            const SizedBox(height: 24),
            Text('No friends found yet', style: syne(sz: 18, w: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('Invite your friends to join Necxa to connect with them here.', style: dm(sz: 14, c: C.sub), textAlign: TextAlign.center),
            const SizedBox(height: 32),
            _ActionTile(
              label: 'Invite Friends',
              icon: Icons.share,
              color: C.brand,
              onTap: () {},
            ),
          ],
        ),
      ),
    );
  }
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


