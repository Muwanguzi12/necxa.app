import 'package:flutter/material.dart';

// ── Models ────────────────────────────────────────────────────

class Post {
  final String id,
      creatorId,
      creator,
      avatar,
      type,
      title,
      views,
      duration,
      grad;
  final int likes, comments, gifts, earned;
  final List<String> tags;
  final String timeAgo;
  final bool verified;

  const Post({
    required this.id,
    required this.creatorId,
    required this.creator,
    required this.avatar,
    required this.verified,
    required this.type,
    required this.title,
    required this.views,
    required this.likes,
    required this.comments,
    required this.gifts,
    required this.duration,
    required this.grad,
    required this.tags,
    required this.timeAgo,
    required this.earned,
  });
}

class Creator {
  final String id, name, username, avatar, followers, category, bio;
  final int totalEarned;
  final bool verified;

  const Creator({
    required this.id,
    required this.name,
    required this.username,
    required this.avatar,
    required this.followers,
    required this.verified,
    required this.category,
    required this.bio,
    required this.totalEarned,
  });
}

class Profile {
  final String id, username;
  final String? fullName, avatarUrl, bio;
  final bool verified, aiVerified;
  final DateTime createdAt;

  Profile({
    required this.id,
    required this.username,
    this.fullName,
    this.avatarUrl,
    this.bio,
    required this.verified,
    required this.aiVerified,
    required this.createdAt,
  });

  factory Profile.fromMap(Map<String, dynamic> m) => Profile(
    id: m['id'],
    username: m['username'] ?? m['full_name']?.toLowerCase().replaceAll(' ', '_') ?? 'user_${m['id'].toString().substring(0, 4)}',
    fullName: m['full_name'] ?? 'Necxa User',
    avatarUrl: m['avatar_url'],
    bio: m['bio'],
    verified: m['verified'] ?? false,
    aiVerified: m['ai_verified'] ?? false,
    createdAt: m['created_at'] != null ? DateTime.parse(m['created_at']) : DateTime.now(),
  );
}

class Gift {
  final String id, emoji, name;
  final int price, fee;
  final String? imageUrl;
  /// Kept separate from [imageUrl] so the lightweight picker can use PNGs
  /// while a received-gift notification can load its JPEG only when opened.
  final String? notificationImageUrl;
  const Gift({
    required this.id,
    required this.emoji,
    required this.name,
    required this.price,
    required this.fee,
    this.imageUrl,
    this.notificationImageUrl,
  });
}

class GiftPreset {
  final int id;
  final double ncxAmount;
  final String icon;
  final String label;
  final String? color;
  final int? order;

  GiftPreset({
    required this.id,
    required this.ncxAmount,
    required this.icon,
    required this.label,
    this.color,
    this.order,
  });

  factory GiftPreset.fromJson(Map<String, dynamic> json) {
    return GiftPreset(
      id: json['id'],
      ncxAmount: (json['ncx_amount'] as num).toDouble(),
      icon: json['icon'],
      label: json['label'],
      color: json['color'],
      order: json['order'],
    );
  }
}

class PaymentMethod {
  final String type;
  final String name;
  final String icon;
  final Color color;

  PaymentMethod(this.type, this.name, this.icon, this.color);
}

// ── Static Data ───────────────────────────────────────────────

// ── Helpers ───────────────────────────────────────────────────

const String _giftCdn = 'https://anregykcgolpgxecfxej.supabase.co/storage/v1/object/public/gift-icons';
const String _giftPickerCdn = '$_giftCdn/gift%20icon';

/// The picker uses the supplied PNG artwork. Gift records carry only an ID,
/// never an image URL, so a transfer remains small and is not blocked by media.
const Map<String, String> giftPickerImageUrls = {
  'rose': '$_giftPickerCdn/file_00000000d79481f89b4523d67e1b4d29.png',
  'clap': '$_giftPickerCdn/file_0000000089c481f4816d139e6f26262a.png',
  'coffee': '$_giftPickerCdn/file_00000000857081f4a3c8768f37acdd83.png',
  'star': '$_giftPickerCdn/file_0000000099ac81f481b11ce02752b0c2.png',
  'fire': '$_giftPickerCdn/file_00000000a43881f4a34869b1e449e685.png',
  'rocket': '$_giftPickerCdn/file_000000006a0c81fd84117047c3de8479.png',
  'trophy': '$_giftPickerCdn/file_00000000ec7881f4b94ee4cb666786ce.png',
  'diamond': '$_giftPickerCdn/file_00000000d3d881f4a1f3522af02db335.png',
  'money_bag': '$_giftPickerCdn/file_00000000c24481f483798d796fa9e5ab.png',
  'sports_car': '$_giftPickerCdn/file_00000000d0f081f4b0f47169f3e987f9.png',
  'yacht': '$_giftPickerCdn/file_00000000898c81f4bafd3c88dd3fdfcd.png',
  // The duplicated filename supplied for Mansion is used here; the separate
  // correctly named PNG is reserved for Private Jet below.
  'mansion': '$_giftPickerCdn/file_00000000218481f488f653dcf7520c10.png',
  'jet': '$_giftPickerCdn/Private%20Jet%20.png',
  'globe': '$_giftPickerCdn/file_00000000b280820ab886eb4cf8be8fa3.png',
  'stadium': '$_giftPickerCdn/file_0000000095f081f490d301c0473200d4.png',
  'ressort': '$_giftPickerCdn/ressort.png',
};

