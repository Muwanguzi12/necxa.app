import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../app_state.dart';
import 'local_db_service.dart';
import 'notification_service.dart';

// ── Necxa Social Service — Lazy Sync Architecture ────────────────────────────
// Rules:
//  1. LOCAL FIRST  — always serve from SQLite immediately.
//  2. DELTA ONLY   — network fetches only records newer than the sync cursor.
//  3. CONNECTIVITY — skip background sync when offline; queue writes instead.
//  4. DEBOUNCE     — don't hammer the backend; respect cooldown windows.
//  5. THIN PAYLOADS— select only required columns to minimise data usage.
// ─────────────────────────────────────────────────────────────────────────────

class SocialService {
  SupabaseClient get client => Supabase.instance.client;
  final AppState state;

  SocialService(this.state);

  // ── In-memory caches (hot path for fast-scroll) ────────────────────────
  final Map<String, Map<String, dynamic>> _profileCache = {};

  // ── Sync debounce tracking (prevents hammering the backend) ───────────
  bool _feedSyncing = false;
  bool _shopSyncing = false;
  static const Duration _feedCooldown = Duration(minutes: 5);
  static const Duration _shopCooldown = Duration(minutes: 10);
  static const int _fetchLimit = 20; // Keep payloads lean
  static const Duration _prefetchCooldown = Duration(seconds: 30);

  DateTime? _feedLastSync;
  DateTime? _shopLastSync;
  DateTime? _prefetchLastSync;

  // ── High-speed Memory Cache (Ultra-low latency startup) ────────────
  List<Map<String, dynamic>> _feedCache = [];
  List<Map<String, dynamic>> _shopCache = [];

  List<Map<String, dynamic>> get feedPosts => _feedCache;
  List<Map<String, dynamic>> get shopListings => _shopCache;

