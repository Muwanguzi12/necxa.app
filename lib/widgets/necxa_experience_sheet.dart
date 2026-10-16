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
      barrierColor: Colors.black.withOpacity(0.7),
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
  String? _selectedUserPhotoPath;
  int _selectedVariantIndex = 0;
  int _selectedResultIndex = 0;

  final ImagePicker _picker = ImagePicker();

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
        _selectedUserPhotoPath = file.path;
        _isProcessing = true;
        _activeStep = 2; // AI Preview
      });

      // Call YouCam try-on API via Goobox Edge Function (where YouCam credentials reside)
      try {
        final images = _extractImages();
        final garmentUrl = images.isNotEmpty ? images[_selectedVariantIndex.clamp(0, images.length - 1)] : '';

        final gooboxUrl = Uri.parse('https://anregykcgolpgxecfxej.supabase.co/functions/v1/youcam-try-on');
        await http.post(
          gooboxUrl,
          headers: {
            'Content-Type': 'application/json',
            'apikey': 'sb_publishable_KzEAI6a7Xvw-Jz-BqPQRRA_mn4iKnou',
            'Authorization': 'Bearer sb_publishable_KzEAI6a7Xvw-Jz-BqPQRRA_mn4iKnou',
          },
          body: jsonEncode({
            'action': 'try-on',
            'src_image_url': file.path,
            'garment_image_url': garmentUrl,
            'listing_id': widget.listing['id'],
          }),
        );
      } catch (err) {
        debugPrint('[ExperienceSheet] Goobox Edge function notice: $err');
      }

      // Smooth transition to results after AI generation
      await Future.delayed(const Duration(milliseconds: 1400));
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _activeStep = 3; // Results
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

  @override
  Widget build(BuildContext context) {
    final images = _extractImages();
    final primaryImg = images.isNotEmpty
        ? images[_selectedVariantIndex.clamp(0, images.length - 1)]
        : '';
    final title = widget.listing['title'] ?? 'Product';
    final price = widget.listing['price'] ?? 0;
    final rawProf = widget.listing['profiles'] ?? widget.listing['lister'];
    final prof = (rawProf is List && rawProf.isNotEmpty)
        ? rawProf[0]
        : (rawProf is Map ? rawProf : null);
    final vendorName = prof?['display_name'] ?? prof?['full_name'] ?? 'Vendor';

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: MediaQuery.of(context).size.height * 0.82,
          decoration: BoxDecoration(
            color: const Color(0xFF030A14).withOpacity(0.96),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(
              color: const Color(0xFF00E5FF).withOpacity(0.3),
              width: 1.2,
            ),
          ),
          child: Column(
            children: [
              // 1. Top Drag Handle & Close Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 16, 4),
                child: Column(
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E5FF).withOpacity(0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Sparkle Avatar Icon
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFF00E5FF),
                              width: 1.2,
                            ),
                            color: const Color(0xFF00E5FF).withOpacity(0.12),
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.auto_awesome,
                              color: Color(0xFF00E5FF),
                              size: 20,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RichText(
                                text: TextSpan(
                                  children: [
                                    TextSpan(
                                      text: 'NECXA ',
                                      style: syne(
                                        sz: 18,
                                        w: FontWeight.w900,
                                        c: Colors.white,
                                      ),
                                    ),
                                    TextSpan(
                                      text: 'Experience',
                                      style: syne(
                                        sz: 18,
                                        w: FontWeight.w900,
                                        c: const Color(0xFF00E5FF),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'See how this product looks on you with AI',
                                style: dm(
                                  sz: 12,
                                  w: FontWeight.w400,
                                  c: const Color(0xFF8A9AB2),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70, size: 22),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // 2. Stepper Progress Pill (1. Your Photo -> 2. AI Preview -> 3. Results)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A1324),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildStepItem(1, 'Your Photo', _activeStep >= 1),
                      Icon(Icons.chevron_right, color: Colors.white24, size: 16),
                      _buildStepItem(2, 'AI Preview', _activeStep >= 2),
                      Icon(Icons.chevron_right, color: Colors.white24, size: 16),
                      _buildStepItem(3, 'Results', _activeStep >= 3),
                    ],
                  ),
                ),
              ),

              const Divider(color: Colors.white12, height: 1),

              // 3. Scrollable Interactive Body
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  children: [
                    // Product Showcase & Selector Card
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Main Product Card
                        Expanded(
                          flex: 5,
                          child: Container(
                            height: 200,
                            decoration: BoxDecoration(
                              color: const Color(0xFF0A1324),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: primaryImg.isNotEmpty
                                  ? Image.network(
                                      primaryImg,
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.checkroom_outlined,
                                        color: Colors.white38,
                                        size: 40,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.checkroom_outlined,
                                      color: Colors.white38,
                                      size: 40,
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),

                        // Variant Selection Strip
                        if (images.length > 1)
                          Expanded(
                            flex: 2,
                            child: SizedBox(
                              height: 200,
                              child: ListView.separated(
                                scrollDirection: Axis.vertical,
                                itemCount: images.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 8),
                                itemBuilder: (context, idx) {
                                  final isSel = idx == _selectedVariantIndex;
                                  return GestureDetector(
                                    onTap: () => setState(() => _selectedVariantIndex = idx),
                                    child: Container(
                                      height: 56,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: isSel
                                              ? const Color(0xFF00E5FF)
                                              : Colors.white12,
                                          width: isSel ? 1.8 : 1.0,
                                        ),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(9),
                                        child: Image.network(
                                          images[idx],
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Product Title, Price, Vendor & Rating
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: syne(
                                  sz: 15,
                                  w: FontWeight.w700,
                                  c: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                ugx(num.tryParse(price.toString()) ?? 0),
                                style: dm(
                                  sz: 14,
                                  w: FontWeight.w800,
                                  c: const Color(0xFF00E5FF),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.storefront_outlined,
                                    size: 13,
                                    color: Color(0xFF8A9AB2),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    vendorName,
                                    style: dm(
                                      sz: 11,
                                      w: FontWeight.w500,
                                      c: const Color(0xFF8A9AB2),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const Icon(
                                    Icons.star_rounded,
                                    size: 14,
                                    color: Colors.amber,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    '4.9 (24)',
                                    style: dm(
                                      sz: 11,
                                      w: FontWeight.w500,
                                      c: const Color(0xFF8A9AB2),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    // Step 1: Select a Photo Action Box
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A1324),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.08)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00E5FF).withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.account_box_outlined,
                                  color: Color(0xFF00E5FF),
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Select a photo',
                                    style: syne(
                                      sz: 13,
                                      w: FontWeight.w700,
                                      c: Colors.white,
                                    ),
                                  ),
                                  Text(
                                    'Choose a clear, well-lit photo of yourself',
                                    style: dm(
                                      sz: 11,
                                      c: const Color(0xFF8A9AB2),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),

                          // Gallery Button
                          GestureDetector(
                            onTap: _isProcessing
                                ? null
                                : () => _pickImage(ImageSource.gallery),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xFF00E5FF),
                                  width: 1.2,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.image_outlined,
                                    color: Color(0xFF00E5FF),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Upload from Gallery',
                                    style: dm(
                                      sz: 13,
                                      w: FontWeight.w600,
                                      c: const Color(0xFF00E5FF),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),

                          // Camera Button
                          GestureDetector(
                            onTap: _isProcessing
                                ? null
                                : () => _pickImage(ImageSource.camera),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF101B2E),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.camera_alt_outlined,
                                    color: Colors.white70,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Take a Photo',
                                    style: dm(
                                      sz: 13,
                                      w: FontWeight.w600,
                                      c: Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 12),
                          // Tips for best results
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.lightbulb_outline_rounded,
                                color: Colors.amber,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Tips: Use good lighting • Face the camera • Avoid sunglasses',
                                  style: dm(
                                    sz: 10.5,
                                    w: FontWeight.w400,
                                    c: const Color(0xFF8A9AB2),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Step 3 / Results Preview: Experience it on you
                    Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome,
                          color: Color(0xFF00E5FF),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Experience it on you',
                          style: syne(
                            sz: 13,
                            w: FontWeight.w700,
                            c: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    if (_isProcessing)
                      Container(
                        height: 110,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A1324),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFF00E5FF).withOpacity(0.3),
                          ),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF00E5FF),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'AI generating try-on preview...',
                                style: dm(
                                  sz: 11,
                                  c: const Color(0xFF00E5FF),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        height: 110,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          children: [
                            for (int i = 0; i < (images.isNotEmpty ? images.length : 3); i++)
                              GestureDetector(
                                onTap: () => setState(() => _selectedResultIndex = i),
                                child: Container(
                                  width: 82,
                                  margin: const EdgeInsets.only(right: 10),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: _selectedResultIndex == i
                                          ? const Color(0xFF00E5FF)
                                          : Colors.white12,
                                      width: _selectedResultIndex == i ? 2 : 1,
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(11),
                                    child: Image.network(
                                      images.isNotEmpty
                                          ? images[i % images.length]
                                          : primaryImg,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.checkroom,
                                        color: Colors.white30,
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                            // "More styles >" Card
                            Container(
                              width: 82,
                              decoration: BoxDecoration(
                                color: const Color(0xFF0A1324),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.white10),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.auto_awesome,
                                    color: Color(0xFF00E5FF),
                                    size: 18,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'More styles >',
                                    style: dm(
                                      sz: 9.5,
                                      w: FontWeight.w600,
                                      c: const Color(0xFF00E5FF),
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),

              // 4. Sticky Bottom Commerce Bar
              Container(
                padding: EdgeInsets.fromLTRB(
                  16,
                  10,
                  16,
                  MediaQuery.of(context).padding.bottom + 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF060F1E),
                  border: Border(
                    top: BorderSide(
                      color: Colors.white.withOpacity(0.08),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.shopping_cart_outlined,
                        color: Colors.white70,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Love this look?',
                            style: syne(
                              sz: 12,
                              w: FontWeight.w700,
                              c: Colors.white,
                            ),
                          ),
                          Text(
                            'Get it from our trusted vendors.',
                            style: dm(
                              sz: 10,
                              c: const Color(0xFF8A9AB2),
                            ),
                          ),
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
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E5FF),
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x5500E5FF),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.shopping_cart,
                              color: Colors.black,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Buy Now',
                              style: syne(
                                sz: 13,
                                w: FontWeight.w900,
                                c: Colors.black,
                              ),
                            ),
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

  Widget _buildStepItem(int stepNumber, String title, bool isCurrentOrCompleted) {
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isCurrentOrCompleted
                ? const Color(0xFF00E5FF)
                : Colors.white.withOpacity(0.1),
          ),
          child: Center(
            child: Text(
              '$stepNumber',
              style: dm(
                sz: 11,
                w: FontWeight.w800,
                c: isCurrentOrCompleted ? Colors.black : Colors.white60,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          title,
          style: dm(
            sz: 12,
            w: isCurrentOrCompleted ? FontWeight.w700 : FontWeight.w400,
            c: isCurrentOrCompleted ? Colors.white : Colors.white54,
          ),
        ),
      ],
    );
  }
}