const Set<String> _builtInGiftIds = {
  'rose',
  'clap',
  'heart',
  'coffee',
  'star',
  'fire',
  'rocket',
  'crown',
  'trophy',
  'diamond',
  'money_bag',
  'sports_car',
  'yacht',
  'mansion',
  'jet',
  'globe',
  'stadium',
  'ressort',
};

/// Resolve a notification image only at display time. This prevents media URLs
/// from being stored in the gift ledger or sent with every payment request.
String? giftNotificationImageUrlFor(String giftId) {
  if (!_builtInGiftIds.contains(giftId)) return null;
  return '$_giftCdn/$giftId.jpeg';
}

String? giftPickerImageUrlFor(String giftId) => giftPickerImageUrls[giftId];

const List<Gift> gifts = [
  Gift(id: 'rose',       emoji: '🌹', name: 'Rose',        price: 1,     fee: 0,    imageUrl: '$_giftPickerCdn/file_00000000d79481f89b4523d67e1b4d29.png', notificationImageUrl: '$_giftCdn/rose.jpeg'),
  Gift(id: 'clap',       emoji: '👏', name: 'Clap',        price: 2,     fee: 0,    imageUrl: '$_giftPickerCdn/file_0000000089c481f4816d139e6f26262a.png', notificationImageUrl: '$_giftCdn/clap.jpeg'),
  Gift(id: 'heart',      emoji: '❤️', name: 'Heart',       price: 3,     fee: 0),
  Gift(id: 'coffee',     emoji: '☕', name: 'Coffee',      price: 5,     fee: 1,    imageUrl: '$_giftPickerCdn/file_00000000857081f4a3c8768f37acdd83.png', notificationImageUrl: '$_giftCdn/coffee.jpeg'),
  Gift(id: 'star',       emoji: '⭐', name: 'Star',        price: 5,     fee: 1,    imageUrl: '$_giftPickerCdn/file_0000000099ac81f481b11ce02752b0c2.png', notificationImageUrl: '$_giftCdn/star.jpeg'),
  Gift(id: 'fire',       emoji: '🔥', name: 'Fire',        price: 10,    fee: 1,    imageUrl: '$_giftPickerCdn/file_00000000a43881f4a34869b1e449e685.png', notificationImageUrl: '$_giftCdn/fire.jpeg'),
  Gift(id: 'rocket',     emoji: '🚀', name: 'Rocket',      price: 20,    fee: 2,    imageUrl: '$_giftPickerCdn/file_000000006a0c81fd84117047c3de8479.png', notificationImageUrl: '$_giftCdn/rocket.jpeg'),
  Gift(id: 'crown',      emoji: '👑', name: 'Crown',       price: 25,    fee: 3),
  Gift(id: 'trophy',     emoji: '🏆', name: 'Trophy',      price: 50,    fee: 6,    imageUrl: '$_giftPickerCdn/file_00000000ec7881f4b94ee4cb666786ce.png', notificationImageUrl: '$_giftCdn/trophy.jpeg'),
  Gift(id: 'diamond',    emoji: '💎', name: 'Diamond',     price: 50,    fee: 6,    imageUrl: '$_giftPickerCdn/file_00000000d3d881f4a1f3522af02db335.png', notificationImageUrl: '$_giftCdn/diamond.jpeg'),
  Gift(id: 'money_bag',  emoji: '💰', name: 'Money Bag',   price: 100,   fee: 11,   imageUrl: '$_giftPickerCdn/file_00000000c24481f483798d796fa9e5ab.png', notificationImageUrl: '$_giftCdn/money_bag.jpeg'),
  Gift(id: 'sports_car', emoji: '🏎️', name: 'Sports Car',  price: 200,   fee: 22,   imageUrl: '$_giftPickerCdn/file_00000000d0f081f4b0f47169f3e987f9.png', notificationImageUrl: '$_giftCdn/sports_car.jpeg'),
  Gift(id: 'yacht',      emoji: '🛥️', name: 'Yacht',       price: 500,   fee: 55,   imageUrl: '$_giftPickerCdn/file_00000000898c81f4bafd3c88dd3fdfcd.png', notificationImageUrl: '$_giftCdn/yacht.jpeg'),
  Gift(id: 'mansion',    emoji: '🏰', name: 'Mansion',     price: 1000,  fee: 110,  imageUrl: '$_giftPickerCdn/file_00000000218481f488f653dcf7520c10.png', notificationImageUrl: '$_giftCdn/mansion.jpeg'),
  Gift(id: 'jet',        emoji: '✈️', name: 'Private Jet', price: 1500,  fee: 165,  imageUrl: '$_giftPickerCdn/Private%20Jet%20.png', notificationImageUrl: '$_giftCdn/jet.jpeg'),
  Gift(id: 'globe',      emoji: '🌍', name: 'Globe',       price: 5000,  fee: 550,  imageUrl: '$_giftPickerCdn/file_00000000b280820ab886eb4cf8be8fa3.png', notificationImageUrl: '$_giftCdn/globe.jpeg'),
  Gift(id: 'stadium',    emoji: '🏟️', name: 'Stadium',     price: 10000, fee: 1100, imageUrl: '$_giftPickerCdn/file_0000000095f081f490d301c0473200d4.png', notificationImageUrl: '$_giftCdn/stadium.jpeg'),
  Gift(id: 'ressort',    emoji: '🎢', name: 'Ressort',     price: 50000, fee: 5500, imageUrl: '$_giftPickerCdn/ressort.png', notificationImageUrl: '$_giftCdn/ressort.jpeg'),
];

