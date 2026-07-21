import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'dart:ui';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../theme.dart';
import '../app_state.dart';
import '../widgets/necxa_video_player.dart';
import '../data.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:async';
import 'dart:convert';
import '../models/music_models.dart';
import '../services/music_library_service.dart';
import 'sound_hub_screen.dart';
import 'live_studio_screen.dart';
import '../widgets/checkout_overlay.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';

String? _extractListingImageUrl(dynamic value) {
  if (value == null) return null;
  if (value is String) return value.trim().isEmpty ? null : value.trim();
  if (value is Map) {
    for (final key in ['url', 'image_url', 'thumbnail_url', 'media_url', 'path']) {
      final url = _extractListingImageUrl(value[key]);
      if (url != null) return url;
    }
  }
  return null;
}

List<String> _listingPhotoUrls(dynamic rawPhotos) {
  dynamic value = rawPhotos;
  if (value is String && value.isNotEmpty) {
    try {
      value = jsonDecode(value);
    } catch (_) {
      final url = _extractListingImageUrl(value);
      return url == null ? [] : [url];
    }
  }
  if (value is List) {
    return value
        .map(_extractListingImageUrl)
        .whereType<String>()
        .where((url) => url.isNotEmpty)
        .toList();
  }
  final url = _extractListingImageUrl(value);
  return url == null ? [] : [url];
}

String? _primaryListingImageUrl(Map<String, dynamic> listing) {
  final photos = _listingPhotoUrls(
    listing['miniature_photos'] ?? listing['photos'] ?? listing['listing_photos'],
  );
  if (photos.isNotEmpty) return photos.first;
  return _extractListingImageUrl(listing['thumbnail_url']) ??
      _extractListingImageUrl(listing['image_url']) ??
      _extractListingImageUrl(listing['media_url']) ??
      _extractListingImageUrl(listing['film_hub_content']);
}

int communityDestinationTabIndex(String? destination) =>
    destination == 'shop' ? 1 : 0;

class CommunityScreen extends StatefulWidget {
  final AppState state;
  const CommunityScreen({super.key, required this.state});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  late PageController _pageController;
  int _selectedTab = 0; // 0: Feed, 1: Shop
  int _currentPageIndex = 0;
  List<Map<String, dynamic>> _currentItems = [];
  Future<List<Map<String, dynamic>>>? _itemsFuture;
  int _currentFeedLimit = 10;
  int _currentShopLimit = 10;

  @override
  void initState() {
    super.initState();
    final pendingDestination = widget.state.pendingDestinationTab;
    _selectedTab = communityDestinationTabIndex(
      pendingDestination ?? widget.state.creatorTab,
    );
    if (pendingDestination != null) {
      widget.state.pendingDestinationTab = null;
    }
    _currentPageIndex = _selectedTab == 0
        ? widget.state.communityFeedIndex
        : widget.state.communityShopIndex;
    _pageController = PageController(initialPage: _currentPageIndex);
    _refreshFuture();
    widget.state.addListener(_onStateUpdate);
  }

  void _onStateUpdate() {
    if (!mounted) return;

    // 🚀 NEURAL DESTINATION WARP: Consume pending tab switch from upload wizard
    final dest = widget.state.pendingDestinationTab;
    if (dest != null) {
      widget.state.pendingDestinationTab = null; // consume immediately
      final targetTabIndex = communityDestinationTabIndex(dest);
      if (_selectedTab != targetTabIndex) {
        setState(() {
          _selectedTab = targetTabIndex;
          _currentPageIndex = 0;
          _pageController.jumpToPage(0);
        });
        _refreshFuture(force: true); // Force fresh data so new upload is at top
        return;
      }
    }

    // Instead of unconditionally calling _refreshFuture() and causing an infinite loop,
    // we simply trigger a rebuild. The FutureBuilder will use the synchronous cache
    // from widget.state.social.feedPosts / shopListings to display data immediately.
    setState(() {});
  }