  /// Warms up the memory cache from SQLite - call at app start.
  Future<void> preWarmCache() async {
    final localDb = LocalDbService();
    try {
      _feedCache = await localDb.getCachedFeed(limit: 15);
      _shopCache = await localDb.getCachedListings(limit: 15);
      debugPrint(
        '🛡️ Social: Memory cache pre-warmed (Feed: ${_feedCache.length}, Shop: ${_shopCache.length})',
      );
    } catch (e) {
      debugPrint('Social Pre-warm Error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CONNECTIVITY GUARD
  // ─────────────────────────────────────────────────────────────────────────

  Future<bool> _isOnline() async {
    try {
      final connectivity = Connectivity();
      // Use both check and current status to be sure
      final result = await connectivity.checkConnectivity();
      if (result.contains(ConnectivityResult.none)) return false;
      if (result.isEmpty) return true; // Assume online if list is empty (rare)
      return true;
    } catch (_) {
      return true; // Optimistic fallback — let the network call fail naturally
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // COMMUNITY FEED
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns local cache immediately, then schedules a background delta sync.
  Future<List<Map<String, dynamic>>> fetchPosts({
    bool forceRefresh = false,
    int limit = 30,
  }) async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return [];

    final localDb = LocalDbService();

    // Always ensure _feedCache has up to 'limit' items if available locally
    if (forceRefresh || _feedCache.length < limit) {
      final cached = await localDb.getCachedFeed(limit: limit);
      if (cached.isNotEmpty) _feedCache = cached;
    }

    // Schedule lazy delta sync if cooldown expired
    final now = DateTime.now();
    if (forceRefresh ||
        _feedLastSync == null ||
        now.difference(_feedLastSync!) >= _feedCooldown) {
      _lazyFeedSync(userId, limit);
    }

    return _feedCache;
  }

  /// Pulls ONLY records newer than the local cursor — minimal data transfer.
  Future<List<Map<String, dynamic>>> syncFeed(
    String userId, {
    bool force = false,
    int limit = 30,
  }) async {
    if (_feedSyncing) return _feedCache;
    if (!await _isOnline()) return _feedCache;

    _feedSyncing = true;
    state.notify(); // Show spinner in UI
    _feedLastSync = DateTime.now();
    final localDb = LocalDbService();

    try {
      final sinceCursor = force
          ? null
          : await localDb.getSyncCursor('feed:$userId');
      var syncedFromEdge = false;

      // Thin payload — only fetch what the feed card needs
      final res = await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'fetch-feed',
          'payload': {'since_time': sinceCursor},
        },
      );

      if (res.data?['success'] == true) {
        final newPosts = List<Map<String, dynamic>>.from(
          res.data['data'] ?? [],
        );
        if (newPosts.isNotEmpty) {
          await localDb.saveCommunityPosts(newPosts); // Upsert-merge
          // Store the NEWEST post's timestamp as the high-watermark cursor.
          // Next delta sync will request posts created AFTER this time.
          await localDb.setSyncCursor(
            'feed:$userId',
            newPosts.first['created_at'],
          );
          debugPrint(
            '[Feed] Synced ${newPosts.length} posts. Cursor → ${newPosts.first['created_at']}',
          );
        } else {
          debugPrint('[Feed] No new posts since cursor.');
        }
        syncedFromEdge = true;
      } else if (res.data != null) {
        debugPrint('[Feed] Edge function error: ${res.data['error']}');
      }
      if (!syncedFromEdge) {
        await _syncFeedDirect(localDb, sinceCursor, limit);
      }
    } catch (e) {
      debugPrint('[LazySync] Feed sync error: $e');
      try {
        final sinceCursor = force
            ? null
            : await localDb.getSyncCursor('feed:$userId');
        await _syncFeedDirect(localDb, sinceCursor, limit);
      } catch (fallbackError) {
        debugPrint('[LazySync] Feed direct fallback error: $fallbackError');
      }
    } finally {
      // 🚀 CRITICAL FIX: Ensure the cache reflects the latest DB state after sync
      _feedCache = await localDb.getCachedFeed(limit: limit);
      _feedSyncing = false;
      state.notify(); // Hide spinner and update UI
    }
    return _feedCache;
  }

  /// Background sync — fire-and-forget, never blocks the UI.
  Future<void> _syncFeedDirect(
    LocalDbService localDb,
    String? sinceCursor,
    int limit,
  ) async {
    var query = client
        .from('community_posts')
        .select(
          'id, author_id, title, content, media_url, thumbnail_url, media_type, hls_url, created_at, likes_count, comments_count, profiles:author_id(full_name, avatar_url, trust_score_tier)',
        )
        .inFilter('status', ['verified', 'pending', 'active'])
        .or('visibility.eq.public,visibility.is.null');

    if (sinceCursor != null) query = query.gt('created_at', sinceCursor);

    final rows = List<Map<String, dynamic>>.from(
      await query.order('created_at', ascending: false).limit(limit),
    );
    if (rows.isEmpty) return;

    await localDb.saveCommunityPosts(rows);
    final userId = client.auth.currentUser?.id;
    if (userId != null) {
      await localDb.setSyncCursor('feed:$userId', rows.first['created_at']);
    }
    debugPrint('[Feed] Direct fallback synced ${rows.length} posts.');
  }

  void _lazyFeedSync(String userId, int limit) async {
    await syncFeed(userId, limit: limit);
    await syncPendingActions(); // Also drain the offline write queue
  }

  /// 🚀 NEURAL PREFETCH: Triggered by fast scrolling or intent
  void triggerPrefetch() async {
    if (state.user == null) return;
    final now = DateTime.now();
    if (_prefetchLastSync != null &&
        now.difference(_prefetchLastSync!) < _prefetchCooldown)
      return;

    _prefetchLastSync = now;
    debugPrint('🧠 Neural Prefetch: Fast scroll detected, syncing feed...');
    await syncFeed(state.user!.id);
  }

  /// Pagination: fetch posts strictly older than [beforeTime]
  Future<void> fetchOlderFeed(String beforeTime) async {
    if (_feedSyncing) return;
    if (!await _isOnline()) return;

    _feedSyncing = true;
    state.notify();
    try {
      final res = await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'fetch-feed',
          'payload': {'before_time': beforeTime},
        },
      );

      if (res.data?['success'] == true) {
        final olderPosts = List<Map<String, dynamic>>.from(
          res.data['data'] ?? [],
        );
        if (olderPosts.isNotEmpty) {
          await LocalDbService().saveCommunityPosts(olderPosts);
        }
      }
    } catch (e) {
      debugPrint('[LazySync] Fetch older feed error: $e');
    } finally {
      // Refresh cache so the UI sees the newly paginated data
      final localDb = LocalDbService();
      _feedCache = await localDb.getCachedFeed(limit: _feedCache.length + 10);
      _feedSyncing = false;
      state.notify();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // USER POSTS (Profile Screen)
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchUserPosts(
    String userId, {
    bool forceRefresh = false,
  }) async {
    final localDb = LocalDbService();
    final cached = await localDb.getUserCachedPosts(userId);

    if (!forceRefresh && cached.isNotEmpty) {
      // Background refresh — doesn't block UI
      _lazyUserSync(userId);
      return cached;
    }
    return await syncUserPosts(userId);
  }

  Future<List<Map<String, dynamic>>> syncUserPosts(String userId) async {
    if (!await _isOnline()) return LocalDbService().getUserCachedPosts(userId);
    final localDb = LocalDbService();
    try {
      // Delta: only fetch posts newer than what we have locally
      final cursor = await localDb.getSyncCursor('userposts:$userId');

      // Build filter chain: all filters BEFORE order/limit
      var baseQuery = client
          .from('community_posts')
          // Thin select — including profile info for denormalization
          .select(
            'id, author_id, content, media_url, thumbnail_url, media_type, created_at, profiles(full_name, avatar_url, trust_score_tier)',
          )
          .eq('author_id', userId);

      // Apply delta cursor while still on FilterBuilder
      if (cursor != null) baseQuery = baseQuery.gt('created_at', cursor);

      final res = List<Map<String, dynamic>>.from(
        await baseQuery
            .order('created_at', ascending: false)
            .limit(_fetchLimit),
      );
      if (res.isNotEmpty) {
        await localDb.saveCommunityPosts(res);
        await localDb.setSyncCursor(
          'userposts:$userId',
          res.first['created_at'],
        );
        state.notify(); // Ensure UI knows we got fresh data
      }
      return await localDb.getUserCachedPosts(userId);
    } catch (e) {
      debugPrint('[LazySync] User posts error: $e');
      return await localDb.getUserCachedPosts(userId);
    }
  }

  void _lazyUserSync(String userId) async => await syncUserPosts(userId);

  // ─────────────────────────────────────────────────────────────────────────
  // SHOP / LISTINGS
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchListings({
    String? category,
    bool forceRefresh = false,
    int limit = 30,
  }) async {
    final localDb = LocalDbService();

    if (forceRefresh || _shopCache.length < limit || category != null) {
      final cached = await localDb.getCachedListings(
        limit: limit,
        category: category,
      );
      if (category == null && cached.isNotEmpty) _shopCache = cached;
    }

    final now = DateTime.now();
    if (forceRefresh ||
        _shopLastSync == null ||
        now.difference(_shopLastSync!) >= _shopCooldown) {
      _lazyShopSync(category: category, limit: limit, force: forceRefresh);
    }

    return category == null
        ? _shopCache
        : await localDb.getCachedListings(limit: limit, category: category);
  }

  Future<List<Map<String, dynamic>>> _fetchListingsFromNetwork({
    String? category,
    bool force = false,
    int limit = 30,
  }) async {
    if (_shopSyncing) return _shopCache;
    if (!await _isOnline()) return _shopCache;

    _shopSyncing = true;
    _shopLastSync = DateTime.now();
    final localDb = LocalDbService();

    try {
      final cursor = force ? null : await localDb.getSyncCursor('shop');

      // Try Redis-backed edge function first (fastest)
      try {
        final res = await client.functions.invoke(
          'clever-processor',
          body: {
            'action': 'fetch-shop-feed',
            'payload': {'category': category, 'since_time': cursor},
          },
        );
        if (res.data?['success'] == true) {
          final listings = List<Map<String, dynamic>>.from(
            res.data['data'] ?? [],
          );
          if (listings.isNotEmpty) {
            await localDb.saveListings(listings);
            await localDb.setSyncCursor('shop', listings.first['created_at']);
          }
        }
      } catch (_) {}
    } catch (e) {
      debugPrint('[LazySync] Shop sync error: $e');
    } finally {
      final updated = await localDb.getCachedListings(
        limit: limit,
        category: category,
      );
      if (category == null) _shopCache = updated;
      _shopSyncing = false;
      state.notify();
    }
    return category == null
        ? _shopCache
        : await localDb.getCachedListings(limit: limit, category: category);
  }

  /// Pagination: fetch listings strictly older than [beforeTime]
  Future<void> fetchOlderListings(String beforeTime, {String? category}) async {
    if (_shopSyncing) return;
    if (!await _isOnline()) return;

    _shopSyncing = true;
    state.notify();
    try {
      final res = await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'fetch-shop-feed',
          'payload': {'category': category, 'before_time': beforeTime},
        },
      );

      if (res.data?['success'] == true) {
        final olderListings = List<Map<String, dynamic>>.from(
          res.data['data'] ?? [],
        );
        if (olderListings.isNotEmpty) {
          await LocalDbService().saveListings(olderListings);
        }
      }
    } catch (e) {
      debugPrint('[LazySync] Fetch older shop error: $e');
    } finally {
      final localDb = LocalDbService();
      _shopCache = await localDb.getCachedListings(
        limit: _shopCache.length + 10,
      );
      _shopSyncing = false;
      state.notify();
    }
  }

