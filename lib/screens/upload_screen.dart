import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import '../theme.dart';
import 'pro_media_editor_screen.dart';
import 'responsive_media_editor.dart';
import '../widgets/campaign_ui_kit.dart';
import '../utils/content_sanitizer.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'necxa_camera_capture_screen.dart';
import '../main.dart' show cameras;
import '../app_state.dart';
import '../models/music_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../services/media_compression_service.dart';
import '../services/editor_export_service.dart';
import '../services/ai_service.dart';
import '../utils/error_handler.dart';

// ══════════════════════════════════════════════════════════════
// CREATOR TYPE ENUM
// ══════════════════════════════════════════════════════════════
enum CreatorType {
  unified, // 🎭  Automatic Content Selector (Photo/Video/Music)
  artist, // 👨‍🎤  Artist Hub (Visual mood + beat track)
  audio, // 🎙️  Podcast & Voice (Simplified audio-first)
}

extension CreatorTypeX on CreatorType {
  String get label {
    switch (this) {
      case CreatorType.unified:
        return 'Create';
      case CreatorType.artist:
        return 'Artist Hub';
      case CreatorType.audio:
        return 'Voice & Music';
    }
  }

  String get subtitle {
    switch (this) {
      case CreatorType.unified:
        return 'Automatic selector for photos, videos, and music';
      case CreatorType.artist:
        return 'Select visual mood · Add your own beat';
      case CreatorType.audio:
        return 'Record or upload your next hit or podcast';
    }
  }

  String get emoji {
    switch (this) {
      case CreatorType.unified:
        return '✨';
      case CreatorType.artist:
        return '👨‍🎤';
      case CreatorType.audio:
        return '🎙️';
    }
  }

  bool get hasMusicLayer => true;
  bool get hasAudio => true;
  bool get isArtist => this == CreatorType.artist;
  bool get isUnified => this == CreatorType.unified;
}

// ══════════════════════════════════════════════════════════════
// UPLOAD SCREEN
// ══════════════════════════════════════════════════════════════
class UploadScreen extends StatefulWidget {
  final AppState state;
  final MusicTrack? initialTrack;
  const UploadScreen({super.key, required this.state, this.initialTrack});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen>
    with TickerProviderStateMixin {
  // ── Navigation ──────────────────────────────────────────────
  // NEW Campaign Hierarchy
  // Step 0: Goal Selection
  // Step 1: Setup (Budget/Target/Category)
  // Step 2: Creative (Film Hub)
  // Step 3: Review & Publish
  int _step = 0;
  String? _objectiveId; // awareness, conversion, sales

  // ── Creative Metadata ───────────────────────────────────────
  MusicTrack? _bakedTrack;
  File? _visualFile;
  List<File> _multiFiles = [];
  final List<File> _productPhotos = []; // 📸 Miniature product photos for Sales
  bool _isVideo = false;
  File? _preparedThumbnailFile;
  Map<String, dynamic>? _aiVerification;
  bool _visualAlreadyCompressed = false;
  List<File>? _preparedVisualFiles;
  Map<String, dynamic>? _uploadedMediaCache;

  // -- Audio / Recording --
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  File? _audioFile;
  Timer? _recTimer;

  // -- Artist Hub --
  File? _beatCoverFile;
  File? _artistArtFile;

  // -- Layers --
  List<Map<String, dynamic>> _overlays = [];
  File? _voiceOverFile;
  final Map<int, double> _startOffsets = {};
  final Map<int, double> _endOffsets = {};

  // ── Setup Metadata ──────────────────────────────────────────
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _tagsController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _skuController = TextEditingController();
  final TextEditingController _stockController = TextEditingController();
  final TextEditingController _weightController = TextEditingController();
  final TextEditingController _lengthController = TextEditingController();
  final TextEditingController _widthController = TextEditingController();
  final TextEditingController _heightController = TextEditingController();

  String _title = '';
  String _desc = '';
  String _tags = '';
  final String _category = 'Standard';
  String _price = '';
  String _sku = '';
  String _stock = '';
  Map<String, dynamic>? _linkedListing;
  double? _pickupLatitude;
  double? _pickupLongitude;

  // ── Sync State ──────────────────────────────────────────────
  bool _isOptimizing = false;
  String _optimizingStatus = "";
  bool _agreedToPolicies = false;

  @override
  void initState() {
    super.initState();
    _bakedTrack = widget.initialTrack;
    if (_bakedTrack != null) {
      _title = _bakedTrack!.title;
      _titleController.text = _title;
    }

    _titleController.addListener(() => _title = _titleController.text);
    _descController.addListener(() => _desc = _descController.text);
    _tagsController.addListener(() => _tags = _tagsController.text);
    _priceController.addListener(() => _price = _priceController.text);
    _skuController.addListener(() => _sku = _skuController.text);
    _stockController.addListener(() => _stock = _stockController.text);
  }

  @override
  void dispose() {
    _recTimer?.cancel();
    _recorder.dispose();
    _player.dispose();
    _titleController.dispose();
    _descController.dispose();
    _tagsController.dispose();
    _priceController.dispose();
    _skuController.dispose();
    _stockController.dispose();
    _weightController.dispose();
    _lengthController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────
  void _err(String m) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(m), backgroundColor: C.red));

  List<String> _cleanTags(String raw) =>
      ContentSanitizer.generateUnifiedTagPayload(raw, _desc);

