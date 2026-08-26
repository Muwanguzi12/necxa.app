import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme.dart';
import '../data.dart';
import '../app_state.dart';

class GiftOverlay extends StatelessWidget {
  final AppState state;
  final void Function(String emoji, String name, int price, int fee) onSend;

  GiftOverlay({super.key, required this.state, required this.onSend});

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
        color: Color(0xFF0B111D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(
            color: C.text.withOpacity(0.1),
            width: 1.0,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: 30,
            offset: Offset(0, -10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // -- Handle Bar --
          Padding(
            padding: EdgeInsets.only(top: 10, bottom: 4),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: C.text.withOpacity(0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // -- Header Row --
          Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Row(
              children: [
                // Balance Pill (Left)
                GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    state.go('profile');
                  },
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Color(0xFF131D2D),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Color(0xFF38BDF8).withOpacity(0.25),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: Color(0xFF0284C7),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              'T',
                              style: TextStyle(
                                color: C.text,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'NCX ',
                          style: dm(sz: 11, w: FontWeight.bold, c: C.sub),
                        ),
                        Text(
                          '${coinBalance.toInt()}',
                          style: syne(sz: 13, w: FontWeight.bold, c: Color(0xFF38BDF8)),
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
                      c: C.text,
                    ),
                  ),
                ),

                // Close Button (Right)
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Color(0xFF172132),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: C.sub,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // -- Gifts Grid (Scrollable) --
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: RawScrollbar(
                thumbColor: Color(0xFF38BDF8).withOpacity(0.4),
                radius: Radius.circular(4),
                thickness: 4,
                thumbVisibility: true,
                child: GridView.builder(
                  padding: EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                  physics: BouncingScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    childAspectRatio: 0.76,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: gifts.length,
                  itemBuilder: (context, index) {
                    final g = gifts[index];
                    final canAfford = coinBalance >= g.price;
                    return Semantics(
                      button: true,
                      label: canAfford
                          ? 'Send ${g.name} for ${g.price} NCX'
                          : 'Add NCX to send ${g.name}',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: canAfford
                              ? () => onSend(g.emoji, g.name, g.price, g.fee)
                              : () {
                                  Navigator.pop(context);
                                  state.go('profile');
                                },
                          borderRadius: BorderRadius.circular(12),
                          child: AnimatedOpacity(
                        duration: Duration(milliseconds: 180),
                        opacity: canAfford ? 1.0 : 0.45,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Gift Image or Emoji fallback (Un-encased, floating)
                            SizedBox(
                              width: 44,
                              height: 44,
                            child: g.imageUrl != null &&
                                    g.imageUrl!.startsWith('assets/')
                                ? Image.asset(g.imageUrl!, fit: BoxFit.contain)
                                : g.imageUrl != null
                                ? ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: CachedNetworkImage(
                                        imageUrl: g.imageUrl!,
                                        fit: BoxFit.contain,
                                        placeholder: (_, __) => Center(
                                          child: Text(g.emoji,
                                              style: TextStyle(
                                                  fontSize: 32)),
                                        ),
                                        errorWidget: (_, __, ___) => Center(
                                          child: Text(g.emoji,
                                              style: TextStyle(
                                                  fontSize: 32)),
                                        ),
                                      ),
                                    )
                                  : Center(
                                      child: Text(g.emoji,
                                          style: TextStyle(fontSize: 32)),
                                    ),
                            ),
                            SizedBox(height: 6),
                            // Gift Name Label
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 2),
                              child: Text(
                                g.name,
                                style: dm(sz: 11, w: FontWeight.w600, c: C.text),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            SizedBox(height: 4),
                            // Price Badge
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Color(0xFF0B243B),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Color(0xFF38BDF8).withOpacity(0.25),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: Color(0xFF0284C7),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Center(
                                      child: Text(
                                        'T',
                                        style: TextStyle(
                                          color: C.text,
                                          fontSize: 7,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    '${g.price}',
                                    style: dm(
                                      sz: 10,
                                      w: FontWeight.w800,
                                      c: Color(0xFF38BDF8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          // -- Footer Banner --
          Padding(
            padding: EdgeInsets.fromLTRB(14, 8, 14, 14),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Color(0xFF0F1A2E),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: C.text.withOpacity(0.08),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Color(0xFF38BDF8).withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.shield_outlined,
                      color: Color(0xFF38BDF8),
                      size: 15,
                    ),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Send gifts to support and celebrate your favorite creators!',
                      style: dm(sz: 11, c: C.sub, h: 1.2),
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
