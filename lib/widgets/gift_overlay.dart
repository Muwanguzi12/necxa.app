import 'package:flutter/material.dart';
import '../theme.dart';
import '../data.dart';
import '../app_state.dart';

class GiftOverlay extends StatefulWidget {
  final AppState state;
  final void Function(String emoji, String name, int price, int fee) onSend;

  const GiftOverlay({super.key, required this.state, required this.onSend});

  @override
  State<GiftOverlay> createState() => _GiftOverlayState();
}

class _GiftOverlayState extends State<GiftOverlay> {
  String selectedTab = 'All';
  String? selectedGiftId;

  final List<Map<String, dynamic>> categories = [
    {'name': 'All', 'icon': null},
    {'name': 'Popular', 'icon': Icons.whatshot_rounded},
    {'name': 'Premium', 'icon': Icons.workspace_premium_rounded},
    {'name': 'Luxury', 'icon': Icons.auto_awesome_rounded},
    {'name': 'Big Gifts', 'icon': Icons.directions_car_rounded},
  ];

  List<Gift> get filteredGifts {
    if (selectedTab == 'All') return gifts;
    if (selectedTab == 'Popular') {
      return gifts.where((g) => ['rose', 'fire', 'rocket', 'heart', 'clap'].contains(g.id)).toList();
    }
    if (selectedTab == 'Premium') {
      return gifts.where((g) => ['crown', 'diamond', 'trophy', 'moneybag', 'star'].contains(g.id)).toList();
    }
    if (selectedTab == 'Luxury') {
      return gifts.where((g) => ['sportscar', 'yacht', 'villa'].contains(g.id)).toList();
    }
    if (selectedTab == 'Big Gifts') {
      return gifts.where((g) => ['jet', 'dragon'].contains(g.id)).toList();
    }
    return gifts;
  }

  @override
  Widget build(BuildContext context) {
    final coinBalance = widget.state.coinBalance;
    final maxHeight = MediaQuery.of(context).size.height * 0.80;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: const Color(0xFF030A14),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border(
          top: BorderSide(color: C.text.withOpacity(0.05), width: 1.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: C.text.withOpacity(0.1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                // Balance Pill
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131D2D),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: C.blue.withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: const BoxDecoration(
                          color: C.blue,
                          shape: BoxShape.circle,
                        ),
                        child: const Center(
                          child: Text('N', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${coinBalance.toInt()}',
                        style: syne(sz: 14, w: FontWeight.w800, c: C.blue),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          widget.state.go('profile');
                        },
                        child: const Icon(Icons.add_circle_rounded, color: C.blue, size: 18),
                      ),
                    ],
                  ),
                ),

                // Title
                Expanded(
                  child: Column(
                    children: [
                      const Icon(Icons.card_giftcard_rounded, color: C.blue, size: 20),
                      Text('Gift Coins', style: syne(sz: 16, w: FontWeight.w900)),
                      Text('Send gifts • Support creators', style: dm(sz: 10, c: C.sub)),
                    ],
                  ),
                ),

                // Close
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: C.text.withOpacity(0.05),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close_rounded, size: 20, color: C.text),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Tabs
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final cat = categories[index];
                final isSelected = selectedTab == cat['name'];
                return GestureDetector(
                  onTap: () => setState(() => selectedTab = cat['name']),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      gradient: isSelected
                          ? const LinearGradient(colors: [Color(0xFF00E5FF), Color(0xFF00B2CC)])
                          : null,
                      color: isSelected ? null : C.text.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: isSelected
                          ? [BoxShadow(color: C.blue.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))]
                          : null,
                    ),
                    child: Row(
                      children: [
                        if (cat['icon'] != null) ...[
                          Icon(cat['icon'], size: 14, color: isSelected ? Colors.black : C.sub),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          cat['name'],
                          style: dm(
                            sz: 13,
                            w: isSelected ? FontWeight.w800 : FontWeight.w500,
                            c: isSelected ? Colors.black : C.sub,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 16),

          // Grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 0.75,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemCount: filteredGifts.length,
              itemBuilder: (context, index) {
                final g = filteredGifts[index];
                final isSelected = selectedGiftId == g.id;
                final canAfford = coinBalance >= g.price;

                return GestureDetector(
                  onTap: () => setState(() => selectedGiftId = g.id),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected ? C.blue.withOpacity(0.1) : const Color(0xFF0A1324),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected ? C.blue : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Hero(
                              tag: 'gift_${g.id}',
                              child: g.imageUrl != null
                                  ? Image.asset(g.imageUrl!, fit: BoxFit.contain)
                                  : Text(g.emoji, style: const TextStyle(fontSize: 32)),
                            ),
                          ),
                        ),
                        Text(g.name, style: dm(sz: 11, w: FontWeight.w600), textAlign: TextAlign.center),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131D2D),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.stars_rounded, color: C.blue, size: 10),
                              const SizedBox(width: 4),
                              Text('${g.price}', style: syne(sz: 10, w: FontWeight.w900, c: C.blue)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // Footer Banner
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF6366F1), Color(0xFFA855F7), Color(0xFFEC4899)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.card_giftcard_rounded, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Make someone\'s day!', style: syne(sz: 14, w: FontWeight.w900, c: Colors.white)),
                        Text(
                          'Send gifts and celebrate your favorite creators on Necxa.',
                          style: dm(sz: 10, c: Colors.white.withOpacity(0.8), h: 1.2),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () {
                      if (selectedGiftId == null) return;
                      final g = gifts.firstWhere((element) => element.id == selectedGiftId);
                      if (coinBalance >= g.price) {
                        widget.onSend(g.emoji, g.name, g.price, g.fee);
                      } else {
                        Navigator.pop(context);
                        widget.state.go('profile');
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      elevation: 0,
                    ),
                    child: Row(
                      children: [
                        Text('Send Gift', style: syne(sz: 12, w: FontWeight.w900, c: Colors.black)),
                        const SizedBox(width: 4),
                        const Icon(Icons.send_rounded, size: 14),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
