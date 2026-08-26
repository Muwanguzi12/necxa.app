import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart';
import '../models/property_container.dart';
import 'dart:async';
import 'package:intl/intl.dart';
import '../models/booking_models.dart';
import 'package:cached_network_image/cached_network_image.dart';

// -------------------------------------------------------------
// PROPERTY DETAIL SCREEN � Production Release 2.0
// -------------------------------------------------------------
class DetailScreen extends StatefulWidget {
  final AppState state;
  const DetailScreen({super.key, required this.state});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  Timer? _timer;
  Duration _timeLeft = Duration.zero;
  final PageController _pageController = PageController();
  int _currentPath = 0;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _startTimer() {
    final p = widget.state.currentProperty;
    if (p != null && p.escrow.status == EscrowStatus.pending_escrow && p.escrow.expiresAt != null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        setState(() {
          _timeLeft = p.escrow.expiresAt!.difference(DateTime.now());
          if (_timeLeft.isNegative) {
            _timeLeft = Duration.zero;
            _timer?.cancel();
          }
        });
      });
    }
  }

  String _fmtDur(Duration d) {
    if (d.isNegative) return "00h 00m 00s";
    String two(int n) => n >= 10 ? "$n" : "0$n";
    return "${two(d.inHours)}h ${two(d.inMinutes.remainder(60))}m ${two(d.inSeconds.remainder(60))}s";
  }

  AppState get s => widget.state;

  @override
  Widget build(BuildContext context) {
    final p = s.currentProperty;
    if (p == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      backgroundColor: C.bg,
      body: Stack(
        children: [
          // Content
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              _buildSliverHero(p),
              SliverToBoxAdapter(child: _buildMainContent(p)),
              const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
            ],
          ),
          
          // Sticky Header
          Positioned(top: 0, left: 0, right: 0, child: _buildStickyNav(p)),
          
          // Bottom Interaction Bar
          Positioned(bottom: 0, left: 0, right: 0, child: _buildInteractionBar(p)),
        ],
      ),
    );
  }

  // -- HERO ------------------------------------------------------
  Widget _buildSliverHero(PropertyContainer p) {
    final images = p.core.images;
    return SliverAppBar(
      expandedHeight: 400,
      automaticallyImplyLeading: false,
      backgroundColor: C.bg,
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (images.isNotEmpty)
              PageView.builder(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _currentPath = i),
                itemCount: images.length,
                itemBuilder: (_, i) => CachedNetworkImage(
                  imageUrl: images[i],
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const Center(
                    child: CircularProgressIndicator(color: C.brand, strokeWidth: 2),
                  ),
                  errorWidget: (_, __, ___) => const Center(
                    child: Icon(Icons.error_outline, color: C.dim),
                  ),
                ),
              )
            else
              Container(color: C.card, child: Center(child: NecxaLogo(size: 108, shadow: true))),
            
            // Mirror Gradient
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent, Colors.transparent, C.bg],
                  stops: const [0.0, 0.2, 0.8, 1.0],
                ),
              ),
            ),
            
            // Image Indicator
            if (images.length > 1)
              Positioned(
                bottom: 30, right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
                  child: Text('${_currentPath + 1} / ${images.length}', style: dm(sz: 10, c: C.text)),
                ),
              ),
            
            // Badge Overlay
            Positioned(
              top: 130, left: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Badge(label: p.financial.isVerified ? '? AI VERIFIED' : 'PENDING AUDIT', color: p.financial.isVerified ? C.green : C.brand),
                  const SizedBox(height: 8),
                  if (p.escrow.status == EscrowStatus.pending_escrow)
                     const _Badge(label: '?? RESERVED � 72H WINDOW', color: C.red),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStickyNav(PropertyContainer p) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 52, 16, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent]),
      ),
      child: Row(
        children: [
          _CircleInner(icon: Icons.arrow_back_ios_new, onTap: () => s.go('home')),
          const Spacer(),
          _CircleInner(icon: Icons.share_outlined, onTap: () {}),
          const SizedBox(width: 10),
          _CircleInner(icon: Icons.favorite_border, onTap: () {}),
        ],
      ),
    );
  }

  // -- CONTENT ---------------------------------------------------
  Widget _buildMainContent(PropertyContainer p) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.core.propertyType.name.toUpperCase(), style: dm(sz: 11, c: C.brand, w: FontWeight.w700, ls: 1.5)),
                  const SizedBox(height: 4),
                  Text(p.core.title, style: syne(sz: 24, w: FontWeight.bold)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
                child: Column(
                  children: [
                    Text(ugx(p.financial.price), style: syne(sz: 18, c: C.brand, w: FontWeight.bold)),
                    Text(p.financial.priceType == PriceType.monthly ? '/ month' : '/ night', style: dm(sz: 9, c: C.dim)),
                  ],
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 12),
          Row(children: [
            Icon(Icons.location_on, size: 14, color: C.dim),
            const SizedBox(width: 4),
            Text('${p.core.district}, ${p.core.city}', style: dm(sz: 13, c: C.dim)),
          ]),
          
          const SizedBox(height: 30),
          _buildQuickSpecs(p),
          
          const SizedBox(height: 32),
          Text('Property Narrative', style: syne(sz: 18, w: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(p.core.description, style: dm(sz: 14, c: C.sub, h: 1.6)),
          
          const SizedBox(height: 32),
          _buildAgentCard(p),
          
          const SizedBox(height: 32),
          _buildVerificationGrid(p),
          
          if (p.shadow.isUnlockedByCurrentUser) ...[
             const SizedBox(height: 32),
             _buildUnlockedDetails(p),
          ],
        ],
      ),
    );
  }

  Widget _buildQuickSpecs(PropertyContainer p) {
    return Row(
      children: [
        _SpecBox(icon: '???', label: '${p.core.bedrooms} Beds'),
        const SizedBox(width: 10),
        _SpecBox(icon: '??', label: '${p.core.bathrooms} Baths'),
        const SizedBox(width: 10),
        _SpecBox(icon: '??', label: '${p.core.sizeSqft} sqft'),
      ],
    );
  }

  Widget _buildAgentCard(PropertyContainer p) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(20), border: Border.all(color: C.border)),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 50, height: 50,
                decoration: BoxDecoration(shape: BoxShape.circle, color: C.border),
                child: const Center(child: Text('??', style: TextStyle(fontSize: 24))),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('John Doe', style: dm(sz: 14, w: FontWeight.bold)),
                    Text('Verified Necxa Agent', style: dm(sz: 11, c: C.dim)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: C.brand.withOpacity(.15), borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  Icon(Icons.star, color: C.brand, size: 14),
                  const SizedBox(width: 4),
                  Text('98 TRUST', style: dm(sz: 10, c: C.brand, w: FontWeight.bold)),
                ]),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Btn(
            label: '??? Direct In-App Chat',
            color: C.brand.withOpacity(.1),
            textColor: C.brand,
            border: true,
            onTap: () => s.openOrCreateChat(p),
          ),
        ],
      ),
    );
  }

  Widget _buildVerificationGrid(PropertyContainer p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Digital Shards', style: syne(sz: 18, w: FontWeight.bold)),
        const SizedBox(height: 16),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.2,
          children: const [
            _VerifyTile(icon: '??', label: 'Identity Sync', verified: true),
            _VerifyTile(icon: '?', label: 'Utility Proof', verified: true),
            _VerifyTile(icon: '???', label: 'Authority Stamp', verified: true),
            _VerifyTile(icon: '??', label: 'GPS Physical Lock', verified: true),
          ],
        ),
      ],
    );
  }

  Widget _buildUnlockedDetails(PropertyContainer p) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [const Color(0xFF0d1f14), C.bg]),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.green.withOpacity(.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('??', style: TextStyle(fontSize: 22)),
            const SizedBox(width: 10),
            Text('RESTRICTED INTEL', style: syne(sz: 14, c: C.green, w: FontWeight.bold)),
          ]),
          const SizedBox(height: 16),
          _IntelRow(label: 'Exact Address', val: p.core.address),
          if (p.core.agentPhone != null)
            _IntelRow(label: 'Agent Phone', val: p.core.agentPhone!),
          if (p.core.agentWhatsapp != null)
            _IntelRow(label: 'WhatsApp', val: p.core.agentWhatsapp!),
          if (p.core.agentGoogleMeet != null)
            _IntelRow(label: 'Google Meet', val: p.core.agentGoogleMeet!),
          const SizedBox(height: 16),
          _VirtualTourWidget(property: p, state: s),
        ],
      ),
    );
  }

  // -- INTERACTION BAR -------------------------------------------
  Widget _buildInteractionBar(PropertyContainer p) {
    final curStep = _getInteractionState(p);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 42),
      decoration: BoxDecoration(
        color: C.card.withOpacity(.95),
        border: Border(top: BorderSide(color: C.border)),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 40, offset: Offset(0, -10))],
      ),
      child: _buildInteractionContent(p, curStep),
    );
  }

  _InteractionState _getInteractionState(PropertyContainer p) {
    if (p.escrow.status == EscrowStatus.pending_escrow) {
       // Is the current user the one who reserved? (In a real app, we'd check current user ID)
       // For this prototype, we'll assume yes if it's reserved.
       return _InteractionState.reserved;
    }
    if (p.shadow.isUnlockedByCurrentUser) return _InteractionState.unlocked;
    return _InteractionState.locked;
  }

  Widget _buildInteractionContent(PropertyContainer p, _InteractionState state) {
    switch (state) {
      case _InteractionState.locked:
        return Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Unlock Identity Shard', style: dm(sz: 14, w: FontWeight.bold)),
                  Text('${p.financial.unlockCost} NCX COINS (10%)', style: dm(sz: 10, c: C.brand, w: FontWeight.bold)),
                ],
              ),
            ),
            _Btn(label: 'Unlock Details ?', color: C.brand, textColor: C.bg, onTap: () => s.go('payment')),
          ],
        );
      case _InteractionState.unlocked:
        return Row(
          children: [
             Expanded(
               child: Column(
                 mainAxisSize: MainAxisSize.min,
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   Text('Reserve for 72 Hours', style: dm(sz: 14, w: FontWeight.bold)),
                   Text('UGX ${ugx(p.financial.escrowDeposit.toInt())} (10%)', style: dm(sz: 11, c: C.blue, w: FontWeight.bold)),
                 ],
               ),
             ),
             _Btn(label: 'Reserve Now ??', color: C.blue, textColor: C.text, onTap: () => s.reserveProperty(p.core.id)),
          ],
        );
      case _InteractionState.reserved:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.timer_outlined, color: C.red, size: 16),
                const SizedBox(width: 6),
                Text('WINDOW EXPIRES IN: ${_fmtDur(_timeLeft)}', style: syne(sz: 12, c: C.red, w: FontWeight.bold)),
                const Spacer(),
                Text('RESERVED', style: dm(sz: 10, c: C.red, w: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _Btn(label: 'Show QR Handshake ??', color: C.green, textColor: C.text, onTap: () => _showHandshake(context, p))),
                const SizedBox(width: 10),
                Expanded(child: _Btn(label: 'Dispute ??', color: C.card, textColor: C.dim, border: true, onTap: () {})),
              ],
            ),
          ],
        );
    }
  }

  void _showHandshake(BuildContext context, PropertyContainer p) {
    showModalBottomSheet(
      context: context,
      backgroundColor: C.bg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
      builder: (_) => Container(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Handshake Protocol', style: syne(sz: 20, w: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('Scanning this QR indicates you have physically visited the property and agree with its status.',
                textAlign: TextAlign.center, style: TextStyle(color: C.dim, fontSize: 13)),
            const SizedBox(height: 30),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: C.text, borderRadius: BorderRadius.circular(20)),
              child: const NecxaLogo(size: 270, shadow: false), // Placeholder for real QR
            ),
            const SizedBox(height: 30),
            _Btn(label: 'I Have Scanned It', color: C.brand, textColor: C.bg, onTap: () {
               Navigator.pop(context);
               s.doHandshake(p.core.id);
            }),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// -- Components ------------------------------------------------

