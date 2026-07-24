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
  static const int _dbVersion = 10;

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
        price REAL DEFAULT 0,
        media_url TEXT,
        thumbnail_url TEXT,
        media_type TEXT DEFAULT 'image',
        category TEXT,
        is_verified INTEGER DEFAULT 0,
        photos TEXT, -- JSON Array of miniature URLs
        film_hub_content TEXT, -- Explicit main media URL
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
        created_at TEXT
      )
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
        created_at TEXT
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
        created_at TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_comments_post ON community_comments(post_id)',
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
        'media_url': mediaUrl,
        'thumbnail_url': thumbnailUrl,
        'media_type': l['media_type'] ?? 'image',
        'category': l['category'] ?? 'General',
        'is_verified': (l['is_verified'] == true || l['is_verified'] == 1)
            ? 1
            : 0,
        'photos': jsonEncode(photos),
        'film_hub_content': _extractUrl(l['film_hub_content']) ?? mediaUrl,
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
  }) async {
    final db = await database;
    await db.insert('social_actions_queue', {
      'action_type': type,
      'post_id': postId,
      'payload': payload == null ? null : jsonEncode(payload),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getPendingActions() async {
    final db = await database;
    return await db.query('social_actions_queue', orderBy: 'created_at ASC');
  }

  Future<void> removeAction(int id) async {
    final db = await database;
    await db.delete('social_actions_queue', where: 'id = ?', whereArgs: [id]);
  }

  // ─── Notifications ────────────────────────────────────────────────────────

  Future<void> saveNotification(Map<String, dynamic> notif) async {
    final db = await database;
    await db.insert(
      'app_notifications',
      notif,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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

  Future<void> markNotificationAsRead(String id) async {
    final db = await database;
    await db.update(
      'app_notifications',
      {'is_read': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ─── Transport Orders persistence ───────────────────────────────────────

  Future<void> saveTransportOrders(List<Map<String, dynamic>> orders) async {
    final db = await database;
    final batch = db.batch();
    for (var order in orders) {
      batch.insert(
        'transport_orders',
        order,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> getCachedTransportOrders() async {
    final db = await database;
    return await db.query('transport_orders', orderBy: 'created_at DESC');
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
        'created_at': c['created_at'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
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
}