const List<Post> posts = [
  Post(id: 'p1', creatorId: 'c1', creator: 'Sheeba UG', avatar: '🎤', verified: true, type: 'music', title: 'Afrobeats Fusion – New Drop 🔥', views: '2.4M', likes: 184000, comments: 3200, gifts: 1240, duration: '3:42', grad: 'music', tags: ['#Afrobeats', '#Uganda', '#NewMusic'], timeAgo: '2h ago', earned: 3240000),
  Post(id: 'p2', creatorId: 'c2', creator: 'Kampala Art', avatar: '🎨', verified: false, type: 'art', title: 'Abstract East Africa – Limited Edition', views: '890K', likes: 62000, comments: 1100, gifts: 480, duration: '1:20', grad: 'art', tags: ['#Art', '#EastAfrica', '#NFT'], timeAgo: '5h ago', earned: 820000),
  Post(id: 'p3', creatorId: 'c3', creator: 'DJ Nexus 256', avatar: '🎧', verified: true, type: 'live', title: '🔴 LIVE: Friday Vibe Session', views: '14K', likes: 9200, comments: 740, gifts: 320, duration: 'LIVE', grad: 'live', tags: ['#Live', '#DJ', '#Kampala'], timeAgo: 'Now', earned: 1450000),
];

const List<Creator> creators = [
  Creator(id: 'c1', name: 'Sheeba UG', username: '@sheeba_ug', avatar: '🎤', followers: '2.4M', verified: true, category: 'Music', bio: 'Afrobeats queen. Top creator Uganda 2024.', totalEarned: 48000000),
  Creator(id: 'c2', name: 'Kampala Art', username: '@kampala_art', avatar: '🎨', followers: '890K', verified: false, category: 'Art', bio: 'Visual artist & digital creator.', totalEarned: 12000000),
  Creator(id: 'c3', name: 'DJ Nexus 256', username: '@djnexus256', avatar: '🎧', followers: '1.1M', verified: true, category: 'Music', bio: 'East Africa\'s top DJ. Kampala nights.', totalEarned: 31000000),
];

// ── Helpers ───────────────────────────────────────────────────
String ugx(num n) {
  // 1. Convert to integer to strip decimals
  final int val = n.toInt();
  final String s = val.toString();
  final buf = StringBuffer();
  
  for (int i = 0; i < s.length; i++) {
    int revPos = s.length - i;
    if (i > 0 && revPos % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return 'UGX $buf';
}

String kNum(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}K';
  return n.toString();
}
