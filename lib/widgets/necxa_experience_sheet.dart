import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart';

class NecxaExperienceSheet extends StatefulWidget {
  final Map<String, dynamic> listing;
  final AppState state;
  final VoidCallback onBuyNow;

  const NecxaExperienceSheet({
    super.key,
    required this.listing,
    required this.state,
    required this.onBuyNow,
  });

  static Future<void> show({
    required BuildContext context,
    required Map<String, dynamic> listing,
    required AppState state,
    required VoidCallback onBuyNow,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => NecxaExperienceSheet(
        listing: listing,
        state: state,
        onBuyNow: onBuyNow,
      ),
    );
  }

  @override
  State<NecxaExperienceSheet> createState() => _NecxaExperienceSheetState();
}

class _NecxaExperienceSheetState extends State<NecxaExperienceSheet> {
  int _activeStep = 1; // 1: Your Photo, 2: AI Preview, 3: Results
  bool _isProcessing = false;
  XFile? _selectedUserPhoto;
  int _selectedVariantIndex = 0;
  int _selectedResultIndex = 0;
  List<String> _aiResultImages = [];

  final ImagePicker _picker = ImagePicker();

  // ── Helpers ─────────────────────────────────────────────────────────────

  List<String> _extractImages() {
    final list = <String>[];
    final photos = widget.listing['photos'];
    if (photos is List) {
      for (final p in photos) {
        if (p is String && p.isNotEmpty) list.add(p);
      }
    } else if (photos is String && photos.isNotEmpty) {
      try {
        final decoded = jsonDecode(photos);
        if (decoded is List) {
          for (final p in decoded) {
            if (p is String && p.isNotEmpty) list.add(p);
          }
        }
      } catch (_) {
        list.add(photos);
      }
    }
    if (list.isEmpty) {
      final fallback = widget.listing['thumbnail_url'] ??
          widget.listing['media_url'] ??
          widget.listing['image_url'];
      if (fallback != null && fallback.toString().isNotEmpty) {
        list.add(fallback.toString());
      }
    }
    return list;
  }

