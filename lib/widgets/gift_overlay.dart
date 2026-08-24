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
    final coinBalance = state.wallet;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E1A),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(
            color: Colors.white.withOpacity(0.06),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
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
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // ── Header ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              children: [
                const Text('🎁', style: TextStyle(fontSize: 22)),
                const SizedBox(width: 8),
                Text('Send a Gift', style: syne(sz: 20, w: FontWeight.w700)),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(
                      child: Text('✕',
                          style: TextStyle(
                              color: C.text.withOpacity(0.6), fontSize: 16)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text('Creator gets 60% · Platform fee 40%',
                style: dm(sz: 11, c: C.dim)),
          ),

          // ── Wallet Balance ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF1A1F2E),
                    const Color(0xFF141825),
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withOpacity(0.04)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFFFD700), Color(0xFFF5A623)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Center(
                      child: Text('N',
                          style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.w900,
                              fontSize: 14)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('NCX Balance', style: dm(sz: 12, c: C.sub)),
                  const Spacer(),
                  Text('${coinBalance.toInt()} NCX',
                      style: syne(sz: 16, c: const Color(0xFFFFD700))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // ── Gifts Grid ──
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const BouncingScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  childAspectRatio: 0.72,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                ),
                itemCount: gifts.length,
                itemBuilder: (context, index) {
                  final g = gifts[index];
                  final canAfford = coinBalance >= g.price;
                  return GestureDetector(
                    onTap: canAfford
                        ? () => onSend(g.emoji, g.name, g.price, g.fee)
                        : null,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: canAfford ? 1.0 : 0.3,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF131826),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: canAfford
                                ? Colors.white.withOpacity(0.06)
                                : Colors.transparent,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Gift image or emoji fallback
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: g.imageUrl != null
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: CachedNetworkImage(
                                        imageUrl: g.imageUrl!,
                                        fit: BoxFit.cover,
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
                                          style:
                                              const TextStyle(fontSize: 32)),
                                    ),
                            ),
                            const SizedBox(height: 4),
                            Text(g.name,
                                style: dm(sz: 9, w: FontWeight.w700),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 2),
                            // NCX price badge
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFD700).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text('${g.price} NCX',
                                  style: dm(
                                      sz: 8,
                                      w: FontWeight.w800,
                                      c: const Color(0xFFFFD700))),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 10),

          // ── Top Up Button ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
            child: GestureDetector(
              onTap: () {
                Navigator.pop(context);
                state.go('profile');
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  gradient: brandGrad,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: C.brand.withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('➕ ', style: TextStyle(fontSize: 16)),
                    Text('Top Up Wallet',
                        style: dm(sz: 14, w: FontWeight.w800, c: C.bg)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
