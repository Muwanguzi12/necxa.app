import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';
import '../theme.dart';
import '../app_state.dart';
import 'pro_media_editor_screen.dart';
import '../widgets/campaign_ui_kit.dart';
import '../utils/content_sanitizer.dart';
import '../utils/media_helpers.dart';
import '../models/music_models.dart';
import '../services/draft_service.dart';
import '../services/music_library_service.dart';
import 'policies_screen.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'necxa_camera_capture_screen.dart';
import '../main.dart' show cameras;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/media_compression_service.dart';
import '../data.dart';
import '../utils/error_handler.dart';

// ══════════════════════════════════════════════════════════════
// CREATOR TYPE ENUM
// ══════════════════════════════════════════════════════════════
enum CreatorType {
  unified,       // 🎭  Automatic Content Selector (Photo/Video/Music)
  artist,        // 👨‍🎤  Artist Hub (Visual mood + beat track)
  audio,         // 🎙️  Podcast & Voice (Simplified audio-first)
}

extension CreatorTypeX on CreatorType {
  String get label {
    switch (this) {
      case CreatorType.unified: return 'Create';
      case CreatorType.artist:  return 'Artist Hub';
      case CreatorType.audio:   return 'Voice & Music';
    }
  }

  String get subtitle {
    switch (this) {
      case CreatorType.unified: return 'Automatic selector for photos, videos, and music';
      case CreatorType.artist:  return 'Select visual mood · Add your own beat';
      case CreatorType.audio:   return 'Record or upload your next hit or podcast';
    }
  }

  String get emoji {
    switch (this) {
      case CreatorType.unified: return '✨';
      case CreatorType.artist:  return '👨‍🎤';
      case CreatorType.audio:   return '🎙️';
    }
  }

  bool get hasMusicLayer => true;
  bool get hasAudio      => true;
  bool get isArtist      => this == CreatorType.artist;
  bool get isUnified     => this == CreatorType.unified;
}

// ══════════════════════════════════════════════════════════════
// SYNTH MOODS
// ══════════════════════════════════════════════════════════════
const _synthMoods = [
  _SynthMood('Dark Pulse',    [Color(0xFF0a0a1a), Color(0xFF1a0a3a)], '🌑'),
  _SynthMood('Vibrant City',  [Color(0xFF1a0040), Color(0xFFFF0099)], '🌆'),
  _SynthMood('Cosmic',        [Color(0xFF000428), Color(0xFF004e92)], '🌌'),
  _SynthMood('Neon Grid',     [Color(0xFF000000), Color(0xFF00ff88)], '⚡'),
  _SynthMood('Golden Hour',   [Color(0xFF1a0a00), Color(0xFFFF8C00)], '🌅'),
  _SynthMood('Deep Sea',      [Color(0xFF001a2e), Color(0xFF006994)], '🌊'),
];

class _SynthMood {
  final String name;
  final List<Color> colors;
  final String emoji;
  const _SynthMood(this.name, this.colors, this.emoji);
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
  String? _objectiveId;    // awareness, conversion, sales

  // ── Creative Metadata ───────────────────────────────────────
  MusicTrack? _bakedTrack; 
  File? _visualFile;       
  List<File> _multiFiles = [];
  List<File> _productPhotos = []; // 📸 Miniature product photos for Sales
  bool _isVideo = false;
  
  // -- Audio / Recording --
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  File? _audioFile;
  String? _audioPath;
  bool _isRecording = false;
  bool _isPlaying = false;
  Duration _recDuration = Duration.zero;
  Timer? _recTimer;

  // -- Artist Hub --
  File? _beatCoverFile;
  File? _artistArtFile;

  // -- Layers --
  List<Map<String, dynamic>> _overlays = [];
  File? _voiceOverFile;
  Map<int, double> _startOffsets = {};
  Map<int, double> _endOffsets = {};

  // ── Setup Metadata ──────────────────────────────────────────
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _tagsController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _skuController = TextEditingController();
  final TextEditingController _stockController = TextEditingController();
  