enum _InteractionState { locked, unlocked, reserved }

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
    child: Text(label, style: TextStyle(color: C.text, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.0)),
  );
}

class _CircleInner extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleInner({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 44, height: 44,
      decoration: BoxDecoration(color: C.dim, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.dim)),
      child: Icon(icon, color: C.text, size: 20),
    ),
  );
}

class _SpecBox extends StatelessWidget {
  final String icon, label;
  const _SpecBox({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)),
      child: Column(
        children: [
          Text(icon, style: const TextStyle(fontSize: 20)),
          const SizedBox(height: 6),
          Text(label, style: dm(sz: 11, w: FontWeight.w600)),
        ],
      ),
    ),
  );
}

class _VerifyTile extends StatelessWidget {
  final String icon, label;
  final bool verified;
  const _VerifyTile({required this.icon, required this.label, required this.verified});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)),
    child: Row(
      children: [
        Text(icon, style: const TextStyle(fontSize: 18)),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: dm(sz: 10, w: FontWeight.w600))),
        if (verified) const Icon(Icons.check_circle, color: C.green, size: 14),
      ],
    ),
  );
}

class _IntelRow extends StatelessWidget {
  final String label, val;
  const _IntelRow({required this.label, required this.val});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Text(label, style: dm(sz: 13, c: C.dim)),
        const Spacer(),
        Text(val, style: dm(sz: 13, w: FontWeight.bold)),
      ],
    ),
  );
}