  Future<void> _capturePickupLocation() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied)
      permission = await Geolocator.requestPermission();
    if (permission != LocationPermission.whileInUse &&
        permission != LocationPermission.always) {
      _err('Pickup location permission is required for delivery pricing');
      return;
    }
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    if (!mounted) return;
    setState(() {
      _pickupLatitude = position.latitude;
      _pickupLongitude = position.longitude;
    });
  }

  // ── Media pickers ─────────────────────────────────────────────
  Future<void> _processResult(
    XFile? f,
    bool isVideo, {
    bool isFastSync = false,
  }) async {
    if (f == null) {
      return;
    }
    final file = File(f.path);
    if (!mounted) return;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ResponsiveMediaEditor(
          state: widget.state,
          initialImage: isVideo ? null : file,
          initialVideo: isVideo ? file : null,
          initialTrack: _bakedTrack,
          multiFiles: _multiFiles,
          isFastSync: isFastSync,
        ),
      ),
    );

    if (result is EditorExportResult && result.success) {
      final outputPath = result.outputPath;
      if (outputPath == null || outputPath.isEmpty) {
        _err('The verified export did not contain a publishable video');
        return;
      }
      final preparedVideo = File(outputPath);
      if (!await preparedVideo.exists()) {
        _err(
          'The verified export is no longer available. Please export again.',
        );
        return;
      }
      final thumbnailPath = result.thumbnailPath;
      final preparedThumbnail = thumbnailPath == null
          ? null
          : File(thumbnailPath);
      if (preparedThumbnail != null && !await preparedThumbnail.exists()) {
        _err(
          'The verified thumbnail is no longer available. Please export again.',
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _visualFile = preparedVideo;
        _multiFiles = [];
        _isVideo = true;
        _preparedThumbnailFile = preparedThumbnail;
        _aiVerification = {
          ...result.verificationPayload,
          'verified': true,
          'source': 'mobile_editor',
        };
        _visualAlreadyCompressed = true;
        _preparedVisualFiles = [preparedVideo];
        _uploadedMediaCache = null;
        _step = 3;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verified. Ready to publish.')),
      );
      return;
    }

    if (result is Map) {
      final List? sequence = result['sequence'];
      final File? combinedFile = result['combined_file'];
      final File? enhanced =
          combinedFile ??
          (sequence != null && sequence.isNotEmpty
              ? (sequence.first as VideoClip).file
              : null);
      final MusicTrack? track = result['track'];

      if (sequence != null && sequence.isNotEmpty) {
        setState(() {
          if (combinedFile != null) {
            // A flattened desktop timeline is one final publishable video.
            _multiFiles = [];
          } else if (sequence.first is VideoClip) {
            _multiFiles = (sequence as List<VideoClip>)
                .map((c) => c.file)
                .toList();
          } else {
            _multiFiles = sequence as List<File>;
          }
        });
      }

      if (enhanced != null || (sequence != null && sequence.isNotEmpty)) {
        setState(() {
          _visualFile = enhanced;
          _isVideo = enhanced?.path.toLowerCase().endsWith('.mp4') ?? isVideo;
          _bakedTrack = track;
          _overlays = result['overlays'] ?? [];
          _voiceOverFile = result['voice_over'];
          _preparedThumbnailFile = null;
          _aiVerification = null;
          _visualAlreadyCompressed = false;
          _preparedVisualFiles = null;
          _uploadedMediaCache = null;
          if (track != null && (_title.isEmpty || _title == 'Original Sound')) {
            _title = track.title;
            _titleController.text = _title;
          }
          _step = 3; // 🚀 JUMP straight to Final Review (Step 3)
        });
      }
    }
  }

  Future<void> _pickUnifiedMedia() async {
    // 🎭 TikTok Style: Pick multiple media (Images & Videos)
    final res = await ImagePicker().pickMultipleMedia();
    if (res.isNotEmpty) {
      setState(() {
        _multiFiles = res.map((x) => File(x.path)).toList();
        _visualFile = _multiFiles.first;
        _isVideo =
            _visualFile!.path.toLowerCase().endsWith('.mp4') ||
            _visualFile!.path.toLowerCase().endsWith('.mov');
      });
      await _processResult(res.first, _isVideo);
    }
  }

  Future<void> _captureMedia() async {
    if (cameras.isEmpty) {
      _err('No cameras detected on this device');
      return;
    }

    final dynamic result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NecxaCameraCaptureScreen(cameras: cameras),
      ),
    );

    if (result == 'OPEN_GALLERY') {
      _pickUnifiedMedia();
    } else if (result is File) {
      _processResult(XFile(result.path), true);
    } else if (result is List<File>) {
      setState(() {
        _multiFiles = [..._multiFiles, ...result];
        _visualFile = _multiFiles.first;
        _isVideo = true;
      });
      _processResult(XFile(_multiFiles.first.path), true);
    }
  }

  // ── Step navigation ────────────────────────────────────────────
  void _next() {
    if (_step == 0) {
      if (_objectiveId == null) {
        _err('Select an objective to continue');
        return;
      }
    }
    if (_step == 1) {
      if (_title.isEmpty) {
        _err('Headline is required');
        return;
      }
      if (_objectiveId == 'sales' && _price.isEmpty) {
        _err('Price is required for sales');
        return;
      }
      if (_objectiveId == 'sales' &&
          !RegExp(r'^\d{4}[A-Za-z]{3}$').hasMatch(_sku.trim())) {
        _err(
          'SKU is required and must contain 4 digits followed by 3 letters (example: 1234ABC)',
        );
        return;
      }
      if (_objectiveId == 'sales' &&
          (double.tryParse(_weightController.text) == null ||
              double.tryParse(_lengthController.text) == null ||
              double.tryParse(_widthController.text) == null ||
              double.tryParse(_heightController.text) == null)) {
        _err('Product weight and all package dimensions are required');
        return;
      }
      if (_objectiveId == 'sales' &&
          (_pickupLatitude == null || _pickupLongitude == null)) {
        _err('Pin the product pickup location before continuing');
        return;
      }
    }
    if (_step == 2) {
      if (_multiFiles.isEmpty && _visualFile == null) {
        _err('Assets are required for this campaign');
        return;
      }
    }
    if (_step == 3) {
      if (!_agreedToPolicies) {
        _err('Please agree to Necxa policies');
        return;
      }
      _publishPost();
      return;
    }

    setState(() => _step++);
  }

  Future<void> _publishPost() async {
    setState(() => _step = 99);
    try {
      if (_objectiveId == 'sales') {
        await _dispatchSalesCampaign();
      } else if (_objectiveId == 'conversion') {
        await _dispatchArtistCampaign();
      } else {
        await _dispatchSocialCampaign();
      }

      // Cleanup compression cache
      await VideoCompress.deleteAllCache();

      // 🚀 NEURAL DESTINATION WARP: Teleport user to where their content lives
      final destinationTab = (_objectiveId == 'sales') ? 'shop' : 'feed';
      final successMsg = (_objectiveId == 'sales')
          ? '🛍️ Your product is LIVE in the Shop!'
          : (_objectiveId == 'conversion')
          ? '🎵 Your release is LIVE in the Feed!'
          : '⚡ Your post is LIVE in the Feed!';

      _onShareSuccess(successMsg, destinationTab: destinationTab);
    } catch (e) {
      debugPrint('Upload error: $e');
      if (mounted) {
        setState(() {
          _step = 3;
          _isOptimizing = false;
        });
      }
      _err(getUserFriendlyError(e));
    } finally {
      if (mounted) setState(() => _isOptimizing = false);
    }
  }

  bool _isVideoFile(File file) {
    final path = file.path.toLowerCase();
    return path.endsWith('.mp4') ||
        path.endsWith('.mov') ||
        path.endsWith('.avi') ||
        path.endsWith('.m4v');
  }

  Future<Map<String, dynamic>> _verifyFileForPublishing(File file) async {
    Map<String, dynamic> report;
    if (_isVideoFile(file)) {
      final frameDirectory = await Directory.systemTemp.createTemp(
        'necxa_publish_frames_',
      );
      try {
        final frames = await NecxaAI.extractVideoFrameFiles(
          file,
          directory: frameDirectory,
        );
        if (frames.isEmpty) {
          throw Exception('Could not extract video frames for verification');
        }
        report = await NecxaAI.verifyVideoWorker(frames);
      } finally {
        try {
          await frameDirectory.delete(recursive: true);
        } catch (_) {}
      }
    } else {
      report = await NecxaAI.verifyPhotoWorker(file);
    }

    if (report['success'] == false) {
      throw Exception(
        report['error']?.toString() ??
            'AI verification is temporarily unavailable. Please try again.',
      );
    }
    final result = report['result'];
    final verified =
        NecxaAI.moderationVerified(report) ||
        report['verified'] == true ||
        report['safe'] == true ||
        (result is Map && result['verified'] == true);
    if (!verified) {
      throw Exception('AI verification flagged this media for review');
    }
    return {...report, 'verified': true};
  }

  Future<void> _ensureVisualVerification(List<File> files) async {
    if (_aiVerification?['verified'] == true) return;
    if (files.isEmpty) {
      throw Exception('No media is available for verification');
    }

    setState(() => _optimizingStatus = 'Running AI verification...');
    final reports = <Map<String, dynamic>>[];
    for (var index = 0; index < files.length; index++) {
      if (files.length > 1) {
        setState(
          () => _optimizingStatus =
              'Verifying asset ${index + 1} of ${files.length}...',
        );
      }
      reports.add(await _verifyFileForPublishing(files[index]));
    }
    _aiVerification = reports.length == 1
        ? reports.single
        : {
            'success': true,
            'verified': true,
            'assets': reports,
            'source': 'upload_screen',
          };
  }

  Future<Map<String, dynamic>> _uploadRequired(
    File file, {
    String bucket = 'community-media',
    String assetType = 'generic',
  }) async {
    final result = await widget.state.cloud.uploadMedia(
      file,
      bucket: bucket,
      assetType: assetType,
    );
    final url = result?['url']?.toString();
    if (result == null || url == null || url.isEmpty) {
      throw Exception(
        'Media upload failed. Your verified export was kept for retry.',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> _optimizeMediaAssets() async {
    final cached = _uploadedMediaCache;
    if (cached != null) return Map<String, dynamic>.from(cached);

    String? visualUrl;
    List<String> multiUrls = [];
    String? mediaType;
    String? thumbUrl;

    if (_multiFiles.length > 1) {
      setState(() => _isOptimizing = true);
      final optimizedFiles = <File>[];

      final preparedFiles = _preparedVisualFiles;
      if (preparedFiles != null &&
          preparedFiles.length == _multiFiles.length &&
          preparedFiles.every((file) => file.existsSync())) {
        optimizedFiles.addAll(preparedFiles);
      } else {
        if (preparedFiles != null) _aiVerification = null;
        for (var index = 0; index < _multiFiles.length; index++) {
          final file = _multiFiles[index];
          if (_isVideoFile(file)) {
            setState(
              () => _optimizingStatus =
                  'Optimizing clip ${index + 1} of ${_multiFiles.length}...',
            );
            optimizedFiles.add(
              await MediaCompressionService.compressVideo(file),
            );
          } else {
            setState(
              () => _optimizingStatus =
                  'Compressing photo ${index + 1} of ${_multiFiles.length}...',
            );
            optimizedFiles.add(
              await MediaCompressionService.compressImage(file),
            );
          }
        }
        _preparedVisualFiles = List<File>.from(optimizedFiles);
      }

      // All optimized files are verified before any cloud upload begins.
      await _ensureVisualVerification(optimizedFiles);
      setState(() => _optimizingStatus = 'Uploading verified media...');
      multiUrls = await widget.state.cloud.uploadMultiMedia(
        optimizedFiles,
        bucket: 'community-media',
      );
      if (multiUrls.length != optimizedFiles.length) {
        throw Exception('One or more media files failed to upload');
      }
      visualUrl = multiUrls.first;
      mediaType = _isVideo ? 'video' : 'gallery';

      final firstFile = optimizedFiles.first;
      if (_isVideoFile(firstFile)) {
        setState(() => _optimizingStatus = 'Uploading cover photo...');
        final thumbPath = await VideoThumbnail.thumbnailFile(
          video: firstFile.path,
          thumbnailPath: (await getTemporaryDirectory()).path,
          imageFormat: ImageFormat.JPEG,
          quality: 40,
        );
        if (thumbPath == null) {
          throw Exception('Could not create the video cover photo');
        }
        thumbUrl = (await _uploadRequired(File(thumbPath)))['url'] as String;
      } else {
        thumbUrl = visualUrl;
      }
    } else if (_isVideo && _visualFile != null) {
      setState(() {
        _isOptimizing = true;
        _optimizingStatus = _visualAlreadyCompressed
            ? 'Preparing verified video...'
            : 'Compressing main video...';
      });

      final preparedFiles = _preparedVisualFiles;
      final hasPreparedVideo =
          preparedFiles != null &&
          preparedFiles.length == 1 &&
          preparedFiles.single.existsSync();
      if (preparedFiles != null && !hasPreparedVideo) {
        _aiVerification = null;
      }
      var visualToUpload = hasPreparedVideo
          ? preparedFiles.single
          : _visualFile!;
      if (!_visualAlreadyCompressed && visualToUpload == _visualFile) {
        visualToUpload = await MediaCompressionService.compressVideo(
          visualToUpload,
        );
        _preparedVisualFiles = [visualToUpload];
      }

      await _ensureVisualVerification([visualToUpload]);

      var thumbnail = _preparedThumbnailFile;
      if (thumbnail != null && !thumbnail.existsSync()) thumbnail = null;
      if (thumbnail == null) {
        final thumbPath = await VideoThumbnail.thumbnailFile(
          video: visualToUpload.path,
          thumbnailPath: (await getTemporaryDirectory()).path,
          imageFormat: ImageFormat.JPEG,
          quality: 40,
        );
        if (thumbPath == null) {
          throw Exception('Could not create the video cover photo');
        }
        thumbnail = File(thumbPath);
      }

      setState(() => _optimizingStatus = 'Uploading verified video...');
      thumbUrl = (await _uploadRequired(thumbnail))['url'] as String;
      visualUrl = (await _uploadRequired(visualToUpload))['url'] as String;
      mediaType = 'video';
    } else if (_visualFile != null || _multiFiles.isNotEmpty) {
      final source = _visualFile ?? _multiFiles.first;
      setState(() => _optimizingStatus = 'Compressing visual asset...');
      final preparedFiles = _preparedVisualFiles;
      final hasPreparedImage =
          preparedFiles != null &&
          preparedFiles.length == 1 &&
          preparedFiles.single.existsSync();
      if (preparedFiles != null && !hasPreparedImage) {
        _aiVerification = null;
      }
      final compressed = hasPreparedImage
          ? preparedFiles.single
          : _visualAlreadyCompressed
          ? source
          : await MediaCompressionService.compressImage(source);
      _preparedVisualFiles = [compressed];
      await _ensureVisualVerification([compressed]);
      setState(() => _optimizingStatus = 'Uploading verified image...');
      final result = await _uploadRequired(compressed);
      visualUrl = result['url'] as String;
      mediaType = result['media_type'] as String? ?? 'image';
      thumbUrl = visualUrl;
      if (_multiFiles.isNotEmpty) multiUrls = [visualUrl];
    } else {
      throw Exception('No media is available for publishing');
    }

    final completed = <String, dynamic>{
      'visualUrl': visualUrl,
      'multiUrls': multiUrls,
      'mediaType': mediaType,
      'thumbUrl': thumbUrl,
    };
    _uploadedMediaCache = completed;
    return Map<String, dynamic>.from(completed);
  }

  Future<void> _dispatchSalesCampaign() async {
    final userId = widget.state.user?.id;
    if (userId == null || userId.isEmpty) {
      throw Exception('Please sign in before publishing');
    }
    // Prepare and verify every product photo before the first upload begins.
    final compressedProductPhotos = <File>[];
    final productPhotoVerifications = <Map<String, dynamic>>[];
    if (_productPhotos.isNotEmpty) {
      setState(() => _optimizingStatus = "Compressing Product Miniatures...");
      for (int i = 0; i < _productPhotos.length; i++) {
        setState(
          () => _optimizingStatus =
              "Compressing Photo ${i + 1} of ${_productPhotos.length}...",
        );
        final compressed = await MediaCompressionService.compressImage(
          _productPhotos[i],
        );
        compressedProductPhotos.add(compressed);
        setState(
          () => _optimizingStatus =
              'Verifying product photo ${i + 1} of ${_productPhotos.length}...',
        );
        productPhotoVerifications.add(
          await _verifyFileForPublishing(compressed),
        );
      }
    }

    final media = await _optimizeMediaAssets();
    final mediaType = media['mediaType'] as String?;
    var verification = _requiredVerificationReport();
    if (productPhotoVerifications.isNotEmpty) {
      verification = {
        'success': true,
        'verified': true,
        'visual': verification,
        'product_photos': productPhotoVerifications,
      };
      _aiVerification = verification;
    }

    // 🛡️ Upload product photos only after all AI checks have passed.
    List<String> productPhotoUrls = [];
    if (compressedProductPhotos.isNotEmpty) {
      setState(() => _optimizingStatus = "Syncing Product Miniatures...");
      productPhotoUrls = await widget.state.cloud.uploadMultiMedia(
        compressedProductPhotos,
        bucket: 'listing-photos',
      );
      if (productPhotoUrls.length != compressedProductPhotos.length) {
        throw Exception('One or more product photos failed to upload');
      }
    }

    Map<String, dynamic> listing;
    if (_linkedListing != null) {
      // UPDATE EXISTING LISTING
      listing = Map<String, dynamic>.from(
        await Supabase.instance.client
            .from('listings')
            .update({
              'media_url': media['visualUrl'],
              'media_type': mediaType,
              'thumbnail_url': media['thumbUrl'],
              'is_verified': true,
              'ai_verification': verification,
              'photos': productPhotoUrls.isNotEmpty
                  ? productPhotoUrls
                  : (_linkedListing!['photos'] ?? []),
            })
            .eq('id', _linkedListing!['id'])
            .select()
            .single(),
      );
    } else {
      // CREATE NEW LISTING
      listing = await widget.state.social.createListing(userId, {
        'title': _title,
        'description': _desc,
        'price': _price,
        'sku': _sku.trim().toUpperCase(),
        'tags': _cleanTags(_tags),
        'weight_kg': double.parse(_weightController.text),
        'length_cm': double.parse(_lengthController.text),
        'width_cm': double.parse(_widthController.text),
        'height_cm': double.parse(_heightController.text),
        'latitude': _pickupLatitude,
        'longitude': _pickupLongitude,
        'category': _category,
        'media_url': media['visualUrl'], // Film Hub / Video Content
        'thumbnail_url': media['thumbUrl'],
        'media_type': mediaType,
        'type': 'COMMERCIAL',
        'stock_count': _stock.isNotEmpty ? int.tryParse(_stock) ?? 999 : 999,
        'music_track_id': _bakedTrack?.id,
        'audio_url': _bakedTrack?.audioUrl,
        // Strictly separate: photos should only contain product miniatures
        'photos': productPhotoUrls.isNotEmpty ? productPhotoUrls : [],
        'status': 'active',
        'is_verified': true,
        'ai_verification': verification,
      }, aiResult: verification);
    }
    await widget.state.social.logVerification(
      userId,
      'listing',
      verification,
      contentId: listing['id']?.toString(),
    );
  }

  Future<void> _dispatchArtistCampaign() async {
    final userId = widget.state.user?.id;
    if (userId == null || userId.isEmpty) {
      throw Exception('Please sign in before publishing');
    }

    // Optimize and verify before charging the distribution fee.
    final media = await _optimizeMediaAssets();
    final verification = _requiredVerificationReport();
    final visualUrl = media['visualUrl'] as String?;
    final multiUrls = media['multiUrls'] as List<String>;
    final mediaType = media['mediaType'] as String?;
    final thumbUrl = media['thumbUrl'] as String?;

    await widget.state.payment.chargeArtistDistributionFee(userId, 150);
    widget.state.updateCoins(-150);

    // Optimize artist specific art
    String? beatCoverUrl;
    String? artistProfileUrl;
    if (_beatCoverFile != null) {
      final res = await _uploadRequired(
        _beatCoverFile!,
        bucket: 'artist-media',
      );
      beatCoverUrl = res['url'] as String;
    }
    if (_artistArtFile != null) {
      final res = await _uploadRequired(
        _artistArtFile!,
        bucket: 'artist-media',
      );
      artistProfileUrl = res['url'] as String;
    }

    String? audioUrl = _bakedTrack?.audioUrl;
    if (_audioFile != null) {
      final res = await _uploadRequired(
        _audioFile!,
        bucket: 'community-media',
        assetType: 'audio',
      );
      audioUrl = res['url'] as String;
    }

    // Register Media Asset
    String? mediaAssetId;
    if (visualUrl != null) {
      mediaAssetId = await widget.state.social.registerMediaAsset(userId, {
        'asset_type': mediaType == 'video' ? 'original_sound' : 'image_asset',
        'url': audioUrl ?? visualUrl,
        'title': _title,
        'metadata': {
          'visual_url': visualUrl,
          'thumbnail_url': thumbUrl,
          'gallery': multiUrls,
          'is_artist_release': true,
        },
      });
    }

    final post = await widget.state.social.createPost(userId, {
      'title': _title,
      'content': _desc,
      'tags': _cleanTags(_tags),
      'media_url': visualUrl,
      'thumbnail_url': thumbUrl,
      'media_type': mediaType,
      'media_asset_id': mediaAssetId,
      'audio_url': audioUrl,
      'music_track_id': _bakedTrack?.id,
      'creator_mode': 'artist',
      'is_fast_sync': true,
      'gallery_urls': multiUrls,
      'artist_metadata': {
        'beat_cover_url': beatCoverUrl,
        'artist_profile_url': artistProfileUrl,
      },
      'editing_metadata': {
        'objective': 'conversion',
        'layers': _multiFiles.length,
        'has_voice_over': _voiceOverFile != null,
        'text_layers': _overlays.length,
        'overlays': _overlays,
        'start_offsets': _startOffsets,
        'end_offsets': _endOffsets,
      },
      'status': 'verified',
      'is_verified': true,
      'ai_verification': verification,
    });
    await widget.state.social.logVerification(
      userId,
      'post',
      verification,
      contentId: post['id']?.toString(),
    );
  }

  Future<void> _dispatchSocialCampaign() async {
    final userId = widget.state.user?.id;
    if (userId == null || userId.isEmpty) {
      throw Exception('Please sign in before publishing');
    }
    final media = await _optimizeMediaAssets();
    final verification = _requiredVerificationReport();
    final visualUrl = media['visualUrl'] as String?;
    final multiUrls = media['multiUrls'] as List<String>;
    final mediaType = media['mediaType'] as String?;
    final thumbUrl = media['thumbUrl'] as String?;

    String? audioUrl = _bakedTrack?.audioUrl;
    if (_audioFile != null) {
      final res = await _uploadRequired(
        _audioFile!,
        bucket: 'community-media',
        assetType: 'audio',
      );
      audioUrl = res['url'] as String;
    }

    String? mediaAssetId;
    if (visualUrl != null) {
      mediaAssetId = await widget.state.social.registerMediaAsset(userId, {
        'asset_type': mediaType == 'video' ? 'original_sound' : 'image_asset',
        'url': audioUrl ?? visualUrl,
        'title': _title,
        'metadata': {
          'visual_url': visualUrl,
          'thumbnail_url': thumbUrl,
          'gallery': multiUrls,
          'is_artist_release': false,
        },
      });
    }

    final post = await widget.state.social.createPost(userId, {
      'title': _title,
      'content': _desc,
      'tags': _cleanTags(_tags),
      'media_url': visualUrl,
      'thumbnail_url': thumbUrl,
      'media_type': mediaType,
      'media_asset_id': mediaAssetId,
      'audio_url': audioUrl,
      'music_track_id': _bakedTrack?.id,
      'creator_mode': 'unified',
      'is_fast_sync': true,
      'gallery_urls': multiUrls,
      'editing_metadata': {
        'objective': 'awareness',
        'layers': _multiFiles.length,
        'has_voice_over': _voiceOverFile != null,
        'text_layers': _overlays.length,
        'overlays': _overlays,
        'start_offsets': _startOffsets,
        'end_offsets': _endOffsets,
      },
      'status': 'verified',
      'is_verified': true,
      'ai_verification': verification,
    });
    await widget.state.social.logVerification(
      userId,
      'post',
      verification,
      contentId: post['id']?.toString(),
    );
  }

  Map<String, dynamic> _requiredVerificationReport() {
    final report = _aiVerification;
    if (report == null || report['verified'] != true) {
      throw Exception('AI verification must finish before publishing');
    }
    return Map<String, dynamic>.from(report);
  }

  void _onShareSuccess(String msg, {String destinationTab = 'feed'}) {
    if (!mounted) return;

    // 🚀 NEURAL DESTINATION WARP
    // 1. Set the correct community tab BEFORE navigating
    widget.state.setCreatorTab(destinationTab);

    // 2. Navigate to CommunityScreen — user lands directly on their content
    widget.state.go('community');

    // 3. Show a premium confirmation banner
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.check_circle_rounded,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    msg,
                    style: syne(sz: 13, w: FontWeight.bold, c: Colors.white),
                  ),
                  Text(
                    destinationTab == 'shop'
                        ? 'Tap Shop to see your product'
                        : 'Scroll to find your post',
                    style: dm(sz: 11, c: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: destinationTab == 'shop'
            ? const Color(0xFFB8860B) // Gold for shop
            : const Color(0xFF0D7A3E), // Green for feed
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════
  // BUILD
  // ════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    Color accent = _objectiveId == 'sales' ? C.gold : C.brand;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(_getStepTitle(), () {
              if (_step > 0) {
                setState(() => _step--);
              } else {
                widget.state.go('community');
              }
            }, color: accent),

            PremiumStepper(
              currentStep: _step,
              totalSteps: 4,
              accentColor: accent,
            ),

            Expanded(
              child: _step == 99
                  ? _buildLoading()
                  : SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 20,
                      ),
                      child: _buildCurrentStep(),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _step < 99 ? _buildPrimaryAction(accent) : null,
    );
  }

  String _getStepTitle() {
    switch (_step) {
      case 0:
        return 'Select Objective';
      case 1:
        return 'Campaign Setup';
      case 2:
        return 'Film Hub';
      case 3:
        return 'Review & Release';
      default:
        return 'Upload Portal';
    }
  }

  Widget _buildCurrentStep() {
    switch (_step) {
      case 0:
        return _buildObjectiveSelection();
      case 1:
        return _buildSetupStep();
      case 2:
        return _buildCreativeStep();
      case 3:
        return _buildFinalReview();
      default:
        return const SizedBox();
    }
  }

  // ── STEP 0: OBJECTIVE SELECTION ─────────────────────────────
  Widget _buildObjectiveSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CHOOSE YOUR GOAL',
          style: syne(sz: 12, w: FontWeight.w900, c: Colors.white38, ls: 2),
        ),
        const SizedBox(height: 16),
        ObjectiveCard(
          title: 'Awareness',
          subtitle: 'Community contribution & Social synergy',
          icon: Icons.auto_awesome,
          colors: const [Color(0xFF00E5FF), Color(0xFF3B82F6)],
          isSelected: _objectiveId == 'awareness',
          onTap: () => setState(() => _objectiveId = 'awareness'),
        ),
        ObjectiveCard(
          title: 'Conversion',
          subtitle: 'Artist Hub. Digital collectibles & Audio visual releases',
          icon: Icons.library_music,
          colors: const [Color(0xFFA855F7), Color(0xFF7B2FFF)],
          isSelected: _objectiveId == 'conversion',
          onTap: () {
            if (!widget.state.isArtist) {
              widget.state.go('artist_auth');
              return;
            }
            setState(() => _objectiveId = 'conversion');
          },
        ),
        ObjectiveCard(
          title: 'Sales',
          subtitle: 'Catalog-based commerce & Product listings',
          icon: Icons.shopping_bag_outlined,
          colors: const [Color(0xFFF4A228), Color(0xFFEF4444)],
          isSelected: _objectiveId == 'sales',
          onTap: () => setState(() => _objectiveId = 'sales'),
        ),
      ],
    );
  }

  // ── STEP 1: CAMPAIGN SETUP ──────────────────────────────────
  Widget _buildSetupStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CAMPAIGN DETAILS',
          style: syne(sz: 12, w: FontWeight.w900, c: Colors.white38, ls: 2),
        ),
        const SizedBox(height: 24),
        GlassCard(
          child: Column(
            children: [
              if (_objectiveId == 'sales') ...[
                const SizedBox(height: 20),
                if (_linkedListing == null) ...[
                  _buildProductPhotoPicker(),
                  const SizedBox(height: 20),
                ],
                const Divider(color: Colors.white10),
                const SizedBox(height: 20),
              ],
              _inputField(
                'Headline',
                'A catchy title for your content',
                _titleController,
              ),
              const SizedBox(height: 16),
              _inputField(
                'Description',
                'Tell the world more...',
                _descController,
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              _inputField(
                'Hashtags',
                'Type words; # is added automatically',
                _tagsController,
              ),
              if (_objectiveId == 'sales' && _linkedListing == null) ...[
                const SizedBox(height: 16),
                _inputField(
                  'Price (UGX)',
                  'e.g. 25,000',
                  _priceController,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                _inputField(
                  'SKU (Required)',
                  '1234ABC',
                  _skuController,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z]')),
                    LengthLimitingTextInputFormatter(7),
                    _UpperCaseTextFormatter(),
                  ],
                ),
                const SizedBox(height: 16),
                _inputField(
                  'Stock Quantity (Optional)',
                  'Leave empty for infinite, e.g. 10',
                  _stockController,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                _inputField(
                  'Weight (kg)',
                  'e.g. 2.5',
                  _weightController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _inputField(
                        'Length (cm)',
                        '30',
                        _lengthController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _inputField(
                        'Width (cm)',
                        '20',
                        _widthController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _inputField(
                        'Height (cm)',
                        '10',
                        _heightController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _pickupLatitude == null
                        ? Icons.add_location_alt_outlined
                        : Icons.location_on,
                    color: C.brand,
                  ),
                  title: Text(
                    _pickupLatitude == null
                        ? 'Pin pickup location'
                        : 'Pickup location pinned',
                    style: dm(sz: 14, c: Colors.white),
                  ),
                  subtitle: _pickupLatitude == null
                      ? null
                      : Text(
                          '${_pickupLatitude!.toStringAsFixed(5)}, ${_pickupLongitude!.toStringAsFixed(5)}',
                          style: dm(sz: 11, c: Colors.white38),
                        ),
                  onTap: _capturePickupLocation,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProductPhotoPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PRODUCT MINIATURES (MAX 3)',
          style: syne(sz: 10, w: FontWeight.w900, c: Colors.white38, ls: 1.5),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 80,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _productPhotos.length < 3
                ? _productPhotos.length + 1
                : 3,
            itemBuilder: (context, i) {
              if (i == _productPhotos.length && i < 3) {
                return GestureDetector(
                  onTap: _pickProductPhoto,
                  child: Container(
                    width: 80,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(13),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white10,
                        style: BorderStyle.solid,
                      ),
                    ),
                    child: const Icon(
                      Icons.add_a_photo_outlined,
                      color: Colors.white24,
                      size: 24,
                    ),
                  ),
                );
              }
              return Container(
                width: 80,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  image: DecorationImage(
                    image: FileImage(_productPhotos[i]),
                    fit: BoxFit.cover,
                  ),
                  border: Border.all(color: Colors.white10),
                ),
                child: Align(
                  alignment: Alignment.topRight,
                  child: GestureDetector(
                    onTap: () => setState(() => _productPhotos.removeAt(i)),
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _pickProductPhoto() async {
    final ImagePicker picker = ImagePicker();
    final List<XFile> images = await picker.pickMultiImage(
      limit: 3 - _productPhotos.length,
    );
    if (images.isNotEmpty) {
      setState(() {
        _productPhotos.addAll(images.map((x) => File(x.path)));
      });
    }
  }

  // ── STEP 2: FILM HUB ────────────────────────────────────────
  Widget _buildCreativeStep() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'ASSETS',
              style: syne(sz: 12, w: FontWeight.w900, c: Colors.white38, ls: 2),
            ),
            if (_multiFiles.isNotEmpty)
              Text(
                '${_multiFiles.length} TRACKS LOADED',
                style: syne(sz: 10, w: FontWeight.bold, c: C.brand),
              ),
          ],
        ),
        const SizedBox(height: 16),

        // 🚀 LIVE CONTENT CAPTURE BUTTON
        if (_objectiveId == 'awareness')
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: GestureDetector(
              onTap: _captureMedia,
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF0000), Color(0xFF990000)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withAlpha(77),
                      blurRadius: 15,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(
                        color: Colors.white24,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.videocam,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'LIVE CAPTURE',
                            style: syne(
                              sz: 18,
                              w: FontWeight.w900,
                              c: Colors.white,
                            ),
                          ),
                          Text(
                            'Speed · Filters · 4K Mastery',
                            style: dm(sz: 12, c: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward_ios,
                      color: Colors.white,
                      size: 16,
                    ),
                  ],
                ),
              ),
            ),
          ),

        _buildMediaGrid(),
        const SizedBox(height: 24),
        if (_multiFiles.isNotEmpty)
          GestureDetector(
            onTap: () =>
                _processResult(XFile(_multiFiles.first.path), _isVideo),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: C.brand.withAlpha(26),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: C.brand.withAlpha(77)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.movie_filter_outlined,
                    color: C.brand,
                    size: 32,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'OPEN FILM HUB',
                          style: syne(sz: 16, w: FontWeight.w900, c: C.brand),
                        ),
                        Text(
                          'Edit layers, tracks, and timing',
                          style: dm(sz: 11, c: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios, color: C.brand, size: 16),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ── STEP 3: FINAL REVIEW ────────────────────────────────────
  Widget _buildFinalReview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'FINAL SYNTHESIS',
          style: syne(sz: 12, w: FontWeight.w900, c: Colors.white38, ls: 2),
        ),
        const SizedBox(height: 16),
        GlassCard(
          child: Column(
            children: [
              _reviewRow('Objective', _objectiveId?.toUpperCase() ?? 'NONE'),
              _reviewRow('Tracks', '${_multiFiles.length} Layers'),
              _reviewRow('Sound', _bakedTrack?.title ?? 'Original'),
              const Divider(color: Colors.white10, height: 32),
              Row(
                children: [
                  Checkbox(
                    value: _agreedToPolicies,
                    onChanged: (v) =>
                        setState(() => _agreedToPolicies = v ?? false),
                    activeColor: C.brand,
                  ),
                  Expanded(
                    child: Text(
                      'I agree to Necxa Content Policies',
                      style: dm(sz: 11, c: Colors.white60),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _reviewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: dm(sz: 12, c: Colors.white38)),
          Text(
            value,
            style: syne(sz: 12, w: FontWeight.bold, c: Colors.white),
          ),
        ],
      ),
    );
  }

  // ── SHARED WIDGETS ───────────────────────────────────────────
  Widget _topBar(
    String title,
    VoidCallback onBack, {
    Color color = Colors.white,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new),
            onPressed: onBack,
            color: color,
          ),
          Text(
            title,
            style: syne(sz: 18, w: FontWeight.w900, c: color),
          ),
        ],
      ),
    );
  }

  Widget _inputField(
    String label,
    String hint,
    TextEditingController controller, {
    int maxLines = 1,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: syne(sz: 11, w: FontWeight.w800, c: Colors.white38, ls: 1),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          style: dm(sz: 14, c: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: dm(sz: 14, c: Colors.white12),
            filled: true,
            fillColor: Colors.black26,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.all(16),
          ),
        ),
      ],
    );
  }

  Widget _buildMediaGrid() {
    if (_multiFiles.isEmpty) {
      return GestureDetector(
        onTap: _pickUnifiedMedia,
        child: Container(
          height: 160,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(13),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.add_photo_alternate_outlined,
                color: Colors.white24,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text('Tap to select media', style: dm(sz: 13, c: Colors.white24)),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _multiFiles.length + 1,
      itemBuilder: (context, i) {
        if (i == _multiFiles.length) {
          return GestureDetector(
            onTap: _pickUnifiedMedia,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: const Icon(Icons.add, color: Colors.white54),
            ),
          );
        }
        return Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                image: DecorationImage(
                  image: FileImage(_multiFiles[i]),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: () => setState(() => _multiFiles.removeAt(i)),
                child: const CircleAvatar(
                  radius: 10,
                  backgroundColor: Colors.black54,
                  child: Icon(Icons.close, size: 12, color: Colors.white),
                ),
              ),
            ),
            if (_multiFiles[i].path.toLowerCase().endsWith('.mp4'))
              const Center(
                child: Icon(
                  Icons.play_circle_outline,
                  color: Colors.white70,
                  size: 30,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildPrimaryAction(Color accent) {
    String label = 'Next';
    if (_step == 0) label = 'Configure Setup';
    if (_step == 1) label = 'Open Film Hub';
    if (_step == 2) label = 'Final Review';
    if (_step == 3) label = 'Publish Now';

    return GestureDetector(
      onTap: _next,
      child: Container(
        height: 60,
        margin: const EdgeInsets.symmetric(horizontal: 40),
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: accent.withAlpha(77),
              blurRadius: 20,
              spreadRadius: 0,
            ),
          ],
        ),
        child: Center(
          child: Text(
            label.toUpperCase(),
            style: syne(sz: 14, w: FontWeight.w900, c: Colors.black, ls: 2),
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Container(
      width: double.infinity,
      color: Colors.black,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Cybernetic Ring
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 120,
                height: 120,
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(
                    C.brand.withAlpha(51),
                  ),
                  strokeWidth: 2,
                ),
              ),
              const SizedBox(
                width: 100,
                height: 100,
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(C.brand),
                  strokeWidth: 4,
                ),
              ),
              const Icon(Icons.psychology_outlined, color: C.brand, size: 40),
            ],
          ),
          const SizedBox(height: 48),

          Text(
            'NEURAL SYNTHESIS',
            style: syne(sz: 16, w: FontWeight.w900, c: C.brand, ls: 6),
          ),
          const SizedBox(height: 16),

          TweenAnimationBuilder<int>(
            tween: IntTween(begin: 0, end: 4),
            duration: const Duration(seconds: 4),
            builder: (context, value, _) {
              final messages = [
                'Initializing neural pathways...',
                'Synthesizing multi-track layers...',
                'Baking 48kHz spatial audio...',
                'Polishing visual metadata...',
                'Synchronizing with the Mesh...',
              ];
              return Column(
                children: [
                  Text(
                    _isOptimizing
                        ? _optimizingStatus.toUpperCase()
                        : messages[value].toUpperCase(),
                    style: syne(
                      sz: 10,
                      w: FontWeight.bold,
                      c: _isOptimizing ? C.brand : Colors.white70,
                      ls: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Step ${value + 1} of 5',
                    style: dm(sz: 10, c: Colors.white24),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 60),
          // Progress bar at the bottom
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 60),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: const LinearProgressIndicator(
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(C.brand),
                minHeight: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.copyWith(text: newValue.text.toUpperCase());
}
