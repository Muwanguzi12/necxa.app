import 'finance_backend.dart';
import 'finance_initializer.dart';

class GiftItem {
  const GiftItem({required this.id, required this.name, required this.emoji, required this.ncxValue,
    required this.ugxValue, required this.category, required this.sortOrder, this.isActive = true});
  final String id, name, emoji, category;
  final int ncxValue, ugxValue, sortOrder;
  final bool isActive;
  factory GiftItem.fromJson(Map<String, dynamic> json) => GiftItem(
    id: json['id']?.toString() ?? '', name: json['name']?.toString() ?? '',
    emoji: json['emoji']?.toString() ?? '\u{1F48E}', ncxValue: (json['ncx_value'] as num?)?.toInt() ?? 0,
    ugxValue: (json['ugx_value'] as num?)?.toInt() ?? 0, category: json['category']?.toString() ?? 'standard',
    sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0, isActive: json['is_active'] as bool? ?? true);
}

class GiftResult {
  const GiftResult({required this.success, required this.giftId, required this.giftEmoji,
    required this.giftName, required this.ncxAmount, required this.receiverNcx,
    required this.platformFeeNcx, required this.ugxEquivalent, required this.isHighlighted,
    required this.message});
  final bool success, isHighlighted;
  final String giftId, giftEmoji, giftName, message;
  final int ncxAmount, receiverNcx, platformFeeNcx, ugxEquivalent;
}

class FinanceGiftingService {
  Future<List<GiftItem>> fetchGiftItems() async {
    await FinanceInitializer.instance.ensureInitialized();
    final result = await FinanceBackend.instance.invoke('list_gift_items');
    return (result['giftItems'] as List? ?? const [])
        .map((item) => GiftItem.fromJson(Map<String, dynamic>.from(item as Map))).toList();
  }

  Future<GiftResult> sendGift({required String senderId, required String receiverId,
    required String giftItemId, required int ncxAmount, required String contextType,
    String? contextId, String? contextNote, bool isAnonymous = false, String? idempotencyKey}) async {
    try {
      await FinanceInitializer.instance.ensureInitialized();
      final result = await FinanceBackend.instance.invoke('send_gift', body: {
        'receiverId': receiverId, 'giftItemId': giftItemId, 'ncxAmount': ncxAmount,
        'contextType': contextType, 'contextId': contextId ?? 'direct:$receiverId',
        'contextNote': contextNote, 'isAnonymous': isAnonymous,
        'idempotencyKey': idempotencyKey ?? 'gift-${DateTime.now().microsecondsSinceEpoch}',
      });
      return GiftResult(success: true, giftId: result['giftId']?.toString() ?? '',
        giftEmoji: result['giftEmoji']?.toString() ?? '\u{1F48E}', giftName: result['giftName']?.toString() ?? '',
        ncxAmount: (result['ncxAmount'] as num?)?.toInt() ?? 0,
        receiverNcx: (result['receiverNcx'] as num?)?.toInt() ?? 0,
        platformFeeNcx: (result['platformFeeNcx'] as num?)?.toInt() ?? 0,
        ugxEquivalent: (result['ugxEquivalent'] as num?)?.toInt() ?? 0,
        isHighlighted: result['isHighlighted'] == true, message: result['message']?.toString() ?? 'Gift sent.');
    } catch (error) {
      return GiftResult(success: false, giftId: '', giftEmoji: '\u{1F48E}', giftName: '',
        ncxAmount: ncxAmount, receiverNcx: 0, platformFeeNcx: 0, ugxEquivalent: 0,
        isHighlighted: false, message: error.toString());
    }
  }
}