class _Btn extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final bool border;
  final VoidCallback onTap;
  const _Btn({required this.label, required this.color, required this.textColor, this.border = false, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: border ? Border.all(color: C.border) : null,
      ),
      child: Center(child: Text(label, style: syne(sz: 13, w: FontWeight.bold, c: textColor))),
    ),
  );
}

class _VirtualTourWidget extends StatelessWidget {
  final PropertyContainer property;
  final AppState state;
  const _VirtualTourWidget({required this.property, required this.state});

  @override
  Widget build(BuildContext context) {
    // Find if user already has a booking for this property
    VirtualTourBooking? booking;
    try {
      booking = state.tourBookings.firstWhere((b) => b.propertyId == property.core.id);
    } catch (_) {}

    if (booking == null) {
      return _Btn(
        label: '?? Schedule Virtual Tour',
        color: C.brand.withOpacity(.1),
        textColor: C.brand,
        border: true,
        onTap: () => _pickDateTime(context),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.bg.withOpacity(0.5), borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.videocam, color: C.brand, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('VIRTUAL TOUR: ${booking.status.toUpperCase()}', style: dm(sz: 10, w: FontWeight.w800, c: C.brand)),
                    Text(DateFormat('MMM dd, yyyy @ hh:mm a').format(booking.scheduledFor), style: dm(sz: 12, w: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
          if (booking.status == 'confirmed' && booking.meetLink != null) ...[
            const SizedBox(height: 12),
            _Btn(
              label: 'Join Meeting Link ??',
              color: C.green,
              textColor: C.text,
              onTap: () {
                // url_launcher to booking.meetLink
              },
            ),
          ],
        ],
      ),
    );
  }

  void _pickDateTime(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.dark(primary: C.brand, onPrimary: C.bg, surface: C.card, onSurface: C.text),
        ),
        child: child!,
      ),
    );
    if (date == null || !context.mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 10, minute: 0),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.dark(primary: C.brand, onPrimary: C.bg, surface: C.card, onSurface: C.text),
        ),
        child: child!,
      ),
    );
    if (time == null) return;

    final fullDate = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    state.scheduleVirtualTour(property, fullDate);
  }
}