  void _lazyShopSync({
    String? category,
    int limit = 30,
    bool force = false,
  }) async => await _fetchListingsFromNetwork(
    category: category,
    limit: limit,
    force: force,
  );

  Future<List<Map<String, dynamic>>> searchShopListings(
    String query, {
    List<String>? tags,
    double? minPrice,
    double? maxPrice,
    String? category,
  }) async {
    if (!await _isOnline()) return [];

    try {
      final res = await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'search-listings',
          'payload': {
            'query': query,
            'tags': tags,
            'min_price': minPrice,
            'max_price': maxPrice,
            'category': category,
          },
        },
      );

      if (res.data?['success'] == true) {
        return List<Map<String, dynamic>>.from(res.data['data'] ?? []);
      }
      return [];
    } catch (e) {
      debugPrint('[ShopSearch] Error: $e');
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // USER SHOWCASE (Vendor Storefront)
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchUserListings(String userId) async {
    // 1. Memory cache (hot path for fast profile loads)
    if (state.cachedUserShowcases.containsKey(userId)) {
      _syncUserListingsInBackground(userId);
      return state.cachedUserShowcases[userId]!;
    }

    if (!await _isOnline()) return state.cachedUserShowcases[userId] ?? [];

    try {
      final res = await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'fetch-showcase',
          'payload': {'user_id': userId},
        },
      );
      if (res.data?['success'] == true) {
        final data = List<Map<String, dynamic>>.from(res.data['data'] ?? []);
        state.cachedUserShowcases[userId] = data;
        return data;
      }
    } catch (_) {}

    // Thin fallback
    try {
      final res = await client
          .from('listings')
          .select(
            'id, title, description, price, price_ugx, media_url, thumbnail_url, media_type, is_verified, created_at, sku, photos, stock_count, film_hub_content, category, lister_id, user_id, profiles:user_id(full_name, avatar_url, trust_score_tier)',
          )
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(_fetchLimit);
      final data = List<Map<String, dynamic>>.from(res);
      state.cachedUserShowcases[userId] = data;
      return data;
    } catch (e) {
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // REALTIME STREAMS (used for Realtime channel subscriptions only)
  // ─────────────────────────────────────────────────────────────────────────

  Stream<List<Map<String, dynamic>>> streamPosts() {
    return client
        .from('community_posts')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false)
        .map(
          (data) => data
              .where(
                (m) => m['visibility'] == 'public' || m['visibility'] == null,
              )
              .toList(),
        );
  }

  Stream<List<Map<String, dynamic>>> streamUserPosts(String userId) {
    return client
        .from('community_posts')
        .stream(primaryKey: ['id'])
        .eq('author_id', userId)
        .order('created_at', ascending: false)
        .map((data) => List<Map<String, dynamic>>.from(data));
  }

  Stream<List<Map<String, dynamic>>> streamPostsByMusic(String trackId) {
    return client
        .from('community_posts')
        .stream(primaryKey: ['id'])
        .eq('media_asset_id', trackId)
        .order('created_at', ascending: false)
        .map((data) => List<Map<String, dynamic>>.from(data));
  }

  // ── Smart Load Helpers ──────────────────────────────────────────

  bool isSyncing(String key) => key == 'feed' ? _feedSyncing : _shopSyncing;

  Future<void> createListing(
    String userId,
    Map<String, dynamic> data, {
    Map<String, dynamic>? aiResult,
  }) async {
    final double parsedPrice =
        double.tryParse(data['price']?.toString() ?? '0') ?? 0;
    num? parseScore(dynamic value) {
      if (value is num) return value;
      if (value == null) return null;
      return num.tryParse(value.toString());
    }

    final num? aiScore = parseScore(aiResult?['score'] ?? data['ai_score']);
    final String? aiDescription =
        aiResult?['description']?.toString() ??
        data['ai_description']?.toString();
    // 1. Sanitize payload for 'listings' table
    final sanitizedData = {
      'user_id': userId,
      'lister_id': userId,
      'title': data['title'],
      'description': data['description'],
      'price': parsedPrice,
      'price_ugx': parsedPrice,
      'image_url':
          data['thumbnail_url'] ?? data['media_url'] ?? data['image_url'],
      'media_url': data['media_url'],
      'thumbnail_url': data['thumbnail_url'] ?? data['media_url'],
      'media_type': data['media_type'] ?? 'image',
      'is_verified': aiResult?['verified'] ?? data['is_verified'] ?? false,
      'ai_verification': aiResult ?? data['ai_verification'],
      'ai_score': aiScore,
      'ai_description': aiDescription,
      'status': 'active', // Force active so it shows in the feed immediately
      'photos': data['photos'] ?? [],
      'sku': data['sku'],
      'stock_count': data['stock_count'] ?? 999,
      'tags': data['tags'] ?? [],
      'weight_kg': data['weight_kg'],
      'length_cm': data['length_cm'],
      'width_cm': data['width_cm'],
      'height_cm': data['height_cm'],
      'latitude': data['latitude'],
      'longitude': data['longitude'],
      'category': data['category'] ?? 'General',
      'film_hub_content': data['media_url'],
    };

    try {
      final res = await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'create-listing',
          'payload': {
            ...sanitizedData,
            'media_url': data['media_url'],
            'media_type': data['media_type'] ?? 'image',
            'photos': data['photos'] ?? [],
            'music_track_id': data['music_track_id'],
            'audio_url': data['audio_url'],
          },
        },
      );

      if (res.data?['success'] == true) {
        final listing = res.data['data'];
        if (listing != null) {
          // 🚀 IMMEDIATE PERSISTENCE: Save with identity
          await LocalDbService().saveListings([listing]);
        }
      }
      state.notify();
    } catch (e) {
      debugPrint('Redis Listing Creation Error: $e');
      // Fallback: Use direct insert + select with profile JOIN
      final res = await client
          .from('listings')
          .insert(sanitizedData)
          .select(
            '*, profiles:user_id(full_name, avatar_url, trust_score_tier)',
          )
          .single();

      await LocalDbService().saveListings([res]);
      state.notify();
    }
  }

  void _syncUserListingsInBackground(String userId) async {
    try {
      final res = await client
          .from('listings')
          .select(
            'id, title, description, price, price_ugx, media_url, thumbnail_url, media_type, is_verified, created_at, sku, photos, stock_count, film_hub_content, category, lister_id, user_id, profiles:user_id(full_name, avatar_url, trust_score_tier)',
          )
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(20);
      final data = List<Map<String, dynamic>>.from(res);
      if (state.cachedUserShowcases[userId].toString() != data.toString()) {
        state.cachedUserShowcases[userId] = data;
        state.notify();
      }
    } catch (_) {}
  }

  Future<void> createPost(String userId, Map<String, dynamic> data) async {
    try {
      // 🚀 COMMUNITY V2: NEURAL SYNC
      // Call Edge Function to handle both Supabase persistence and Redis feed caching
      final res = await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'create-post',
          'payload': {
            'title': data['title'],
            'content': data['content'],
            'media_url': data['media_url'],
            'thumbnail_url': data['thumbnail_url'],
            'media_type': data['media_type'] ?? 'image',
            'media_asset_id': data['media_asset_id'],
            'audio_url': data['audio_url'],
            'tags': data['tags'] ?? [],
            'creator_mode': data['creator_mode'] ?? 'unified',
            'is_fast_sync': data['is_fast_sync'] ?? false,
            'gallery_urls': data['gallery_urls'] ?? [],
            'editing_metadata': data['editing_metadata'] ?? {},
            'artist_metadata': data['artist_metadata'] ?? {},
          },
        },
      );

      if (res.data != null && res.data['success'] == true) {
        final post = res.data['data'];
        if (post != null) {
          // 🛡️ IMMEDIATE LOCAL PERSISTENCE
          final localDb = LocalDbService();
          await localDb.saveCommunityPosts([post]);

          debugPrint('🎬 SocialService: New post persisted locally.');
          state.notify(); // 🚀 Trigger UI update
        }
      }
    } catch (e) {
      debugPrint('Edge Function Post Creation Error: $e');

      // Fallback: Direct insert + select with profile JOIN
      try {
        final res = await client
            .from('community_posts')
            .insert({
              'author_id': userId,
              'title': data['title'],
              'content': data['content'],
              'media_url': data['media_url'],
              'media_type': data['media_type'] ?? 'image',
              'status': 'verified',
            })
            .select(
              '*, profiles:author_id(full_name, avatar_url, trust_score_tier)',
            )
            .single();

        await LocalDbService().saveCommunityPosts([res]);
        state.notify();
      } catch (e2) {
        debugPrint('Emergency Post Fallback Error: $e2');
      }
    }
  }

  Future<void> deletePost(String postId) async {
    try {
      // 🚀 COMMUNITY V2: NEURAL SYNC
      // Call Edge Function to handle both Supabase deletion and Redis cache removal
      await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'delete-post',
          'payload': {'post_id': postId},
        },
      );

      // 🛡️ IMMEDIATE LOCAL CLEANUP
      final localDb = LocalDbService();
      final db = await localDb.database;
      await db.delete('community_posts', where: 'id = ?', whereArgs: [postId]);
      debugPrint('🎬 SocialService: Post $postId deleted from all nodes.');
    } catch (e) {
      debugPrint('Post Deletion Error: $e');
      rethrow;
    }
  }

  Future<void> toggleReaction(String postId) async {
    final localDb = LocalDbService();
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    // 1. Optimistic Update locally
    await localDb.incrementPostMetric(postId, 'likes_count');
    state.notify(); // 🚀 UI Pulse

    // 2. Queue action for persistence
    await localDb.queueSocialAction('like', postId);

    // 2. Try to sync immediately
    try {
      await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'toggle-like',
          'payload': {'post_id': postId},
        },
      );

      // 🚀 NOTIFIER SYNC (Local & Remote)
      await dispatchSocialNotification(
        'like',
        postId,
        'New Like!',
        'Someone loved your post on Necxa.',
      );
    } catch (e) {
      debugPrint('Offline Like Queued: $e');
      // Even if offline, we show local feedback if we want "connected" feel
      await _showLocalNotification(
        'like',
        'Like Queued',
        'Your reaction will sync when you are back online.',
      );
    }
  }

  Future<void> postComment(String postId, String content) async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      // 🚀 COMMUNITY V2: NEURAL SYNC (REDIS)
      // Delegating to Edge Function to handle Supabase + Redis + Notifs atomically
      await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'create-comment',
          'payload': {'post_id': postId, 'content': content},
        },
      );

      // 🚀 OPTIMISTIC UPDATE: Increment local comment count
      final localDb = LocalDbService();
      await localDb.incrementPostMetric(postId, 'comments_count');
      state.notify();

      // Local Alert for immediate UX
      await _showLocalNotification(
        'comment',
        'Comment Posted',
        'Your thought has joined the neural grid.',
      );
    } catch (e) {
      debugPrint('Comment Creation Error: $e');
      rethrow;
    }
  }

  /// 🚀 NEURAL PULSE: Fetch comments from Redis/Backend
  Future<List<Map<String, dynamic>>> fetchComments(String postId) async {
    final localDb = LocalDbService();

    // 1. serve local cache immediately (Persistent)
    final cached = await localDb.getCachedComments(postId);

    if (!await _isOnline()) return cached;

    try {
      final response = await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'fetch-comments',
          'payload': {'post_id': postId},
        },
      );

      if (response.status == 200 && response.data != null) {
        final List<dynamic> raw = response.data['data'] ?? [];
        final comments = raw.cast<Map<String, dynamic>>();

        // 2. Persist to Local DB
        await localDb.saveComments(postId, comments);

        return comments;
      }
    } catch (e) {
      debugPrint('Fetch Comments Error: $e');
    }
    return cached;
  }

  Future<void> dispatchSocialNotification(
    String type,
    String targetId,
    String title,
    String body,
  ) async {
    // 1. Local Alert & DB Persistence
    await _showLocalNotification(type, title, body);

    // 2. Remote Redis Sync
    await notifySocialEvent(type, targetId);
  }

  Future<void> _showLocalNotification(
    String type,
    String title,
    String body,
  ) async {
    final NotificationService ns = NotificationService();
    await ns.simulateNotification(type, title, body);
  }

  Future<void> notifySocialEvent(
    String type,
    String targetId, {
    Map<String, dynamic>? metadata,
  }) async {
    try {
      // 🚀 COMMUNITY V2: NEURAL SYNC (REDIS)
      // Invoke the processor with a notification trigger
      await client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'trigger-notification',
          'payload': {
            'type': type,
            'target_id': targetId,
            'actor_id': client.auth.currentUser?.id,
            'timestamp': DateTime.now().toIso8601String(),
            'metadata': metadata ?? {},
          },
        },
      );
      debugPrint('🔔 SocialService: Redis Notification Triggered [$type]');
    } catch (e) {
      debugPrint('Notification Trigger Error: $e');
    }
  }

  /// 🚀 NEURAL PULSE: Fetch real-time alerts from Redis
  Future<List<Map<String, dynamic>>> fetchRedisNotifications() async {
    try {
      final response = await client.functions.invoke(
        'clever-processor',
        body: {'action': 'fetch-notifications'},
      );

      if (response.status == 200 && response.data != null) {
        final List<dynamic> raw = response.data['data'] ?? [];
        return raw.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('Redis Fetch Error: $e');
    }
    return [];
  }

  Future<void> syncPendingActions() async {
    final localDb = LocalDbService();
    final actions = await localDb.getPendingActions();
    if (actions.isEmpty) return;

    for (var action in actions) {
      try {
        if (action['action_type'] == 'like') {
          await client.functions.invoke(
            'clever-processor',
            body: {
              'action': 'toggle-like',
              'payload': {'post_id': action['post_id']},
            },
          );
        } else if (action['action_type'] == 'follow') {
          await toggleFollow(
            action['post_id'],
          ); // post_id is used as target_user_id here
        }
        // Remove on success
        await localDb.removeAction(action['id']);
      } catch (_) {
        // Keep in queue for next retry
      }
    }
  }

  Future<Map<String, dynamic>?> getProfile(String userId) async {
    if (_profileCache.containsKey(userId)) return _profileCache[userId];

    // 1. Check Local DB first (Offline Resilience)
    final localDb = LocalDbService();
    final cached = await localDb.getProfile(userId);
    if (cached != null) {
      final normalized = {
        'display_name': cached['display_name'],
        'photo_url': cached['photo_url'],
        'is_verified': cached['is_verified'] == 1,
        'trust_score': cached['trust_score'],
      };
      _profileCache[userId] = normalized;
      return normalized;
    }

    // 2. Fallback to Supabase if online
    try {
      final res = await client
          .from('profiles')
          .select('*')
          .eq('id', userId)
          .maybeSingle();

      if (res != null) {
        final normalized = {
          'display_name': res['full_name'],
          'photo_url': res['avatar_url'],
          'is_verified':
              res['trust_score_tier'] == 'titan_trust' ||
              res['trust_score_tier'] == 'verified',
        };
        _profileCache[userId] = normalized;
        return normalized;
      }
    } catch (e) {
      debugPrint('Error fetching profile $userId: $e');
    }
    return null;
  }

  Future<void> updateProfile(String userId, Map<String, dynamic> data) async {
    await client.from('profiles').update(data).eq('id', userId);
    _profileCache.remove(userId); // Invalidate cache
  }

  Future<String?> registerMediaAsset(
    String userId,
    Map<String, dynamic> data,
  ) async {
    try {
      final res = await client
          .from('media_assets')
          .insert({
            'creator_id': userId,
            'asset_type': data['asset_type'] ?? 'original_sound',
            'url': data['url'],
            'title': data['title'] ?? 'Original Sound',
            'description': data['description'],
            'metadata': data['metadata'] ?? {},
          })
          .select('id')
          .single();

      return res['id'] as String?;
    } catch (e) {
      debugPrint('Media Registration Error: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> fetchTrendingMedia() async {
    try {
      final res = await client.from('trending_media').select();
      return List<Map<String, dynamic>>.from(res);
    } catch (e) {
      debugPrint('Trending Media Error: $e');
      return [];
    }
  }

  Future<void> logVerification(
    String userId,
    String type,
    Map<String, dynamic> report,
  ) async {
    try {
      await client.from('verifications').insert({
        'user_id': userId,
        'status': report['verified'] == true ? 'verified' : 'rejected',
        'details': report,
      });
    } catch (e) {
      debugPrint('Verification Logging Error: $e');
    }
  }

  // ── NEW BACKEND INTERACTIONS ──────────────────────────────────

  Future<void> toggleFollow(String targetUserId) async {
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId == targetUserId) return;

    final localDb = LocalDbService();
    // 1. Queue action locally
    await localDb.queueSocialAction('follow', targetUserId);

    // 2. Try to sync immediately
    try {
      final existing = await client.from('creator_followers').select().match({
        'follower_id': userId,
        'creator_id': targetUserId,
      }).maybeSingle();

      if (existing != null) {
        await client.from('creator_followers').delete().match({
          'follower_id': userId,
          'creator_id': targetUserId,
        });
      } else {
        await client.from('creator_followers').insert({
          'follower_id': userId,
          'creator_id': targetUserId,
        });
        // 🚀 NOTIFIER SYNC
        await dispatchSocialNotification(
          'follow',
          targetUserId,
          'New Follower!',
          'Someone started following you on Necxa.',
        );
      }
    } catch (e) {
      debugPrint('Offline Follow Queued: $e');
    }
  }

  Future<void> reportContent(
    String targetId,
    String type,
    String reason,
  ) async {
    final userId = client.auth.currentUser?.id;
    await client.from('reports').insert({
      'reporter_id': userId,
      'target_id': targetId,
      'target_type': type,
      'reason': reason,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> toggleSavePost(String postId) async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    final existing = await client.from('saved_posts').select().match({
      'user_id': userId,
      'post_id': postId,
    }).maybeSingle();

    if (existing != null) {
      await client.from('saved_posts').delete().match({
        'user_id': userId,
        'post_id': postId,
      });
    } else {
      await client.from('saved_posts').insert({
        'user_id': userId,
        'post_id': postId,
      });
      // 🚀 NOTIFIER SYNC
      await dispatchSocialNotification(
        'save',
        postId,
        'Post Saved',
        'You successfully saved this post to your library.',
      );
    }
  }

  Future<void> hideContent(String targetId, String type) async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    await client.from('user_preferences').insert({
      'user_id': userId,
      'target_id': targetId,
      'preference_type': 'not_interested',
      'content_type': type,
    });
  }

  // ── BATCH MANAGEMENT (PROFILE) ────────────────────────────────

  Future<void> bulkDeletePosts(List<String> ids) async {
    try {
      await client.rpc('bulk_delete_posts', params: {'p_post_ids': ids});
    } catch (e) {
      debugPrint('Bulk Delete Error: $e');
      // Fallback: Individual deletes if RPC fails
      for (final id in ids) {
        await client
            .from('community_posts')
            .update({'status': 'archived'})
            .eq('id', id);
      }
    }
  }

  Future<void> bulkUpdatePostPrivacy(
    List<String> ids,
    String visibility,
  ) async {
    try {
      await client.rpc(
        'bulk_update_post_privacy',
        params: {'p_post_ids': ids, 'p_visibility': visibility},
      );
    } catch (e) {
      debugPrint('Bulk Privacy Error: $e');
      for (final id in ids) {
        await client
            .from('community_posts')
            .update({'visibility': visibility})
            .eq('id', id);
      }
    }
  }

  Future<void> triggerDataExport(String userId, String email) async {
    try {
      await client.functions.invoke(
        'data-exporter',
        body: {'user_id': userId, 'email': email},
      );
    } catch (e) {
      debugPrint('Data Export Trigger Error: $e');
      rethrow;
    }
  }

  Future<void> requestAccountDeletion(String userId) async {
    try {
      // Mark for deletion in 14 days
      final deletionDate = DateTime.now().add(const Duration(days: 14));
      await client
          .from('profiles')
          .update({
            'scheduled_deletion_at': deletionDate.toIso8601String(),
            'status': 'deleting',
          })
          .eq('id', userId);
    } catch (e) {
      debugPrint('Account Deletion Request Error: $e');
      rethrow;
    }
  }
}
