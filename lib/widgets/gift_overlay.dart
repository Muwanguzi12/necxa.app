import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme.dart';
import '../data.dart';
import '../app_state.dart';

class GiftOverlay extends StatelessWidget {
  final AppState state;
  final void Function(String emoji, String name, int price, int fee) onSend;

  const GiftOverlay({super.key, required this.state, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final coinBalance = state.coinBalance;
    final maxHeight = MediaQuery.of(context).size.height * 0.70;

    return Container(
      constraints: BoxConstraints(
        maxHeight: maxHeight,
      ),
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0B111D),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(
            color: Colors.white.withOpacity(0.1),
            width: 1.0,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Handle Bar ──
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // ── Header Row ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Row(
              children: [
                // Balance Pill (Left)
                GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    state.go('profile');
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131D2D),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF38BDF8).withOpacity(0.25),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 18,
                          height: 18,
                          decoration: const BoxDecoration(
                            color: Color(0xFF0284C7),
                            shape: BoxShape.circle,
                          ),
                          child: const Center(
                            child: Text(
                              'T',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'NCX ',
                          style: dm(sz: 11, w: FontWeight.bold, c: Colors.white70),
                        ),
                        Text(
                          '${coinBalance.toInt()}',
                          style: syne(sz: 13, w: FontWeight.bold, c: const Color(0xFF38BDF8)),
                        ),
                      ],
                    ),
                  ),
                ),

                // Title (Center)
                Expanded(
                  child: Text(
                    'GIFT COINS',
                    textAlign: TextAlign.center,
                    style: syne(
                      sz: 16,
                      w: FontWeight.w900,
                      ls: 1.2,
                      c: Colors.white,
                    ),
                  ),
                ),

                // Close Button (Right)
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: Color(0xFF172132),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Gifts Grid (Scrollable) ──
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: RawScrollbar(
                thumbColor: const Color(0xFF38BDF8).withOpacity(0.4),
                radius: const Radius.circular(4),
                thickness: 4,
                thumbVisibility: true,
                child: GridView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                  physics: const BouncingScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    childAspectRatio: 0.76,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: gifts.length,
                  itemBuilder: (context, index) {
                    final g = gifts[index];
                    final canAfford = coinBalance >= g.price;
                    return GestureDetector(
                      onTap: canAfford
                          ? () => onSend(g.emoji, g.name, g.price, g.fee)
                          : () {
                              Navigator.pop(context);
                              state.go('profile');
                            },
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: canAfford ? 1.0 : 0.45,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Gift Image or Emoji fallback (Un-encased, floating)
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: g.imageUrl != null
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: CachedNetworkImage(
                                        imageUrl: g.imageUrl!,
                                        fit: BoxFit.contain,
                                        placeholder: (_, __) => Center(
                                          child: Text(g.emoji,
                                              style: const TextStyle(
                                                  fontSize: 32)),
                                        ),
                                        errorWidget: (_, __, ___) => Center(
                                          child: Text(g.emoji,
                                              style: const TextStyle(
                                                  fontSize: 32)),
                                        ),
                                      ),
                                    )
                                  : Center(
                                      child: Text(g.emoji,
                                          style: const TextStyle(fontSize: 32)),
                                    ),
                            ),
                            const SizedBox(height: 6),
                            // Gift Name Label
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: Text(
                                g.name,
                                style: dm(sz: 11, w: FontWeight.w600, c: Colors.white),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 4),
                            // Price Badge
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0B243B),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFF38BDF8).withOpacity(0.25),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF0284C7),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Center(
                                      child: Text(
                                        'T',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 7,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${g.price}',
                                    style: dm(
                                      sz: 10,
                                      w: FontWeight.w800,
                                      c: const Color(0xFF38BDF8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          // ── Footer Banner ──
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF0F1A2E),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withOpacity(0.08),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF38BDF8).withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.shield_outlined,
                      color: Color(0xFF38BDF8),
                      size: 15,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Send gifts to support and celebrate your favorite creators!',
                      style: dm(sz: 11, c: Colors.white70, h: 1.2),
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
