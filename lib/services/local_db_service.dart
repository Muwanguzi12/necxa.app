import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import '../models/chat_models.dart';
import 'dart:async';
import 'dart:convert';

// ── Necxa Local Vault — Offline-First Neural DB ─────────────────────────────
// Design principles:
//  • SQLite is ALWAYS the primary source — never cleared on network restore.
//  • Backend fetches only the DELTA (records newer than last sync cursor).
//  • Feed pruned to max 120 posts; shop to 60 listings to stay lightweight.
//  • Author info is DENORMALIZED into posts to avoid runtime JOINs on reads.
// ────────────────────────────────────────────────────────────────────────────

class LocalDbService {
  static final LocalDbService _instance = LocalDbService._internal();
  factory LocalDbService() => _instance;
  LocalDbService._internal();

  static const int _feedMaxRows = 500;
  static const int _shopMaxRows = 300;
  static const int _notifMaxRows = 50;
  static const int _dbVersion = 17;

  static String? _extractUrl(dynamic value) {
    if (value == null) return null;
    if (value is String) return value.trim().isEmpty ? null : value.trim();
    if (value is Map) {
      for (final key in [
        'url',
        'image_url',
        'thumbnail_url',
        'media_url',
        'path',
      ]) {
        final url = _extractUrl(value[key]);
        if (url != null) return url;
      }
    }
    return null;
  }

