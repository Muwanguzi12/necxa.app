import 'package:flutter/material.dart';
import '../theme.dart';
import '../data.dart';
import '../app_state.dart';
import '../widgets/ai_chat_modal.dart';
import '../models/property_container.dart';

class HomeScreen extends StatelessWidget {
  final AppState state;
  const HomeScreen({super.key, required this.state});

  static final _filters = [
    ('all', 'All'), ('rent', 'For Rent'), ('shortStay', 'Short Stay'),
    ('lease', 'Lease'), ('sale', 'For Sale'), ('villa', 'Villas'),
    ('commercial', 'Office'),
  ];

  @override
  Widget build(BuildContext context) {
    final filtered = state.filtered;
    return Column(
      children: [
        _buildNav(context),
        _buildAppTabs(),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHero(),
                _buildStats(filtered.length),
                _buildFilterRow(),
                _buildListings(filtered),
              ],
            ),
          ),
        ),
        _buildBottomNav(),
      ],
    );
  }

  // ── Nav ──
  Widget _buildNav(BuildContext context) {
    return Container(
      color: C.card,
      padding: const EdgeInsets.fromLTRB(18, 52, 18, 12),
      child: Row(
        children: [
          const NecxaLogo(size: 44, shadow: false),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('NECXA', style: syne(sz: 20, ls: -.5)),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: C.green.withOpacity(.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: C.green.withOpacity(.25)),
                  ),
                  child: Text('🇺🇬 UGX', style: dm(sz: 9, w: FontWeight.w700, c: C.green)),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _showAiChat(context, state),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2631),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.withOpacity(.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                   Image.asset('assets/images/necxa ai.jpeg', width: 14, height: 14),
                   const SizedBox(width: 6),
                   Text('Necxa AI', style: syne(sz: 11, c: Colors.blue)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => state.go('profile'),
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) {
                final url = state.myProfile?['photo_url'];
                return Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: C.brand, width: 1.5),
                    image: url != null ? DecorationImage(image: NetworkImage(url), fit: BoxFit.cover) : null,
                  ),
                  child: url == null ? Icon(Icons.person, color: C.brand, size: 20) : null,
                );
              }
            ),
          ),
        ],
      ),
    );
  }

  void _showAiChat(BuildContext context, AppState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => AiChatModal(state: state),
    );
  }

  // ── App Tabs ──
  Widget _buildAppTabs() {
    return _AppTabs(current: 'home', state: state, onTap: (t) {
      if (t == 'transport') state.go('transport');
      if (t == 'upload') state.go('upload');
      if (t == 'profile') state.go('profile');
    });
  }

  // ── Hero ──
  Widget _buildHero() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xFF0c1628), C.bg],
        ),
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: C.brand.withOpacity(.07),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: C.brand.withOpacity(.17)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PulsingDot(),
                const SizedBox(width: 6),
                Text("Uganda's Only Biometric-Verified Platform",
                    style: dm(sz: 10, w: FontWeight.w700, c: C.brand)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          RichText(
            text: TextSpan(
              style: syne(sz: 27, h: 1.15),
              children: const [
                TextSpan(text: 'Find Your Perfect\n'),
                TextSpan(text: 'Property in Uganda',
                    style: TextStyle(color: C.brand)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text('Every listing verified with National ID + Face ID + GPS',
              style: dm(sz: 12, c: C.dim, h: 1.6)),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: C.cardDk,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: state.zoneMetadata != null 
                  ? Color(int.parse(state.zoneMetadata!['color_hex'].replaceFirst('#', '0xFF')))
                  : C.border,
                width: state.zoneMetadata != null ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Text(state.isSearching ? '⏳' : '🔍', style: dm(sz: 16)),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    onChanged: (v) => state.performSearch(v),
                    style: dm(sz: 13),
                    decoration: InputDecoration(
                      hintText: 'Search Kampala, Entebbe, Jinja...',
                      hintStyle: dm(sz: 13, c: C.dim),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (state.searchQuery.isNotEmpty && !state.isSearching)
                  GestureDetector(
                    onTap: () => state.performSearch(''),
                    child: Icon(Icons.close, size: 14, color: C.dim),
                  ),
              ],
            ),
          ),
          if (state.zoneMetadata != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Color(int.parse(state.zoneMetadata!['color_hex'].replaceFirst('#', '0xFF'))).withOpacity(.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Color(int.parse(state.zoneMetadata!['color_hex'].replaceFirst('#', '0xFF'))).withOpacity(.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                   Icon(Icons.map_outlined, size: 12, color: Color(int.parse(state.zoneMetadata!['color_hex'].replaceFirst('#', '0xFF')))),
                   const SizedBox(width: 6),
                   Text(state.zoneMetadata!['zone_label'].toString().toUpperCase(), 
                     style: dm(sz: 9, w: FontWeight.w800, 
                       c: Color(int.parse(state.zoneMetadata!['color_hex'].replaceFirst('#', '0xFF'))))),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Stats row ──
  Widget _buildStats(int count) {
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: Row(
        children: [
          _StatCell(icon: '🏠', val: '$count+', lab: 'Listings'),
          Container(width: 1, height: 60, color: C.border),
          const _StatCell(icon: '✅', val: '100%', lab: 'AI Verified'),
          Container(width: 1, height: 60, color: C.border),
          const _StatCell(icon: '🔐', val: '5%', lab: 'Broker Fee'),
        ],
      ),
    );
  }

  // ── Filters ──
  Widget _buildFilterRow() {
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: _filters.map((f) {
            final active = state.filter == f.$1;
            return GestureDetector(
              onTap: () => state.setFilter(f.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: active ? C.brand.withOpacity(.09) : C.card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: active ? C.brand : C.border,
                  ),
                ),
                child: Text(f.$2,
                    style: dm(sz: 11, w: FontWeight.w600,
                        c: active ? C.brand : C.dim)),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ── Listings ──
  Widget _buildListings(List<PropertyContainer> filtered) {
    if (state.isLoadingProperties) {
      return const Padding(
        padding: EdgeInsets.all(40.0),
        child: Center(child: CircularProgressIndicator(color: C.green)),
      );
    }
    if (filtered.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32.0),
        child: Center(
          child: Text('No properties found.', style: dm(sz: 14, c: C.dim)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${filtered.length} Properties Found',
              style: syne(sz: 16)),
          const SizedBox(height: 14),
          ...filtered.map((p) => _PropertyCard(p: p, state: state)),
        ],
      ),
    );
  }

  // ── Bottom Nav ──
  Widget _buildBottomNav() {
    return _BottomNav(
      current: 'home',
      savedCount: state.saved.length,
      onTap: (t) {
        if (t == 'community') state.go('community');
        if (t == 'chat') state.go('chat');
        if (t == 'home') state.go('home');
        if (t == 'list') state.go('list');
      },
    );
  }
}

// ── Property Card ─────────────────────────────────────────────
class _PropertyCard extends StatelessWidget {
  final PropertyContainer p;
  final AppState state;
  const _PropertyCard({required this.p, required this.state});

  @override
  Widget build(BuildContext context) {
    final saved = state.saved.contains(p.core.id);
    final isReserved = p.escrow.status == EscrowStatus.pending_escrow;
    
    return GestureDetector(
      onTap: () => state.openDetail(p.core.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isReserved ? C.red.withOpacity(.3) : C.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              child: Container(
                height: 145,
                decoration: BoxDecoration(
                  color: C.cardDk,
                  image: p.core.images.isNotEmpty 
                    ? DecorationImage(image: NetworkImage(p.core.images.first), fit: BoxFit.cover)
                    : null,
                ),
                child: Stack(
                  children: [
                    if (p.core.images.isEmpty)
                      Center(child: Text(p.core.propertyType == PropertyType.apartment ? '🏢' : '🏡', style: const TextStyle(fontSize: 50))),
                    
                    Positioned(
                      top: 10, left: 10,
                      child: _TrustBadge(status: p.financial.trustStatus),
                    ),
                    Positioned(
                      top: 10, right: 10,
                      child: _PurposeBadge(p.core.listingType.name.toUpperCase(), C.brand),
                    ),
                    if (p.shadow.isUnlockedByCurrentUser)
                      const Positioned(
                        bottom: 10, right: 10,
                        child: _Badge('🔓 Unlocked', C.green, Colors.white),
                      ),
                    if (isReserved)
                       Positioned.fill(
                         child: Container(
                           color: Colors.black45,
                           child: Center(
                             child: Container(
                               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                               decoration: BoxDecoration(color: C.red, borderRadius: BorderRadius.circular(8)),
                               child: Text('RESERVED', style: syne(sz: 10, c: Colors.white, w: FontWeight.w800)),
                             ),
                           ),
                         ),
                       ),
                  ],
                ),
              ),
            ),
            // Body
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(p.core.title, style: syne(sz: 15)),
                      ),
                      GestureDetector(
                        onTap: () => state.toggleSave(p.core.id),
                        child: Text(saved ? '❤️' : '🤍',
                            style: const TextStyle(fontSize: 18)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('📍 ${p.core.district}, ${p.core.city}', style: dm(sz: 11, c: C.dim)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text('🛏 ${p.core.bedrooms} Bed', style: dm(sz: 11, c: C.sub)),
                      const SizedBox(width: 12),
                      Text('🚿 ${p.core.bathrooms} Bath', style: dm(sz: 11, c: C.sub)),
                      const SizedBox(width: 12),
                      Text('📐 ${p.core.sizeSqft}m²', style: dm(sz: 11, c: C.sub)),
                      const SizedBox(width: 12),
                      Text('⭐ 4.8',
                          style: dm(sz: 11, c: C.brand, w: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(ugx(p.financial.price),
                              style: syne(sz: 18, c: C.brand)),
                          Row(
                            children: [
                              Text(p.financial.priceType == PriceType.monthly ? '/mo' : '/night', style: dm(sz: 10, c: C.dim)),
                              const SizedBox(width: 8),
                              if (!p.shadow.isUnlockedByCurrentUser)
                                Text('•  Unlock: ${ugx(p.financial.unlockCost)}', 
                                  style: dm(sz: 10, c: C.gold, w: FontWeight.w700)),
                            ],
                          ),
                        ],
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: isReserved ? C.red.withOpacity(.1) : C.brand.withOpacity(.09),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: isReserved ? C.red : C.brand.withOpacity(.22)),
                        ),
                        child: Text(isReserved ? 'Reserved' : 'View →',
                            style: dm(sz: 11, w: FontWeight.w700,
                                c: isReserved ? C.red : C.brand)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shared Widgets ────────────────────────────────────────────
class _TrustBadge extends StatelessWidget {
  final TrustStatus status;
  const _TrustBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg;
    String label;
    switch (status) {
      case TrustStatus.titan_trust:
        bg = const Color(0xFFB8860B); label = '💎 TITAN TRUST'; break;
      case TrustStatus.verified:
        bg = C.green; label = '✓ VERIFIED'; break;
      case TrustStatus.limited:
        bg = Colors.orange; label = '⚠️ LIMITED'; break;
      default:
        bg = Colors.blueGrey; label = 'STANDARD';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg, borderRadius: BorderRadius.circular(20),
        boxShadow: [
          if (status == TrustStatus.titan_trust)
            BoxShadow(color: bg.withOpacity(.4), blurRadius: 8, spreadRadius: 1),
        ],
      ),
      child: Text(label, style: const TextStyle(
        fontSize: 9, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 0.5)),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color bg, textColor;
  const _Badge(this.text, this.bg, this.textColor);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg, borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: TextStyle(
        fontSize: 9, fontWeight: FontWeight.w700, color: textColor)),
    );
  }
}

class _PurposeBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _PurposeBadge(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: C.bg.withOpacity(.82),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(.27)),
      ),
      child: Text(label, style: TextStyle(
          fontSize: 9, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String icon, val, lab;
  const _StatCell({required this.icon, required this.val, required this.lab});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        color: C.card,
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            Text(icon, style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 2),
            Text(val, style: syne(sz: 17, c: C.brand)),
            Text(lab, style: dm(sz: 10, c: C.dim)),
          ],
        ),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}
class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);
  late final Animation<double> _anim =
      Tween(begin: 1.0, end: 0.4).animate(_ctrl);

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: const Text('●', style: TextStyle(color: C.brand, fontSize: 10)),
    );
  }
}

// ── App Tabs (shared) ─────────────────────────────────────────
class _AppTabs extends StatelessWidget {
  final String current;
  final void Function(String) onTap;
  final AppState state;
  const _AppTabs({required this.current, required this.onTap, required this.state});

  static final _tabs = [
    ('home', '🏠', 'Property'),
    ('transport', '🚚', 'Transport'),
    ('upload', '➕', 'Upload'),
    ('profile', '👤', 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: Row(
        children: _tabs.map((t) {
          final active = t.$1 == current;
          final isProfile = t.$1 == 'profile';
          
          return Expanded(
            child: GestureDetector(
              onTap: () => onTap(t.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active ? C.brand : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isProfile) 
                      ListenableBuilder(
                        listenable: state,
                        builder: (context, _) {
                          final url = state.myProfile?['photo_url'];
                          return Container(
                            width: 14, height: 14,
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: C.dim.withOpacity(.2),
                              image: url != null ? DecorationImage(image: NetworkImage(url), fit: BoxFit.cover) : null,
                            ),
                            child: url == null ? Icon(Icons.person, size: 8, color: C.dim) : null,
                          );
                        }
                      )
                    else 
                      Text(t.$2, style: const TextStyle(fontSize: 10)),
                    
                    if (!isProfile) const SizedBox(width: 4),
                    
                    Text(t.$3,
                        textAlign: TextAlign.center,
                        style: dm(
                          sz: 10,
                          w: active ? FontWeight.w800 : FontWeight.w600,
                          c: active ? C.brand : C.dim,
                        )),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Bottom Nav (shared) ───────────────────────────────────────
class _BottomNav extends StatelessWidget {
  final String current;
  final int savedCount;
  final void Function(String) onTap;
  const _BottomNav(
      {required this.current, required this.savedCount, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        border: Border(top: BorderSide(color: C.border)),
      ),
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _BotBtn('🏠', 'Property', current == 'home', () => onTap('home')),
          _BotBtn('⚡', 'Community', current == 'community', () => onTap('community')),
          _BotBtn('📋', 'Listings', current == 'list', () => onTap('list')),
          _BotBtn('💬', 'Chat', current == 'chat', () => onTap('chat')),
        ],
      ),
    );
  }
}

class _BotBtn extends StatelessWidget {
  final String icon, label;
  final bool active;
  final VoidCallback onTap;
  const _BotBtn(this.icon, this.label, this.active, this.onTap);
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 22)),
          const SizedBox(height: 3),
          Text(label,
              style: dm(sz: 9, w: FontWeight.w600,
                  c: active ? C.brand : C.dim)),
        ],
      ),
    );
  }
}