  /// Upload user photo bytes to Necxa Storage → return public URL for YouCam.
  Future<String?> _uploadUserPhoto(XFile file) async {
    try {
      final bytes = await file.readAsBytes();
      final ext = file.path.split('.').last.toLowerCase();
      final mime = ext == 'png' ? 'image/png' : 'image/jpeg';
      final name =
          'tryon_${DateTime.now().millisecondsSinceEpoch}_${widget.listing['id'] ?? 'item'}.$ext';
      final client = Supabase.instance.client;
      await client.storage.from('user-tryons').uploadBinary(
            name,
            bytes,
            fileOptions: FileOptions(contentType: mime, upsert: true),
          );
      return client.storage.from('user-tryons').getPublicUrl(name);
    } catch (e) {
      debugPrint('[ExperienceSheet] upload error: $e');
      return null;
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? file = await _picker.pickImage(
        source: source,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 85,
      );
      if (file == null) return;

      setState(() {
        _selectedUserPhoto = file;
        _isProcessing = true;
        _activeStep = 2;
      });

      List<String> aiResults = [];
      try {
        final images = _extractImages();
        final garmentUrl = images.isNotEmpty
            ? images[_selectedVariantIndex.clamp(0, images.length - 1)]
            : '';
        final publicPhotoUrl = await _uploadUserPhoto(file);

        if (garmentUrl.isNotEmpty && publicPhotoUrl != null) {
          final res = await http.post(
            Uri.parse(
                'https://anregykcgolpgxecfxej.supabase.co/functions/v1/youcam-try-on'),
            headers: {
              'Content-Type': 'application/json',
              'apikey': 'sb_publishable_KzEAI6a7Xvw-Jz-BqPQRRA_mn4iKnou',
              'Authorization':
                  'Bearer sb_publishable_KzEAI6a7Xvw-Jz-BqPQRRA_mn4iKnou',
            },
            body: jsonEncode({
              'action': 'try-on',
              'src_image_url': publicPhotoUrl,
              'garment_image_url': garmentUrl,
              'listing_id': widget.listing['id'],
            }),
          );
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            if (data is Map && data['result_url'] != null) {
              aiResults.add(data['result_url'].toString());
            }
            if (data is Map && data['variations'] is List) {
              for (final v in data['variations']) {
                if (v is String && v.isNotEmpty && !aiResults.contains(v)) {
                  aiResults.add(v);
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[ExperienceSheet] Goobox notice: $e');
      }

      await Future.delayed(const Duration(milliseconds: 1400));
      if (mounted) {
        setState(() {
          if (aiResults.isNotEmpty) _aiResultImages = aiResults;
          _isProcessing = false;
          _activeStep = 3;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load image: $e')),
        );
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final images = _extractImages();
    final title = widget.listing['title'] ?? 'Product';
    final price = widget.listing['price'] ?? 0;
    final rawProf = widget.listing['profiles'] ?? widget.listing['lister'];
    final prof = (rawProf is List && rawProf.isNotEmpty)
        ? rawProf[0]
        : (rawProf is Map ? rawProf : null);
    final vendorName =
        prof?['display_name'] ?? prof?['full_name'] ?? 'Vendor';

    // Main image: show selected AI result in Step 3, otherwise selected variant
    final displayResults =
        _aiResultImages.isNotEmpty ? _aiResultImages : images;
    final mainImg = (_activeStep == 3 &&
            _aiResultImages.isNotEmpty &&
            _selectedResultIndex < _aiResultImages.length)
        ? _aiResultImages[_selectedResultIndex]
        : (images.isNotEmpty
            ? images[_selectedVariantIndex.clamp(0, images.length - 1)]
            : '');

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: MediaQuery.of(context).size.height * 0.88,
          decoration: BoxDecoration(
            color: const Color(0xFF060F1E),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(
              color: const Color(0xFF00E5FF).withValues(alpha: 0.25),
              width: 1.0,
            ),
          ),
          child: Column(
            children: [
              // ── Drag Handle ───────────────────────────────────────────
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // ── Header Row: ✦✦ NECXA Experience  [X] ────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Two 4-pointed sparkle stars (matches mockup exactly)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.stars_rounded,
                            color: const Color(0xFF00E5FF), size: 18),
                        const SizedBox(height: 2),
                        Icon(Icons.stars_rounded,
                            color: const Color(0xFF00E5FF), size: 14),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          RichText(
                            text: TextSpan(children: [
                              TextSpan(
                                text: 'NECXA  ',
                                style: syne(
                                    sz: 20,
                                    w: FontWeight.w900,
                                    c: Colors.white),
                              ),
                              TextSpan(
                                text: 'Experience',
                                style: syne(
                                    sz: 20,
                                    w: FontWeight.w900,
                                    c: const Color(0xFF00E5FF)),
                              ),
                            ]),
                          ),
                          Text(
                            'See how this product looks on you with AI',
                            style: dm(
                                sz: 11.5,
                                c: const Color(0xFF8A9AB2)),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close,
                            color: Colors.white70, size: 18),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // ── Stepper Pill ──────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A1324),
                    borderRadius: BorderRadius.circular(30),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Row(
                    children: [
                      _stepPill(1, 'Your Photo'),
                      const Icon(Icons.chevron_right,
                          color: Colors.white24, size: 16),
                      _stepPill(2, 'AI Preview'),
                      const Icon(Icons.chevron_right,
                          color: Colors.white24, size: 16),
                      _stepPill(3, 'Results'),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),
              const Divider(color: Colors.white10, height: 1),

              // ── Scrollable Body ───────────────────────────────────────
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── 2-column layout: Product card LEFT, Photo picker RIGHT
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // LEFT: Main product image + variant strip + info
                            Expanded(
                              flex: 5,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Main image card
                                  Container(
                                    height: 190,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0A1324),
                                      borderRadius:
                                          BorderRadius.circular(14),
                                      border: Border.all(
                                        color: (_activeStep == 3 &&
                                                _aiResultImages.isNotEmpty)
                                            ? const Color(0xFF00E5FF)
                                                .withValues(alpha: 0.6)
                                            : Colors.white10,
                                        width: (_activeStep == 3 &&
                                                _aiResultImages.isNotEmpty)
                                            ? 1.5
                                            : 1.0,
                                      ),
                                    ),
                                    child: ClipRRect(
                                      borderRadius:
                                          BorderRadius.circular(13),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          if (mainImg.isNotEmpty)
                                            Image.network(
                                              mainImg,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  const Icon(
                                                Icons.checkroom_outlined,
                                                color: Colors.white24,
                                                size: 36,
                                              ),
                                            )
                                          else
                                            const Icon(
                                              Icons.checkroom_outlined,
                                              color: Colors.white24,
                                              size: 36,
                                            ),
                                          // AI-processing shimmer overlay
                                          if (_isProcessing)
                                            Container(
                                              color: Colors.black
                                                  .withValues(alpha: 0.55),
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  const SizedBox(
                                                    width: 22,
                                                    height: 22,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color:
                                                          Color(0xFF00E5FF),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                    'AI generating…',
                                                    style: dm(
                                                        sz: 10,
                                                        c: const Color(
                                                            0xFF00E5FF)),
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // Variant thumbnails (horizontal strip below main image)
                                  if (images.length > 1) ...[
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      height: 52,
                                      child: ListView.separated(
                                        scrollDirection: Axis.horizontal,
                                        itemCount: images.length,
                                        separatorBuilder: (_, __) =>
                                            const SizedBox(width: 6),
                                        itemBuilder: (_, idx) {
                                          final sel =
                                              idx == _selectedVariantIndex;
                                          return GestureDetector(
                                            onTap: () => setState(() =>
                                                _selectedVariantIndex = idx),
                                            child: Container(
                                              width: 48,
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                border: Border.all(
                                                  color: sel
                                                      ? const Color(
                                                          0xFF00E5FF)
                                                      : Colors.white12,
                                                  width: sel ? 1.8 : 1.0,
                                                ),
                                              ),
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(7),
                                                child: Image.network(
                                                    images[idx],
                                                    fit: BoxFit.cover),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],

                                  const SizedBox(height: 10),

                                  // Product title + price + vendor + rating (UNDER main image)
                                  Text(
                                    title,
                                    style: syne(
                                        sz: 13,
                                        w: FontWeight.w800,
                                        c: Colors.white),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    ugx(num.tryParse(price.toString()) ?? 0),
                                    style: dm(
                                        sz: 14,
                                        w: FontWeight.w800,
                                        c: const Color(0xFF00E5FF)),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      const Icon(Icons.storefront_outlined,
                                          size: 12,
                                          color: Color(0xFF8A9AB2)),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          vendorName,
                                          style: dm(
                                              sz: 11,
                                              c: const Color(0xFF8A9AB2)),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  // Star rating
                                  Row(
                                    children: [
                                      ...List.generate(
                                          5,
                                          (i) => const Icon(
                                                Icons.star_rounded,
                                                size: 13,
                                                color: Colors.amber,
                                              )),
                                      const SizedBox(width: 4),
                                      Text(
                                        '(24)',
                                        style: dm(
                                            sz: 10,
                                            c: const Color(0xFF8A9AB2)),
                                      ),
                                    ],
                                  ),

                                  // User photo thumbnail (shown after picking)
                                  if (_selectedUserPhoto != null) ...[
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(24),
                                          child: Image.file(
                                            File(_selectedUserPhoto!.path),
                                            width: 38,
                                            height: 38,
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Your photo',
                                          style: dm(
                                              sz: 10,
                                              c: const Color(0xFF8A9AB2)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),

                            const SizedBox(width: 12),

                            // RIGHT: Select a photo box
                            Expanded(
                              flex: 5,
                              child: _buildPhotoPickerBox(),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 22),

                      // ── "Experience it on you" section ────────────────
                      Row(
                        children: [
                          const Icon(Icons.auto_awesome,
                              color: Color(0xFF00E5FF), size: 15),
                          const SizedBox(width: 6),
                          Text(
                            'Experience it on you',
                            style: syne(
                                sz: 13,
                                w: FontWeight.w700,
                                c: Colors.white),
                          ),
                          if (_activeStep == 3 &&
                              _aiResultImages.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00E5FF)
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: const Color(0xFF00E5FF)
                                        .withValues(alpha: 0.4)),
                              ),
                              child: Text('AI Results',
                                  style: dm(
                                      sz: 9,
                                      w: FontWeight.w700,
                                      c: const Color(0xFF00E5FF))),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Results carousel — 170px wide cards to match mockup
                      SizedBox(
                        height: 200,
                        child: _isProcessing
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const CircularProgressIndicator(
                                        color: Color(0xFF00E5FF),
                                        strokeWidth: 2),
                                    const SizedBox(height: 10),
                                    Text('AI generating try-on preview…',
                                        style: dm(
                                            sz: 11,
                                            c: const Color(0xFF00E5FF))),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                // images or placeholders + 1 "More styles" card
                                itemCount:
                                    (displayResults.isNotEmpty
                                            ? displayResults.length
                                            : 4) +
                                        1,
                                itemBuilder: (ctx, i) {
                                  final total = displayResults.isNotEmpty
                                      ? displayResults.length
                                      : 4;
                                  // "More styles ›" card
                                  if (i >= total) {
                                    return Container(
                                      width: 100,
                                      margin: const EdgeInsets.only(right: 10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF0A1324),
                                        borderRadius:
                                            BorderRadius.circular(14),
                                        border: Border.all(
                                            color: Colors.white10),
                                      ),
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          const Icon(Icons.auto_awesome,
                                              color: Color(0xFF00E5FF),
                                              size: 22),
                                          const SizedBox(height: 8),
                                          Text(
                                            'More\nstyles ›',
                                            textAlign: TextAlign.center,
                                            style: dm(
                                                sz: 11,
                                                w: FontWeight.w600,
                                                c: const Color(0xFF00E5FF)),
                                          ),
                                        ],
                                      ),
                                    );
                                  }

                                  final isSel = _selectedResultIndex == i;
                                  final imgUrl = displayResults.isNotEmpty
                                      ? displayResults[
                                          i % displayResults.length]
                                      : '';

                                  return GestureDetector(
                                    onTap: () => setState(
                                        () => _selectedResultIndex = i),
                                    child: Container(
                                      width: 170,
                                      margin:
                                          const EdgeInsets.only(right: 10),
                                      decoration: BoxDecoration(
                                        borderRadius:
                                            BorderRadius.circular(14),
                                        border: Border.all(
                                          color: isSel
                                              ? const Color(0xFF00E5FF)
                                              : Colors.white12,
                                          width: isSel ? 2.0 : 1.0,
                                        ),
                                      ),
                                      child: ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(13),
                                        child: imgUrl.isNotEmpty
                                            ? Image.network(imgUrl,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    const Icon(
                                                        Icons.checkroom,
                                                        color: Colors.white24))
                                            : Container(
                                                color:
                                                    const Color(0xFF0A1324),
                                                child: const Icon(
                                                    Icons.checkroom,
                                                    color: Colors.white24,
                                                    size: 32),
                                              ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),

                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),

              // ── Sticky Bottom Commerce Bar ────────────────────────────
              Container(
                padding: EdgeInsets.fromLTRB(
                    16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF060F1E),
                  border: Border(
                      top: BorderSide(
                          color: Colors.white.withValues(alpha: 0.08))),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.shopping_cart_outlined,
                          color: Colors.white70, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Love this look?',
                              style: syne(
                                  sz: 12,
                                  w: FontWeight.w700,
                                  c: Colors.white)),
                          Text('Get it from our trusted vendors.',
                              style: dm(sz: 10, c: const Color(0xFF8A9AB2))),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        widget.onBuyNow();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 22, vertical: 13),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E5FF),
                          borderRadius: BorderRadius.circular(26),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x5500E5FF),
                              blurRadius: 12,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.shopping_cart,
                                color: Colors.black, size: 16),
                            const SizedBox(width: 6),
                            Text('Buy Now',
                                style: syne(
                                    sz: 13,
                                    w: FontWeight.w900,
                                    c: Colors.black)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Right-column photo picker box (matches mockup layout) ─────────────
  Widget _buildPhotoPickerBox() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1324),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(Icons.account_box_outlined,
                    color: Color(0xFF00E5FF), size: 16),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Select a photo',
                        style: syne(
                            sz: 12, w: FontWeight.w700, c: Colors.white)),
                    Text('Choose a clear, well-lit photo of yourself',
                        style: dm(sz: 10, c: const Color(0xFF8A9AB2))),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Upload from Gallery
          GestureDetector(
            onTap: _isProcessing
                ? null
                : () => _pickImage(ImageSource.gallery),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: const Color(0xFF00E5FF), width: 1.2),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.image_outlined,
                      color: Color(0xFF00E5FF), size: 16),
                  const SizedBox(width: 6),
                  Text('Upload from Gallery',
                      style: dm(
                          sz: 12,
                          w: FontWeight.w600,
                          c: const Color(0xFF00E5FF))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Take a Photo
          GestureDetector(
            onTap: _isProcessing
                ? null
                : () => _pickImage(ImageSource.camera),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                color: const Color(0xFF101B2E),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.camera_alt_outlined,
                      color: Colors.white70, size: 16),
                  const SizedBox(width: 6),
                  Text('Take a Photo',
                      style: dm(
                          sz: 12,
                          w: FontWeight.w600,
                          c: Colors.white70)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Bullet-point tips (matches mockup "Tips for best results:")
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lightbulb_outline_rounded,
                  color: Colors.amber, size: 14),
              const SizedBox(width: 5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tips for best results:',
                        style: dm(
                            sz: 10,
                            w: FontWeight.w700,
                            c: Colors.white70)),
                    const SizedBox(height: 3),
                    _tip('Use good lighting'),
                    _tip('Face the camera'),
                    _tip('Avoid sunglasses or hats'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tip(String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• ',
                style: dm(sz: 10, c: const Color(0xFF8A9AB2))),
            Flexible(
              child: Text(text,
                  style: dm(sz: 10, c: const Color(0xFF8A9AB2))),
            ),
          ],
        ),
      );

  // ── Stepper pill item ─────────────────────────────────────────────────
  Widget _stepPill(int n, String label) {
    final active = _activeStep >= n;
    return Expanded(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? const Color(0xFF00E5FF)
                  : Colors.white.withValues(alpha: 0.1),
            ),
            child: Center(
              child: Text('$n',
                  style: dm(
                      sz: 11,
                      w: FontWeight.w800,
                      c: active ? Colors.black : Colors.white60)),
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: dm(
                sz: 11,
                w: active ? FontWeight.w700 : FontWeight.w400,
                c: active ? Colors.white : Colors.white54,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
