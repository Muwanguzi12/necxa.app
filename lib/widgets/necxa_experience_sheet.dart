import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:convert';
import 'dart:async';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../theme.dart';
import '../app_state.dart';
import '../data.dart';

enum ExperienceCategory {
  fashion,
  homeLiving,
  electronics,
  beautyJewelry,
  general,
}

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
  bool _showOriginalPhoto = false; // "Before vs After" toggle
  int _processingSeconds = 0;
  Timer? _processingTimer;
  double _spatialScale = 1.0;
  Offset _spatialPosition = Offset.zero;

  final ImagePicker _picker = ImagePicker();

  ExperienceCategory get _category {
    final cat = (widget.listing['category'] ?? '').toString().toLowerCase();
    final title = (widget.listing['title'] ?? '').toString().toLowerCase();
    final desc = (widget.listing['description'] ?? '').toString().toLowerCase();
    final combined = '$cat $title $desc';

    if (combined.contains('sofa') ||
        combined.contains('chair') ||
        combined.contains('table') ||
        combined.contains('bed') ||
        combined.contains('furniture') ||
        combined.contains('lamp') ||
        combined.contains('rug') ||
        combined.contains('decor') ||
        combined.contains('desk') ||
        combined.contains('mirror') ||
        combined.contains('curtain') ||
        combined.contains('shelf') ||
        combined.contains('plant') ||
        combined.contains('couch') ||
        combined.contains('cushion') ||
        combined.contains('appliance')) {
      return ExperienceCategory.homeLiving;
    }

    if (combined.contains('laptop') ||
        combined.contains('phone') ||
        combined.contains('monitor') ||
        combined.contains('headphone') ||
        combined.contains('speaker') ||
        combined.contains('keyboard') ||
        combined.contains('tech') ||
        combined.contains('gadget') ||
        combined.contains('screen') ||
        combined.contains('audio') ||
        combined.contains('camera')) {
      return ExperienceCategory.electronics;
    }

    if (combined.contains('lipstick') ||
        combined.contains('makeup') ||
        combined.contains('cosmetic') ||
        combined.contains('cream') ||
        combined.contains('skincare') ||
        combined.contains('watch') ||
        combined.contains('ring') ||
        combined.contains('earring') ||
        combined.contains('necklace') ||
        combined.contains('bracelet') ||
        combined.contains('jewelry') ||
        combined.contains('chain')) {
      return ExperienceCategory.beautyJewelry;
    }

    if (combined.contains('shirt') ||
        combined.contains('pant') ||
        combined.contains('trouser') ||
        combined.contains('dress') ||
        combined.contains('suit') ||
        combined.contains('jacket') ||
        combined.contains('coat') ||
        combined.contains('hoodie') ||
        combined.contains('shoe') ||
        combined.contains('sneaker') ||
        combined.contains('heel') ||
        combined.contains('boot') ||
        combined.contains('hat') ||
        combined.contains('cap') ||
        combined.contains('clothes') ||
        combined.contains('clothing') ||
        combined.contains('wear') ||
        combined.contains('t-shirt') ||
        combined.contains('fashion')) {
      return ExperienceCategory.fashion;
    }

    return ExperienceCategory.general;
  }

  String get _categorySubtitle {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'See how this furniture fits in your room with AI';
      case ExperienceCategory.electronics:
        return 'See how this tech fits on your desk with AI';
      case ExperienceCategory.beautyJewelry:
        return 'See how this piece looks on you with AI';
      case ExperienceCategory.general:
        return 'See how this product fits in your space with AI';
      case ExperienceCategory.fashion:
        return 'See how this product looks on you with AI';
    }
  }

  String get _step1Label {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'Your Room';
      case ExperienceCategory.electronics:
        return 'Your Desk';
      case ExperienceCategory.beautyJewelry:
        return 'Your Photo';
      case ExperienceCategory.general:
        return 'Your Space';
      case ExperienceCategory.fashion:
        return 'Your Photo';
    }
  }

  String get _step2Label {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'Room Preview';
      case ExperienceCategory.electronics:
        return 'Setup Preview';
      case ExperienceCategory.beautyJewelry:
        return 'AI Preview';
      case ExperienceCategory.general:
        return 'Space Preview';
      case ExperienceCategory.fashion:
        return 'AI Preview';
    }
  }

  String get _experienceSectionTitle {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'Experience in your room';
      case ExperienceCategory.electronics:
        return 'Experience on your desk';
      case ExperienceCategory.beautyJewelry:
        return 'Experience on you';
      case ExperienceCategory.general:
        return 'Experience in your space';
      case ExperienceCategory.fashion:
        return 'Experience it on you';
    }
  }

  String get _resultsBadgeLabel {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'Room Results';
      case ExperienceCategory.electronics:
        return 'Desk Results';
      case ExperienceCategory.beautyJewelry:
        return 'AI Results';
      case ExperienceCategory.general:
        return 'Space Results';
      case ExperienceCategory.fashion:
        return 'AI Results';
    }
  }

  String get _pickerTitle {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'Select a room photo';
      case ExperienceCategory.electronics:
        return 'Select a desk photo';
      case ExperienceCategory.beautyJewelry:
        return 'Select a photo';
      case ExperienceCategory.general:
        return 'Select a space photo';
      case ExperienceCategory.fashion:
        return 'Select a photo';
    }
  }

  String get _pickerDesc {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'Choose a photo of your living room, wall, or corner';
      case ExperienceCategory.electronics:
        return 'Choose a photo of your desk, table, or workspace';
      case ExperienceCategory.beautyJewelry:
        return 'Choose a clear photo of your face, wrist, or hand';
      case ExperienceCategory.general:
        return 'Choose a photo of where you plan to place this';
      case ExperienceCategory.fashion:
        return 'Choose a clear, well-lit photo of yourself';
    }
  }

  List<String> get _pickerTips {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return ['Capture the entire corner or wall', 'Keep floor visible for scale', 'Clear away clutter'];
      case ExperienceCategory.electronics:
        return ['Capture your workspace surface', 'Use natural daylight', 'Leave open desk space'];
      case ExperienceCategory.beautyJewelry:
        return ['Hold wrist or face steady', 'Direct front lighting', 'Avoid heavy shadows'];
      case ExperienceCategory.general:
        return ['Capture the full surface', 'Use clear lighting', 'Hold camera steady'];
      case ExperienceCategory.fashion:
        return ['Use good lighting', 'Face the camera', 'Avoid sunglasses or hats'];
    }
  }

  String get _uploadButtonLabel {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'Upload Room Photo';
      case ExperienceCategory.electronics:
        return 'Upload Desk Photo';
      case ExperienceCategory.beautyJewelry:
        return 'Upload from Gallery';
      case ExperienceCategory.general:
        return 'Upload Space Photo';
      case ExperienceCategory.fashion:
        return 'Upload from Gallery';
    }
  }

  String get _cameraButtonLabel {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'Take Room Photo';
      case ExperienceCategory.electronics:
        return 'Take Desk Photo';
      case ExperienceCategory.beautyJewelry:
        return 'Take a Photo';
      case ExperienceCategory.general:
        return 'Take Space Photo';
      case ExperienceCategory.fashion:
        return 'Take a Photo';
    }
  }

  String get _photoBadgeLabel {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'Your room';
      case ExperienceCategory.electronics:
        return 'Your desk';
      case ExperienceCategory.beautyJewelry:
        return 'Your photo';
      case ExperienceCategory.general:
        return 'Your space';
      case ExperienceCategory.fashion:
        return 'Your photo';
    }
  }

  String get _beforePillLabel {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'Empty Room';
      case ExperienceCategory.electronics:
        return 'Empty Desk';
      case ExperienceCategory.beautyJewelry:
        return 'Before';
      case ExperienceCategory.general:
        return 'Original Space';
      case ExperienceCategory.fashion:
        return 'Before (You)';
    }
  }

  String get _afterPillLabel {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        return 'In Room ✨';
      case ExperienceCategory.electronics:
        return 'On Desk ✨';
      case ExperienceCategory.beautyJewelry:
        return 'Try-On ✨';
      case ExperienceCategory.general:
        return 'In Space ✨';
      case ExperienceCategory.fashion:
        return 'AI Fit ✨';
    }
  }

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

  void _startProcessingTimer() {
    _processingSeconds = 0;
    _processingTimer?.cancel();
    _processingTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _processingSeconds++;
      });
    });
  }

  void _stopProcessingTimer() {
    _processingTimer?.cancel();
    _processingTimer = null;
  }

  String _getProcessingStageText(int s) {
    switch (_category) {
      case ExperienceCategory.homeLiving:
        if (s < 3) return 'Analyzing room dimensions & lighting…';
        if (s < 7) return 'Calibrating floor plane & perspective…';
        if (s < 13) return 'Staging furniture into your space…';
        return 'Finalizing interactive room preview…';
      case ExperienceCategory.electronics:
        if (s < 3) return 'Analyzing desk workspace surface…';
        if (s < 7) return 'Aligning scale & tabletop angle…';
        if (s < 13) return 'Placing device in your setup…';
        return 'Finalizing realistic desk view…';
      case ExperienceCategory.beautyJewelry:
        if (s < 3) return 'Detecting contour & surface angle…';
        if (s < 7) return 'Aligning reflections & realistic gleam…';
        if (s < 13) return 'Compositing item onto your photo…';
        return 'Finalizing try-on preview…';
      case ExperienceCategory.general:
        if (s < 3) return 'Analyzing scene perspective & lighting…';
        if (s < 7) return 'Calibrating surface placement…';
        if (s < 13) return 'Compositing item into your space…';
        return 'Finalizing interactive preview…';
      case ExperienceCategory.fashion:
        if (s < 3) return 'Detecting silhouette & posture…';
        if (s < 7) return 'Aligning fabric drape & lighting…';
        if (s < 13) return 'Synthesizing realistic AI fit…';
        return 'Polishing high-definition preview…';
    }
  }

  double _getProcessingStageProgress(int s) {
    if (s <= 0) return 0.12;
    if (s >= 18) return 0.95;
    return (0.12 + (s / 18.0) * 0.83).clamp(0.12, 0.95);
  }

  /// Reusable try-on submission and polling engine
  Future<void> _runTryOn({required String garmentUrl, required String userPhotoUrl}) async {
    setState(() {
      _isProcessing = true;
      _activeStep = 2;
      _showOriginalPhoto = false;
    });
    _startProcessingTimer();

    List<String> aiResults = [];
    try {
      final res = await http.post(
        Uri.parse('https://anregykcgolpgxecfxej.supabase.co/functions/v1/youcam-try-on'),
        headers: {
          'Content-Type': 'application/json',
          'apikey': 'sb_publishable_KzEAI6a7Xvw-Jz-BqPQRRA_mn4iKnou',
          'Authorization': 'Bearer sb_publishable_KzEAI6a7Xvw-Jz-BqPQRRA_mn4iKnou',
        },
        body: jsonEncode({
          'action': 'try-on',
          'src_image_url': userPhotoUrl,
          'garment_image_url': garmentUrl,
          'listing_id': widget.listing['id'],
          'garment_category':
              _category == ExperienceCategory.fashion ? null : 'spatial_placement',
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

        // If asynchronous task_id provided, poll for status up to 25 times (50 seconds)
        final taskId = data is Map ? data['task_id'] : null;
        if (taskId != null && aiResults.isEmpty) {
          for (int poll = 0; poll < 25; poll++) {
            await Future.delayed(const Duration(milliseconds: 2000));
            if (!mounted) break;
            try {
              final pollRes = await http.post(
                Uri.parse('https://anregykcgolpgxecfxej.supabase.co/functions/v1/youcam-try-on'),
                headers: {
                  'Content-Type': 'application/json',
                  'apikey': 'sb_publishable_KzEAI6a7Xvw-Jz-BqPQRRA_mn4iKnou',
                  'Authorization': 'Bearer sb_publishable_KzEAI6a7Xvw-Jz-BqPQRRA_mn4iKnou',
                },
                body: jsonEncode({
                  'action': 'check-status',
                  'task_id': taskId,
                  'garment_image_url': garmentUrl,
                }),
              );
              if (pollRes.statusCode == 200) {
                final pollData = jsonDecode(pollRes.body);
                final status = pollData['status'];
                final resultUrl = pollData['result_url'];
                if (status == 'SUCCESS' && resultUrl != null && resultUrl.toString().isNotEmpty) {
                  aiResults.insert(0, resultUrl.toString());
                  break;
                } else if (status == 'FAILED') {
                  break;
                }
              }
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('[ExperienceSheet] Goobox notice: $e');
    } finally {
      _stopProcessingTimer();
    }

    // If no AI result returned, fallback to product variations
    if (aiResults.isEmpty) {
      final images = _extractImages();
      aiResults.addAll(images);
    }

    if (mounted) {
      setState(() {
        if (aiResults.isNotEmpty) {
          _aiResultImages = aiResults;
          _selectedResultIndex = 0;
        }
        _isProcessing = false;
        _activeStep = 3;
      });
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

      final images = _extractImages();
      final garmentUrl = images.isNotEmpty
          ? images[_selectedVariantIndex.clamp(0, images.length - 1)]
          : '';
      final uploadedStorageUrl = await _uploadUserPhoto(file);
      _uploadedStorageUrl = uploadedStorageUrl;

      if (garmentUrl.isNotEmpty && uploadedStorageUrl != null) {
        await _runTryOn(garmentUrl: garmentUrl, userPhotoUrl: uploadedStorageUrl);
      } else {
        setState(() => _isProcessing = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not prepare photo or garment for try-on.')),
          );
        }
      }
    } catch (e) {
      _stopProcessingTimer();
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load image: $e')),
        );
      }
    }
  }

  void _openFullScreenViewer({
    required BuildContext context,
    required String imageUrl,
    File? localFile,
    required String title,
    bool isAi = false,
  }) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.94),
      builder: (ctx) => Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4.5,
              clipBehavior: Clip.none,
              child: localFile != null
                  ? Image.file(localFile, fit: BoxFit.contain)
                  : Image.network(
                      imageUrl,
                      fit: BoxFit.contain,
                      loadingBuilder: (c, child, progress) {
                        if (progress == null) return child;
                        return const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF00E5FF),
                            strokeWidth: 2,
                          ),
                        );
                      },
                      errorBuilder: (_, __, ___) => const Center(
                        child: Icon(Icons.broken_image, color: Colors.white24, size: 48),
                      ),
                    ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(ctx).padding.top + 14,
            left: 16,
            right: 16,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isAi
                          ? const Color(0xFF00E5FF).withValues(alpha: 0.5)
                          : Colors.white24,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isAi ? Icons.auto_awesome : Icons.person,
                        color: isAi ? const Color(0xFF00E5FF) : Colors.white70,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isAi ? 'AI Virtual Fit' : 'Original Photo',
                        style: dm(
                          sz: 11,
                          w: FontWeight.w700,
                          c: isAi ? const Color(0xFF00E5FF) : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Icon(Icons.close, color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: MediaQuery.of(ctx).padding.bottom + 18,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.pinch, color: Color(0xFF00E5FF), size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'Pinch to zoom • Drag to pan details',
                      style: dm(sz: 11, c: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _shareLook(String url, String title) {
    Share.share(
      'Check out how "$title" looks on me with NECXA Experience AI try-on!\n$url',
    );
  }

  String? _uploadedStorageUrl;

  @override
  void dispose() {
    _stopProcessingTimer();
    // Privacy-first ephemeral cleanup: Purge temporary uploaded try-on image
    if (_uploadedStorageUrl != null) {
      try {
        final uri = Uri.parse(_uploadedStorageUrl!);
        final parts = uri.pathSegments;
        if (parts.isNotEmpty) {
          final fileName = parts.last;
          Supabase.instance.client.storage
              .from('user-tryons')
              .remove([fileName]).catchError((_) => <FileObject>[]);
        }
      } catch (_) {}
    }
    super.dispose();
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
                      children: const [
                        Icon(Icons.stars_rounded,
                            color: Color(0xFF00E5FF), size: 18),
                        SizedBox(height: 2),
                        Icon(Icons.stars_rounded,
                            color: Color(0xFF00E5FF), size: 14),
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
                            _categorySubtitle,
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
                      _stepPill(1, _step1Label),
                      const Icon(Icons.chevron_right,
                          color: Colors.white24, size: 16),
                      _stepPill(2, _step2Label),
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
                                  // Main image card + vertical variant thumbnail column side-by-side
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // Main preview card (Interactive tap to zoom + Before/After toggle)
                                      Expanded(
                                        child: GestureDetector(
                                          onTap: () {
                                            if (_isProcessing) return;
                                            if (_showOriginalPhoto && _selectedUserPhoto != null) {
                                              _openFullScreenViewer(
                                                context: context,
                                                imageUrl: '',
                                                localFile: File(_selectedUserPhoto!.path),
                                                title: title,
                                                isAi: false,
                                              );
                                            } else if (mainImg.isNotEmpty) {
                                              _openFullScreenViewer(
                                                context: context,
                                                imageUrl: mainImg,
                                                title: title,
                                                isAi: (_activeStep == 3 && _aiResultImages.isNotEmpty),
                                              );
                                            }
                                          },
                                          child: Container(
                                            height: 190,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF0A1324),
                                              borderRadius: BorderRadius.circular(14),
                                              border: Border.all(
                                                color: (_activeStep == 3 && _aiResultImages.isNotEmpty)
                                                    ? const Color(0xFF00E5FF).withValues(alpha: 0.7)
                                                    : Colors.white10,
                                                width: (_activeStep == 3 && _aiResultImages.isNotEmpty) ? 1.5 : 1.0,
                                              ),
                                            ),
                                            child: ClipRRect(
                                              borderRadius: BorderRadius.circular(13),
                                              child: Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  // Main display: Original photo or Spatial Room/Desk Placement or AI Try-On result or Product garment
                                                  if (_showOriginalPhoto && _selectedUserPhoto != null)
                                                    Image.file(
                                                      File(_selectedUserPhoto!.path),
                                                      fit: BoxFit.cover,
                                                    )
                                                  else if (_category != ExperienceCategory.fashion &&
                                                      _activeStep == 3 &&
                                                      _selectedUserPhoto != null)
                                                    // ── Interactive Spatial Room / Desk Placement Mode ──
                                                    Stack(
                                                      fit: StackFit.expand,
                                                      children: [
                                                        // Background: Room / Desk photo taken or uploaded by shopper
                                                        Image.file(
                                                          File(_selectedUserPhoto!.path),
                                                          fit: BoxFit.cover,
                                                        ),
                                                        // Draggable & Scalable product composited into room
                                                        Center(
                                                          child: Transform.translate(
                                                            offset: _spatialPosition,
                                                            child: Transform.scale(
                                                              scale: _spatialScale,
                                                              child: GestureDetector(
                                                                onPanUpdate: (details) {
                                                                  setState(() {
                                                                    _spatialPosition += details.delta;
                                                                  });
                                                                },
                                                                child: Container(
                                                                  decoration: BoxDecoration(
                                                                    boxShadow: [
                                                                      BoxShadow(
                                                                        color: Colors.black.withValues(alpha: 0.5),
                                                                        blurRadius: 18,
                                                                        offset: const Offset(0, 8),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                  child: ClipRRect(
                                                                    borderRadius: BorderRadius.circular(8),
                                                                    child: Image.network(
                                                                      images.isNotEmpty
                                                                          ? images[_selectedVariantIndex.clamp(0, images.length - 1)]
                                                                          : mainImg,
                                                                      width: 110,
                                                                      height: 110,
                                                                      fit: BoxFit.contain,
                                                                      errorBuilder: (_, __, ___) => const Icon(
                                                                        Icons.checkroom_outlined,
                                                                        color: Colors.white24,
                                                                        size: 36,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        // Floating pan helper badge
                                                        Positioned(
                                                          bottom: 8,
                                                          left: 8,
                                                          child: Container(
                                                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                                            decoration: BoxDecoration(
                                                              color: Colors.black.withValues(alpha: 0.75),
                                                              borderRadius: BorderRadius.circular(12),
                                                              border: Border.all(color: Colors.white12),
                                                            ),
                                                            child: Row(
                                                              mainAxisSize: MainAxisSize.min,
                                                              children: [
                                                                const Icon(Icons.touch_app, color: Color(0xFF00E5FF), size: 10),
                                                                const SizedBox(width: 4),
                                                                Text('Drag to place', style: dm(sz: 9, c: Colors.white70)),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                        // Scale buttons [-] [+]
                                                        Positioned(
                                                          bottom: 8,
                                                          right: 8,
                                                          child: Container(
                                                            decoration: BoxDecoration(
                                                              color: Colors.black.withValues(alpha: 0.75),
                                                              borderRadius: BorderRadius.circular(16),
                                                              border: Border.all(color: Colors.white12),
                                                            ),
                                                            child: Row(
                                                              mainAxisSize: MainAxisSize.min,
                                                              children: [
                                                                GestureDetector(
                                                                  onTap: () {
                                                                    setState(() {
                                                                      _spatialScale = (_spatialScale - 0.15).clamp(0.4, 2.5);
                                                                    });
                                                                  },
                                                                  child: const Padding(
                                                                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                                                    child: Icon(Icons.remove, color: Colors.white, size: 14),
                                                                  ),
                                                                ),
                                                                Text(
                                                                  '${(_spatialScale * 100).toInt()}%',
                                                                  style: dm(sz: 9, w: FontWeight.w700, c: const Color(0xFF00E5FF)),
                                                                ),
                                                                GestureDetector(
                                                                  onTap: () {
                                                                    setState(() {
                                                                      _spatialScale = (_spatialScale + 0.15).clamp(0.4, 2.5);
                                                                    });
                                                                  },
                                                                  child: const Padding(
                                                                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                                                    child: Icon(Icons.add, color: Colors.white, size: 14),
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    )
                                                  else if (mainImg.isNotEmpty)
                                                    Image.network(
                                                      mainImg,
                                                      fit: BoxFit.cover,
                                                      errorBuilder: (_, __, ___) => const Icon(
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

                                                  // Floating Before/After toggle pill (top-left)
                                                  if (_activeStep == 3 &&
                                                      (_aiResultImages.isNotEmpty || _category != ExperienceCategory.fashion) &&
                                                      _selectedUserPhoto != null)
                                                    Positioned(
                                                      top: 8,
                                                      left: 8,
                                                      child: GestureDetector(
                                                        onTap: () => setState(() => _showOriginalPhoto = !_showOriginalPhoto),
                                                        child: Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                          decoration: BoxDecoration(
                                                            color: Colors.black.withValues(alpha: 0.8),
                                                            borderRadius: BorderRadius.circular(20),
                                                            border: Border.all(
                                                              color: _showOriginalPhoto
                                                                  ? Colors.white60
                                                                  : const Color(0xFF00E5FF),
                                                              width: 1.2,
                                                            ),
                                                          ),
                                                          child: Row(
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              Icon(
                                                                _showOriginalPhoto ? Icons.visibility_outlined : Icons.auto_awesome,
                                                                size: 11,
                                                                color: _showOriginalPhoto
                                                                    ? Colors.white
                                                                    : const Color(0xFF00E5FF),
                                                              ),
                                                              const SizedBox(width: 4),
                                                              Text(
                                                                _showOriginalPhoto ? _beforePillLabel : _afterPillLabel,
                                                                style: dm(
                                                                  sz: 9.5,
                                                                  w: FontWeight.w700,
                                                                  c: _showOriginalPhoto
                                                                      ? Colors.white
                                                                      : const Color(0xFF00E5FF),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ),

                                                  // Floating Zoom icon button (top-right)
                                                  if (!_isProcessing && (_selectedUserPhoto != null || mainImg.isNotEmpty))
                                                    Positioned(
                                                      top: 8,
                                                      right: 8,
                                                      child: Container(
                                                        padding: const EdgeInsets.all(5),
                                                        decoration: BoxDecoration(
                                                          color: Colors.black.withValues(alpha: 0.7),
                                                          shape: BoxShape.circle,
                                                          border: Border.all(color: Colors.white24),
                                                        ),
                                                        child: const Icon(Icons.fullscreen, color: Colors.white, size: 15),
                                                      ),
                                                    ),

                                                  // Multi-Stage AI-Processing Overlay with animated progress
                                                  if (_isProcessing)
                                                    Container(
                                                      color: Colors.black.withValues(alpha: 0.85),
                                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                                      child: Column(
                                                        mainAxisAlignment: MainAxisAlignment.center,
                                                        children: [
                                                          SizedBox(
                                                            width: 42,
                                                            height: 42,
                                                            child: Stack(
                                                              fit: StackFit.expand,
                                                              children: [
                                                                CircularProgressIndicator(
                                                                  value: _getProcessingStageProgress(_processingSeconds),
                                                                  strokeWidth: 3,
                                                                  backgroundColor: Colors.white12,
                                                                  color: const Color(0xFF00E5FF),
                                                                ),
                                                                const Center(
                                                                  child: Icon(Icons.auto_awesome, size: 18, color: Color(0xFF00E5FF)),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                          const SizedBox(height: 10),
                                                          Text(
                                                            _getProcessingStageText(_processingSeconds),
                                                            textAlign: TextAlign.center,
                                                            style: dm(sz: 10.5, w: FontWeight.w700, c: const Color(0xFF00E5FF)),
                                                          ),
                                                          const SizedBox(height: 4),
                                                          Text(
                                                            '${_processingSeconds}s elapsed',
                                                            style: dm(sz: 9.5, c: Colors.white54),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),

                                      // Vertical variant thumbnails to the right of the main image
                                      if (images.length > 1) ...[
                                        const SizedBox(width: 8),
                                        SizedBox(
                                          width: 48,
                                          height: 190,
                                          child: ListView.separated(
                                            padding: EdgeInsets.zero,
                                            physics: const NeverScrollableScrollPhysics(),
                                            itemCount: images.length > 3 ? 3 : images.length,
                                            separatorBuilder: (_, __) =>
                                                const SizedBox(height: 8),
                                            itemBuilder: (_, idx) {
                                              final sel =
                                                  idx == _selectedVariantIndex;
                                              return GestureDetector(
                                                onTap: () {
                                                  setState(() {
                                                    _selectedVariantIndex = idx;
                                                    _showOriginalPhoto = false;
                                                  });
                                                },
                                                child: Container(
                                                  height: 54,
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
                                    ],
                                  ),

                                  // 1-Tap Variant Try-On Button (if photo is uploaded & multi variants exist)
                                  if (images.length > 1 && _uploadedStorageUrl != null && !_isProcessing) ...[
                                    const SizedBox(height: 8),
                                    GestureDetector(
                                      onTap: () {
                                        final selGarment = images[_selectedVariantIndex.clamp(0, images.length - 1)];
                                        _runTryOn(garmentUrl: selGarment, userPhotoUrl: _uploadedStorageUrl!);
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.35)),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.auto_awesome, size: 12, color: Color(0xFF00E5FF)),
                                            const SizedBox(width: 5),
                                            Text(
                                              'Try this color on you',
                                              style: dm(sz: 10, w: FontWeight.w700, c: const Color(0xFF00E5FF)),
                                            ),
                                          ],
                                        ),
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

                                  // User photo thumbnail + Change photo button
                                  if (_selectedUserPhoto != null) ...[
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          child: Image.file(
                                            File(_selectedUserPhoto!.path),
                                            width: 36,
                                            height: 36,
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                _photoBadgeLabel,
                                                style: dm(
                                                    sz: 10,
                                                    c: const Color(0xFF8A9AB2)),
                                              ),
                                              GestureDetector(
                                                onTap: _isProcessing
                                                    ? null
                                                    : () => _pickImage(ImageSource.gallery),
                                                child: Text(
                                                  'Change photo',
                                                  style: dm(
                                                    sz: 10,
                                                    w: FontWeight.w700,
                                                    c: const Color(0xFF00E5FF),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
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
                            _experienceSectionTitle,
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
                              child: Text(_resultsBadgeLabel,
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
                                    Text(_getProcessingStageText(_processingSeconds),
                                        style: dm(
                                            sz: 11,
                                            c: const Color(0xFF00E5FF))),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
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
                                    onTap: () => setState(() {
                                      _selectedResultIndex = i;
                                      _showOriginalPhoto = false;
                                    }),
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

              // ── Sticky Bottom Commerce Bar (Share + Add to Bag + Buy Now) ──────
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
                    // Share look button (visible when AI result is available)
                    if (_activeStep == 3 && _aiResultImages.isNotEmpty) ...[
                      GestureDetector(
                        onTap: () {
                          final shareImg = _aiResultImages[_selectedResultIndex.clamp(0, _aiResultImages.length - 1)];
                          _shareLook(shareImg, title);
                        },
                        child: Container(
                          padding: const EdgeInsets.all(11),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white12),
                          ),
                          child: const Icon(Icons.share_outlined,
                              color: Color(0xFF00E5FF), size: 18),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],

                    // Add to Bag Button
                    Expanded(
                      flex: 4,
                      child: GestureDetector(
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Row(
                                children: [
                                  const Icon(Icons.check_circle, color: Color(0xFF00E5FF), size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Added $title to bag 🛍️',
                                      style: dm(sz: 12, c: Colors.white),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              backgroundColor: const Color(0xFF0A1324),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: BorderSide(color: const Color(0xFF00E5FF).withValues(alpha: 0.3)),
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0A1324),
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.shopping_bag_outlined, color: Colors.white, size: 15),
                              const SizedBox(width: 6),
                              Text('Add to Bag',
                                  style: syne(
                                      sz: 12,
                                      w: FontWeight.w700,
                                      c: Colors.white)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),

                    // Buy Now Button
                    Expanded(
                      flex: 5,
                      child: GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          widget.onBuyNow();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 13),
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
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.flash_on,
                                  color: Colors.black, size: 16),
                              const SizedBox(width: 4),
                              Text('Buy Now',
                                  style: syne(
                                      sz: 13,
                                      w: FontWeight.w900,
                                      c: Colors.black)),
                            ],
                          ),
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
                    Text(_pickerTitle,
                        style: syne(
                            sz: 12, w: FontWeight.w700, c: Colors.white)),
                    Text(_pickerDesc,
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
                  Text(_uploadButtonLabel,
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
                  Text(_cameraButtonLabel,
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
                    ..._pickerTips.map((tip) => _tip(tip)),
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