  void _refreshFuture({bool force = false}) {
    setState(() {
      _itemsFuture = _selectedTab == 0
          ? widget.state.social.fetchPosts(
              forceRefresh: force,
              limit: _currentFeedLimit,
            )
          : widget.state.social.fetchListings(
              forceRefresh: force,
              limit: _currentShopLimit,
            );

      // 🚀 DEEP LINK JUMP: If we have a target post ID, jump to it once items load
      if (widget.state.communityPostId != null) {
        _itemsFuture!.then((items) {
          final idx = items.indexWhere(
            (it) => it['id'] == widget.state.communityPostId,
          );
          if (idx != -1 && mounted) {
            setState(() {
              _currentPageIndex = idx;
              _pageController.jumpToPage(idx);
              widget.state.communityPostId = null; // Consume the ID
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateUpdate);
    _pageController.dispose();
    super.dispose();
  }

  void _handleHorizontalSwipe(DragEndDetails details) {
    if (details.primaryVelocity == null) return;
    if (details.primaryVelocity! > 500) {
      widget.state.go('home');
    } else if (details.primaryVelocity! < -500) {
      if (_currentItems.isNotEmpty &&
          _currentPageIndex < _currentItems.length) {
        final currentPost = _currentItems[_currentPageIndex];
        final authorId =
            currentPost['author_id'] ??
            currentPost['user_id'] ??
            currentPost['lister_id'];
        if (authorId != null) {
          widget.state.targetProfileId = authorId;
          widget.state.go('public_profile');
        }
      }
    }
  }

  void _handlePendingHandoff() {
    if (widget.state.pendingCheckoutListing == null) return;
    final listing = widget.state.pendingCheckoutListing!;
    widget.state.pendingCheckoutListing = null;
    setState(() {
      _selectedTab = 1;
    });
    widget.state.selectedListing = listing;
    widget.state.showCheckoutOverlay = true;
    widget.state.notify();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black, // Pure black primary background
      child: GestureDetector(
        onHorizontalDragEnd: _handleHorizontalSwipe,
        child: PopScope(
          canPop: !widget.state.showGiftFloat,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            if (widget.state.showGiftFloat) {
              widget.state.showGiftFloat = false;
              widget.state.notify();
            }
          },
          child: ListenableBuilder(
            listenable: widget.state,
            builder: (context, _) {
              // 🧪 NEURAL HANDOFF DETECTION
              if (widget.state.pendingCheckoutListing != null) {
                SchedulerBinding.instance.addPostFrameCallback(
                  (_) => _handlePendingHandoff(),
                );
              }

              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: FutureBuilder<List<Map<String, dynamic>>>(
                      future: _itemsFuture,
                      builder: (context, snapshot) {
                        // 1. SMART CACHE BINDING
                        // Prioritize the synchronous in-memory cache directly from SocialService.
                        // This prevents UI flickering and bypasses the infinite loading spinner issue.
                        final items = _selectedTab == 0
                            ? widget.state.social.feedPosts
                            : widget.state.social.shopListings;

                        if (items.isEmpty &&
                            snapshot.connectionState ==
                                ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(color: C.brand),
                          );
                        }

                        _currentItems = items; // Update local tracker

                        if (items.isEmpty) {
                          return _buildEmptyState(hasError: snapshot.hasError);
                        }

                        // Check for deep-link handover from Profile
                        if (widget.state.communityPostId != null &&
                            items.isNotEmpty) {
                          final targetId = widget.state.communityPostId;
                          final idx = items.indexWhere(
                            (it) => it['id'] == targetId,
                          );
                          if (idx != -1) {
                            // Clear before jump to avoid loops
                            widget.state.communityPostId = null;
                            SchedulerBinding.instance.addPostFrameCallback((_) {
                              if (_pageController.hasClients) {
                                _pageController.jumpToPage(idx);
                              }
                            });
                          }
                        }

                        return RefreshIndicator(
                          onRefresh: () async {
                            _refreshFuture(force: true);
                            await _itemsFuture;
                          },
                          color: C.brand,
                          backgroundColor: Colors.black,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (notification) {
                              if (notification is ScrollUpdateNotification) {
                                final velocity =
                                    notification.scrollDelta?.abs() ?? 0;
                                if (velocity > 50 && _selectedTab == 0) {
                                  // 🚀 NEURAL SYNC: Fast scrolling triggers prefetch
                                  widget.state.social.triggerPrefetch();
                                }
                              }
                              return false;
                            },
                            child: PageView.builder(
                              key: ValueKey(_selectedTab),
                              controller: _pageController,
                              scrollDirection: Axis.vertical,
                              physics: const BouncingScrollPhysics(),
                              itemCount: items.length,
                              onPageChanged: (index) {
                                _currentPageIndex = index;
                                if (_selectedTab == 0) {
                                  widget.state.communityFeedIndex = index;

                                  // 🚀 INFINITE PAGINATION TRIGGER (Near the end of Feed)
                                  if (index >= items.length - 2 &&
                                      items.isNotEmpty &&
                                      !widget.state.social.isSyncing('feed')) {
                                    final oldestTime = items.last['created_at'];
                                    if (oldestTime != null) {
                                      _currentFeedLimit += 10;
                                      widget.state.social
                                          .fetchOlderFeed(oldestTime)
                                          .then((_) {
                                            if (mounted) _refreshFuture();
                                          });
                                    }
                                  }
                                } else {
                                  widget.state.communityShopIndex = index;

                                  // 🚀 INFINITE PAGINATION TRIGGER (Near the end of Shop)
                                  if (index >= items.length - 2 &&
                                      items.isNotEmpty &&
                                      !widget.state.social.isSyncing('shop')) {
                                    final oldestTime = items.last['created_at'];
                                    if (oldestTime != null) {
                                      _currentShopLimit += 10;
                                      widget.state.social
                                          .fetchOlderListings(oldestTime)
                                          .then((_) {
                                            if (mounted) _refreshFuture();
                                          });
                                    }
                                  }
                                }
                              },
                              itemBuilder: (context, index) {
                                if (index >= items.length) {
                                  return const SizedBox.shrink();
                                }
                                final item = items[index];

                                if (_selectedTab == 0) {
                                  return _ReelItem(
                                    post: item,
                                    state: widget.state,
                                  );
                                } else {
                                  return _ShopReelItem(
                                    listing: item,
                                    state: widget.state,
                                  );
                                }
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Top HUD Layer
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 10,
                    left: 16,
                    right: 16,
                    child: AnimatedOpacity(
                      opacity: widget.state.isFeedCleanMode ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 300),
                      child: IgnorePointer(
                        ignoring: widget.state.isFeedCleanMode,
                        child: _buildTopHUDContent(),
                      ),
                    ),
                  ),
                  // Checkout Overlay
                  if (widget.state.showCheckoutOverlay)
                    CheckoutOverlay(state: widget.state),

                  // ── Smart Live Pipeline (Active Streams) ──
                  if (!widget.state.isFeedCleanMode)
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 65,
                      left: 0,
                      right: 0,
                      child: _buildLivePipeline(),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTopHUDContent() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Back Button (Dashboard Return)
        GestureDetector(
          onTap: () => widget.state.go('home'),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: const Icon(
              Icons.arrow_back_ios_new,
              color: Colors.white,
              size: 16,
            ),
          ),
        ),

        // Toggle Pill (Feed / Shop) + Sync Indicator above it
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSyncDots(),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () {
                setState(() {
                  _selectedTab = _selectedTab == 0 ? 1 : 0;
                  _currentItems = []; // Clear stale data

                  // 🚀 RESTORE PERSISTENCE: Use saved index from AppState for the target tab
                  _currentPageIndex = _selectedTab == 0
                      ? widget.state.communityFeedIndex
                      : widget.state.communityShopIndex;

                  if (_pageController.hasClients) {
                    _pageController.jumpToPage(_currentPageIndex);
                  }
                  // 🚀 FORCE SYNC: Ensure the Smart Loader triggers immediately on tab switch
                  _refreshFuture(force: true);
                });
              },
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _selectedTab == 0
                            ? Colors.white
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Text(
                        'Feed',
                        style: syne(
                          sz: 12,
                          w: FontWeight.bold,
                          c: _selectedTab == 0 ? Colors.black : Colors.white70,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _selectedTab == 1
                            ? Colors.white
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Text(
                        'Shop',
                        style: syne(
                          sz: 12,
                          w: FontWeight.bold,
                          c: _selectedTab == 1 ? Colors.black : Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        // Right Edge: Upload + Search stacked vertically
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Upload / New Shard Button
            GestureDetector(
              onTap: () => _showUploadOptions(context),
              child: Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                ),
                child: const Icon(
                  Icons.cloud_upload_outlined,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Search Button
            GestureDetector(
              onTap: () => _showSearchSheet(context),
              child: Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                ),
                child: const Icon(
                  Icons.search_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ],
    );
  }

  Widget _buildLivePipeline() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: widget.state.live.getActiveStreams(),
      builder: (context, snapshot) {
        final streams = snapshot.data ?? [];
        if (streams.isEmpty) return const SizedBox.shrink();

        return SizedBox(
          height: 70,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: streams.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final s = streams[i];
              final metadata = s['metadata'] as Map? ?? {};
              return GestureDetector(
                onTap: () {
                   Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LiveStudioScreen(
                        state: widget.state,
                        channelName: s['channelId'],
                        isHost: false,
                        hostId: s['hostId']?.toString(),
                      ),
                    ),
                  );
                },
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFF0000), Color(0xFFFF5C00)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(color: const Color(0xFFFF0000).withOpacity(0.3), blurRadius: 8),
                        ],
                      ),
                      child: CircleAvatar(
                        radius: 22,
                        backgroundColor: Colors.black,
                        backgroundImage: metadata['avatar'] != null && metadata['avatar'] != '' ? NetworkImage(metadata['avatar']) : null,
                        child: (metadata['avatar'] == null || metadata['avatar'] == '') ? const Icon(Icons.person, color: Colors.white, size: 20) : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      metadata['hostName']?.split(' ').first ?? 'Live',
                      style: syne(sz: 9, w: FontWeight.w900, c: Colors.white, ls: 0.5),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      }
    );
  }

  Widget _buildSyncDots() {
    return StreamBuilder<List<ConnectivityResult>>(
      stream: Connectivity().onConnectivityChanged,
      builder: (context, snapshot) {
        final results = snapshot.data ?? [];
        final isOffline =
            results.length == 1 && results.first == ConnectivityResult.none;
        final isSyncing = widget.state.social.isSyncing(
          _selectedTab == 0 ? 'feed' : 'shop',
        );

        // Color Logic per User Request:
        // Red: Fetching/Offline
        // Yellow: Loading/Syncing
        // Green: Success (We'll show all three but highlight the active one)

        final Color redCol = (isOffline || isSyncing)
            ? const Color(0xFFFF5252)
            : Colors.white10;
        final Color yellowCol = isSyncing
            ? const Color(0xFFFFD740)
            : Colors.white10;
        final Color greenCol = (!isOffline && !isSyncing)
            ? const Color(0xFF69F0AE)
            : Colors.white10;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dot(redCol, sz: 3, isPulse: isOffline),
            const SizedBox(width: 2),
            _dot(yellowCol, sz: 3, isPulse: isSyncing),
            const SizedBox(width: 2),
            _dot(greenCol, sz: 3),
          ],
        );
      },
    );
  }

  Widget _dot(Color color, {double sz = 4, bool isPulse = false}) {
    return Container(
      width: sz,
      height: sz,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: (color == Colors.white10 || isPulse)
            ? null
            : [
                BoxShadow(
                  color: color.withOpacity(0.4),
                  blurRadius: 3,
                  spreadRadius: 1,
                ),
              ],
      ),
    );
  }

  // Bottom nav removed per updated design specs

  Widget _buildEmptyState({bool hasError = false}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasError ? Icons.wifi_off_rounded : Icons.satellite_alt_outlined,
            size: 80,
            color: Colors.white.withOpacity(0.1),
          ),
          const SizedBox(height: 24),
          Text(
            hasError ? 'Network Disconnected' : 'Feed is Empty',
            style: syne(
              sz: 20,
              w: FontWeight.w900,
              c: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hasError 
                ? 'Please check your internet connection' 
                : 'No content available right now',
            style: dm(sz: 14, c: Colors.white.withOpacity(0.5)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          GestureDetector(
            onTap: () {
              setState(() {
                _itemsFuture = _selectedTab == 0
                    ? widget.state.social.fetchPosts(forceRefresh: true)
                    : widget.state.social.fetchListings(forceRefresh: true);
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: C.brand.withOpacity(0.2),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: C.brand),
              ),
              child: Text(
                'RETRY SYNC',
                style: dm(sz: 13, w: FontWeight.bold, c: C.brand, ls: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showUploadOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0D121B),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: Colors.white10),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 24),
            Text('CREATE CONTENT', style: syne(sz: 18, w: FontWeight.w900, c: Colors.white, ls: 1)),
            const SizedBox(height: 32),
            _uploadOption(
              icon: Icons.post_add_rounded,
              title: 'New Post',
              sub: 'Upload music, art, or videos',
              onTap: () {
                Navigator.pop(context);
                widget.state.go('upload');
              },
            ),
            const SizedBox(height: 16),
            _uploadOption(
              icon: Icons.live_tv_rounded,
              title: 'Go Live',
              sub: 'Start a superior live shop session',
              color: Colors.red,
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LiveStudioScreen(
                      state: widget.state,
                      channelName: '${widget.state.myProfile?['full_name'] ?? 'User'}_Live',
                      isHost: true,
                      hostId: widget.state.user?.id,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _uploadOption({required IconData icon, required String title, required String sub, required VoidCallback onTap, Color? color}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (color ?? C.brand).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color ?? C.brand, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: syne(sz: 15, w: FontWeight.bold, c: Colors.white)),
                  Text(sub, style: dm(sz: 11, c: Colors.white38)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white24, size: 14),
          ],
        ),
      ),
    );
  }

  void _showSearchSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _CommunitySearchSheet(state: widget.state, initialTab: _selectedTab),
    );
  }
}

class _ReelItem extends StatefulWidget {
  final Map<String, dynamic> post;
  final AppState state;
  const _ReelItem({required this.post, required this.state});

  @override
  State<_ReelItem> createState() => _ReelItemState();
}

class _ReelItemState extends State<_ReelItem> with TickerProviderStateMixin {
  bool _isLiked = false;
  int _likesCount = 0;
  int _commentsCount = 0;
  Map<String, dynamic>? _profile;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _audioInitialized = false;
  bool _isPlaying = true;
  final GlobalKey<NecxaVideoPlayerState> _videoKey = GlobalKey();

  // ── New UX States ──
  bool _isExpanded = false;
  final bool _isDescExpanded = false;
  bool _isCleanMode = false;
  bool _showCleanHint = false;
  late AnimationController _pulseController;
  late AnimationController _expandController;
  Timer? _collapseTimer;

  @override
  void initState() {
    super.initState();
    _likesCount = widget.post['likes_count'] ?? 0;
    _commentsCount = widget.post['comments_count'] ?? 0;
    _hydrateData();
    _initAudio();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _discController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
    if (_isPlaying) _discController.repeat();
  }

  late AnimationController _discController;

  Future<void> _initAudio() async {
    final audioUrl = widget.post['audio_url'];
    final isVideo = widget.post['media_type'] == 'video';

    // Only play secondary audio if it's NOT a video (videos have baked-in audio)
    if (audioUrl != null && !isVideo) {
      try {
        await _audioPlayer.setReleaseMode(ReleaseMode.loop);
        await _audioPlayer.setSourceUrl(audioUrl);
        await _audioPlayer.resume();
        if (mounted) {
          setState(() {
            _audioInitialized = true;
            _isPlaying = true;
          });
        }
      } catch (e) {
        debugPrint('Feed Audio Player Error: $e');
      }
    }
  }

  Future<void> _hydrateData() async {
    // 1. Fetch Profile if not already in the stream (which it typically isn't for Supabase streams)
    final profileId = widget.post['author_id'];
    if (profileId != null) {
      final p = await widget.state.social.getProfile(profileId);
      if (mounted) {
        setState(() {
          _profile = p;
        });
      }
    }

    // 2. Check individual like status
    if (widget.state.user != null) {
      try {
        final res = await Supabase.instance.client
            .from('community_likes')
            .select()
            .match({
              'post_id': widget.post['id'],
              'user_id': widget.state.user!.id,
            })
            .maybeSingle();
        if (mounted) setState(() => _isLiked = res != null);
      } catch (_) {}
    }
  }

  void _goToSoundHub() async {
    final trackId = widget.post['music_track_id'];
    if (trackId == null) return;

    // Show a small loader or feedback
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Opening Sound Hub...'),
        duration: Duration(milliseconds: 500),
      ),
    );

    final track = await widget.state.music.getTrackById(trackId);
    if (track != null && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SoundHubScreen(track: track, state: widget.state),
        ),
      );
    }
  }

  void _handleLike() async {
    if (widget.state.user == null) return;

    // Optimistic UI update
    setState(() {
      _isLiked = !_isLiked;
      if (_isLiked) {
        _likesCount++;
      } else {
        _likesCount--;
      }
    });

    // Background push
    try {
      await widget.state.social.toggleReaction(widget.post['id']);
    } catch (e) {
      // Revert if failed
      if (mounted) {
        setState(() {
          _isLiked = !_isLiked;
          if (_isLiked) {
            _likesCount++;
          } else {
            _likesCount--;
          }
        });
      }
    }
  }

  void _showComments() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          _CommentSheet(post: widget.post, state: widget.state),
    ).then((_) {
      // Refresh count if needed
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _pulseController.dispose();
    _expandController.dispose();
    _discController.dispose();
    _collapseTimer?.cancel();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        // 🚀 SYNC: Pause when expanding to focus on creator
        if (_isPlaying) _togglePlayPause();
        _expandController.forward();
        _startCollapseTimer();
      } else {
        _expandController.reverse();
        _collapseTimer?.cancel();
      }
    });
  }