  String _title = '';
  String _desc  = '';
  String _tags  = '';
  String _category = 'Standard';
  String _price    = '';
  String _sku      = '';
  String _stock    = '';
  Map<String, dynamic>? _linkedListing;

  // ── Sync State ──────────────────────────────────────────────
  bool _isProcessing = false;
  bool _isOptimizing = false;
  String _optimizingStatus = "";
  bool _agreedToPolicies = false;

  // ── Animations ──────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _bakedTrack = widget.initialTrack;
    if (_bakedTrack != null) {
      _title = _bakedTrack!.title;
      _titleController.text = _title;
    }
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _titleController.addListener(() => _title = _titleController.text);
    _descController.addListener(() => _desc = _descController.text);
    _tagsController.addListener(() => _tags = _tagsController.text);
    _priceController.addListener(() => _price = _priceController.text);
    _skuController.addListener(() => _sku = _skuController.text);
    _stockController.addListener(() => _stock = _stockController.text);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _recTimer?.cancel();
    _recorder.dispose();
    _player.dispose();
    _titleController.dispose();
    _descController.dispose();
    _tagsController.dispose();
    _priceController.dispose();
    _skuController.dispose();
    _stockController.dispose();
    super.dispose();
  }

  void _clearState() {
    setState(() {
      _step = 0;
      _objectiveId = null;
      _visualFile = null;
      _multiFiles = [];
      _title = '';
      _desc = '';
      _tags = '';
      _price = '';
      _sku = '';
      _agreedToPolicies = false;
      _bakedTrack = widget.initialTrack;
    });
  }

  // ── Helpers ───────────────────────────────────────────────────
  void _err(String m) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m), backgroundColor: C.red));

  String _fmtDur(Duration d) => MediaHelpers.formatDuration(d);

  List<String> _cleanTags(String raw) => ContentSanitizer.generateUnifiedTagPayload(raw, _desc);


  // ── Media pickers ─────────────────────────────────────────────
  Future<void> _processResult(XFile? f, bool isVideo, {bool isFastSync = false}) async {
    if (f == null) return;
    final file = File(f.path);
    if (!mounted) return;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProMediaEditorScreen(
          initialImage: isVideo ? null : file,
          initialVideo: isVideo ? file : null,
          initialTrack: _bakedTrack,
          multiFiles: _multiFiles,
          isFastSync: isFastSync,
          state: widget.state,
        ),
      ),
    );
    
    if (result is Map) {
      final List? sequence = result['sequence'];
      final File? enhanced = result['combined_file'] ?? (sequence != null && sequence.isNotEmpty ? (sequence.first as VideoClip).file : null);
      final MusicTrack? track = result['track'];

      if (sequence != null) {
        setState(() {
          if (sequence.first is VideoClip) {
            _multiFiles = (sequence as List<VideoClip>).map((c) => c.file).toList();
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
        _isVideo = _visualFile!.path.toLowerCase().endsWith('.mp4') || _visualFile!.path.toLowerCase().endsWith('.mov');
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
       MaterialPageRoute(builder: (_) => NecxaCameraCaptureScreen(cameras: cameras)),
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

  Future<void> _pickImage() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70);
    await _processResult(f, false);
  }

  Future<void> _captureImage() async {
    final f = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 70);
    await _processResult(f, false);
  }

  Widget _editorAction(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(backgroundColor: Colors.white10, radius: 30, child: Icon(icon, color: Colors.white, size: 28)),
          const SizedBox(height: 8),
          Text(label, style: syne(sz: 12, c: Colors.white)),
        ],
      ),
    );
  }

  Future<void> _pickAudioFile() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (res != null && res.files.single.path != null) {
      setState(() { _audioFile = File(res.files.single.path!); _audioPath = res.files.single.path; });
    }
  }

  Future<void> _pickArtistPhoto(bool isCover) async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (f != null) {
      setState(() {
        if (isCover) _beatCoverFile = File(f.path);
        else _artistArtFile = File(f.path);
      });
    }
  }

  // ── Audio recording ───────────────────────────────────────────
  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) { _err('Microphone permission required'); return; }
    final dir  = await getTemporaryDirectory();
    final path = '${dir.path}/necxa_rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recDuration += const Duration(seconds: 1));
    });
    setState(() { _isRecording = true; _recDuration = Duration.zero; _audioPath = path; });
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    _recTimer?.cancel();
    if (path != null) setState(() { _audioFile = File(path); _isRecording = false; });
  }

  Future<void> _togglePlay() async {
    if (_audioPath == null) return;
    if (_isPlaying) {
      await _player.pause();
      setState(() => _isPlaying = false);
    } else {
      await _player.setFilePath(_audioPath!);
      await _player.play();
      setState(() => _isPlaying = true);
      _player.playerStateStream.listen((s) {
        if (s.processingState == ProcessingState.completed) {
          if (mounted) setState(() => _isPlaying = false);
        }
      });
    }
  }

  // ── Step navigation ────────────────────────────────────────────
  void _next() {
    if (_step == 0) {
      if (_objectiveId == null) { _err('Select an objective to continue'); return; }
    }
    if (_step == 1) {
      if (_title.isEmpty) { _err('Headline is required'); return; }
      if (_objectiveId == 'sales' && _price.isEmpty) { _err('Price is required for sales'); return; }
    }
    if (_step == 2) {
      if (_multiFiles.isEmpty && _visualFile == null) { _err('Assets are required for this campaign'); return; }
    }
    if (_step == 3) {
      if (!_agreedToPolicies) { _err('Please agree to Necxa policies'); return; }
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
      if (mounted) setState(() { _step = 3; _isOptimizing = false; });
      _err(getUserFriendlyError(e));
    } finally {
      if (mounted) setState(() => _isOptimizing = false);
    }
  }

  Future<Map<String, dynamic>> _optimizeMediaAssets() async {
    String? visualUrl;
    List<String> multiUrls = [];
    String? mediaType;
    String? thumbUrl;
    File visualToUpload = _visualFile ?? File('');

    if (_multiFiles.length > 1) {
      // 🚀 OPTIMIZED MULTI-UPLOAD WITH SEQUENTIAL COMPRESSION
      setState(() => _isOptimizing = true);
      final List<File> optimizedFiles = [];
      
      for (int i = 0; i < _multiFiles.length; i++) {
        final f = _multiFiles[i];
        if (f.path.toLowerCase().endsWith('.mp4') || f.path.toLowerCase().endsWith('.mov')) {
          setState(() => _optimizingStatus = "Optimizing Clip ${i + 1} of ${_multiFiles.length}...");
          final mediaInfo = await VideoCompress.compressVideo(
            f.path,
            quality: VideoQuality.MediumQuality,
            deleteOrigin: false,
          );
          optimizedFiles.add(mediaInfo?.file ?? f);
        } else {
          setState(() => _optimizingStatus = "Compressing Photo ${i + 1} of ${_multiFiles.length}...");
          final compressed = await MediaCompressionService.compressImage(f);
          optimizedFiles.add(compressed);
        }
      }
      
      setState(() => _optimizingStatus = "Synthesizing Layers...");
      multiUrls = await widget.state.cloud.uploadMultiMedia(optimizedFiles, bucket: 'community-media');
      visualUrl = multiUrls.isNotEmpty ? multiUrls.first : null;
      mediaType = _isVideo ? 'video' : 'gallery';

      // Auto capture cover photo for multi-files
      if (_multiFiles.isNotEmpty) {
        final firstFile = _multiFiles.first;
        if (firstFile.path.toLowerCase().endsWith('.mp4') || firstFile.path.toLowerCase().endsWith('.mov')) {
          setState(() => _optimizingStatus = "Capturing Cover Photo...");
          final thumbPath = await VideoThumbnail.thumbnailFile(
            video: firstFile.path,
            thumbnailPath: (await getTemporaryDirectory()).path,
            imageFormat: ImageFormat.JPEG,
            quality: 40,
          );
          if (thumbPath != null) {
            final tRes = await widget.state.cloud.uploadMedia(File(thumbPath), bucket: 'community-media');
            thumbUrl = tRes?['url'] as String?;
          }
        } else {
          thumbUrl = visualUrl; // The first uploaded file is the image itself.
        }
      }
    } else if (_isVideo && _visualFile != null) {
      // ⏳ VIDEO OPTIMIZATION
      setState(() { _isOptimizing = true; _optimizingStatus = "Compressing Main Video..."; });
      
      // 1. Generate Thumbnail
      final thumbPath = await VideoThumbnail.thumbnailFile(
        video: _visualFile!.path,
        thumbnailPath: (await getTemporaryDirectory()).path,
        imageFormat: ImageFormat.JPEG,
        quality: 40,
      );
      if (thumbPath != null) {
        final tRes = await widget.state.cloud.uploadMedia(File(thumbPath), bucket: 'community-media');
        thumbUrl = tRes?['url'] as String?;
      }
      
      // 2. Transcode Video
      final mediaInfo = await VideoCompress.compressVideo(
        _visualFile!.path,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false,
      );
      if (mediaInfo != null && mediaInfo.file != null) {
        visualToUpload = mediaInfo.file!;
      }
      
      final res = await widget.state.cloud.uploadMedia(visualToUpload, bucket: 'community-media');
      visualUrl = res?['url'] as String?;
      mediaType = 'video';
    } else if (_visualFile != null) {
      setState(() => _optimizingStatus = "Compressing Visual Asset...");
      final compressed = await MediaCompressionService.compressImage(_visualFile!);
      final res = await widget.state.cloud.uploadMedia(compressed, bucket: 'community-media');
      visualUrl = res?['url'] as String?;
      mediaType = res?['media_type'] as String?;
      thumbUrl = visualUrl; // Auto capture cover photo for single image
    } else if (_multiFiles.isNotEmpty) {
      // Fallback if _multiFiles has exactly 1 image
      setState(() => _optimizingStatus = "Compressing Visual Asset...");
      final compressed = await MediaCompressionService.compressImage(_multiFiles.first);
      final res = await widget.state.cloud.uploadMedia(compressed, bucket: 'community-media');
      visualUrl = res?['url'] as String?;
      mediaType = 'gallery';
      thumbUrl = visualUrl;
      multiUrls = visualUrl != null ? [visualUrl] : [];
    }

    return {
      'visualUrl': visualUrl,
      'multiUrls': multiUrls,
      'mediaType': mediaType,
      'thumbUrl': thumbUrl,
    };
  }

  Future<void> _dispatchSalesCampaign() async {
    final media = await _optimizeMediaAssets();
    final visualUrl = media['visualUrl'] as String?;
    final multiUrls = media['multiUrls'] as List<String>;
    final mediaType = media['mediaType'] as String?;
    
    // 🛡️ Pre-calculate product photo URLs (Miniatures)
    List<String> productPhotoUrls = [];
    if (_productPhotos.isNotEmpty) {
      setState(() => _optimizingStatus = "Compressing Product Miniatures...");
      final List<File> compressedProductPhotos = [];
      for (int i = 0; i < _productPhotos.length; i++) {
        setState(() => _optimizingStatus = "Compressing Photo ${i + 1} of ${_productPhotos.length}...");
        final compressed = await MediaCompressionService.compressImage(_productPhotos[i]);
        compressedProductPhotos.add(compressed);
      }
      setState(() => _optimizingStatus = "Syncing Product Miniatures...");
      productPhotoUrls = await widget.state.cloud.uploadMultiMedia(compressedProductPhotos, bucket: 'listing-photos');
    }

    if (_linkedListing != null) {
      // UPDATE EXISTING LISTING
      await Supabase.instance.client
          .from('listings')
          .update({
            'media_url': visualUrl,
            'media_type': mediaType,
            'photos': productPhotoUrls.isNotEmpty 
                      ? productPhotoUrls 
                      : (_linkedListing!['photos'] ?? []),
          })
          .eq('id', _linkedListing!['id']);
    } else {
      // CREATE NEW LISTING
      await widget.state.social.createListing(widget.state.user?.id ?? '', {
        'title': _title,
        'description': _desc,
        'price': _price,
        'sku': _sku.isNotEmpty ? _sku : 'SKU-${DateTime.now().millisecondsSinceEpoch}',
        'category': _category,
        'media_url': visualUrl, // Film Hub / Video Content
        'thumbnail_url': media['thumbUrl'],
        'media_type': mediaType,
        'type': 'COMMERCIAL',
        'stock_count': _stock.isNotEmpty ? int.tryParse(_stock) ?? 999 : 999,
        'music_track_id': _bakedTrack?.id,
        'audio_url': _bakedTrack?.audioUrl,
        // Strictly separate: photos should only contain product miniatures
        'photos': productPhotoUrls.isNotEmpty 
                  ? productPhotoUrls 
                  : [],
        'status': 'active',
      });
    }
  }

  Future<void> _dispatchArtistCampaign() async {
    final userId = widget.state.user?.id ?? '';
    // Pay distribute fee
    await widget.state.payment.chargeArtistDistributionFee(userId, 150);
    widget.state.updateCoins(-150);

    // Optimize artist specific art
    String? beatCoverUrl;
    String? artistProfileUrl;
    if (_beatCoverFile != null) {
      final res = await widget.state.cloud.uploadMedia(_beatCoverFile!, bucket: 'artist-media');
      beatCoverUrl = res?['url'] as String?;
    }
    if (_artistArtFile != null) {
      final res = await widget.state.cloud.uploadMedia(_artistArtFile!, bucket: 'artist-media');
      artistProfileUrl = res?['url'] as String?;
    }

    final media = await _optimizeMediaAssets();
    final visualUrl = media['visualUrl'] as String?;
    final multiUrls = media['multiUrls'] as List<String>;
    final mediaType = media['mediaType'] as String?;
    final thumbUrl = media['thumbUrl'] as String?;

    String? audioUrl;
    if (_audioFile != null) {
      final res = await widget.state.cloud.uploadMedia(_audioFile!, bucket: 'community-media', assetType: 'audio');
      audioUrl = res?['url'] as String?;
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
        }
      });
    }

    await widget.state.social.createPost(userId, {
      'title': _title,
      'content': _desc,
      'tags': _cleanTags(_tags),
      'media_url': visualUrl,
      'thumbnail_url': thumbUrl,
      'media_type': mediaType,
      'media_asset_id': mediaAssetId,
      'audio_url': audioUrl ?? _bakedTrack?.audioUrl,
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
    });
  }

  Future<void> _dispatchSocialCampaign() async {
    final userId = widget.state.user?.id ?? '';
    final media = await _optimizeMediaAssets();
    final visualUrl = media['visualUrl'] as String?;
    final multiUrls = media['multiUrls'] as List<String>;
    final mediaType = media['mediaType'] as String?;
    final thumbUrl = media['thumbUrl'] as String?;

    String? audioUrl;
    if (_audioFile != null) {
      final res = await widget.state.cloud.uploadMedia(_audioFile!, bucket: 'community-media', assetType: 'audio');
      audioUrl = res?['url'] as String?;
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
        }
      });
    }

    await widget.state.social.createPost(userId, {
      'title': _title,
      'content': _desc,
      'tags': _cleanTags(_tags),
      'media_url': visualUrl,
      'thumbnail_url': thumbUrl,
      'media_type': mediaType,
      'media_asset_id': mediaAssetId,
      'audio_url': audioUrl ?? _bakedTrack?.audioUrl,
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
    });
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
            const Icon(Icons.check_circle_rounded, color: Colors.white, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(msg, style: syne(sz: 13, w: FontWeight.bold, c: Colors.white)),
                  Text(
                    destinationTab == 'shop' ? 'Tap Shop to see your product' : 'Scroll to find your post',
                    style: dm(sz: 11, c: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: destinationTab == 'shop'
            ? const Color(0xFFB8860B)   // Gold for shop
            : const Color(0xFF0D7A3E),  // Green for feed
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
              accentColor: accent
            ),

            Expanded(
              child: _step == 99 
                ? _buildLoading()
                : SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
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
      case 0: return 'Select Objective';
      case 1: return 'Campaign Setup';
      case 2: return 'Film Hub';
      case 3: return 'Review & Release';
      default: return 'Upload Portal';
    }
  }

  Widget _buildCurrentStep() {
    switch (_step) {
      case 0: return _buildObjectiveSelection();
      case 1: return _buildSetupStep();
      case 2: return _buildCreativeStep();
      case 3: return _buildFinalReview();
      default: return const SizedBox();
    }
  }

  // ── STEP 0: OBJECTIVE SELECTION ─────────────────────────────
  Widget _buildObjectiveSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('CHOOSE YOUR GOAL', style: syne(sz: 12, w: FontWeight.w900, c: Colors.white38, ls: 2)),
        const SizedBox(height: 16),
        ObjectiveCard(
          title: 'Awareness',
          subtitle: 'Community contribution & Social synergy',
          icon: Icons.auto_awesome,
          colors: [const Color(0xFF00E5FF), const Color(0xFF3B82F6)],
          isSelected: _objectiveId == 'awareness',
          onTap: () => setState(() => _objectiveId = 'awareness'),
        ),
        ObjectiveCard(
          title: 'Conversion',
          subtitle: 'Artist Hub. Digital collectibles & Audio visual releases',
          icon: Icons.library_music,
          colors: [const Color(0xFFA855F7), const Color(0xFF7B2FFF)],
          isSelected: _objectiveId == 'conversion',
          onTap: () {
            if (!widget.state.isArtist) { widget.state.go('artist_auth'); return; }
            setState(() => _objectiveId = 'conversion');
          },
        ),
        ObjectiveCard(
          title: 'Sales',
          subtitle: 'Catalog-based commerce & Product listings',
          icon: Icons.shopping_bag_outlined,
          colors: [const Color(0xFFF4A228), const Color(0xFFEF4444)],
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
        Text('CAMPAIGN DETAILS', style: syne(sz: 12, w: FontWeight.w900, c: Colors.white38, ls: 2)),
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
              _inputField('Headline', 'A catchy title for your content', _titleController),
              const SizedBox(height: 16),
              _inputField('Description', 'Tell the world more...', _descController, maxLines: 3),
              const SizedBox(height: 16),
              _inputField('Tags', '#vision #necx...', _tagsController),
              if (_objectiveId == 'sales' && _linkedListing == null) ...[
                const SizedBox(height: 16),
                _inputField('Price (UGX)', 'e.g. 25,000', _priceController, keyboardType: TextInputType.number),
                const SizedBox(height: 16),
                _inputField('SKU (Optional)', 'e.g. NXC-1234', _skuController),
                const SizedBox(height: 16),
                _inputField('Stock Quantity (Optional)', 'Leave empty for infinite, e.g. 10', _stockController, keyboardType: TextInputType.number),
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
        Text('PRODUCT MINIATURES (MAX 3)', style: syne(sz: 10, w: FontWeight.w900, c: Colors.white38, ls: 1.5)),
        const SizedBox(height: 12),
        SizedBox(
          height: 80,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _productPhotos.length < 3 ? _productPhotos.length + 1 : 3,
            itemBuilder: (context, i) {
              if (i == _productPhotos.length && i < 3) {
                return GestureDetector(
                  onTap: _pickProductPhoto,
                  child: Container(
                    width: 80,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white10, style: BorderStyle.solid),
                    ),
                    child: const Icon(Icons.add_a_photo_outlined, color: Colors.white24, size: 24),
                  ),
                );
              }
              return Container(
                width: 80,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  image: DecorationImage(image: FileImage(_productPhotos[i]), fit: BoxFit.cover),
                  border: Border.all(color: Colors.white10),
                ),
                child: Align(
                  alignment: Alignment.topRight,
                  child: GestureDetector(
                    onTap: () => setState(() => _productPhotos.removeAt(i)),
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.close, size: 14, color: Colors.white),
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
    final List<XFile> images = await picker.pickMultiImage(limit: 3 - _productPhotos.length);
    if (images.isNotEmpty) {
      setState(() {
        _productPhotos.addAll(images.map((x) => File(x.path)));
      });
    }
  }

  void _showProductPicker() async {
    final listings = await widget.state.social.fetchUserListings(widget.state.user?.id ?? 'c1');
    
    if (!mounted) return;
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: C.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 24),
            Text('SELECT PRODUCT', style: syne(sz: 14, w: FontWeight.w900, ls: 2)),
            const SizedBox(height: 24),
            Expanded(
              child: listings.isEmpty 
                ? Center(child: Text('NO PRODUCTS IN SHOWCASE', style: syne(sz: 11, c: Colors.white24)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    itemCount: listings.length,
                    itemBuilder: (context, i) {
                      final l = listings[i];
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _linkedListing = l;
                            _titleController.text = l['title'] ?? '';
                            _priceController.text = (l['price'] ?? '').toString();
                          });
                          Navigator.pop(context);
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(l['media_url'] ?? '', width: 50, height: 50, fit: BoxFit.cover, errorBuilder: (_,__,___) => const Icon(Icons.shopping_bag)),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(l['title'] ?? 'Product', style: syne(sz: 13, w: FontWeight.bold)),
                                    Text(ugx((l['price'] ?? 0).toDouble()), style: dm(sz: 12, c: C.brand)),
                                  ],
                                ),
                              ),
                              const Icon(Icons.add_circle_outline, color: C.brand, size: 20),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
            ),
          ],
        ),
      ),
    );
  }

  // ── STEP 2: FILM HUB ────────────────────────────────────────
  Widget _buildCreativeStep() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('ASSETS', style: syne(sz: 12, w: FontWeight.w900, c: Colors.white38, ls: 2)),
            if (_multiFiles.isNotEmpty) 
              Text('${_multiFiles.length} TRACKS LOADED', style: syne(sz: 10, w: FontWeight.bold, c: C.brand)),
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
                    BoxShadow(color: Colors.red.withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 8))
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                      child: const Icon(Icons.videocam, color: Colors.white, size: 32),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('LIVE CAPTURE', style: syne(sz: 18, w: FontWeight.w900, c: Colors.white)),
                          Text('Speed · Filters · 4K Mastery', style: dm(sz: 12, c: Colors.white70)),
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 16),
                  ],
                ),
              ),
            ),
          ),

        _buildMediaGrid(),
        const SizedBox(height: 24),
        if (_multiFiles.isNotEmpty)
          GestureDetector(
            onTap: () => _processResult(XFile(_multiFiles.first.path), _isVideo),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: C.brand.withOpacity(0.1),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: C.brand.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.movie_filter_outlined, color: C.brand, size: 32),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('OPEN FILM HUB', style: syne(sz: 16, w: FontWeight.w900, c: C.brand)),
                        Text('Edit layers, tracks, and timing', style: dm(sz: 11, c: Colors.white54)),
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
         Text('FINAL SYNTHESIS', style: syne(sz: 12, w: FontWeight.w900, c: Colors.white38, ls: 2)),
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
                     onChanged: (v) => setState(() => _agreedToPolicies = v ?? false),
                     activeColor: C.brand,
                   ),
                   Expanded(child: Text('I agree to Necxa Content Policies', style: dm(sz: 11, c: Colors.white60))),
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
          Text(value, style: syne(sz: 12, w: FontWeight.bold, c: Colors.white)),
        ],
      ),
    );
  }

  // ── SHARED WIDGETS ───────────────────────────────────────────
  Widget _topBar(String title, VoidCallback onBack, {Color color = Colors.white}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.arrow_back_ios_new), onPressed: onBack, color: color),
          Text(title, style: syne(sz: 18, w: FontWeight.w900, c: color)),
        ],
      ),
    );
  }

  Widget _inputField(String label, String hint, TextEditingController controller, {int maxLines = 1, TextInputType? keyboardType}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: syne(sz: 11, w: FontWeight.w800, c: Colors.white38, ls: 1)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          style: dm(sz: 14, c: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: dm(sz: 14, c: Colors.white12),
            filled: true,
            fillColor: Colors.black26,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
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
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add_photo_alternate_outlined, color: Colors.white24, size: 40),
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
        crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
      itemCount: _multiFiles.length + 1,
      itemBuilder: (context, i) {
        if (i == _multiFiles.length) {
          return GestureDetector(
            onTap: _pickUnifiedMedia,
            child: Container(
              decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white10)),
              child: const Icon(Icons.add, color: Colors.white54),
            ),
          );
        }
        return Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                image: DecorationImage(image: FileImage(_multiFiles[i]), fit: BoxFit.cover),
              ),
            ),
            Positioned(
              top: 4, right: 4,
              child: GestureDetector(
                onTap: () => setState(() => _multiFiles.removeAt(i)),
                child: CircleAvatar(radius: 10, backgroundColor: Colors.black54, child: const Icon(Icons.close, size: 12, color: Colors.white)),
              ),
            ),
            if (_multiFiles[i].path.toLowerCase().endsWith('.mp4'))
               const Center(child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 30)),
          ],
        );
      },
    );
  }

  Widget _srcBtn(String label, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: 48,
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white10)),
      child: Center(child: Text(label, style: syne(sz: 13, w: FontWeight.w700))),
    ),
  );
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
            BoxShadow(color: accent.withOpacity(0.3), blurRadius: 20, spreadRadius: 0)
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
                width: 120, height: 120,
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(C.brand.withOpacity(0.2)),
                  strokeWidth: 2,
                ),
              ),
              SizedBox(
                width: 100, height: 100,
                child: CircularProgressIndicator(
                  valueColor: const AlwaysStoppedAnimation<Color>(C.brand),
                  strokeWidth: 4,
                ),
              ),
              const Icon(Icons.psychology_outlined, color: C.brand, size: 40),
            ],
          ),
          const SizedBox(height: 48),
          
          Text(
            'NEURAL SYNTHESIS', 
            style: syne(sz: 16, w: FontWeight.w900, c: C.brand, ls: 6)
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
                'Synchronizing with the Mesh...'
              ];
              return Column(
                children: [
                  Text(
                    _isOptimizing ? _optimizingStatus.toUpperCase() : messages[value].toUpperCase(), 
                    style: syne(sz: 10, w: FontWeight.bold, c: _isOptimizing ? C.brand : Colors.white70, ls: 1.5)
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Step ${value + 1} of 5', 
                    style: dm(sz: 10, c: Colors.white24)
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

  Widget _buildDraftsGallery() {
    return FutureBuilder<List<DraftPost>>(
      future: widget.state.drafts.getDrafts(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) return const SizedBox.shrink();
        final drafts = snapshot.data!;
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Drafts', style: syne(sz: 18, w: FontWeight.w900)),
                Text('${drafts.length} total', style: dm(sz: 12, c: C.dim)),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 160,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: drafts.length,
                itemBuilder: (context, i) {
                  final d = drafts[i];
                  return GestureDetector(
                    onTap: () => _resumeDraft(d),
                    child: Container(
                      width: 110,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const Center(child: Icon(Icons.movie_outlined, color: Colors.white24, size: 32)),
                          Positioned(
                            bottom: 8, left: 8,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                              child: const Icon(Icons.history, color: C.brand, size: 10),
                            ),
                          ),
                          Positioned(
                            top: 4, right: 4,
                            child: IconButton(
                              icon: const Icon(Icons.close, color: Colors.white38, size: 14),
                              onPressed: () async {
                                await widget.state.drafts.deleteDraft(d.id);
                                setState(() {});
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _resumeDraft(DraftPost d) async {
    final file = File(d.mediaPath);
    if (!await file.exists()) {
       _err("Draft file missing from storage");
       return;
    }

    MusicTrack? track;
    if (d.trackId != null) {
      track = await widget.state.music.getTrackById(d.trackId!);
    }

    if (mounted) {
      final res = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProMediaEditorScreen(
            state: widget.state,
            initialVideo: file,
            initialTrack: track,
          ),
        ),
      );

      if (res != null && res is Map) {
        setState(() {
          _visualFile = res['file'];
          _bakedTrack = res['track'];
          _step = 1;
        });
      }
    }
  }
}
