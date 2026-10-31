class Wallet {
  final String id;
  final String userId;
  final double fiatBalance;
  final double escrowBalance;
  final double coinBalance;
  final double stakedBalance;
  final double totalEarned;
  final double totalSpent;
  final double totalCommissionEarned;
  final int dailyWithdrawalLimit;
  final int monthlyWithdrawalLimit;
  final bool isFrozen;
  final String? freezeReason;
  final DateTime? frozenAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  Wallet({
    required this.id,
    required this.userId,
    required this.fiatBalance,
    required this.escrowBalance,
    required this.coinBalance,
    required this.stakedBalance,
    required this.totalEarned,
    required this.totalSpent,
    required this.totalCommissionEarned,
    required this.dailyWithdrawalLimit,
    required this.monthlyWithdrawalLimit,
    required this.isFrozen,
    this.freezeReason,
    this.frozenAt,
    required this.createdAt,
    required this.updatedAt,
  });

  static DateTime _parseDate(dynamic value) {
    if (value == null) return DateTime.now();
    if (value is String) return DateTime.parse(value);
    if (value.runtimeType.toString() == 'Timestamp') return value.toDate(); // Handles Cloud Firestore Timestamp
    return DateTime.now();
  }

  static double _parseAmount(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  static int _parseLimit(dynamic value, int fallback) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  factory Wallet.fromJson(Map<String, dynamic> json, {String? docId}) {
    return Wallet(
      id: docId ?? json['id'] ?? json['user_id'] ?? 'unknown',
      userId: json['user_id'] ?? 'unknown',
      fiatBalance: _parseAmount(json['fiat_balance']),
      escrowBalance: _parseAmount(json['escrow_balance']),
      coinBalance: _parseAmount(json['coin_balance']),
      stakedBalance: _parseAmount(json['staked_balance']),
      totalEarned: _parseAmount(json['total_earned']),
      totalSpent: _parseAmount(json['total_spent']),
      totalCommissionEarned: _parseAmount(json['total_commission_earned']),
      dailyWithdrawalLimit: _parseLimit(
        json['daily_withdrawal_limit'],
        5000000,
      ),
      monthlyWithdrawalLimit: _parseLimit(
        json['monthly_withdrawal_limit'],
        50000000,
      ),
      isFrozen: json['is_frozen'] ?? false,
      freezeReason: json['freeze_reason'],
      frozenAt: json['frozen_at'] != null ? _parseDate(json['frozen_at']) : null,
      createdAt: _parseDate(json['created_at']),
      updatedAt: _parseDate(json['updated_at'] ?? json['last_topup_at'] ?? json['last_sync_from_supabase']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'fiat_balance': fiatBalance,
      'escrow_balance': escrowBalance,
      'coin_balance': coinBalance,
      'staked_balance': stakedBalance,
      'is_frozen': isFrozen,
    };
  }
}