  void _startCollapseTimer() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isExpanded) {
        setState(() {
          _isExpanded = false;
          _expandController.reverse();
        });
      }
    });
  }

  void _enterCleanMode() {
    setState(() {
      _isCleanMode = true;
      _isExpanded = false;
      _expandController.reverse();
      _showCleanHint = true;
      // 🚀 SYNC: Ensure playing in clean mode
      if (!_isPlaying) _togglePlayPause();
    });
    widget.state.isFeedCleanMode = true;
    widget.state.notify();

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showCleanHint = false);
    });
  }

  void _exitCleanMode() {
    if (_isCleanMode) {
      setState(() => _isCleanMode = false);
      widget.state.isFeedCleanMode = false;
      widget.state.notify();
      // Optional: pause if they were just watching clean?
    }
  }

  void _collapseIfExpanded() {
    if (_isExpanded) {
      setState(() {
        _isExpanded = false;
        _expandController.reverse();
        _collapseTimer?.cancel();
      });
    }
  }

  void _togglePlayPause() {
    if (_videoKey.currentState != null) {
      _videoKey.currentState!.togglePlay();
    } else {
      setState(() {
        _isPlaying = !_isPlaying;
        if (_isPlaying) {
          _audioPlayer.resume();
          _discController.repeat();
        } else {
          _audioPlayer.pause();
          _discController.stop();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaUrl = widget.post['media_url'];
    // Robust Type Detection & URL selection
    final String? hlsUrl =
        (widget.post['hls_url']?.toString().isNotEmpty ?? false)
        ? widget.post['hls_url']
        : null;
    final String? dashUrl =
        (widget.post['dash_url']?.toString().isNotEmpty ?? false)
        ? widget.post['dash_url']
        : null;
    final String? videoUrl = hlsUrl ?? dashUrl ?? mediaUrl;
    final username = _profile?['display_name'] ?? 'Necxa User';
    final description = widget.post['content'] ?? widget.post['title'] ?? '';

    final bool isVideo =
        widget.post['media_type'] == 'video' ||
        (videoUrl != null &&
            (videoUrl.toLowerCase().contains('.mp4') ||
                videoUrl.toLowerCase().contains('.mov') ||
                videoUrl.toLowerCase().contains('.m3u8')));

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. SMART ADAPTIVE BACKGROUND (Blurred Cover)
        if (mediaUrl != null && mediaUrl.isNotEmpty)
          Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                imageUrl: mediaUrl,
                fit: BoxFit.cover,
                errorWidget: (context, error, stack) =>
                    _buildFallbackBackground(),
              ),
              ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    color: const Color(0x660A0F2C),
                  ), // 40% opacity Night Blue
                ),
              ),
              Container(color: Colors.black26),
            ],
          ),

        // 2. MAIN CONTENT LAYER (Actual Ratio - Contain)
        mediaUrl != null && mediaUrl.isNotEmpty
            ? Center(
                child: isVideo
                    ? NecxaVideoPlayer(
                        key: _videoKey,
                        url: videoUrl ?? '',
                        audioUrl: widget.post['audio_url'],
                        adaptive: true, // 🚀 RESTORED: Always original size
                        lowDataMode: widget.state.isDataSaverMode,
                        onToggle: (playing) => setState(() {
                          _isPlaying = playing;
                          if (playing) {
                            _discController.repeat();
                          } else {
                            _discController.stop();
                          }
                        }),
                      )
                    : GestureDetector(
                        onTap: () {
                          setState(() {
                            _isPlaying = !_isPlaying;
                            if (_isPlaying) {
                              _audioPlayer.resume();
                              _discController.repeat();
                            } else {
                              _audioPlayer.pause();
                              _discController.stop();
                            }
                          });
                        },
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CachedNetworkImage(
                              imageUrl: mediaUrl,
                              fit: BoxFit.contain,
                              placeholder: (context, url) => const Center(
                                child: CircularProgressIndicator(
                                  color: C.brand,
                                  strokeWidth: 2,
                                ),
                              ),
                              errorWidget: (context, url, error) => Stack(
                                children: [
                                  _buildFallbackBackground(),
                                  const Center(
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      color: Colors.white24,
                                      size: 48,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
              )
            : _buildFallbackBackground(),

        // 2. NEURAL GESTURE LAYER (DEAD SPACE ONLY)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_isCleanMode) {
                _exitCleanMode();
              } else if (_isExpanded) {
                _toggleExpanded();
              } else {
                _togglePlayPause();
              }
            },
            onLongPress: () {
              setState(() => _isCleanMode = true);
              Future.delayed(const Duration(seconds: 3), () {
                if (mounted) setState(() => _isCleanMode = false);
              });
            },
            child: Container(color: Colors.transparent),
          ),
        ),

        // 3. UI Layer (TOP LAYER)
        AnimatedOpacity(
          opacity: _isCleanMode ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 300),
          child: IgnorePointer(
            ignoring: _isCleanMode,
            child: Stack(
              children: [
                // Scrim
                IgnorePointer(
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black26,
                          Colors.transparent,
                          Colors.black87,
                        ],
                      ),
                    ),
                  ),
                ),

                // Creator Bubble
                Positioned(
                  left: 16,
                  bottom: MediaQuery.of(context).padding.bottom + 120,
                  child: _buildExpandableBubble(),
                ),

                // Info Section
                Positioned(
                  left: 20,
                  bottom: MediaQuery.of(context).padding.bottom + 40,
                  right: 80,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '@$username',
                        style: syne(
                          sz: 13,
                          w: FontWeight.w900,
                          c: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        description,
                        style: dm(sz: 13, c: Colors.white.withOpacity(0.9)),
                      ),

                      // 🚀 SHOP REEL: Inline Buy Button if linked to a listing
                      if (widget.post['listings'] != null) ...[
                        const SizedBox(height: 12),
                        _buildMiniBuyCard(widget.post['listings']),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        if (_isCleanMode)
          GestureDetector(
            onTap: () {
              _exitCleanMode();
              _togglePlayPause();
            },
            child: Container(
              color: Colors.transparent,
              child: _showCleanHint
                  ? Center(
                      child: Text(
                        'Tap to exit clean mode',
                        style: dm(sz: 13, c: Colors.white38),
                      ),
                    )
                  : null,
            ),
          ),

        // 5. ROTATING SOUND DISC (Bottom Right)
        Positioned(
          right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 40,
          child: AnimatedOpacity(
            opacity: _isCleanMode ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 300),
            child: IgnorePointer(
              ignoring: _isCleanMode,
              child: GestureDetector(
                onTap: _goToSoundHub,
                child: _buildRotatingDisc(),
              ),
            ),
          ),
        ),

        // 4. Side Action Hub
        Positioned(
          right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 100,
          child: AnimatedOpacity(
            opacity: _isCleanMode ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 300),
            child: IgnorePointer(
              ignoring: _isCleanMode,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _actionButton(
                    icon: _isLiked ? Icons.favorite : Icons.favorite_outline,
                    label: kNum(_likesCount),
                    iconColor: _isLiked ? Colors.redAccent : Colors.white,
                    onTap: _handleLike,
                  ),
                  const SizedBox(height: 14),
                  _actionButton(
                    icon: Icons.chat_bubble_outline,
                    label: kNum(_commentsCount),
                    onTap: _showComments,
                  ),
                  const SizedBox(height: 14),
                  _actionButton(
                    icon: Icons.card_giftcard,
                    label: 'Gift',
                    iconColor: Colors.amberAccent,
                    onTap: () {
                      widget.state.targetProfileId = widget.post['author_id'];
                      widget.state.listingId = widget.post['id'];
                      widget.state.showGiftFloat = true;
                      widget.state.notify();
                    },
                  ),
                  const SizedBox(height: 14),
                  _actionButton(
                    icon: Icons.share_outlined,
                    label: 'Share',
                    onTap: () async {
                      final String urlToShare = mediaUrl ?? 'https://necxa.app';
                      final String shareText =
                          'Check out this amazing post on Necxa!\n\n${description.isNotEmpty ? '"$description"\n\n' : ''}$urlToShare';
                      await Share.share(
                        shareText,
                        subject: 'Necxa Post by @$username',
                      );

                      // 🚀 REDIS NOTIFICATION
                      widget.state.social.notifySocialEvent(
                        'share',
                        widget.post['id'],
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  _actionButton(
                    icon: Icons.more_horiz,
                    label: 'More',
                    onTap: () => _showPostOptions(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showPostOptions() {
    final bool isOwner = widget.state.user?.id == widget.post['author_id'];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0D121B),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              ListTile(
                leading: const Icon(
                  Icons.report_problem_outlined,
                  color: Colors.white,
                ),
                title: Text(
                  'Report Content',
                  style: dm(sz: 16, c: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  // Implement report
                },
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color iconColor = Colors.white,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: dm(sz: 8, w: FontWeight.w700, c: Colors.white, ls: 1),
          ),
        ],
      ),
    );
  }

  // ── NEW UI COMPONENTS ───────────────────────────────────────

  Widget _buildExpandableBubble() {
    return GestureDetector(
      onTap: () {}, // Handled by children to prevent whole-stack interception
      child: Stack(
        alignment: Alignment.centerLeft,
        clipBehavior: Clip.none, // Allow glow to breathe without capturing hits
        children: [
          // Expanded Panel (Grows from Avatar)
          SizeTransition(
            sizeFactor: _expandController,
            axis: Axis.horizontal,
            axisAlignment: -1,
            child: GestureDetector(
              onTap: () {
                _startCollapseTimer();
                // Custom logic for panel expansion if needed
              },
              child: _buildExpandedPanel(),
            ),
          ),

          // Avatar (The primary toggle)
          GestureDetector(
            onTap: () {
              if (!_isExpanded) _toggleExpanded();
              _startCollapseTimer();
            },
            child: _buildAvatar(),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    final photoUrl = _profile?['photo_url'];
    final username = _profile?['display_name'] ?? 'U';

    return ScaleTransition(
      scale: Tween(begin: 1.0, end: 1.05).animate(
        CurvedAnimation(parent: _expandController, curve: Curves.easeOut),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Glowing Pulse Ring
          ScaleTransition(
            scale: Tween(begin: 0.9, end: 1.2).animate(_pulseController),
            child: FadeTransition(
              opacity: Tween(begin: 0.6, end: 0.0).animate(_pulseController),
              child: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF00E5FF),
                ),
              ),
            ),
          ),

          // Outer Ring
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x3300E5FF),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),

          // Actual Avatar
          GestureDetector(
            onTap: () {
              if (_isExpanded) {
                // Navigate to profile
                widget.state.targetProfileId = widget.post['author_id'];
                widget.state.go('public_profile');
              } else {
                _toggleExpanded();
              }
            },
            child: CircleAvatar(
              radius: 21,
              backgroundColor: const Color(0xFF0A0F2C),
              backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
              child: photoUrl == null
                  ? Text(
                      username.isNotEmpty ? username[0].toUpperCase() : 'U',
                      style: syne(c: Colors.white, w: FontWeight.bold),
                    )
                  : null,
            ),
          ),

          // Status Dot (Legacy)
          Positioned(
            top: 2,
            right: 2,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black, width: 2),
              ),
            ),
          ),

          // 🚀 PROFESSIONAL FOLLOW BUTTON (+)
          Positioned(
            bottom: -2,
            child: ListenableBuilder(
              listenable: widget.state,
              builder: (context, _) {
                final authorId = widget.post['author_id'];
                final isFollowed = widget.state.followed.contains(authorId);

                return AnimatedScale(
                  scale: (isFollowed || authorId == widget.state.user?.id)
                      ? 0.0
                      : 1.0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutBack,
                  child: GestureDetector(
                    onTap: () {
                      if (authorId != null) {
                        widget.state.toggleFollow(authorId);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Color(0xFF00E5FF),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: Colors.black26, blurRadius: 4),
                        ],
                      ),
                      child: const Icon(
                        Icons.add,
                        color: Colors.black,
                        size: 14,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedPanel() {
    final username = _profile?['display_name'] ?? 'Necxa User';
    final description = widget.post['content'] ?? 'it’s so wonderful';

    return Container(
      height: 46,
      margin: const EdgeInsets.only(left: 20), // Offset for avatar
      padding: const EdgeInsets.fromLTRB(28, 4, 12, 4),
      constraints: const BoxConstraints(maxWidth: 260),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F2C).withOpacity(0.5),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 15),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // User Info
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      username,
                      style: syne(sz: 13, w: FontWeight.bold, c: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),

              // Follow Button
              _FollowButton(
                onTap: () {
                  _startCollapseTimer();
                  final authorId = widget.post['author_id'];
                  if (authorId != null) {
                    widget.state.toggleFollow(authorId);
                  }
                },
              ),

              const SizedBox(width: 8),

              // Creator Chat
              GestureDetector(
                onTap: () {
                  _startCollapseTimer();
                  final authorId = widget.post['author_id'];
                  if (authorId != null) {
                    final postTitle =
                        widget.post['title'] ??
                        widget.post['content'] ??
                        'your recent post';
                    // Truncate long content
                    final shortTitle = postTitle.length > 30
                        ? '${postTitle.substring(0, 30)}...'
                        : postTitle;

                    widget.state.openCreatorChat(
                      authorId,
                      _profile?['display_name'] ?? 'Creator',
                      _profile?['photo_url'],
                      initialContextText: "Hi! I saw your post: $shortTitle",
                      context: 'social',
                    );
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.chat_bubble_outline_rounded,
                    color: Color(0xFF00E5FF),
                    size: 16,
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // Global Mute Toggle (Sync)
              ListenableBuilder(
                listenable: widget.state,
                builder: (context, _) {
                  return GestureDetector(
                    onTap: () {
                      _startCollapseTimer();
                      widget.state.setGlobalMute(!widget.state.isGlobalMuted);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: widget.state.isGlobalMuted
                            ? Colors.redAccent.withOpacity(0.2)
                            : Colors.white.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        widget.state.isGlobalMuted
                            ? Icons.volume_off
                            : Icons.volume_up,
                        color: widget.state.isGlobalMuted
                            ? Colors.redAccent
                            : const Color(0xFF00E5FF),
                        size: 16,
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(width: 8),

              // Menu
              GestureDetector(
                onTap: () {
                  _startCollapseTimer();
                  _showThreeDotMenu(context);
                },
                child: const Icon(
                  Icons.more_horiz,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showThreeDotMenu(BuildContext context) {
    final RenderBox box = context.findRenderObject() as RenderBox;
    final Offset position = box.localToGlobal(Offset.zero);

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Menu',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) {
        return Stack(
          children: [
            Positioned(
              left: 16,
              bottom:
                  MediaQuery.of(context).padding.bottom +
                  195, // Above the panel
              child: Material(
                color: Colors.transparent,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Container(
                      width: 180,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A0F2C).withOpacity(0.8),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _menuItem(
                            'Enter Clean Mode ✨',
                            Icons.auto_awesome,
                            isAccent: true,
                            onTap: () {
                              Navigator.pop(context);
                              _enterCleanMode();
                            },
                          ),
                          _menuItem(
                            'Mute',
                            Icons.volume_off_outlined,
                            onTap: () => Navigator.pop(context),
                          ),
                          _menuItem(
                            'Save',
                            Icons.bookmark_border,
                            onTap: () {
                              Navigator.pop(context);
                              widget.state.toggleSavePost(widget.post['id']);
                            },
                          ),
                          _menuItem(
                            'Not Interested',
                            Icons.sentiment_dissatisfied,
                            onTap: () {
                              Navigator.pop(context);
                              widget.state.notInterested(
                                widget.post['id'],
                                'post',
                              );
                            },
                          ),
                          _menuItem(
                            'Report',
                            Icons.flag_outlined,
                            color: Colors.redAccent,
                            onTap: () {
                              Navigator.pop(context);
                              widget.state.reportContent(
                                widget.post['id'],
                                'post',
                                'Inappropriate content',
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Post reported'),
                                  backgroundColor: Colors.redAccent,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _menuItem(
    String label,
    IconData icon, {
    Color? color,
    bool isAccent = false,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color:
                  color ??
                  (isAccent ? const Color(0xFF00E5FF) : Colors.white70),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: dm(
                  sz: 13,
                  c:
                      color ??
                      (isAccent ? const Color(0xFF00E5FF) : Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRotatingDisc() {
    return RotationTransition(
      turns: _discController,
      child: Container(
        width: 40,
        height: 40,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const SweepGradient(
            colors: [Colors.black, Colors.grey, Colors.black],
          ),
          border: Border.all(color: Colors.white24, width: 2),
        ),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.black,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.music_note, color: Colors.white, size: 12),
        ),
      ),
    );
  }

  Widget _buildGalleryViewer(List<String> urls) {
    return PageView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: urls.length,
      itemBuilder: (context, i) => Image.network(
        urls[i],
        fit: BoxFit.contain,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white24,
            ),
          );
        },
      ),
    );
  }

  Widget _buildMiniBuyCard(Map<String, dynamic> listing) {
    final url = _primaryListingImageUrl(listing);
    final price = num.tryParse(listing['price']?.toString() ?? '0') ?? 0;

    return GestureDetector(
      onTap: () {
        widget.state.selectedListing = listing;
        widget.state.showCheckoutOverlay = true;
        widget.state.notify();
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    width: 30,
                    height: 30,
                    color: Colors.white.withOpacity(0.05),
                    child: url != null && url.isNotEmpty
                        ? Image.network(
                            url,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) => const Icon(
                              Icons.shopping_bag_outlined,
                              color: Colors.white24,
                              size: 14,
                            ),
                          )
                        : const Icon(
                            Icons.shopping_bag_outlined,
                            color: Colors.white24,
                            size: 14,
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'BUY NOW',
                      style: syne(
                        sz: 10,
                        w: FontWeight.w900,
                        c: Colors.white,
                        ls: 1,
                      ),
                    ),
                    Text(
                      ugx(price),
                      style: dm(
                        sz: 11,
                        w: FontWeight.bold,
                        c: const Color(0xFF00E5FF),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.arrow_forward_ios,
                  color: Colors.white54,
                  size: 10,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFallbackBackground() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [C.cardDk, C.bg],
        ),
      ),
      child: const Center(
        child: Icon(Icons.style_outlined, size: 100, color: Colors.white10),
      ),
    );
  }
}

// ── UI HELPERS ─────────────────────────────────────────────────────────────

class _FollowButton extends StatefulWidget {
  final VoidCallback onTap;
  const _FollowButton({required this.onTap});

  @override
  State<_FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends State<_FollowButton> {
  bool _following = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        setState(() => _following = !_following);
        widget.onTap();
      },
      child: AnimatedScale(
        scale: 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            gradient: _following
                ? null
                : const LinearGradient(
                    colors: [Color(0xFF00E5FF), Color(0xFF00B2CC)],
                  ),
            color: _following ? Colors.white24 : null,
            borderRadius: BorderRadius.circular(16),
            boxShadow: _following
                ? null
                : [
                    BoxShadow(
                      color: const Color(0xFF00E5FF).withOpacity(0.3),
                      blurRadius: 8,
                    ),
                  ],
          ),
          child: Text(
            _following ? 'Following' : 'Follow',
            style: syne(
              sz: 11,
              w: FontWeight.w900,
              c: _following ? Colors.white : Colors.black,
            ),
          ),
        ),
      ),
    );
  }
}

class PillarVsync extends TickerProvider {
  final TickerProvider tp;
  PillarVsync(this.tp);
  @override
  Ticker createTicker(TickerCallback onTick) => tp.createTicker(onTick);
}

// ── Shop Reel Item ────────────────────────────────────────────────────────
class _ShopReelItem extends StatefulWidget {
  final Map<String, dynamic> listing;
  final AppState state;
  const _ShopReelItem({required this.listing, required this.state});

  @override
  State<_ShopReelItem> createState() => _ShopReelItemState();
}

class _ShopReelItemState extends State<_ShopReelItem>
    with TickerProviderStateMixin {
  final GlobalKey<NecxaVideoPlayerState> _videoKey =
      GlobalKey<NecxaVideoPlayerState>();
  bool _buyPanelVisible = false;
  Timer? _buyPanelTimer;

  bool _isLiked = false;
  int _likesCount = 0;
  int _commentsCount = 0;

  // New Bubble States
  bool _isExpanded = false;
  late AnimationController _pulseController;
  late AnimationController _expandController;
  Timer? _collapseTimer;

  @override
  void initState() {
    super.initState();
    _isLiked = widget.listing['is_liked'] == true;
    _likesCount = widget.listing['likes_count'] ?? 0;
    _commentsCount = widget.listing['comments_count'] ?? 0;

    // 🚀 CLEVER LOADING: Delay the buy panel by 4s to save data and focus on media
    _buyPanelTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _buyPanelVisible = true);
    });

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _expandController.forward();
        _startCollapseTimer();
      } else {
        _expandController.reverse();
        _collapseTimer?.cancel();
      }
    });
  }

  void _startCollapseTimer() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isExpanded) {
        setState(() {
          _isExpanded = false;
          _expandController.reverse();
        });
      }
    });
  }

  @override
  void dispose() {
    _buyPanelTimer?.cancel();
    _pulseController.dispose();
    _expandController.dispose();
    _collapseTimer?.cancel();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_videoKey.currentState != null) {
      _videoKey.currentState!.togglePlay();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 🚀 FILM HUB: Background always prioritizes the main media_url (Video/Reel)
    // Using explicit backend path if available
    final photos = (widget.listing['photos'] is String)
        ? (jsonDecode(widget.listing['photos']) as List? ?? [])
        : (widget.listing['photos'] as List? ?? []);
    final firstPhoto = photos.isNotEmpty ? photos[0] : null;

    final mediaUrl =
        widget.listing['media_url'] ??
        widget.listing['film_hub_content'] ??
        (widget.listing['hls_url'] ?? widget.listing['video_url']) ??
        firstPhoto;
    final price = widget.listing['price'] ?? 0;
    final title = widget.listing['title'] ?? 'Luxury Shard';
    final description = widget.listing['description'] ?? '';

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. ADAPTIVE BACKGROUND (Blurred Cover)
        if (mediaUrl != null && mediaUrl.isNotEmpty)
          Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                mediaUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => _buildFallback(),
              ),
              ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(color: const Color(0x660A0F2C)),
                ),
              ),
              Container(color: Colors.black45),
            ],
          ),

        // 2. MAIN CONTENT LAYER (Actual Ratio - Contain)
        if (mediaUrl != null && mediaUrl.isNotEmpty)
          Center(
            child:
                (widget.listing['media_type'] == 'video' ||
                    mediaUrl.toLowerCase().contains('.mp4') ||
                    mediaUrl.toLowerCase().contains('.mov') ||
                    mediaUrl.toLowerCase().contains('.m3u8'))
                ? NecxaVideoPlayer(
                    key: _videoKey,
                    url: mediaUrl,
                    adaptive:
                        true, // 🚀 FILM HUB: Always use original aspect ratio
                    lowDataMode: widget.state.isDataSaverMode,
                    state: widget.state,
                  )
                : Image.network(
                    mediaUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) =>
                        const SizedBox.shrink(),
                  ),
          )
        else
          _buildFallback(),

        // 3. Clean Mode & Play/Pause Listener (DEAD SPACE ONLY)
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPress: () {
            widget.state.isFeedCleanMode = true;
            widget.state.notify();
            Future.delayed(const Duration(seconds: 3), () {
              widget.state.isFeedCleanMode = false;
              widget.state.notify();
            });
          },
          onTap: () {
            if (widget.state.isFeedCleanMode) {
              widget.state.isFeedCleanMode = false;
              widget.state.notify();
              _togglePlayPause();
            } else {
              _togglePlayPause();
            }
          },
          child: Container(color: Colors.transparent),
        ),

        // 4. OVERLAY GRADIENT
        AnimatedOpacity(
          opacity: widget.state.isFeedCleanMode ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 300),
          child: IgnorePointer(
            ignoring: true,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black26, Colors.transparent, Colors.black],
                ),
              ),
            ),
          ),
        ),

        // 5. SIDE ACTION HUB (RIGHT)
        Positioned(
          right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 120,
          child: AnimatedOpacity(
            opacity: widget.state.isFeedCleanMode ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 300),
            child: IgnorePointer(
              ignoring: widget.state.isFeedCleanMode,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _shopAction(
                    icon: _isLiked ? Icons.favorite : Icons.favorite_outline,
                    label: kNum(_likesCount),
                    iconColor: _isLiked ? Colors.redAccent : Colors.white,
                    onTap: () => setState(() => _isLiked = !_isLiked),
                  ),
                  const SizedBox(height: 16),
                  _shopAction(
                    icon: Icons.chat_bubble_outline,
                    label: kNum(_commentsCount),
                    onTap: () =>
                        _showCommentSheet(context, widget.listing['id']),
                  ),
                  const SizedBox(height: 16),
                  _shopAction(
                    icon: Icons.message_outlined,
                    label: 'Chat',
                    iconColor: const Color(0xFF00E5FF),
                    onTap: () {
                      final authorId =
                          widget.listing['author_id'] ??
                          widget.listing['user_id'] ??
                          widget.listing['lister_id'];
                      if (authorId != null) {
                        final vendorName =
                            widget.listing['lister_name'] ?? 'Vendor';
                        final vendorAvatar = widget.listing['lister_avatar'];
                        final title = widget.listing['title'] ?? 'your item';

                        widget.state.openCreatorChat(
                          authorId,
                          vendorName,
                          vendorAvatar,
                          initialContextText: "Hi! I am interested in: $title",
                          context: 'vendor',
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  _shopAction(
                    icon: Icons.card_giftcard,
                    label: 'Gift',
                    iconColor: Colors.amberAccent,
                    onTap: () {
                      widget.state.targetProfileId = authorId;
                      widget.state.showGiftFloat = true;
                      widget.state.notify();
                    },
                  ),
                  const SizedBox(height: 16),
                  _shopAction(
                    icon: Icons.star_outline,
                    label: 'Reviews',
                    iconColor: Colors.orangeAccent,
                    onTap: () => _showReviewSheet(context),
                  ),
                  const SizedBox(height: 16),
                  _shopAction(
                    icon: Icons.share_outlined,
                    label: 'Share',
                    onTap: () {
                      final title = widget.listing['title'] ?? 'Luxury Product';
                      final sku = widget.listing['sku'] ?? 'sku';
                      final url =
                          "https://necxa.app/listing/${widget.listing['id']}?sku=$sku";
                      // External Share Linkage
                      debugPrint('🔗 Sharing linkage: $url');
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Link copied: $url')),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),

        // 6. BOTTOM INTERACTIVE UI (LEFT)
        Positioned(
          left: 16,
          bottom: MediaQuery.of(context).padding.bottom + 20,
          right: 80, // Leave space for side actions
          child: AnimatedOpacity(
            opacity: widget.state.isFeedCleanMode ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 300),
            child: IgnorePointer(
              ignoring: widget.state.isFeedCleanMode,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1. Creator Info Bubble
                  _buildExpandableBubble(),
                  const SizedBox(height: 12),

                  // 2. Product Description & Price (Always visible)
                  Text(
                    title,
                    style: syne(sz: 14, w: FontWeight.w900, c: Colors.white),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: dm(sz: 12, c: Colors.white70),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),

                  // 3. 4s DELAYED BUY OVERLAY
                  // This overlays on top but is fairly small as requested.
                  if (_buyPanelVisible) _buildExpandedBuyPanel(context),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingPlaceholder() {
    return Container(
      width: double.infinity,
      height: 90,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF00E5FF),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 120, height: 10, color: Colors.white10),
              const SizedBox(height: 8),
              Container(width: 80, height: 10, color: Colors.white10),
            ],
          ),
        ],
      ),
    );
  }

  String? get authorId =>
      widget.listing['author_id'] ??
      widget.listing['user_id'] ??
      widget.listing['lister_id'];

  Widget _buildExpandableBubble() {
    return GestureDetector(
      onTap: () {}, // Handled by children
      child: Stack(
        alignment: Alignment.centerLeft,
        clipBehavior: Clip.none,
        children: [
          // Expanded Panel (Grows from Avatar)
          SizeTransition(
            sizeFactor: _expandController,
            axis: Axis.horizontal,
            axisAlignment: -1,
            child: GestureDetector(
              onTap: () {
                _startCollapseTimer();
              },
              child: _buildExpandedPanel(),
            ),
          ),

          // Avatar (The primary toggle)
          GestureDetector(
            onTap: () {
              if (!_isExpanded) _toggleExpanded();
              _startCollapseTimer();
            },
            child: _buildAvatar(),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    // 🚀 LOCAL-FIRST: Prioritize denormalized data from SQLite
    final String photoUrl = widget.listing['lister_avatar'] ?? '';
    final String username = widget.listing['lister_name'] ?? 'Vendor';

    return ScaleTransition(
      scale: Tween(begin: 1.0, end: 1.05).animate(
        CurvedAnimation(parent: _expandController, curve: Curves.easeOut),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Glowing Pulse Ring
          ScaleTransition(
            scale: Tween(begin: 0.9, end: 1.2).animate(_pulseController),
            child: FadeTransition(
              opacity: Tween(begin: 0.6, end: 0.0).animate(_pulseController),
              child: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF00E5FF),
                ),
              ),
            ),
          ),

          // Outer Ring
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x3300E5FF),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),

          // Actual Avatar
          GestureDetector(
            onTap: () {
              if (_isExpanded) {
                if (authorId != null) {
                  widget.state.targetProfileId = authorId;
                  widget.state.go('public_profile');
                }
              } else {
                _toggleExpanded();
              }
            },
            child: CircleAvatar(
              radius: 21,
              backgroundColor: const Color(0xFF0A0F2C),
              backgroundImage: NetworkImage(photoUrl),
              child: null,
            ),
          ),

          // Professional Follow Button (+)
          Positioned(
            bottom: -2,
            child: ListenableBuilder(
              listenable: widget.state,
              builder: (context, _) {
                final isFollowed =
                    authorId != null &&
                    widget.state.followed.contains(authorId);

                return AnimatedScale(
                  scale: (isFollowed || authorId == widget.state.user?.id)
                      ? 0.0
                      : 1.0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutBack,
                  child: GestureDetector(
                    onTap: () {
                      if (authorId != null) {
                        widget.state.toggleFollow(authorId!);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Color(0xFF00E5FF),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: Colors.black26, blurRadius: 4),
                        ],
                      ),
                      child: const Icon(
                        Icons.add,
                        color: Colors.black,
                        size: 14,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedPanel() {
    final rawProf = widget.listing['profiles'] ?? widget.listing['lister'];
    final prof = (rawProf is List && rawProf.isNotEmpty)
        ? rawProf[0]
        : (rawProf is Map ? rawProf : null);
    final username = prof?['display_name'] ?? prof?['full_name'] ?? 'Vendor';

    return Container(
      height: 46,
      margin: const EdgeInsets.only(left: 20),
      padding: const EdgeInsets.fromLTRB(28, 4, 12, 4),
      constraints: const BoxConstraints(maxWidth: 240),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F2C).withOpacity(0.5),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 15),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // User Info
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      username,
                      style: syne(sz: 13, w: FontWeight.bold, c: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),

              // Follow Button
              _FollowButton(
                onTap: () {
                  _startCollapseTimer();
                  if (authorId != null) {
                    widget.state.toggleFollow(authorId!);
                  }
                },
              ),

              const SizedBox(width: 8),

              // Creator Chat
              GestureDetector(
                onTap: () {
                  _startCollapseTimer();
                  if (authorId != null) {
                    final title = widget.listing['title'] ?? 'your item';
                    widget.state.openCreatorChat(
                      authorId!,
                      prof?['display_name'] ?? prof?['full_name'] ?? 'Vendor',
                      prof?['photo_url'] ?? prof?['avatar_url'],
                      initialContextText: "Hi! I am interested in: $title",
                      context: 'vendor',
                    );
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.chat_bubble_outline_rounded,
                    color: Color(0xFF00E5FF),
                    size: 16,
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // Global Mute Toggle (Sync)
              ListenableBuilder(
                listenable: widget.state,
                builder: (context, _) {
                  return GestureDetector(
                    onTap: () {
                      _startCollapseTimer();
                      widget.state.setGlobalMute(!widget.state.isGlobalMuted);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: widget.state.isGlobalMuted
                            ? Colors.redAccent.withOpacity(0.2)
                            : Colors.white.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        widget.state.isGlobalMuted
                            ? Icons.volume_off
                            : Icons.volume_up,
                        color: widget.state.isGlobalMuted
                            ? Colors.redAccent
                            : const Color(0xFF00E5FF),
                        size: 16,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedBuyPanel(BuildContext context) {
    // 🚀 MINIATURES: Strictly use photos or fallback to thumbnail_url (Never the main video)
    // Guard: SQLite rows not read through getCachedListings() may still hold a raw JSON string.
    final url = _primaryListingImageUrl(widget.listing);
    final price = widget.listing['price'] ?? 0;
    final title = widget.listing['title'] ?? 'Product';

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 60,
                  height: 60,
                  color: Colors.white.withOpacity(0.05),
                  child: url != null && url.isNotEmpty
                      ? Image.network(
                          url,
                          fit: BoxFit.cover,
                          cacheWidth:
                              120, // Internal Converter: Force 2x scaling for 60px display
                          cacheHeight: 120,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 1,
                                color: Colors.white.withOpacity(0.2),
                              ),
                            );
                          },
                          errorBuilder: (context, error, stack) => const Center(
                            child: Icon(
                              Icons.shopping_bag_outlined,
                              color: Colors.white24,
                              size: 20,
                            ),
                          ),
                        )
                      : const Center(
                          child: Icon(
                            Icons.shopping_bag_outlined,
                            color: Colors.white24,
                            size: 20,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: syne(sz: 13, w: FontWeight.w900, c: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      ugx(num.tryParse(price.toString()) ?? 0),
                      style: dm(
                        sz: 14,
                        w: FontWeight.bold,
                        c: const Color(0xFF00E5FF),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'SKU: ${widget.listing['sku'] ?? 'N/A'}',
                      style: dm(sz: 9, c: Colors.white38),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  widget.state.selectedListing = widget.listing;
                  widget.state.showCheckoutOverlay = true;
                  widget.state.notify();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withOpacity(0.2),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: Text(
                    'Buy Now',
                    style: syne(sz: 11, w: FontWeight.w900, c: Colors.black),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shopAction({
    required IconData icon,
    required String label,
    Color iconColor = Colors.white,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              const Icon(Icons.circle, color: Colors.transparent, size: 34),
              Icon(icon, color: iconColor, size: 22),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: syne(sz: 10, w: FontWeight.w800, c: Colors.white, ls: 0.5),
          ),
        ],
      ),
    );
  }

  Widget _buildFallback() => Container(
    color: C.cardDk,
    child: const Center(
      child: Icon(
        Icons.shopping_cart_outlined,
        size: 80,
        color: Colors.white10,
      ),
    ),
  );

  void _showCommentSheet(BuildContext context, String postId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          _CommentSheet(post: widget.listing, state: widget.state),
    );
  }

  void _showReviewSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          _ReviewSheet(listing: widget.listing, state: widget.state),
    );
  }
}

// ── Comment Sheet ─────────────────────────────────────────────────────────
class _CommentSheet extends StatefulWidget {
  final Map<String, dynamic> post;
  final AppState state;
  const _CommentSheet({required this.post, required this.state});

  @override
  State<_CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<_CommentSheet> {
  final TextEditingController _ctrl = TextEditingController();
  final SupabaseClient _supabase = Supabase.instance.client;
  bool _sending = false;
  Future<List<Map<String, dynamic>>>? _commentsFuture;

  @override
  void initState() {
    super.initState();
    _refreshComments();
  }

  void _refreshComments() {
    setState(() {
      _commentsFuture = widget.state.social.fetchComments(widget.post['id']);
    });
  }

  // 🚀 CACHE: Store resolved identities to avoid redundant lookups in same session
  static final Map<String, Map<String, dynamic>> _identityCache = {};

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _postComment() async {
    if (_ctrl.text.trim().isEmpty || widget.state.user == null) return;
    setState(() => _sending = true);
    try {
      await widget.state.social.postComment(
        widget.post['id'],
        _ctrl.text.trim(),
      );
      _ctrl.clear();
      _refreshComments(); // 🚀 TRIGGER RE-FETCH
      if (mounted) FocusScope.of(context).unfocus();
    } catch (e) {
      debugPrint('Comment Error: $e');
    }
    setState(() => _sending = false);
  }

  Future<Map<String, dynamic>?> _getIdentity(String userId) async {
    if (_identityCache.containsKey(userId)) return _identityCache[userId];
    final profile = await widget.state.social.getProfile(userId);
    if (profile != null) _identityCache[userId] = profile;
    return profile;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, scrollController) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0D121B),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'NEURAL FEEDBACK',
              style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 4),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _commentsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: C.brand,
                        strokeWidth: 2,
                      ),
                    );
                  }
                  final comments = snapshot.data ?? [];
                  if (comments.isEmpty) {
                    return Center(
                      child: Text(
                        'Be the first to share your thoughts.',
                        style: dm(sz: 13, c: Colors.white24),
                      ),
                    );
                  }

                  return ListView.builder(
                    controller: scrollController,
                    itemCount: comments.length,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    itemBuilder: (context, i) {
                      final c = comments[i];
                      final iden = c['metadata']?['identity'];

                      if (iden != null) {
                        return _buildCommentRow(
                          name: iden['user_name'],
                          avatar: iden['user_avatar'],
                          content: c['content'],
                          isVerified: iden['is_verified'] == true,
                          createdAt: c['created_at'],
                        );
                      }

                      return FutureBuilder<Map<String, dynamic>?>(
                        future: _getIdentity(c['author_id']),
                        builder: (context, profSnap) {
                          final prof = profSnap.data;
                          final cUsername =
                              prof?['display_name'] ?? 'Necxa Contributor';
                          final cAvatar = prof?['photo_url'];

                          return _buildCommentRow(
                            name: cUsername,
                            avatar: cAvatar,
                            content: c['content'],
                            isVerified: false,
                            createdAt: c['created_at'],
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
            _buildInput(),
          ],
        ),
      ),
    );
  }

  Widget _buildCommentRow({
    required String name,
    required String? avatar,
    required String content,
    bool isVerified = false,
    String? createdAt,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: C.brand.withOpacity(0.3), width: 1),
            ),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white.withOpacity(0.05),
              backgroundImage: avatar != null ? NetworkImage(avatar) : null,
              child: avatar == null
                  ? Text(
                      name[0].toUpperCase(),
                      style: dm(sz: 12, w: FontWeight.bold, c: C.brand),
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      name,
                      style: dm(sz: 13, w: FontWeight.w800, c: Colors.white70),
                    ),
                    if (isVerified) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.verified,
                        size: 12,
                        color: Color(0xFF00E5FF),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  content,
                  style: dm(sz: 15, c: Colors.white.withOpacity(0.9), h: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        10,
        MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              style: dm(sz: 15, c: Colors.white),
              decoration: InputDecoration(
                hintText: 'Add a thought...',
                hintStyle: dm(sz: 15, c: Colors.white24),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              maxLines: null,
            ),
          ),
          IconButton(
            onPressed: _sending ? null : _postComment,
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: C.brand,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.arrow_upward_rounded, color: C.brand),
            style: IconButton.styleFrom(
              backgroundColor: C.brand.withOpacity(0.1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Community Search Sheet ─────────────────────────────────────────────────
class _CommunitySearchSheet extends StatefulWidget {
  final AppState state;
  final int initialTab;
  const _CommunitySearchSheet({required this.state, this.initialTab = 0});

  @override
  State<_CommunitySearchSheet> createState() => _CommunitySearchSheetState();
}

class _CommunitySearchSheetState extends State<_CommunitySearchSheet> {
  final TextEditingController _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _loading = false;
  late int _searchMode; // 0 = Feed, 1 = Shop

  // Shop filters
  String _tagInput = '';
  double _minPrice = 0;
  double _maxPrice = 1000000;

  @override
  void initState() {
    super.initState();
    _searchMode = widget.initialTab;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty && _searchMode == 0) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);

    try {
      if (_searchMode == 0) {
        // FEED SEARCH
        final client = Supabase.instance.client;
        final res = await client
            .from('community_posts')
            .select(
              'id, title, content, media_url, media_type, author_id, profiles!author_id(full_name, avatar_url)',
            )
            .or('title.ilike.%$query%,content.ilike.%$query%')
            .order('created_at', ascending: false)
            .limit(20);
        setState(() => _results = List<Map<String, dynamic>>.from(res));
      } else {
        // SHOP SEARCH
        final tagsList = _tagInput.trim().isNotEmpty
            ? _tagInput.split(',').map((e) => e.trim()).toList()
            : null;
        final res = await widget.state.social.searchShopListings(
          query,
          tags: tagsList,
          minPrice: _minPrice > 0 ? _minPrice : null,
          maxPrice: _maxPrice < 1000000 ? _maxPrice : null,
        );
        setState(() => _results = res);
      }
    } catch (_) {
      setState(() => _results = []);
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollController) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            color: const Color(0xFF0D121B).withOpacity(0.97),
            child: Column(
              children: [
                // Handle bar
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 16),

                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    'DISCOVER',
                    style: syne(sz: 20, w: FontWeight.w900, c: Colors.white),
                  ),
                ),
                const SizedBox(height: 16),

                // Search Field
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: C.brand.withOpacity(0.25)),
                    ),
                    child: TextField(
                      controller: _ctrl,
                      autofocus: true,
                      onChanged: _search,
                      onSubmitted: _search,
                      style: dm(sz: 15, c: Colors.white),
                      decoration: InputDecoration(
                        hintText: _searchMode == 0
                            ? 'Search posts, users…'
                            : 'Search shop listings…',
                        hintStyle: dm(sz: 14, c: Colors.white38),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: Colors.white38,
                          size: 18,
                        ),
                        suffixIcon: _loading
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white54,
                                  ),
                                ),
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 16,
                        ),
                      ),
                    ),
                  ),
                ),

                // SHOP FILTERS (Only in Shop mode)
                if (_searchMode == 1) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tags (comma separated)',
                          style: dm(
                            sz: 12,
                            w: FontWeight.bold,
                            c: Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: TextField(
                            onChanged: (v) {
                              _tagInput = v;
                              _search(_ctrl.text);
                            },
                            style: dm(sz: 13, c: Colors.white),
                            decoration: InputDecoration(
                              hintText: 'e.g. fashion, electronics',
                              hintStyle: dm(sz: 13, c: Colors.white24),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Price Range (UGX): ${_minPrice.toInt()} - ${_maxPrice >= 1000000 ? '1M+' : _maxPrice.toInt()}',
                          style: dm(
                            sz: 12,
                            w: FontWeight.bold,
                            c: Colors.white70,
                          ),
                        ),
                        RangeSlider(
                          values: RangeValues(_minPrice, _maxPrice),
                          min: 0,
                          max: 1000000,
                          divisions: 100,
                          activeColor: const Color(0xFF00E5FF),
                          inactiveColor: Colors.white12,
                          onChanged: (vals) {
                            setState(() {
                              _minPrice = vals.start;
                              _maxPrice = vals.end;
                            });
                          },
                          onChangeEnd: (_) => _search(_ctrl.text),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),

                // Results
                Expanded(
                  child: _results.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.explore_outlined,
                                color: Colors.white12,
                                size: 52,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _ctrl.text.isEmpty
                                    ? 'Start typing to discover'
                                    : 'No results found',
                                style: dm(sz: 13, c: Colors.white30),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          itemCount: _results.length,
                          separatorBuilder: (_, __) =>
                              Divider(color: Colors.white.withOpacity(0.06)),
                          itemBuilder: (_, i) {
                            final post = _results[i];
                            final isShop = _searchMode == 1;

                            // Shop Listing Mapping
                            if (isShop) {
                              final title = post['title'] ?? 'Listing';
                              final price =
                                  post['price_ugx'] ?? post['price'] ?? 0;
                              final mediaUrl =
                                  post['thumbnail_url'] ?? post['media_url'];
                              return ListTile(
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.white10,
                                    borderRadius: BorderRadius.circular(8),
                                    image: mediaUrl != null
                                        ? DecorationImage(
                                            image: NetworkImage(mediaUrl),
                                            fit: BoxFit.cover,
                                          )
                                        : null,
                                  ),
                                  child: mediaUrl == null
                                      ? const Icon(
                                          Icons.shopping_bag,
                                          color: Colors.white24,
                                        )
                                      : null,
                                ),
                                title: Text(
                                  title,
                                  style: syne(
                                    sz: 13,
                                    w: FontWeight.w700,
                                    c: Colors.white,
                                  ),
                                  maxLines: 1,
                                ),
                                subtitle: Text(
                                  'UGX $price',
                                  style: dm(
                                    sz: 12,
                                    w: FontWeight.bold,
                                    c: const Color(0xFF00E5FF),
                                  ),
                                ),
                                trailing: const Icon(
                                  Icons.arrow_forward_ios,
                                  color: Colors.white24,
                                  size: 14,
                                ),
                                onTap: () {
                                  Navigator.pop(context);
                                  widget.state.selectedListing = post;
                                  widget.state.showCheckoutOverlay = true;
                                  widget.state.notify();
                                },
                              );
                            }

                            // Community Post Mapping
                            final profile =
                                post['profiles'] as Map<String, dynamic>? ?? {};
                            final avatarUrl = profile['avatar_url'] as String?;
                            final authorName =
                                profile['full_name'] as String? ?? 'Unknown';
                            final title =
                                post['title'] as String? ??
                                post['content'] as String? ??
                                '';

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 4,
                                horizontal: 4,
                              ),
                              leading: CircleAvatar(
                                radius: 22,
                                backgroundColor: C.brand.withOpacity(0.2),
                                backgroundImage: avatarUrl != null
                                    ? NetworkImage(avatarUrl)
                                    : null,
                                child: avatarUrl == null
                                    ? Text(
                                        authorName.isNotEmpty
                                            ? authorName[0].toUpperCase()
                                            : '?',
                                        style: syne(
                                          sz: 16,
                                          w: FontWeight.bold,
                                          c: C.brand,
                                        ),
                                      )
                                    : null,
                              ),
                              title: Text(
                                authorName,
                                style: syne(
                                  sz: 13,
                                  w: FontWeight.w700,
                                  c: Colors.white,
                                ),
                              ),
                              subtitle: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: dm(sz: 12, c: Colors.white54),
                              ),
                              trailing: const Icon(
                                Icons.arrow_forward_ios,
                                color: Colors.white24,
                                size: 14,
                              ),
                              onTap: () {
                                Navigator.pop(context); // Close sheet
                                // Navigate to post / post author profile
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReviewSheet extends StatefulWidget {
  final Map<String, dynamic> listing;
  final AppState state;
  const _ReviewSheet({required this.listing, required this.state});

  @override
  _ReviewSheetState createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  bool _canReview = false;
  bool _isLoading = true;
  List<Map<String, dynamic>> _reviews = [];

  @override
  void initState() {
    super.initState();
    _loadReviews();
  }

  Future<void> _loadReviews() async {
    final sku = widget.listing['sku'];
    if (sku != null) {
      try {
        final res = await widget.state.social.client.functions.invoke(
          'clever-processor',
          body: {
            'action': 'fetch-reviews',
            'payload': {'sku': sku},
          },
        );
        if (res.data?['success'] == true && mounted) {
          setState(() {
            _reviews = List<Map<String, dynamic>>.from(res.data['data'] ?? []);
            _canReview = true; // For now, we allow all for testing
          });
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: Color(0xFF121212),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Text(
            'VERIFIED REVIEWS',
            style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 2),
          ),
          const Divider(color: Colors.white12, height: 30),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.amberAccent),
                  )
                : _reviews.isEmpty
                ? Center(
                    child: Text(
                      'No verified reviews yet.',
                      style: dm(c: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    itemCount: _reviews.length,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    itemBuilder: (context, index) {
                      final r = _reviews[index];
                      final prof = r['profiles'] ?? {};
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 14,
                                  backgroundImage: NetworkImage(
                                    prof['avatar_url'] ?? '',
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  prof['full_name'] ?? 'Buyer',
                                  style: syne(
                                    sz: 12,
                                    w: FontWeight.bold,
                                    c: Colors.white,
                                  ),
                                ),
                                const Spacer(),
                                Row(
                                  children: List.generate(
                                    5,
                                    (i) => Icon(
                                      Icons.star,
                                      size: 12,
                                      color: i < (r['rating'] ?? 0)
                                          ? Colors.amberAccent
                                          : Colors.white10,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              r['comment'] ?? '',
                              style: dm(sz: 14, c: Colors.white70, h: 1.4),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (_canReview)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
              child: _buildPrimaryButton(
                text: 'WRITE A REVIEW',
                onPressed: () {
                  // Review Submission Logic
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Purchase verification in progress...'),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPrimaryButton({
    required String text,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF6C63FF),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6C63FF).withOpacity(0.3),
              blurRadius: 15,
            ),
          ],
        ),
        child: Center(
          child: Text(
            text.toUpperCase(),
            style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 1.5),
          ),
        ),
      ),
    );
  }
}