  static List<String> _normalizePhotoList(dynamic rawPhotos) {
    dynamic value = rawPhotos;
    if (value is String && value.trim().isNotEmpty) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        final url = _extractUrl(value);
        return url == null ? [] : [url];
      }
    }
    if (value is List) {
      return value
          .map(_extractUrl)
          .whereType<String>()
          .where((url) => url.isNotEmpty)
          .toList();
    }
    final url = _extractUrl(value);
    return url == null ? [] : [url];
  }

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'necxa_vault.db');

    return await openDatabase(
      path,
      version: _dbVersion,
      onUpgrade: (db, oldVersion, newVersion) async {
        // Non-destructive upgrade — add columns/tables if missing
        if (oldVersion < 10) {
          try {
            // Version 9 migrations (if skipped)
            try {
              await db.execute(
                'ALTER TABLE community_posts ADD COLUMN listing_data TEXT',
              );
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE chat_messages ADD COLUMN local_media_path TEXT',
              );
            } catch (_) {}
            // Version 10 migrations
            try {
              await db.execute(
                'ALTER TABLE community_posts ADD COLUMN local_media_path TEXT',
              );
            } catch (_) {}
            debugPrint(
              '🛡️ LocalDb: Migrated to v10 (added local_media_path to community_posts)',
            );
          } catch (e) {
            debugPrint('Migration Error: $e');
          }
        }
        if (oldVersion < 11) {
          for (final statement in [
            'ALTER TABLE community_posts ADD COLUMN is_liked INTEGER DEFAULT 0',
            'ALTER TABLE community_posts ADD COLUMN engagement_synced_at TEXT',
            'ALTER TABLE shop_listings ADD COLUMN likes_count INTEGER DEFAULT 0',
            'ALTER TABLE shop_listings ADD COLUMN comments_count INTEGER DEFAULT 0',
            'ALTER TABLE shop_listings ADD COLUMN is_liked INTEGER DEFAULT 0',
            'ALTER TABLE shop_listings ADD COLUMN engagement_synced_at TEXT',
            'ALTER TABLE social_actions_queue ADD COLUMN dedupe_key TEXT',
            'ALTER TABLE social_actions_queue ADD COLUMN retry_count INTEGER DEFAULT 0',
            'ALTER TABLE social_actions_queue ADD COLUMN last_attempt_at TEXT',
            "ALTER TABLE community_comments ADD COLUMN sync_status TEXT DEFAULT 'synced'",
            'ALTER TABLE community_comments ADD COLUMN idempotency_key TEXT',
            "ALTER TABLE community_comments ADD COLUMN target_type TEXT DEFAULT 'post'",
          ]) {
            try {
              await db.execute(statement);
            } catch (_) {}
          }
          await db.execute('DROP INDEX IF EXISTS idx_comments_post');
        }
        if (oldVersion < 12) {
          for (final statement in [
            'ALTER TABLE app_notifications ADD COLUMN actor_id TEXT',
            'ALTER TABLE app_notifications ADD COLUMN actor_name TEXT',
            'ALTER TABLE app_notifications ADD COLUMN actor_avatar TEXT',
            'ALTER TABLE app_notifications ADD COLUMN target_id TEXT',
            "ALTER TABLE app_notifications ADD COLUMN target_type TEXT DEFAULT 'post'",
            "ALTER TABLE app_notifications ADD COLUMN metadata TEXT DEFAULT '{}'",
          ]) {
            try {
              await db.execute(statement);
            } catch (_) {}
          }
        }
        if (oldVersion < 13) {
          debugPrint(
            'LocalDb: Migrating to v13 (durable live comments and mutation queue)',
          );
        }
        if (oldVersion < 14) {
          for (final statement in [
            'ALTER TABLE shop_listings ADD COLUMN description TEXT',
            'ALTER TABLE shop_listings ADD COLUMN price_ugx REAL DEFAULT 0',
            'ALTER TABLE shop_listings ADD COLUMN sku TEXT',
            'ALTER TABLE shop_listings ADD COLUMN stock_count INTEGER DEFAULT 0',
            'ALTER TABLE shop_listings ADD COLUMN lister_id TEXT',
            "ALTER TABLE shop_listings ADD COLUMN status TEXT DEFAULT 'active'",
            'ALTER TABLE shop_listings ADD COLUMN pickup_address TEXT',
            'ALTER TABLE shop_listings ADD COLUMN latitude REAL',
            'ALTER TABLE shop_listings ADD COLUMN longitude REAL',
          ]) {
            try {
              await db.execute(statement);
            } catch (_) {}
          }
        }
        if (oldVersion < 15) {
          for (final statement in [
            'ALTER TABLE transport_orders ADD COLUMN updated_at TEXT',
            'ALTER TABLE transport_orders ADD COLUMN delivery_lat REAL',
            'ALTER TABLE transport_orders ADD COLUMN delivery_lng REAL',
          ]) {
            try {
              await db.execute(statement);
            } catch (_) {}
          }
        }
        await _createOrMigrateV5(db, isUpgrade: true);
      },
      onCreate: (db, version) async {
        await _createOrMigrateV5(db, isUpgrade: false);
      },
    );
  }

  Future<void> _createOrMigrateV5(
    Database db, {
    required bool isUpgrade,
  }) async {
    // ── 1. Chat Rooms ───────────────────────────────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_rooms (
        id TEXT PRIMARY KEY,
        other_party_id TEXT,
        other_name TEXT,
        other_avatar TEXT,
        last_message TEXT,
        last_message_at TEXT,
        unread_count INTEGER DEFAULT 0,
        is_secure INTEGER DEFAULT 0,
        created_at TEXT
      )
    ''');

    // ── 2. Chat Messages ────────────────────────────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_messages (
        id TEXT PRIMARY KEY,
        room_id TEXT,
        sender_id TEXT,
        receiver_id TEXT,
        content TEXT,
        media_url TEXT,
        local_media_path TEXT,
        message_type TEXT DEFAULT 'text',
        is_read INTEGER DEFAULT 0,
        reactions TEXT,
        created_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_room ON chat_messages(room_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_time ON chat_messages(created_at)',
    );

    // ── 3. Community Posts (DENORMALIZED — author info included) ────────────
    // Author name/avatar stored inline to avoid JOINs on every read.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS community_posts (
        id TEXT PRIMARY KEY,
        author_id TEXT,
        author_name TEXT,
        author_avatar TEXT,
        content TEXT,
        media_url TEXT,
        thumbnail_url TEXT,
        hls_url TEXT,
        local_media_path TEXT,
        media_type TEXT DEFAULT 'image',
        likes_count INTEGER DEFAULT 0,
        comments_count INTEGER DEFAULT 0,
        is_liked INTEGER DEFAULT 0,
        engagement_synced_at TEXT,
        listing_data TEXT, -- Full JSON listing metadata
        created_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_posts_time ON community_posts(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_posts_author_created ON community_posts(author_id, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_posts_author ON community_posts(author_id)',
    );

    // Migration: add new columns if upgrading from older schema
    if (isUpgrade) {
      for (final col in [
        'thumbnail_url TEXT',
        'author_name TEXT',
        'author_avatar TEXT',
        'local_media_path TEXT',
      ]) {
        try {
          await db.execute('ALTER TABLE community_posts ADD COLUMN $col');
        } catch (_) {} // Ignore if column already exists
      }
      try {
        await db.execute('ALTER TABLE shop_listings ADD COLUMN photos TEXT');
        await db.execute(
          'ALTER TABLE shop_listings ADD COLUMN film_hub_content TEXT',
        );
      } catch (_) {}
    }

    // ── 4. Social Profiles (lightweight identity cache) ─────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS social_profiles (
        id TEXT PRIMARY KEY,
        display_name TEXT,
        photo_url TEXT,
        trust_score INTEGER DEFAULT 50,
        is_verified INTEGER DEFAULT 0,
        cached_at TEXT
      )
    ''');

    // ── 5. Shop Listings (offline shop cache) ───────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS shop_listings (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        lister_name TEXT,
        lister_avatar TEXT,
        title TEXT,
        description TEXT,
        price REAL DEFAULT 0,
        price_ugx REAL DEFAULT 0,
        sku TEXT,
        stock_count INTEGER DEFAULT 0,
        lister_id TEXT,
        status TEXT DEFAULT 'active',
        media_url TEXT,
        thumbnail_url TEXT,
        media_type TEXT DEFAULT 'image',
        likes_count INTEGER DEFAULT 0,
        comments_count INTEGER DEFAULT 0,
        is_liked INTEGER DEFAULT 0,
        engagement_synced_at TEXT,
        category TEXT,
        is_verified INTEGER DEFAULT 0,
        photos TEXT, -- JSON Array of miniature URLs
        film_hub_content TEXT, -- Explicit main media URL
        pickup_address TEXT,
        latitude REAL,
        longitude REAL,
        created_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_shop_time ON shop_listings(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_shop_user_created ON shop_listings(user_id, created_at DESC)',
    );

    // ── 6. Action Queue (offline-first writes) ──────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS social_actions_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        action_type TEXT,
        post_id TEXT,
        payload TEXT,
        dedupe_key TEXT,
        retry_count INTEGER DEFAULT 0,
        last_attempt_at TEXT,
        created_at TEXT
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_social_queue_dedupe
      ON social_actions_queue(dedupe_key)
      WHERE dedupe_key IS NOT NULL
    ''');

    // ── 7. Sync Cursors (per-key delta tracking) ────────────────────────────
    // One row per cursor key. Keys: 'feed', 'shop', 'notifs', 'chat_rooms'
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_cursors (
        cursor_key TEXT PRIMARY KEY,
        last_sync_at TEXT,
        etag TEXT
      )
    ''');

    // ── 8. Notifications ─────────────────────────────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_notifications (
        id TEXT PRIMARY KEY,
        type TEXT,
        title TEXT,
        body TEXT,
        payload TEXT,
        actor_id TEXT,
        actor_name TEXT,
        actor_avatar TEXT,
        target_id TEXT,
        target_type TEXT DEFAULT 'post',
        metadata TEXT DEFAULT '{}',
        is_read INTEGER DEFAULT 0,
        created_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_notif_time ON app_notifications(created_at DESC)',
    );

    // ── 9. Transport Orders ─────────────────────────────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS transport_orders (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        driver_id TEXT,
        pickup_location TEXT,
        dropoff_location TEXT,
        status TEXT,
        price REAL,
        created_at TEXT,
        updated_at TEXT,
        delivery_lat REAL,
        delivery_lng REAL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_transport_time ON transport_orders(created_at DESC)',
    );

    // ── 10. Community Comments (Modern Persistence) ──────────────────────────
    await db.execute('''
      CREATE TABLE IF NOT EXISTS community_comments (
        id TEXT PRIMARY KEY,
        post_id TEXT,
        user_id TEXT,
        user_name TEXT,
        user_avatar TEXT,
        user_profile_url TEXT,
        content TEXT,
        sync_status TEXT DEFAULT 'synced',
        idempotency_key TEXT,
        target_type TEXT DEFAULT 'post',
        created_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_comments_post ON community_comments(post_id, created_at DESC)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS live_comments (
        id TEXT PRIMARY KEY,
        channel_id TEXT NOT NULL,
        user_id TEXT,
        user_name TEXT,
        user_avatar TEXT,
        text TEXT NOT NULL,
        status TEXT DEFAULT 'active',
        sync_status TEXT DEFAULT 'synced',
        pending_action TEXT,
        client_request_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        edited_at TEXT,
        deleted_at TEXT,
        last_error TEXT,
        retry_count INTEGER DEFAULT 0,
        last_attempt_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_live_comments_channel_time '
      'ON live_comments(channel_id, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_live_comments_pending '
      'ON live_comments(channel_id, sync_status, last_attempt_at)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_live_comments_request '
      'ON live_comments(channel_id, client_request_id) '
      'WHERE client_request_id IS NOT NULL',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS live_comment_actions (
        id TEXT PRIMARY KEY,
        channel_id TEXT NOT NULL,
        comment_id TEXT NOT NULL,
        action_type TEXT NOT NULL,
        payload TEXT DEFAULT '{}',
        sync_status TEXT DEFAULT 'pending',
        retry_count INTEGER DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL,
        last_attempt_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_live_comment_actions_pending '
      'ON live_comment_actions(channel_id, sync_status, last_attempt_at)',
    );

    // Vendor commerce is account-scoped and local-first. Only compact JSON and
    // remote media URLs are stored here; image bytes stay in the image cache.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vendor_dashboard_cache (
        vendor_id TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vendor_order_cache (
        vendor_id TEXT NOT NULL,
        order_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT,
        updated_at TEXT,
        PRIMARY KEY (vendor_id, order_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_vendor_orders_updated '
      'ON vendor_order_cache(vendor_id, updated_at DESC, created_at DESC)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vendor_review_cache (
        vendor_id TEXT NOT NULL,
        review_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT,
        updated_at TEXT,
        PRIMARY KEY (vendor_id, review_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_vendor_reviews_updated '
      'ON vendor_review_cache(vendor_id, updated_at DESC, created_at DESC)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS commerce_order_cache (
        account_id TEXT NOT NULL,
        role TEXT NOT NULL,
        order_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT,
        updated_at TEXT,
        PRIMARY KEY (account_id, role, order_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_commerce_orders_account_updated '
      'ON commerce_order_cache(account_id, role, updated_at DESC, created_at DESC)',
    );
  }

  // ─── Sync Cursor API ─────────────────────────────────────────────────────

  /// Returns the ISO-8601 timestamp of the last successful sync for [key].
  Future<String?> getSyncCursor(String key) async {
    final db = await database;
    final rows = await db.query(
      'sync_cursors',
      where: 'cursor_key = ?',
      whereArgs: [key],
    );
    return rows.isNotEmpty ? rows.first['last_sync_at'] as String? : null;
  }

  /// Persists the sync cursor for [key] after a successful delta pull.
  Future<void> setSyncCursor(String key, String isoTimestamp) async {
    final db = await database;
    await db.insert('sync_cursors', {
      'cursor_key': key,
      'last_sync_at': isoTimestamp,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // Legacy helpers kept for backward-compat
  Future<String?> getFeedSyncTime(String userId) =>
      getSyncCursor('feed:$userId');
  Future<void> updateFeedSyncTime(String userId, String ts) =>
      setSyncCursor('feed:$userId', ts);

  // ─── Community Posts ──────────────────────────────────────────────────────

  /// Upserts posts with DENORMALIZED author info — no JOIN needed on read.
  Future<void> saveCommunityPosts(List<Map<String, dynamic>> posts) async {
    if (posts.isEmpty) return;
    final db = await database;
    final batch = db.batch();

    for (final post in posts) {
      // Flatten nested profile data into the post row
      final profile = post['profiles'] as Map<String, dynamic>?;
      final authorName =
          post['author_name'] ??
          profile?['display_name'] ??
          profile?['full_name'];
      final authorAvatar =
          post['author_avatar'] ??
          profile?['photo_url'] ??
          profile?['avatar_url'];

      // Preserve local_media_path
      String? localPath = post['local_media_path'];
      if (localPath == null) {
        final existing = await db.query(
          'community_posts',
          columns: ['local_media_path'],
          where: 'id = ?',
          whereArgs: [post['id']],
        );
        if (existing.isNotEmpty) {
          localPath = existing.first['local_media_path'] as String?;
        }
      }

      batch.insert('community_posts', {
        'id': post['id'],
        'author_id': post['author_id'] ?? post['user_id'],
        'author_name': authorName,
        'author_avatar': authorAvatar,
        'content': post['content'] ?? post['title'],
        'media_url': post['media_url'],
        'thumbnail_url': post['thumbnail_url'],
        'hls_url': post['hls_url'],
        'local_media_path': localPath,
        'media_type': post['media_type'] ?? 'image',
        'likes_count': post['likes_count'] ?? 0,
        'comments_count': post['comments_count'] ?? 0,
        'is_liked': post['is_liked'] == true || post['is_liked'] == 1 ? 1 : 0,
        'engagement_synced_at': post['engagement_synced_at'],
        'listing_data': post['listings'] != null
            ? jsonEncode(post['listings'])
            : null,
        'created_at': post['created_at'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // Also keep social_profiles warm for profile-screen lookups
      if (profile != null) {
        batch.insert('social_profiles', {
          'id': post['author_id'] ?? post['user_id'],
          'display_name': authorName,
          'photo_url': authorAvatar,
          'trust_score': profile['trust_score'] ?? 50,
          'is_verified':
              (profile['trust_score_tier'] == 'titan_trust' ||
                  profile['trust_score_tier'] == 'verified')
              ? 1
              : 0,
          'cached_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    await batch.commit(noResult: true);
    await _prunePosts(); // Keep DB lean
  }

  /// Returns up to [limit] posts from the local cache — no network call needed.
  Future<List<Map<String, dynamic>>> getCachedFeed({int limit = 30}) async {
    final db = await database;
    // Direct column read — no JOIN needed thanks to denormalization
    final rows = await db.query(
      'community_posts',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map((r) {
      final m = Map<String, dynamic>.from(r);
      if (m['listing_data'] != null && m['listing_data'] is String) {
        try {
          m['listings'] = jsonDecode(m['listing_data']);
        } catch (_) {}
      }
      return m;
    }).toList();
  }

  /// Paginated cursor-based read for infinite scroll.
  Future<List<Map<String, dynamic>>> getPostsPaginated({
    int limit = 20,
    String? beforeTime,
  }) async {
    final db = await database;
    if (beforeTime != null) {
      return await db.query(
        'community_posts',
        where: 'created_at < ?',
        whereArgs: [beforeTime],
        orderBy: 'created_at DESC',
        limit: limit,
      );
    }
    return await db.query(
      'community_posts',
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  Future<List<Map<String, dynamic>>> getUserCachedPosts(String userId) async {
    final db = await database;
    return await db.query(
      'community_posts',
      where: 'author_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
    );
  }

  Future<String?> getLastPostTime() async {
    final db = await database;
    final rows = await db.query(
      'community_posts',
      columns: ['created_at'],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first['created_at'] as String? : null;
  }

  /// Prunes old posts beyond [_feedMaxRows] — keeps the DB from growing unbounded.
  Future<void> _prunePosts() async {
    final db = await database;
    await db.rawDelete('''
      DELETE FROM community_posts WHERE id IN (
        SELECT id FROM community_posts ORDER BY created_at DESC LIMIT -1 OFFSET $_feedMaxRows
      )
    ''');
  }

  Future<void> incrementPostMetric(String postId, String column) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE community_posts SET $column = $column + 1 WHERE id = ?',
      [postId],
    );
  }

  Future<void> setPostMetric(String postId, String column, int value) async {
    if (column != 'likes_count' && column != 'comments_count') {
      throw ArgumentError.value(column, 'column', 'Unsupported post metric');
    }
    final db = await database;
    await db.rawUpdate('UPDATE community_posts SET $column = ? WHERE id = ?', [
      value < 0 ? 0 : value,
      postId,
    ]);
  }

  Future<void> setCachedEngagement({
    required String localId,
    required bool isShop,
    required int likes,
    required int comments,
    required bool isLiked,
  }) async {
    final db = await database;
    final table = isShop ? 'shop_listings' : 'community_posts';
    await db.update(
      table,
      {
        'likes_count': likes < 0 ? 0 : likes,
        'comments_count': comments < 0 ? 0 : comments,
        'is_liked': isLiked ? 1 : 0,
        'engagement_synced_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> incrementCachedEngagementMetric({
    required String localId,
    required bool isShop,
    required String column,
    int amount = 1,
  }) async {
    if (column != 'likes_count' && column != 'comments_count') {
      throw ArgumentError.value(column, 'column', 'Unsupported metric');
    }
    final db = await database;
    final table = isShop ? 'shop_listings' : 'community_posts';
    await db.rawUpdate(
      '''
      UPDATE $table
      SET $column = MAX(0, COALESCE($column, 0) + ?)
      WHERE id = ?
      ''',
      [amount, localId],
    );
  }

  // ─── Shop Listings ────────────────────────────────────────────────────────

  Future<void> saveListings(List<Map<String, dynamic>> listings) async {
    if (listings.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final l in listings) {
      final rawProf = l['profiles'] ?? l['lister'];
      Map<String, dynamic>? profile;
      if (rawProf is List && rawProf.isNotEmpty) {
        profile = rawProf[0] as Map<String, dynamic>?;
      } else if (rawProf is Map) {
        profile = rawProf as Map<String, dynamic>?;
      }

      final photos = _normalizePhotoList(
        l['miniature_photos'] ?? l['photos'] ?? l['listing_photos'],
      );
      final thumbnailUrl =
          _extractUrl(l['thumbnail_url']) ??
          _extractUrl(l['image_url']) ??
          (photos.isNotEmpty ? photos.first : null) ??
          _extractUrl(l['media_url']) ??
          _extractUrl(l['film_hub_content']);
      final mediaUrl =
          _extractUrl(l['media_url']) ??
          _extractUrl(l['image_url']) ??
          _extractUrl(l['film_hub_content']) ??
          thumbnailUrl;

      batch.insert('shop_listings', {
        'id': l['id'],
        'user_id': l['user_id'] ?? l['lister_id'],
        'lister_name':
            l['lister_name'] ??
            profile?['display_name'] ??
            profile?['full_name'] ??
            'Vendor',
        'lister_avatar':
            l['lister_avatar'] ??
            profile?['photo_url'] ??
            profile?['avatar_url'],
        'title': l['title'],
        'price': l['price'] ?? l['price_ugx'] ?? 0,
        'description': l['description'],
        'price_ugx': l['price_ugx'] ?? l['price'] ?? 0,
        'sku': l['sku'],
        'stock_count': l['stock_count'] ?? 0,
        'lister_id': l['lister_id'] ?? l['user_id'],
        'status': l['status'] ?? 'active',
        'media_url': mediaUrl,
        'thumbnail_url': thumbnailUrl,
        'media_type': l['media_type'] ?? 'image',
        'likes_count': l['likes_count'] ?? 0,
        'comments_count': l['comments_count'] ?? 0,
        'is_liked': l['is_liked'] == true || l['is_liked'] == 1 ? 1 : 0,
        'engagement_synced_at': l['engagement_synced_at'],
        'category': l['category'] ?? 'General',
        'is_verified': (l['is_verified'] == true || l['is_verified'] == 1)
            ? 1
            : 0,
        'photos': jsonEncode(photos),
        'film_hub_content': _extractUrl(l['film_hub_content']) ?? mediaUrl,
        'pickup_address': l['pickup_address'],
        'latitude': l['latitude'],
        'longitude': l['longitude'],
        'created_at': l['created_at'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await _pruneListings();
  }

  Future<List<Map<String, dynamic>>> getCachedListings({
    int limit = 30,
    String? category,
  }) async {
    final db = await database;
    final rows = await db.query(
      'shop_listings',
      where: category != null ? 'category = ?' : null,
      whereArgs: category != null ? [category] : null,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map((r) {
      final m = Map<String, dynamic>.from(r);
      // Parse JSON array string back to List
      if (m['photos'] != null && m['photos'] is String) {
        m['photos'] = _normalizePhotoList(m['photos']);
        m['miniature_photos'] = m['photos'];
      }
      return m;
    }).toList();
  }

  Future<void> _pruneListings() async {
    final db = await database;
    // Keep top 10 per category, then global limit
    await db.execute('''
      DELETE FROM shop_listings WHERE id NOT IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (PARTITION BY category ORDER BY created_at DESC) as rank
          FROM shop_listings
        ) WHERE rank <= 10
      )
    ''');

    // Final global cap
    await db.rawDelete('''
      DELETE FROM shop_listings WHERE id IN (
        SELECT id FROM shop_listings ORDER BY created_at DESC LIMIT -1 OFFSET $_shopMaxRows
      )
    ''');
  }

  // ─── Social Profiles ──────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> getProfile(String userId) async {
    final db = await database;
    final rows = await db.query(
      'social_profiles',
      where: 'id = ?',
      whereArgs: [userId],
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<void> upsertProfile(Map<String, dynamic> profile) async {
    final db = await database;
    await db.insert('social_profiles', {
      'id': profile['id'],
      'display_name': profile['full_name'] ?? profile['display_name'],
      'photo_url': profile['avatar_url'] ?? profile['photo_url'],
      'trust_score': profile['trust_score'] ?? 50,
      'is_verified':
          (profile['verified'] == true || profile['is_verified'] == 1) ? 1 : 0,
      'cached_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ─── Chat Rooms ───────────────────────────────────────────────────────────

  Future<void> saveRooms(List<ChatRoom> rooms) async {
    final db = await database;
    final batch = db.batch();
    for (final room in rooms) {
      batch.insert('chat_rooms', {
        'id': room.id,
        'other_party_id': room.otherPartyId,
        'other_name': room.otherName,
        'other_avatar': room.otherAvatar,
        'last_message': room.lastMessage,
        'last_message_at': room.lastMessageAt?.toIso8601String(),
        'unread_count': room.myUnread,
        'created_at': room.createdAt.toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<ChatRoom>> getRooms() async {
    final db = await database;
    final rows = await db.query('chat_rooms', orderBy: 'last_message_at DESC');
    return rows
        .map(
          (m) => ChatRoom(
            id: m['id'] as String,
            otherName: m['other_name'] as String?,
            otherAvatar: m['other_avatar'] as String?,
            lastMessage: m['last_message'] as String?,
            lastMessageAt: DateTime.tryParse(
              m['last_message_at'] as String? ?? '',
            ),
            myUnread: (m['unread_count'] as int?) ?? 0,
            createdAt:
                DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
          ),
        )
        .toList();
  }

  // ─── Chat Messages ────────────────────────────────────────────────────────

  Future<void> saveMessages(List<ChatMessage> messages) async {
    if (messages.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final msg in messages) {
      // 🚀 NEURAL SYNC: Preserve local_media_path if it exists and incoming is null
      String? localPath = msg.localMediaPath;
      if (localPath == null) {
        final existing = await db.query(
          'chat_messages',
          columns: ['local_media_path'],
          where: 'id = ?',
          whereArgs: [msg.id],
        );
        if (existing.isNotEmpty) {
          localPath = existing.first['local_media_path'] as String?;
        }
      }

      batch.insert('chat_messages', {
        'id': msg.id,
        'room_id': msg.conversationId,
        'sender_id': msg.senderId,
        'receiver_id': msg.receiverId,
        'content': msg.content,
        'media_url': msg.mediaUrl,
        'local_media_path': localPath,
        'message_type': msg.messageType,
        'is_read': msg.isRead ? 1 : 0,
        'reactions': msg.reactions?.join(','),
        'created_at': msg.createdAt.toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<ChatMessage>> getMessages(String roomId) async {
    final db = await database;
    final rows = await db.query(
      'chat_messages',
      where: 'room_id = ?',
      whereArgs: [roomId],
      orderBy: 'created_at ASC',
    );
    return rows
        .map(
          (m) => ChatMessage(
            id: m['id'] as String,
            conversationId: m['room_id'] as String,
            senderId: m['sender_id'] as String,
            receiverId: m['receiver_id'] as String? ?? '',
            content: m['content'] as String? ?? '',
            mediaUrl: m['media_url'] as String?,
            messageType: m['message_type'] as String? ?? 'text',
            isRead: m['is_read'] == 1,
            createdAt:
                DateTime.tryParse(m['created_at'] as String? ?? '') ??
                DateTime.now(),
          ),
        )
        .toList();
  }

  Future<String?> getLastMessageTime(String roomId) async {
    final db = await database;
    final rows = await db.query(
      'chat_messages',
      columns: ['created_at'],
      where: 'room_id = ?',
      whereArgs: [roomId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first['created_at'] as String? : null;
  }

  Future<void> updateMessageReactions(
    String messageId,
    List<String> reactions,
  ) async {
    final db = await database;
    await db.update(
      'chat_messages',
      {'reactions': reactions.join(',')},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  // ─── Social Action Queue ──────────────────────────────────────────────────

  Future<void> queueSocialAction(
    String type,
    String postId, {
    Map<String, dynamic>? payload,
    String? dedupeKey,
  }) async {
    final db = await database;
    await db.insert('social_actions_queue', {
      'action_type': type,
      'post_id': postId,
      'payload': payload == null ? null : jsonEncode(payload),
      'dedupe_key': dedupeKey,
      'retry_count': 0,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getPendingActions() async {
    final db = await database;
    return await db.query('social_actions_queue', orderBy: 'created_at ASC');
  }

  Future<void> removeAction(int id) async {
    final db = await database;
    await db.delete('social_actions_queue', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markActionAttempt(int id) async {
    final db = await database;
    await db.rawUpdate(
      '''
      UPDATE social_actions_queue
      SET retry_count = COALESCE(retry_count, 0) + 1,
          last_attempt_at = ?
      WHERE id = ?
      ''',
      [DateTime.now().toIso8601String(), id],
    );
  }

  // ─── Notifications ────────────────────────────────────────────────────────

  Future<void> saveNotification(Map<String, dynamic> notif) async {
    final db = await database;
    await db.insert('app_notifications', {
      'id': notif['id'],
      'type': notif['type'],
      'title': notif['title'],
      'body': notif['body'],
      'payload': notif['payload'],
      'actor_id': notif['actor_id'],
      'actor_name': notif['actor_name'],
      'actor_avatar': notif['actor_avatar'],
      'target_id': notif['target_id'],
      'target_type': notif['target_type'] ?? 'post',
      'metadata': notif['metadata'] ?? '{}',
      'is_read': notif['is_read'] ?? 0,
      'created_at': notif['created_at'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.rawDelete('''
      DELETE FROM app_notifications WHERE id IN (
        SELECT id FROM app_notifications ORDER BY created_at DESC LIMIT -1 OFFSET $_notifMaxRows
      )
    ''');
  }

  Future<List<Map<String, dynamic>>> getNotifications() async {
    final db = await database;
    return await db.query(
      'app_notifications',
      orderBy: 'created_at DESC',
      limit: _notifMaxRows,
    );
  }

  Future<bool> hasNotification(String id) async {
    final db = await database;
    final rows = await db.query(
      'app_notifications',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> saveNotifications(
    List<Map<String, dynamic>> notifications,
  ) async {
    if (notifications.isEmpty) return;
    for (final notification in notifications) {
      await saveNotification(notification);
    }
  }

  Future<void> markNotificationAsRead(String id) async {
    final db = await database;
    await db.update(
      'app_notifications',
      {'is_read': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markAllNotificationsAsRead() async {
    final db = await database;
    await db.update('app_notifications', {'is_read': 1}, where: 'is_read = 0');
  }

  // ─── Transport Orders persistence ───────────────────────────────────────

  Future<void> saveTransportOrders(List<Map<String, dynamic>> orders) async {
    final db = await database;
    final batch = db.batch();
    for (var order in orders) {
      final cachedOrder = <String, dynamic>{
        for (final key in [
          'id',
          'user_id',
          'driver_id',
          'pickup_location',
          'dropoff_location',
          'status',
          'price',
          'created_at',
          'updated_at',
          'delivery_lat',
          'delivery_lng',
        ])
          key: order[key],
      };
      batch.insert(
        'transport_orders',
        cachedOrder,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    final userIds = orders
        .map((order) => order['user_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    for (final userId in userIds) {
      await db.rawDelete(
        'DELETE FROM transport_orders WHERE user_id = ? AND id NOT IN '
        '(SELECT id FROM transport_orders WHERE user_id = ? '
        'ORDER BY updated_at DESC, created_at DESC LIMIT 100)',
        [userId, userId],
      );
    }
  }

  Future<List<Map<String, dynamic>>> getCachedTransportOrders(
    String userId,
  ) async {
    final db = await database;
    return await db.query(
      'transport_orders',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'updated_at DESC, created_at DESC',
      limit: 100,
    );
  }

  // â”€â”€â”€ Vendor Dashboard persistence â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> saveVendorDashboard(
    String vendorId,
    Map<String, dynamic> dashboard,
  ) async {
    final db = await database;
    await db.insert('vendor_dashboard_cache', {
      'vendor_id': vendorId,
      'payload': jsonEncode(dashboard),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getCachedVendorDashboard(
    String vendorId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'vendor_dashboard_cache',
      columns: ['payload'],
      where: 'vendor_id = ?',
      whereArgs: [vendorId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decodeCachedMap(rows.first['payload']);
  }

  Future<void> saveVendorOrders(
    String vendorId,
    List<Map<String, dynamic>> orders,
  ) async {
    if (orders.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final order in orders) {
      final id = order['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final createdAt = order['created_at']?.toString();
      batch.insert('vendor_order_cache', {
        'vendor_id': vendorId,
        'order_id': id,
        'payload': jsonEncode(order),
        'created_at': createdAt,
        'updated_at': order['updated_at']?.toString() ?? createdAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await db.rawDelete(
      'DELETE FROM vendor_order_cache WHERE vendor_id = ? AND order_id NOT IN '
      '(SELECT order_id FROM vendor_order_cache WHERE vendor_id = ? '
      'ORDER BY updated_at DESC, created_at DESC LIMIT 100)',
      [vendorId, vendorId],
    );
  }

  Future<List<Map<String, dynamic>>> getCachedVendorOrders(
    String vendorId, {
    int limit = 30,
  }) async {
    final db = await database;
    final rows = await db.query(
      'vendor_order_cache',
      columns: ['payload'],
      where: 'vendor_id = ?',
      whereArgs: [vendorId],
      orderBy: 'updated_at DESC, created_at DESC',
      limit: limit,
    );
    return rows
        .map((row) => _decodeCachedMap(row['payload']))
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<void> saveVendorReviews(
    String vendorId,
    List<Map<String, dynamic>> reviews,
  ) async {
    if (reviews.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final review in reviews) {
      final id = review['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final createdAt = review['created_at']?.toString();
      batch.insert('vendor_review_cache', {
        'vendor_id': vendorId,
        'review_id': id,
        'payload': jsonEncode(review),
        'created_at': createdAt,
        'updated_at': review['updated_at']?.toString() ?? createdAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await db.rawDelete(
      'DELETE FROM vendor_review_cache WHERE vendor_id = ? AND review_id NOT IN '
      '(SELECT review_id FROM vendor_review_cache WHERE vendor_id = ? '
      'ORDER BY updated_at DESC, created_at DESC LIMIT 60)',
      [vendorId, vendorId],
    );
  }

  Future<List<Map<String, dynamic>>> getCachedVendorReviews(
    String vendorId, {
    int limit = 30,
  }) async {
    final db = await database;
    final rows = await db.query(
      'vendor_review_cache',
      columns: ['payload'],
      where: 'vendor_id = ?',
      whereArgs: [vendorId],
      orderBy: 'updated_at DESC, created_at DESC',
      limit: limit,
    );
    return rows
        .map((row) => _decodeCachedMap(row['payload']))
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<void> saveCommerceOrders(
    String accountId,
    String role,
    List<Map<String, dynamic>> orders,
  ) async {
    if (orders.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final order in orders) {
      final id = order['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final createdAt = order['created_at']?.toString();
      batch.insert('commerce_order_cache', {
        'account_id': accountId,
        'role': role,
        'order_id': id,
        'payload': jsonEncode(order),
        'created_at': createdAt,
        'updated_at': order['updated_at']?.toString() ?? createdAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await db.rawDelete(
      'DELETE FROM commerce_order_cache WHERE account_id = ? AND role = ? '
      'AND order_id NOT IN (SELECT order_id FROM commerce_order_cache '
      'WHERE account_id = ? AND role = ? '
      'ORDER BY updated_at DESC, created_at DESC LIMIT 100)',
      [accountId, role, accountId, role],
    );
  }

  Future<List<Map<String, dynamic>>> getCachedCommerceOrders(
    String accountId,
    String role, {
    int limit = 50,
  }) async {
    final db = await database;
    final rows = await db.query(
      'commerce_order_cache',
      columns: ['payload'],
      where: 'account_id = ? AND role = ?',
      whereArgs: [accountId, role],
      orderBy: 'updated_at DESC, created_at DESC',
      limit: limit,
    );
    return rows
        .map((row) => _decodeCachedMap(row['payload']))
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Map<String, dynamic>? _decodeCachedMap(dynamic payload) {
    try {
      final decoded = jsonDecode(payload?.toString() ?? '');
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  // ─── Selective Cache Clears ───────────────────────────────────────────────
  // NOTE: We NEVER clear community_posts or social_profiles on network restore.
  // Only clear chat data (ephemeral) or on explicit logout.

  /// Clears ONLY ephemeral chat data. Feed/shop/profiles are preserved.
  Future<void> clearChatCache() async {
    final db = await database;
    await db.delete('chat_rooms');
    await db.delete('chat_messages');
  }

  /// Full wipe — only called on logout or user account switch.
  Future<void> clearAllOnLogout() async {
    final db = await database;
    await db.delete('chat_rooms');
    await db.delete('chat_messages');
    await db.delete('community_posts');
    await db.delete('shop_listings');
    await db.delete('social_profiles');
    await db.delete('social_actions_queue');
    await db.delete('sync_cursors');
    await db.delete('app_notifications');
    await db.delete('community_comments');
    await db.delete('live_comments');
    await db.delete('live_comment_actions');
    await db.delete('transport_orders');
    await db.delete('vendor_dashboard_cache');
    await db.delete('vendor_order_cache');
    await db.delete('vendor_review_cache');
    await db.delete('commerce_order_cache');
  }

  // ─── Comments API ────────────────────────────────────────────────────────

  Future<void> saveComments(
    String postId,
    List<Map<String, dynamic>> comments,
  ) async {
    final db = await database;
    final batch = db.batch();
    for (var c in comments) {
      final identity = c['metadata']?['identity'] ?? c['identity'];
      final prof = c['profiles'] ?? c['user'] ?? identity;
      final userId = c['user_id'] ?? c['author_id'] ?? identity?['user_id'];
      batch.insert('community_comments', {
        'id': c['id'],
        'post_id': postId,
        'user_id': userId,
        'user_name':
            c['user_name'] ??
            prof?['user_name'] ??
            prof?['display_name'] ??
            prof?['full_name'],
        'user_avatar':
            c['user_avatar'] ??
            prof?['user_avatar'] ??
            prof?['photo_url'] ??
            prof?['avatar_url'],
        'user_profile_url':
            c['user_profile_url'] ??
            prof?['user_profile_url'] ??
            "https://necxa.app/u/$userId",
        'content': c['content'],
        'sync_status': c['sync_status'] ?? 'synced',
        'idempotency_key': c['idempotency_key'],
        'target_type': c['target_type'] ?? 'post',
        'created_at': c['created_at'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<Map<String, dynamic>> savePendingComment({
    required String id,
    required String postId,
    required String userId,
    required String content,
    required String idempotencyKey,
    required String targetType,
    String? userName,
    String? userAvatar,
  }) async {
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final comment = <String, dynamic>{
      'id': id,
      'post_id': postId,
      'user_id': userId,
      'user_name': userName ?? 'You',
      'user_avatar': userAvatar,
      'user_profile_url': 'https://necxa.app/u/$userId',
      'content': content,
      'sync_status': 'pending',
      'idempotency_key': idempotencyKey,
      'target_type': targetType,
      'created_at': createdAt,
    };
    final db = await database;
    await db.insert(
      'community_comments',
      comment,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return comment;
  }

  Future<void> reconcilePendingComment(
    String localCommentId,
    String postId,
    Map<String, dynamic> serverComment,
  ) async {
    await saveComments(postId, [
      {...serverComment, 'sync_status': 'synced'},
    ]);
    final db = await database;
    await db.delete(
      'community_comments',
      where: 'id = ?',
      whereArgs: [localCommentId],
    );
  }

  Future<List<Map<String, dynamic>>> getCachedComments(String postId) async {
    final db = await database;
    return await db.query(
      'community_comments',
      where: 'post_id = ?',
      whereArgs: [postId],
      orderBy: 'created_at DESC',
    );
  }

  Map<String, dynamic> _liveCommentFromRow(Map<String, Object?> row) {
    return <String, dynamic>{
      'id': row['id'],
      'channelId': row['channel_id'],
      'userId': row['user_id'],
      'user': row['user_name'] ?? 'User',
      'userName': row['user_name'] ?? 'User',
      'avatar': row['user_avatar'] ?? '',
      'text': row['text'] ?? '',
      'status': row['status'] ?? 'active',
      'syncStatus': row['sync_status'] ?? 'synced',
      'pendingAction': row['pending_action'],
      'clientRequestId': row['client_request_id'],
      'timestamp': row['created_at'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
      'editedAt': row['edited_at'],
      'deletedAt': row['deleted_at'],
      'lastError': row['last_error'],
      'retryCount': row['retry_count'] ?? 0,
      'lastAttemptAt': row['last_attempt_at'],
    };
  }

  Future<List<Map<String, dynamic>>> getCachedLiveComments(
    String channelId, {
    int limit = 1000,
  }) async {
    final db = await database;
    final rows = await db.query(
      'live_comments',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(_liveCommentFromRow).toList();
  }

  Future<Map<String, dynamic>> savePendingLiveComment({
    required String id,
    required String channelId,
    required String userId,
    required String userName,
    required String userAvatar,
    required String text,
    required String clientRequestId,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final row = <String, Object?>{
      'id': id,
      'channel_id': channelId,
      'user_id': userId,
      'user_name': userName,
      'user_avatar': userAvatar,
      'text': text,
      'status': 'active',
      'sync_status': 'pending',
      'pending_action': 'send',
      'client_request_id': clientRequestId,
      'created_at': now,
      'updated_at': now,
      'retry_count': 0,
    };
    final db = await database;
    await db.insert(
      'live_comments',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return _liveCommentFromRow(row);
  }

  Future<void> saveLiveComments(
    String channelId,
    List<Map<String, dynamic>> comments, {
    bool overwritePending = false,
  }) async {
    if (comments.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final comment in comments) {
        final id = comment['id']?.toString();
        if (id == null || id.isEmpty) continue;
        final requestId = comment['clientRequestId']?.toString();
        if (requestId != null && requestId.isNotEmpty) {
          await txn.delete(
            'live_comments',
            where: 'channel_id = ? AND client_request_id = ? AND id != ?',
            whereArgs: [channelId, requestId, id],
          );
        }
        final localRows = await txn.query(
          'live_comments',
          columns: ['sync_status'],
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (!overwritePending &&
            localRows.isNotEmpty &&
            localRows.first['sync_status'] != 'synced') {
          continue;
        }
        final createdAt =
            (comment['createdAt'] ?? comment['timestamp'])?.toString() ??
            DateTime.now().toUtc().toIso8601String();
        final updatedAt = comment['updatedAt']?.toString() ?? createdAt;
        await txn.insert('live_comments', {
          'id': id,
          'channel_id': channelId,
          'user_id': comment['userId']?.toString(),
          'user_name':
              (comment['userName'] ?? comment['user'])?.toString() ?? 'User',
          'user_avatar':
              (comment['avatar'] ?? comment['userAvatar'])?.toString() ?? '',
          'text': comment['text']?.toString() ?? '',
          'status': comment['status']?.toString() ?? 'active',
          'sync_status': 'synced',
          'pending_action': null,
          'client_request_id': requestId,
          'created_at': createdAt,
          'updated_at': updatedAt,
          'edited_at': comment['editedAt']?.toString(),
          'deleted_at': comment['deletedAt']?.toString(),
          'last_error': null,
          'retry_count': 0,
          'last_attempt_at': null,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<Map<String, dynamic>>> getPendingLiveCommentMutations(
    String channelId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'live_comments',
      where: "channel_id = ? AND sync_status IN ('pending', 'retrying')",
      whereArgs: [channelId],
      orderBy: 'created_at ASC',
    );
    return rows.map(_liveCommentFromRow).toList();
  }

  Future<void> markLiveCommentMutationAttempt(
    String id, {
    String? error,
    bool failed = false,
  }) async {
    final db = await database;
    await db.rawUpdate(
      '''
      UPDATE live_comments
      SET sync_status = ?,
          retry_count = retry_count + 1,
          last_error = ?,
          last_attempt_at = ?
      WHERE id = ?
      ''',
      [
        failed ? 'failed' : 'retrying',
        error,
        DateTime.now().toUtc().toIso8601String(),
        id,
      ],
    );
  }

  Future<void> resetLiveCommentMutation(String id) async {
    final db = await database;
    await db.update(
      'live_comments',
      {
        'sync_status': 'pending',
        'last_error': null,
        'retry_count': 0,
        'last_attempt_at': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> reconcileLiveCommentMutation(
    String localId,
    String channelId,
    Map<String, dynamic>? serverComment,
  ) async {
    if (serverComment == null) {
      final db = await database;
      await db.delete('live_comments', where: 'id = ?', whereArgs: [localId]);
      return;
    }
    await saveLiveComments(channelId, [serverComment], overwritePending: true);
    if (serverComment['id']?.toString() != localId) {
      final db = await database;
      await db.delete('live_comments', where: 'id = ?', whereArgs: [localId]);
    }
  }

  Future<void> queueLiveCommentEdit(String id, String text) async {
    final db = await database;
    final rows = await db.query(
      'live_comments',
      columns: ['pending_action'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final isPendingSend = rows.first['pending_action'] == 'send';
    await db.update(
      'live_comments',
      {
        'text': text,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'sync_status': 'pending',
        if (!isPendingSend) 'pending_action': 'edit',
        'last_error': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> queueLiveCommentDelete(String id) async {
    final db = await database;
    final rows = await db.query(
      'live_comments',
      columns: ['pending_action'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    if (rows.first['pending_action'] == 'send') {
      await db.delete('live_comments', where: 'id = ?', whereArgs: [id]);
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    await db.update(
      'live_comments',
      {
        'status': 'deleted',
        'sync_status': 'pending',
        'pending_action': 'delete',
        'updated_at': now,
        'deleted_at': now,
        'last_error': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> enqueueLiveCommentAction({
    required String id,
    required String channelId,
    required String commentId,
    required String actionType,
    Map<String, dynamic> payload = const {},
  }) async {
    final db = await database;
    await db.insert('live_comment_actions', {
      'id': id,
      'channel_id': channelId,
      'comment_id': commentId,
      'action_type': actionType,
      'payload': jsonEncode(payload),
      'sync_status': 'pending',
      'retry_count': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, dynamic>>> getPendingLiveCommentActions(
    String channelId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'live_comment_actions',
      where: "channel_id = ? AND sync_status IN ('pending', 'retrying')",
      whereArgs: [channelId],
      orderBy: 'created_at ASC',
    );
    return rows.map((row) {
      Map<String, dynamic> payload = {};
      try {
        payload = Map<String, dynamic>.from(
          jsonDecode(row['payload']?.toString() ?? '{}') as Map,
        );
      } catch (_) {}
      return <String, dynamic>{...row, 'payload': payload};
    }).toList();
  }

  Future<List<String>> getPendingLiveCommentChannels() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT DISTINCT channel_id FROM live_comments
      WHERE sync_status IN ('pending', 'retrying')
      UNION
      SELECT DISTINCT channel_id FROM live_comment_actions
      WHERE sync_status IN ('pending', 'retrying')
    ''');
    return rows
        .map((row) => row['channel_id']?.toString())
        .whereType<String>()
        .where((channelId) => channelId.isNotEmpty)
        .toList();
  }

  Future<void> completeLiveCommentAction(String id) async {
    final db = await database;
    await db.delete('live_comment_actions', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markLiveCommentActionAttempt(
    String id, {
    required String error,
    bool failed = false,
  }) async {
    final db = await database;
    await db.rawUpdate(
      '''
      UPDATE live_comment_actions
      SET sync_status = ?,
          retry_count = retry_count + 1,
          last_error = ?,
          last_attempt_at = ?
      WHERE id = ?
      ''',
      [
        failed ? 'failed' : 'retrying',
        error,
        DateTime.now().toUtc().toIso8601String(),
        id,
      ],
    );
  }
}
