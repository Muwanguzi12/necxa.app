import 'dart:async';
import 'package:universal_io/io.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import '../theme.dart';
import '../app_state.dart';
import '../services/listing_sync_service.dart';
import '../services/ai_service.dart';
import '../utils/error_handler.dart';
import '../main.dart' show cameras;

// -----------------------------------------------------------------------------
// NECXA � 7-Step Property Listing Wizard (Enhanced with ShieldSDK)
// -----------------------------------------------------------------------------
class ListingWizardScreen extends StatefulWidget {
  final AppState state;
  const ListingWizardScreen({super.key, required this.state});

  @override
  State<ListingWizardScreen> createState() => _ListingWizardState();
}

class _ListingWizardState extends State<ListingWizardScreen> {
  int _step = 0;
  bool _loading = false;
  bool _aiGenerating = false;
  bool _identityAdvanceScheduled = false;
  late final String _submissionIdempotencyKey;

  // -- Step 1: Basics --------------------------------------------------------
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _districtCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  String _propType = 'apartment';
  String _purpose = 'rent';
  String _role = 'owner'; // 'owner' or 'agent'

  // -- Step 2: Pricing -------------------------------------------------------
  final _priceCtrl = TextEditingController();
  String _priceType = 'monthly';
  int _bedrooms = 0;
  int _bathrooms = 1;
  int _sqft = 0;
  Set<String> _amenities = {};

  // -- Step 3: Identity Shard (ShieldSDK) ------------------------------------
  String? _identityShardId;

  // -- Step 4: Utility Shard --------------------------------------------------
  final _umemeCtrl = TextEditingController();
  final _nwscCtrl = TextEditingController();
  final _landBlockCtrl = TextEditingController();
  final _landPlotCtrl = TextEditingController();
  final _lc1OfficerCtrl = TextEditingController();
  File? _utilityBillPhoto;
  File? _lc1StampPhoto;
  File? _landTitlePhoto;
  File? _brsLicensePhoto; // Extra slot for agents
  String? _utilityShardId;

  // -- Step 5: GPS Lock ------------------------------------------------------
  Position? _gpsPosition;
  bool _gpsLocked = false;
  String? _gpsNodeId;

  // -- Step 6: Photos --------------------------------------------------------
  final List<File> _exteriorPhotos = [];
  final List<File> _interiorPhotos = [];
  final List<File> _bathroomPhotos = [];

  // -- Step 7: Final ---------------------------------------------------------
  bool _submitted = false;
  String? _mintEventId;
  final GlobalKey<_NeuralScannerOverlayState> _scannerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _identityShardId = widget.state.identityShardId;
    _utilityShardId = widget.state.utilityShardId;
    final userId = widget.state.user?.id ?? 'anonymous';
    _submissionIdempotencyKey =
        'listing-$userId-${DateTime.now().microsecondsSinceEpoch}';
    for (final controller in [
      _titleCtrl,
      _districtCtrl,
      _cityCtrl,
      _priceCtrl,
    ]) {
      controller.addListener(_refreshNavigationGate);
    }
  }

  void _refreshNavigationGate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final controller in [
      _titleCtrl,
      _districtCtrl,
      _cityCtrl,
      _priceCtrl,
    ]) {
      controller.removeListener(_refreshNavigationGate);
    }
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _districtCtrl.dispose();
    _cityCtrl.dispose();
    _priceCtrl.dispose();
    _umemeCtrl.dispose();
    _nwscCtrl.dispose();
    _landBlockCtrl.dispose();
    _landPlotCtrl.dispose();
    _lc1OfficerCtrl.dispose();
    super.dispose();
  }

  static const _steps = [
    ('Role & Basics', '🏠', 'Agent or owner'),
    ('Pricing & Specs', '💰', 'Price and property details'),
    ('Identity Shard', '🪪', 'ID and face verification'),
    ('Utility Shard', '📄', 'Utility and authority docs'),
    ('GPS Node Lock', '📍', 'Lock property coordinates'),
    ('Property Photos', '📸', 'Upload property photos'),
    ('Review & Mint', '✅', 'Review and submit'),
  ];

  bool get _canGoNext {
    switch (_step) {
      case 0:
        return _titleCtrl.text.trim().isNotEmpty &&
            _districtCtrl.text.trim().isNotEmpty &&
            _cityCtrl.text.trim().isNotEmpty;
      case 1:
        return (int.tryParse(_priceCtrl.text.replaceAll(',', '').trim()) ?? 0) >
            0;
      case 2:
        return (widget.state.lastIDResult?.verified ?? false) &&
            (widget.state.lastIDBackResult?.verified ?? false) &&
            (widget.state.lastHoldingResult?.verified ?? false) &&
            (widget.state.lastSelfieResult?.faceMatch ?? false) &&
            (widget.state.identityShardId?.isNotEmpty ?? false);
      case 3:
        return _utilityShardId?.isNotEmpty ?? false;
      case 4:
        return _gpsLocked && (_gpsNodeId?.isNotEmpty ?? false);
      case 5:
        return _exteriorPhotos.isNotEmpty &&
            _interiorPhotos.isNotEmpty &&
            _bathroomPhotos.isNotEmpty;
      case 6:
        return false;
      default:
        return false;
    }
  }



  void _next() {
    if (_canGoNext) setState(() => _step++);
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.bg,
        elevation: 0,
        title: Text('List a Property', style: syne(sz: 17, w: FontWeight.w700)),
        leading: IconButton(
          icon: Icon(Icons.close, color: C.text),
          onPressed: () => widget.state.go('home'),
        ),
      ),
      body: Column(
        children: [
          _buildProgress(),
          _buildStepHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              physics: const BouncingScrollPhysics(),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _buildStepBody(),
              ),
            ),
          ),
          if (!_submitted && _step < _steps.length - 1) _buildBottomNav(),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: List.generate(
          _steps.length,
          (i) => Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(right: i == _steps.length - 1 ? 0 : 4),
              decoration: BoxDecoration(
                color: i <= _step ? C.brand : C.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepHeader() {
    final s = _steps[_step];
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
      child: Row(
        children: [
          Text(s.$2, style: const TextStyle(fontSize: 28)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.$1, style: syne(sz: 18, w: FontWeight.w800)),
                Text(s.$3, style: dm(sz: 11, c: C.dim)),
              ],
            ),
          ),
          Text(
            '${_step + 1}/${_steps.length}',
            style: syne(sz: 12, w: FontWeight.w700, c: C.dim),
          ),
        ],
      ),
    );
  }

  Widget _buildStepBody() {
    switch (_step) {
      case 0:
        return _Step1(
          titleCtrl: _titleCtrl,
          districtCtrl: _districtCtrl,
          cityCtrl: _cityCtrl,
          descCtrl: _descCtrl,
          propType: _propType,
          purpose: _purpose,
          role: _role,
          onType: (v) => setState(() => _propType = v),
          onPurpose: (v) => setState(() => _purpose = v),
          onRole: (v) => setState(() => _role = v),
          onGenerateAi: _generateListingDetailsFromPhotos,
          aiGenerating: _aiGenerating,
          hasPhotos: (_exteriorPhotos.length + _interiorPhotos.length) > 0,
        );
      case 1:
        return _Step2(
          priceCtrl: _priceCtrl,
          priceType: _priceType,
          bedrooms: _bedrooms,
          bathrooms: _bathrooms,
          sqft: _sqft,
          amenities: _amenities,
          onPriceType: (v) => setState(() => _priceType = v),
          onBeds: (v) => setState(() => _bedrooms = v),
          onBaths: (v) => setState(() => _bathrooms = v),
          onSqft: (v) => setState(() => _sqft = v),
          onAmenities: (v) => setState(() => _amenities = v),
        );
      case 2:
        return _Step3Identity(
          state: widget.state,
          idVerified: widget.state.lastIDResult?.verified ?? false,
          faceVerified: widget.state.lastSelfieResult?.faceMatch ?? false,
          onVerify: _runIdentityVerification,
          loading: _loading,
          subStep: widget.state.verificationSubStep,
          scannerKey: _scannerKey,
        );
      case 3:
        return _Step4Utility(
          role: _role,
          umemeCtrl: _umemeCtrl,
          nwscCtrl: _nwscCtrl,
          landBlockCtrl: _landBlockCtrl,
          landPlotCtrl: _landPlotCtrl,
          lc1OfficerCtrl: _lc1OfficerCtrl,
          utilityBillPhoto: _utilityBillPhoto,
          lc1StampPhoto: _lc1StampPhoto,
          landTitlePhoto: _landTitlePhoto,
          brsLicensePhoto: _brsLicensePhoto,
          loading: _loading,
          onPickUtilityBill: (f) => setState(() => _utilityBillPhoto = f),
          onPickLc1: (f) => setState(() => _lc1StampPhoto = f),
          onPickTitle: (f) => setState(() => _landTitlePhoto = f),
          onPickBrs: (f) => setState(() => _brsLicensePhoto = f),
          onSave: _runUtilityVerification,
          utilityShardId: _utilityShardId,
        );
      case 4:
        return _Step5GPS(
          pos: _gpsPosition,
          locked: _gpsLocked,
          loading: _loading,
          onLock: _lockGps,
        );
      case 5:
        return _Step6Photos(
          exterior: _exteriorPhotos,
          interior: _interiorPhotos,
          bathrooms: _bathroomPhotos,
          loading: _loading,
          aiGenerating: _aiGenerating,
          onAdd: _addPropertyPhoto,
          onRemove: (cat, i) => setState(() {
            if (cat == 'EXTERIOR') {
              _exteriorPhotos.removeAt(i);
            } else if (cat == 'INTERIOR')
              _interiorPhotos.removeAt(i);
            else
              _bathroomPhotos.removeAt(i);
          }),
          onGenerateAi: _generateListingDetailsFromPhotos,
        );
      case 6:
        return _Step7Review(
          title: _titleCtrl.text,
          role: _role,
          propType: _propType,
          price: _priceCtrl.text,
          priceType: _priceType,
          idVerified: widget.state.lastIDResult?.verified ?? false,
          faceVerified: widget.state.lastSelfieResult?.faceMatch ?? false,
          gpsLocked: _gpsLocked,
          photoCount: _exteriorPhotos.length + _interiorPhotos.length,
          loading: _loading,
          submitted: _submitted,
          mintEventId: _mintEventId,
          onSubmit: _submitListing,
        );
      default:
        return const SizedBox();
    }
  }

  Widget _buildBottomNav() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.of(context).padding.bottom + 16,
      ),
      decoration: BoxDecoration(
        color: C.card,
        border: Border(top: BorderSide(color: C.border)),
      ),
      child: Row(
        children: [
          if (_step > 0)
            Expanded(
              child: OutlinedButton(
                onPressed: _loading ? null : _back,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: C.border),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  'Back',
                  style: syne(c: C.dim, w: FontWeight.w700),
                ),
              ),
            ),
          if (_step > 0) const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: (_canGoNext && !_loading) ? _next : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: C.brand,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _loading
                  ? SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        color: C.bg,
                        strokeWidth: 2,
                      ),
                    )
                  : Text(
                      _step == _steps.length - 1 ? 'Finish' : 'Continue',
                      style: syne(c: C.bg, w: FontWeight.w800),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  IDResult _idResultFrom(Map<String, dynamic> data) {
    final sessionId =
        data['verificationSessionId']?.toString() ??
        data['sessionId']?.toString() ??
        '';
    final verified =
        data['verified'] == true &&
        data['decision'] == 'pass' &&
        sessionId.isNotEmpty;
    return IDResult(
      verified: verified,
      sessionId: sessionId,
    );
  }

  SelfieResult _selfieResultFrom(Map<String, dynamic> data) {
    // Face matching must be an explicit result from the biometric service.
    final livenessPassed = data['livenessPassed'] == true;
    final faceMatch =
        livenessPassed &&
        data['faceMatch'] == true &&
        data['verified'] == true;
    double? score;
    if (data['score'] is num) {
      score = (data['score'] as num).toDouble();
    } else if (data['similarityScore'] is num) {
      score = (data['similarityScore'] as num).toDouble();
    }
    return SelfieResult(
      faceMatch: faceMatch,
      sessionId:
          data['verificationSessionId']?.toString() ??
          data['sessionId']?.toString() ??
          '',
      score: score,
    );
  }

  String _aiFeedback(Map<String, dynamic> data, String fallback) {
    final feedback = data['feedback']?.toString().trim();
    final approved = data['verified'] == true || data['faceMatch'] == true;
    if (!approved &&
        feedback != null &&
        feedback.toLowerCase().contains('verified')) {
      return fallback;
    }
    return (feedback != null && feedback.isNotEmpty)
        ? feedback
        : data['error']?.toString() ?? data['reason']?.toString() ?? fallback;
  }

  Future<void> _runIdentityVerification() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final state = widget.state;
      state.setShieldFeedback(null);
      final scanner = _scannerKey.currentState;
      if (scanner == null) {
        throw UserMessageException(
          'Camera is not ready yet. Please wait a moment and try again.',
        );
      }
      final requiredLens = state.verificationSubStep == 3
          ? CameraLensDirection.front
          : CameraLensDirection.back;
      final cameraCtrl = await scanner.ensureCamera(requiredLens);

      if (state.verificationSubStep == 0) {
        state
            .captureGps()
            .timeout(const Duration(seconds: 5), onTimeout: () {})
            .catchError((e) {});
        final xfile = await cameraCtrl.takePicture();
        state.idImage = File(xfile.path);
        final result = await NecxaAI.verifyID(
          state.idImage!,
          userId: state.user?.id,
          action: 'verify-id-front',
        );
        final idResult = _idResultFrom(result);
        if (!idResult.verified) {
          throw UserMessageException(
            _aiFeedback(
              result,
              'National ID front scan failed. Please retake a clearer photo.',
            ),
          );
        }
        state.lastIDResult = idResult;
        state.verificationSubStep = 1;
      } else if (state.verificationSubStep == 1) {
        final xfile = await cameraCtrl.takePicture();
        final rawFile = File(xfile.path);
        state.idBackImage = await ListingSyncService.compressImage(rawFile);
        final result = await NecxaAI.verifyID(
          state.idBackImage!,
          userId: state.user?.id,
          action: 'verify-id-back',
        );
        final idResult = _idResultFrom(result);
        if (!idResult.verified) {
          throw UserMessageException(
            _aiFeedback(
              result,
              'Back of ID scan failed. Keep the document flat and retake it.',
            ),
          );
        }
        state.lastIDBackResult = idResult;
        state.verificationSubStep = 2;
      } else if (state.verificationSubStep == 2) {
        final xfile = await cameraCtrl.takePicture();
        final rawFile = File(xfile.path);
        final compressedFile = await ListingSyncService.compressImage(rawFile);
        state.idHoldingImage = compressedFile;
        final result = await NecxaAI.verifyID(
          state.idHoldingImage!,
          userId: state.user?.id,
          action: 'verify-id-holding',
        );
        final idResult = _idResultFrom(result);
        if (!idResult.verified) {
          throw UserMessageException(
            _aiFeedback(
              result,
              'Holding-ID scan failed. Keep your face and ID visible, then retry.',
            ),
          );
        }
        state.lastHoldingResult = idResult;
        state.verificationSubStep = 3;

        // Auto-toggle to selfie camera for 3D Biometric Match
        await _scannerKey.currentState?.switchCamera(CameraLensDirection.front);
        await Future.delayed(const Duration(milliseconds: 300));
      } else if (state.verificationSubStep == 3) {
        final xfile = await cameraCtrl.takePicture();
        state.faceImage = File(xfile.path);
        final selfieResult = await NecxaAI.verifyFaceOnly(
          state.faceImage!,
          userId: state.user?.id,
        );
        final biometric = _selfieResultFrom(selfieResult);
        if (!biometric.faceMatch || biometric.sessionId.isEmpty) {
          throw UserMessageException(
            _aiFeedback(
              selfieResult,
              'Face liveness verification failed. Please retry in better light.',
            ),
          );
        }
        state.lastSelfieResult = biometric;

        final res = await ListingSyncService.submitIdentityShard(
          country: 'Uganda',
          docType: 'National ID',
          docNumber: '',
          idFront: state.idImage!,
          idBack: state.idBackImage!,
          idHolding: state.idHoldingImage!,
          facePhoto: state.faceImage!,
          frontVerificationId: state.lastIDResult!.sessionId,
          backVerificationId: state.lastIDBackResult!.sessionId,
          holdingVerificationId: state.lastHoldingResult!.sessionId,
          biometricVerificationId: biometric.sessionId,
          idempotencyKey: '$_submissionIdempotencyKey:identity',
        );

        final identityShardId = res['identity_shard_id']?.toString();
        if (res['verified'] != true ||
            identityShardId == null ||
            identityShardId.isEmpty) {
          throw UserMessageException(
            res['message']?.toString() ??
                'Identity shard verification was not approved. Please retake the scans.',
          );
        }
        state.identityShardId = identityShardId;
        _identityShardId = identityShardId;

        try {
          await ListingSyncService.cacheFaceSession(
            sessionId: biometric.sessionId,
            identityShardId: identityShardId,
            faceMatch: biometric.faceMatch,
            score: biometric.score ?? 0,
          );
        } catch (cacheError) {
          // Face cache is best-effort; do not block the wizard.
          print('Face cache integration failed: $cacheError');
        }

        state.verificationSubStep = 4;
      }

      state.notify();
      setState(() => _loading = false);

      if (state.verificationSubStep >= 4) {
        if (_identityAdvanceScheduled) return;
        _identityAdvanceScheduled = true;
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted && _step == 2) {
            setState(() => _step++);
          }
        });
      }
    } catch (e) {
      final message = getUserFriendlyError(e);
      widget.state.setShieldFeedback(message);
      setState(() => _loading = false);
      // Identity failures are already rendered persistently inside this step.
      // Do not duplicate the same message in a full-width SnackBar.
    }
  }

  Future<void> _runUtilityVerification() async {
    setState(() => _loading = true);
    try {
      final res = await ListingSyncService.submitUtilityShard(
        country: "Uganda",
        umemeMeter: _umemeCtrl.text.trim(),
        nwscAccount: _nwscCtrl.text.trim(),
        landBlock: _landBlockCtrl.text.trim(),
        landPlot: _landPlotCtrl.text.trim(),
        lc1Officer: _lc1OfficerCtrl.text.trim(),
        utilityBillPhoto: _utilityBillPhoto,
        lc1StampPhoto: _lc1StampPhoto,
        landTitlePhoto: _landTitlePhoto,
        businessLicensePhoto: _brsLicensePhoto,
        role: _role,
        idempotencyKey: '$_submissionIdempotencyKey:utility',
      );
      final utilityShardId = res['utility_shard_id']?.toString();
      if (res['verified'] != true ||
          utilityShardId == null ||
          utilityShardId.isEmpty) {
        throw UserMessageException(
          res['message']?.toString() ??
              'The utility or authority documents were not approved.',
        );
      }
      if (!mounted) return;
      setState(() {
        _utilityShardId = utilityShardId;
        widget.state.utilityShardId = utilityShardId;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      _showError(getUserFriendlyError(e));
    }
  }

  Future<void> _lockGps() async {
    setState(() => _loading = true);
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );
      final result = await ListingSyncService.submitGpsLock(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracy: pos.accuracy,
        reportedAddress: _districtCtrl.text,
        reportedDistrict: _districtCtrl.text,
        idempotencyKey: '$_submissionIdempotencyKey:gps',
      );
      final gpsNodeId =
          result['gps_node_id']?.toString() ?? result['id']?.toString();
      if (gpsNodeId == null || gpsNodeId.isEmpty) {
        throw UserMessageException(
          'The GPS node could not be confirmed. Please move outdoors and retry.',
        );
      }
      if (result['risk_flag'] == true) {
        throw UserMessageException(
          result['message']?.toString() ??
              'GPS accuracy is too low. Move outdoors and lock the location again.',
        );
      }
      if (!mounted) return;
      setState(() {
        _gpsPosition = pos;
        _gpsLocked = true;
        _gpsNodeId = gpsNodeId;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      _showError(getUserFriendlyError(e));
    }
  }

  Future<void> _submitListing() async {
    setState(() => _loading = true);
    try {
      final identityShardId = _identityShardId ?? widget.state.identityShardId;
      if (identityShardId == null || identityShardId.isEmpty) {
        throw UserMessageException(
          'Your verified identity shard is missing. Return to the identity step and verify again.',
        );
      }
      if (_utilityShardId == null || _utilityShardId!.isEmpty) {
        throw UserMessageException(
          'Your verified utility shard is missing. Return to the utility step.',
        );
      }
      if (_gpsNodeId == null || _gpsNodeId!.isEmpty) {
        throw UserMessageException(
          'Your GPS node is missing. Return to the GPS step and lock the property.',
        );
      }
      final result = await ListingSyncService.submitNeuralSynthesis(
        identityShardId: identityShardId,
        utilityShardId: _utilityShardId!,
        gpsNodeId: _gpsNodeId!,
        title: _titleCtrl.text,
        description: _descCtrl.text,
        propertyType: _propType,
        purpose: _purpose,
        country: "Uganda",
        district: _districtCtrl.text,
        address: _cityCtrl.text,
        priceUgx: int.tryParse(_priceCtrl.text.replaceAll(',', '')) ?? 0,
        pricePeriod: _priceType,
        bedrooms: _bedrooms,
        bathrooms: _bathrooms,
        sqft: _sqft,
        amenities: _amenities.toList(),
        photos: _exteriorPhotos + _interiorPhotos,
        bathroomPhotos: _bathroomPhotos,
        livePingLat: widget.state.livePingGps?.latitude,
        livePingLng: widget.state.livePingGps?.longitude,
        securityMetadata: await widget.state.getFullSecurityMetadata(),
        idempotencyKey: _submissionIdempotencyKey,
      );

      final listingId = result['listing_id']?.toString();
      final mintEventId = result['mint_event_id']?.toString();
      if (result['success'] != true ||
          listingId == null ||
          listingId.isEmpty ||
          mintEventId == null ||
          mintEventId.isEmpty) {
        throw UserMessageException(
          result['message']?.toString() ??
              'The listing was not confirmed by the server. Please retry.',
        );
      }
      if (!mounted) return;
      setState(() {
        _submitted = true;
        _mintEventId = mintEventId;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      _showError(getUserFriendlyError(e));
    }
  }

  Future<void> _addPropertyPhoto(String category, File file) async {
    setState(() => _loading = true);
    try {
      final assessment = await NecxaAI.verifyListingPhotoNvidia(
        photo: file,
        category: category.toLowerCase(),
        title: _titleCtrl.text.trim().isEmpty
            ? 'Property listing'
            : _titleCtrl.text.trim(),
      );
      if (assessment['success'] != true || assessment['verified'] != true) {
        throw UserMessageException(
          assessment['reasoning']?.toString() ??
              assessment['description']?.toString() ??
              assessment['error']?.toString() ??
              'This photo could not be approved. Use a clear, original property photo.',
        );
      }
      if (!mounted) return;
      setState(() {
        if (category == 'EXTERIOR') {
          _exteriorPhotos.add(file);
        } else if (category == 'INTERIOR') {
          _interiorPhotos.add(file);
        } else {
          _bathroomPhotos.add(file);
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError(getUserFriendlyError(e));
    }
  }

  Future<void> _generateListingDetailsFromPhotos({File? specificPhoto}) async {
    List<File> sourcePhotos = [];
    if (specificPhoto != null) {
      sourcePhotos.add(specificPhoto);
    } else {
      sourcePhotos = [
        ..._exteriorPhotos,
        ..._interiorPhotos,
        ..._bathroomPhotos,
      ];
    }

    if (sourcePhotos.isEmpty) {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      sourcePhotos.add(File(picked.path));
    }

    setState(() => _aiGenerating = true);

    try {
      final result = await NecxaAI.generateListingDetails(
        photos: sourcePhotos,
        propertyType: _propType,
        district: _districtCtrl.text.trim(),
        city: _cityCtrl.text.trim(),
        purpose: _purpose,
        existingTitle: _titleCtrl.text.trim(),
      );

      if (result['success'] != true) {
        throw Exception(result['error'] ?? 'Could not generate details');
      }

      final generatedDesc = result['description'] as String? ?? '';
      final generatedTitle = result['title'] as String? ?? '';
      final generatedAmenities =
          (result['amenities'] as List?)?.cast<String>() ?? [];
      final suggestedBeds = result['suggested_bedrooms'] as int?;
      final suggestedBaths = result['suggested_bathrooms'] as int?;

      if (!mounted) return;

      setState(() {
        if (generatedDesc.isNotEmpty) {
          _descCtrl.text = generatedDesc;
        }
        if (generatedTitle.isNotEmpty && _titleCtrl.text.trim().isEmpty) {
          _titleCtrl.text = generatedTitle;
        }
        if (generatedAmenities.isNotEmpty) {
          _amenities.addAll(generatedAmenities);
        }
        if (suggestedBeds != null && _bedrooms == 0) {
          _bedrooms = suggestedBeds;
        }
        if (suggestedBaths != null && _bathrooms == 1) {
          _bathrooms = suggestedBaths;
        }
        _aiGenerating = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: C.cardDk,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: C.brand.withOpacity(0.6)),
            ),
            content: Row(
              children: [
                Icon(Icons.auto_awesome, color: C.brand, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '✨ Description & ${generatedAmenities.length} amenities generated with NVIDIA Vision!',
                    style: syne(sz: 13, w: FontWeight.w600, c: C.text),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _aiGenerating = false);
      _showError('AI Generation Error: ${e.toString()}');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
    );
  }
}

// -- Components -------------------------------------------------------------

class _Step1 extends StatelessWidget {
  final TextEditingController titleCtrl, districtCtrl, cityCtrl, descCtrl;
  final String propType, purpose, role;
  final ValueChanged<String> onType, onPurpose, onRole;
  final VoidCallback onGenerateAi;
  final bool aiGenerating;
  final bool hasPhotos;

  const _Step1({
    required this.titleCtrl,
    required this.districtCtrl,
    required this.cityCtrl,
    required this.descCtrl,
    required this.propType,
    required this.purpose,
    required this.role,
    required this.onType,
    required this.onPurpose,
    required this.onRole,
    required this.onGenerateAi,
    required this.aiGenerating,
    required this.hasPhotos,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Distinguish Role'),
        Row(
          children: [
            _roleBtn(
              'Individual Owner',
              'owner',
              role == 'owner',
              () => onRole('owner'),
            ),
            const SizedBox(width: 12),
            _roleBtn(
              'Certified Agent',
              'agent',
              role == 'agent',
              () => onRole('agent'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _label('Property Title'),
        _input(titleCtrl, 'e.g. Modern Villa with Pool'),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('District'),
                  _input(districtCtrl, 'e.g. Kololo'),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [_label('City'), _input(cityCtrl, 'e.g. Kampala')],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _label('Description'),
            GestureDetector(
              onTap: aiGenerating ? null : onGenerateAi,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: C.brand.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: C.brand.withOpacity(0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    aiGenerating
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: C.brand,
                            ),
                          )
                        : Icon(Icons.auto_awesome, size: 13, color: C.brand),
                    const SizedBox(width: 5),
                    Text(
                      aiGenerating
                          ? 'Analyzing...'
                          : (hasPhotos ? 'Auto-Draft with AI' : 'Draft with AI Photo'),
                      style: syne(sz: 11, w: FontWeight.w700, c: C.brand),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _input(descCtrl, 'Describe your property...', maxLines: 3),
        const SizedBox(height: 16),
        _label('Property Type'),
        Wrap(
          spacing: 8,
          children: [
            'apartment',
            'house',
            'villa',
            'commercial',
          ].map((t) => _chip(t, propType == t, () => onType(t))).toList(),
        ),
        const SizedBox(height: 16),
        _label('Purpose'),
        Wrap(
          spacing: 8,
          children: [
            'rent',
            'sale',
          ].map((p) => _chip(p, purpose == p, () => onPurpose(p))).toList(),
        ),
      ],
    );
  }

  Widget _roleBtn(String label, String value, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: active ? C.brand.withOpacity(.1) : C.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: active ? C.brand : C.border),
          ),
          child: Center(
            child: Text(
              label,
              style: syne(
                sz: 12,
                w: FontWeight.w700,
                c: active ? C.brand : C.dim,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Step2 extends StatelessWidget {
  final TextEditingController priceCtrl;
  final String priceType;
  final int bedrooms, bathrooms, sqft;
  final Set<String> amenities;
  final ValueChanged<String> onPriceType;
  final ValueChanged<int> onBeds, onBaths, onSqft;
  final ValueChanged<Set<String>> onAmenities;
  const _Step2({
    required this.priceCtrl,
    required this.priceType,
    required this.bedrooms,
    required this.bathrooms,
    required this.sqft,
    required this.amenities,
    required this.onPriceType,
    required this.onBeds,
    required this.onBaths,
    required this.onSqft,
    required this.onAmenities,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Price (UGX)'),
        Row(
          children: [
            Expanded(
              child: _input(
                priceCtrl,
                'e.g. 5,000,000',
                keyboard: TextInputType.number,
              ),
            ),
            const SizedBox(width: 12),
            _chip(
              'monthly',
              priceType == 'monthly',
              () => onPriceType('monthly'),
            ),
            const SizedBox(width: 8),
            _chip(
              'nightly',
              priceType == 'nightly',
              () => onPriceType('nightly'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(child: _counter('Bedrooms', bedrooms, onBeds)),
            const SizedBox(width: 12),
            Expanded(child: _counter('Bathrooms', bathrooms, onBaths)),
          ],
        ),
        const SizedBox(height: 24),
        _label('Amenities'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: ['WiFi', 'Pool', 'Parking', 'Security', 'Gym', 'AC'].map((
            a,
          ) {
            final sel = amenities.contains(a);
            return _chip(a, sel, () {
              final next = Set<String>.from(amenities);
              if (sel) {
                next.remove(a);
              } else {
                next.add(a);
              }
              onAmenities(next);
            });
          }).toList(),
        ),
      ],
    );
  }

  Widget _counter(String label, int val, ValueChanged<int> onChanged) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.border),
      ),
      child: Column(
        children: [
          Text(label, style: syne(sz: 11, c: C.dim)),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: val > 0 ? () => onChanged(val - 1) : null,
                icon: const Icon(Icons.remove, size: 16),
              ),
              Text('$val', style: syne(sz: 18, w: FontWeight.bold)),
              IconButton(
                onPressed: () => onChanged(val + 1),
                icon: const Icon(Icons.add, size: 16),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Step3Identity extends StatelessWidget {
  final AppState state;
  final bool idVerified, faceVerified, loading;
  final int subStep;
  final Future<void> Function() onVerify;
  final GlobalKey<_NeuralScannerOverlayState> scannerKey;
  const _Step3Identity({
    required this.state,
    required this.idVerified,
    required this.faceVerified,
    required this.loading,
    required this.subStep,
    required this.onVerify,
    required this.scannerKey,
  });

  @override
  Widget build(BuildContext context) {
    // scannerKey is now passed from parent to maintain stability

    final instructions = [
      (
        'National ID (Front)',
        'Ensure the text is clearly visible and within the frame.',
        Icons.badge_outlined,
      ),
      (
        'National ID (Back)',
        'Flip your card and scan the reverse side barcode/details.',
        Icons.qr_code_scanner,
      ),
      (
        'Holding ID Photo',
        'Fit your face and ID inside the frame. Indoor light is okay.',
        Icons.front_hand_outlined,
      ),
      (
        '3D Biometric Match',
        'Hold your phone at eye level for a live biometric synthesis.',
        Icons.face_retouching_natural,
      ),
    ];

    final currentInstr = instructions[subStep.clamp(0, 3)];
    final completedStages = [
      state.lastIDResult?.verified ?? false,
      state.idBackImage != null, // back: captured is enough
      state.lastHoldingResult?.verified ?? false,
      state.lastSelfieResult?.faceMatch ?? false,
    ];
    final completedCount = completedStages.where((complete) => complete).length;

    return Column(
      children: [
        Stack(
          children: [
            _NeuralScannerOverlay(key: scannerKey, documentMode: subStep < 2, subStep: subStep),
            if (loading)
              Positioned(
                left: 18,
                right: 18,
                bottom: 18,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: C.bg.withOpacity(.88),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: C.brand.withOpacity(.42)),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          color: C.brand,
                          strokeWidth: 2.5,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Verifying secure capture...',
                          style: syne(
                            sz: 10,
                            c: C.brand,
                            ls: 1.1,
                            w: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (subStep == 2) ...[
          const SizedBox(height: 12),
          const _HoldingCaptureStatus(),
        ],
        const SizedBox(height: 20),
        _InstructionCard(
          title: currentInstr.$1,
          desc: currentInstr.$2,
          icon: currentInstr.$3,
        ),

        const SizedBox(height: 14),
        _IdentityCaptureProgress(
          completedStages: completedStages,
          completedCount: completedCount,
        ),

        if (state.shieldFeedback != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.shieldFeedback!,
                    style: dm(sz: 11, c: Colors.redAccent),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 36),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: loading ? null : onVerify,
            style: ElevatedButton.styleFrom(
              backgroundColor: C.brand,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon: const Icon(Icons.camera_alt_outlined, color: Colors.black),
            label: Text(
              loading
                  ? 'VERIFYING...'
                  : subStep == 2
                      ? 'SCAN HOLDING ID PHOTO'
                      : 'SCAN ${currentInstr.$1.toUpperCase()}',
              style: syne(c: Colors.black, w: FontWeight.w800, ls: .5),
            ),
          ),
        ),
        if (subStep == 2) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lightbulb_outline, size: 14, color: Colors.white70),
              const SizedBox(width: 6),
              Text(
                'Tips: Avoid glare, blur and cropped edges.',
                style: dm(sz: 11, c: Colors.white70),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _HoldingCaptureStatus extends StatelessWidget {
  const _HoldingCaptureStatus();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.border),
      ),
      child: const Row(
        children: [
          Expanded(
            child: _HoldingStatusItem(
              icon: Icons.light_mode_outlined,
              title: 'Lighting',
              value: 'Clear',
              color: Color(0xFF00E676),
            ),
          ),
          _HoldingStatusDivider(),
          Expanded(
            child: _HoldingStatusItem(
              icon: Icons.badge_outlined,
              title: 'ID readability',
              value: 'Readable',
              color: Color(0xFFFFD54F),
            ),
          ),
          _HoldingStatusDivider(),
          Expanded(
            child: _HoldingStatusItem(
              icon: Icons.face_retouching_natural,
              title: 'Face',
              value: 'Visible',
              color: Color(0xFF00E5FF),
            ),
          ),
        ],
      ),
    );
  }
}

class _HoldingStatusDivider extends StatelessWidget {
  const _HoldingStatusDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 30,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: C.border,
    );
  }
}

class _HoldingStatusItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final Color color;

  const _HoldingStatusItem({
    required this.icon,
    required this.title,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: dm(sz: 9, c: C.dim)),
              Text(value, style: dm(sz: 10, c: color, w: FontWeight.w700)),
            ],
          ),
        ),
      ],
    );
  }
}

class _IdentityCaptureProgress extends StatelessWidget {
  final List<bool> completedStages;
  final int completedCount;

  const _IdentityCaptureProgress({
    required this.completedStages,
    required this.completedCount,
  });

  @override
  Widget build(BuildContext context) {
    const labels = ['Front', 'Back', 'Holding ID', 'Face match'];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$completedCount of 4 secure captures verified',
            style: syne(sz: 11, w: FontWeight.w700, c: C.dim),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(labels.length, (index) {
              final complete = completedStages[index];
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: complete
                      ? C.brand.withOpacity(.12)
                      : C.text.withOpacity(.04),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: complete ? C.brand.withOpacity(.5) : C.border,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      complete
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 14,
                      color: complete ? C.brand : C.dim,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      labels[index],
                      style: dm(sz: 10, c: complete ? C.brand : C.dim),
                    ),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _InstructionCard extends StatelessWidget {
  final String title, desc;
  final IconData icon;
  const _InstructionCard({
    required this.title,
    required this.desc,
    required this.icon,
  });
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: C.brand, size: 24),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: syne(sz: 14, w: FontWeight.bold)),
              Text(desc, style: dm(sz: 11, c: C.dim)),
            ],
          ),
        ),
      ],
    );
  }
}

class _NeuralScannerOverlay extends StatefulWidget {
  final bool documentMode;
  final int subStep;
  const _NeuralScannerOverlay({super.key, required this.documentMode, this.subStep = 0});
  @override
  State<_NeuralScannerOverlay> createState() => _NeuralScannerOverlayState();
}

class _NeuralScannerOverlayState extends State<_NeuralScannerOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();
  CameraController? cameraCtrl;
  CameraLensDirection _currentDirection = CameraLensDirection.back;
  Future<void>? _cameraInitialization;

  @override
  void initState() {
    super.initState();
    unawaited(
      switchCamera(CameraLensDirection.back).catchError((Object error) {
        debugPrint('Camera initialization error: $error');
      }),
    );
  }

  Future<void> _initCamera(CameraLensDirection direction) async {
    if (cameras.isEmpty) {
      throw Exception('No camera is available on this device.');
    }

    // Find the camera with the desired direction
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == direction,
      orElse: () => cameras.first,
    );

    await cameraCtrl?.dispose();

    final nextController = CameraController(
      camera,
      ResolutionPreset.high, // CORRECT RESOLUTION FOR AI CLARITY
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    cameraCtrl = nextController;

    try {
      await nextController.initialize();
      await _setZoomLevel(nextController, 1.0);
      _currentDirection = direction;
      if (mounted) setState(() {});
    } catch (e) {
      if (identical(cameraCtrl, nextController)) cameraCtrl = null;
      await nextController.dispose();
      rethrow;
    }
  }

  Future<void> _setZoomLevel(CameraController controller, double zoomLevel) async {
    try {
      await controller.setZoomLevel(zoomLevel);
    } catch (error) {
      debugPrint('Camera zoom unavailable: $error');
    }
  }

  Future<void> switchCamera(CameraLensDirection direction) async {
    final pendingInitialization = _cameraInitialization;
    if (pendingInitialization != null) await pendingInitialization;

    final currentController = cameraCtrl;
    if (_currentDirection == direction &&
        currentController != null &&
        currentController.value.isInitialized) {
      return;
    }

    final initialization = _initCamera(direction);
    _cameraInitialization = initialization;
    try {
      await initialization;
    } finally {
      if (identical(_cameraInitialization, initialization)) {
        _cameraInitialization = null;
      }
    }
  }

  Future<CameraController> ensureCamera(CameraLensDirection direction) async {
    await switchCamera(direction);
    final activeController = cameraCtrl;
    if (activeController == null || !activeController.value.isInitialized) {
      throw Exception(
        'Camera is not ready yet. Please wait a moment and try again.',
      );
    }
    return activeController;
  }

  @override
  void didUpdateWidget(_NeuralScannerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.subStep != oldWidget.subStep) {
      if (cameraCtrl != null && cameraCtrl!.value.isInitialized) {
        unawaited(_setZoomLevel(cameraCtrl!, 1.0));
      }

      if (widget.subStep == 3) {
        unawaited(switchCamera(CameraLensDirection.front).catchError((_) {}));
      } else if (widget.subStep < 3 && oldWidget.subStep == 3) {
        unawaited(switchCamera(CameraLensDirection.back).catchError((_) {}));
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    cameraCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isHolding = widget.subStep == 2;
    final viewport = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: C.cardDk,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: C.brand.withOpacity(.7), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: C.brand.withOpacity(.12),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(25),
        child: Stack(
          children: [
            if (cameraCtrl != null && cameraCtrl!.value.isInitialized)
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // The camera plugin exposes a portrait preview. Scale it to
                    // to cover the viewport rather than leaving black bars.
                    final viewportAspect =
                        constraints.maxWidth / constraints.maxHeight;
                    double previewAspect = cameraCtrl!.value.aspectRatio;

                    // Correct for camera's native aspect ratio inversion on portrait devices.
                    // If the device is in portrait but the preview aspect ratio is landscape (> 1),
                    // the CameraPreview widget will rotate it internally. We must use the inverted ratio.
                    final isPortrait =
                        MediaQuery.of(context).orientation ==
                        Orientation.portrait;
                    if (isPortrait && previewAspect > 1.0) {
                      previewAspect = 1.0 / previewAspect;
                    } else if (!isPortrait && previewAspect < 1.0) {
                      previewAspect = 1.0 / previewAspect;
                    }

                    final coverScale = viewportAspect > previewAspect
                        ? viewportAspect / previewAspect
                        : previewAspect / viewportAspect;
                    // Identity captures need the full face/card visible. Keep
                    // the native preview scale instead of cropping to cover.
                    final scale = widget.subStep >= 2 ? 1.0 : coverScale;

                    return ClipRect(
                      child: Transform.scale(
                        scale: scale,
                        child: Center(child: CameraPreview(cameraCtrl!)),
                      ),
                    );
                  },
                ),
              )
            else
              const Center(
                child: Opacity(
                  opacity: 0.1,
                  child: Icon(
                    Icons.document_scanner,
                    size: 100,
                    color: C.brand,
                  ),
                ),
              ),

            IgnorePointer(
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, child) {
                  return CustomPaint(
                    size: Size.infinite,
                    painter: _ScannerOverlayPainter(
                      documentMode: widget.documentMode,
                      holdingMode: isHolding,
                      progress: _ctrl.value,
                    ),
                  );
                },
              ),
            ),

            // The Scanner Eye (Document Mode Only — not for holding)
            if (widget.documentMode && !isHolding)
              AnimatedBuilder(
                animation: _ctrl,
                builder: (context, child) => Positioned(
                  top: _ctrl.value * 270,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      boxShadow: const [
                        BoxShadow(
                          color: C.brand,
                          blurRadius: 10,
                          spreadRadius: 2,
                        ),
                      ],
                      gradient: LinearGradient(
                        colors: [
                          C.brand.withOpacity(0),
                          C.brand,
                          C.brand.withOpacity(0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // ── BIOMETRIC HUD (selfie mode only) ──────────────────────────
            if (!widget.documentMode) ...[
              // Top 'LIVE' pill
              Positioned(
                top: 14,
                left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: C.brand,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'LIVE',
                        style: dm(sz: 10, c: Colors.white, w: FontWeight.bold, ls: 0.5),
                      ),
                    ],
                  ),
                ),
              ),

              // Top 'Tips' pill
              Positioned(
                top: 14,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.5),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(.2)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.info_outline, size: 12, color: Colors.white),
                      const SizedBox(width: 5),
                      Text(
                        'Tips',
                        style: dm(sz: 10, c: Colors.white, w: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom prompts
              Positioned(
                bottom: 24,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Fit your face within the oval and look straight',
                      style: dm(sz: 12, c: Colors.white, w: FontWeight.w500),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildTip(Icons.light_mode_outlined, 'Good lighting'),
                        Container(width: 1, height: 12, color: Colors.white.withOpacity(.2), margin: const EdgeInsets.symmetric(horizontal: 12)),
                        _buildTip(Icons.shield_outlined, 'No filters'),
                        Container(width: 1, height: 12, color: Colors.white.withOpacity(.2), margin: const EdgeInsets.symmetric(horizontal: 12)),
                        _buildTip(Icons.face_retouching_off, 'No hats or glasses'),
                      ],
                    ),
                  ],
                ),
              ),
            ],

            if (!isHolding)
              const Positioned(top: 18, left: 18, child: _ScannerNodeStatus()),
            Positioned(
              top: 14,
              right: 14,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: C.text.withOpacity(.94),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.bolt_outlined, color: C.bg, size: 22),
                  ),
                  if (widget.subStep >= 2) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () {
                        final newDirection = _currentDirection == CameraLensDirection.front
                            ? CameraLensDirection.back
                            : CameraLensDirection.front;
                        switchCamera(newDirection).catchError((_) {});
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: C.text.withOpacity(.94),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.flip_camera_ios_outlined, color: C.bg, size: 20),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return isHolding
        ? AspectRatio(aspectRatio: 1.7, child: viewport)
        : SizedBox(height: 270, child: viewport);
  }

  Widget _buildTip(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.cyanAccent),
        const SizedBox(width: 4),
        Text(
          label,
          style: dm(sz: 10, c: Colors.white70),
        ),
      ],
    );
  }

}

class _ScannerNodeStatus extends StatelessWidget {
  const _ScannerNodeStatus();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PulsingLight(),
          const SizedBox(width: 6),
          Text(
            'NEURAL PULSE ACTIVE',
            style: dm(sz: 10, w: FontWeight.w900, c: C.brand, ls: .4),
          ),
        ],
      ),
    );
  }
}

class _PulsingLight extends StatefulWidget {
  const _PulsingLight();
  @override
  State<_PulsingLight> createState() => _PulsingLightState();
}

class _PulsingLightState extends State<_PulsingLight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _ctrl,
    child: Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: C.brand, shape: BoxShape.circle),
    ),
  );
}

class _Step4Utility extends StatelessWidget {
  final String role;
  final TextEditingController umemeCtrl,
      nwscCtrl,
      landBlockCtrl,
      landPlotCtrl,
      lc1OfficerCtrl;
  final File? utilityBillPhoto, lc1StampPhoto, landTitlePhoto, brsLicensePhoto;
  final bool loading;
  final String? utilityShardId;
  final ValueChanged<File> onPickUtilityBill, onPickLc1, onPickTitle, onPickBrs;
  final VoidCallback onSave;

  const _Step4Utility({
    required this.role,
    required this.umemeCtrl,
    required this.nwscCtrl,
    required this.landBlockCtrl,
    required this.landPlotCtrl,
    required this.lc1OfficerCtrl,
    this.utilityBillPhoto,
    this.lc1StampPhoto,
    this.landTitlePhoto,
    this.brsLicensePhoto,
    required this.loading,
    this.utilityShardId,
    required this.onPickUtilityBill,
    required this.onPickLc1,
    required this.onPickTitle,
    required this.onPickBrs,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Umeme Meter Number'),
        _input(umemeCtrl, 'e.g. 1012345'),
        const SizedBox(height: 16),
        _label('NWSC Account'),
        _input(nwscCtrl, 'e.g. NW-9876'),
        const SizedBox(height: 16),
        _filePick(
          'Utility Bill (UMEME / NWSC)',
          utilityBillPhoto,
          onPickUtilityBill,
        ),
        const SizedBox(height: 20),
        _label('Land Title Reference'),
        Row(
          children: [
            Expanded(child: _input(landBlockCtrl, 'Block number')),
            const SizedBox(width: 10),
            Expanded(child: _input(landPlotCtrl, 'Plot number')),
          ],
        ),
        const SizedBox(height: 16),
        _label('LC1 Authorising Officer'),
        _input(lc1OfficerCtrl, 'Officer name shown on the stamp'),
        const SizedBox(height: 16),
        _label('Authority Docs'),
        _filePick('LC1 Authority Stamp', lc1StampPhoto, onPickLc1),
        const SizedBox(height: 12),
        _filePick('Land Title (Proof)', landTitlePhoto, onPickTitle),
        if (role == 'agent') ...[
          const SizedBox(height: 12),
          _filePick('Brokerage / BRS License', brsLicensePhoto, onPickBrs),
        ],
        const SizedBox(height: 32),
        if (utilityShardId == null)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: loading ? null : onSave,
              child: Text(loading ? 'Syncing...' : 'Sync Shard'),
            ),
          ),
        if (utilityShardId != null)
          const Center(
            child: Text(
              '? Utility Shard Synced',
              style: TextStyle(color: C.brand),
            ),
          ),
      ],
    );
  }

  Widget _filePick(String label, File? file, ValueChanged<File> onPick) {
    return GestureDetector(
      onTap: () async {
        final f = await ImagePicker().pickImage(
          source: ImageSource.camera,
          preferredCameraDevice: CameraDevice.rear, // DOCUMENT REQUIREMENT
        );
        if (f != null) onPick(File(f.path));
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: file != null ? C.brand.withOpacity(.05) : C.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: file != null ? C.brand : C.border),
        ),
        child: Row(
          children: [
            Icon(
              file != null ? Icons.check_circle : Icons.camera_alt,
              color: file != null ? C.brand : C.dim,
            ),
            const SizedBox(width: 12),
            Text(label, style: syne(sz: 13, c: file != null ? C.brand : C.dim)),
          ],
        ),
      ),
    );
  }
}

class _Step5GPS extends StatelessWidget {
  final Position? pos;
  final bool locked;
  final bool loading;
  final VoidCallback onLock;
  const _Step5GPS({
    this.pos,
    required this.locked,
    required this.loading,
    required this.onLock,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(
          locked ? Icons.gps_fixed : Icons.location_off,
          size: 80,
          color: locked ? C.brand : C.dim,
        ),
        const SizedBox(height: 24),
        Text(
          locked ? 'Coordinates Locked' : 'GPS Verification',
          style: syne(sz: 18, w: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          'You must be physically present at the property to lock the coordinates.',
          textAlign: TextAlign.center,
          style: dm(c: C.dim),
        ),
        const SizedBox(height: 40),
        if (!locked)
          SizedBox(
            width: 180,
            child: ElevatedButton(
              onPressed: loading ? null : onLock,
              child: Text(loading ? 'Scanning...' : 'Lock Now'),
            ),
          ),
        if (locked)
          Text('${pos?.latitude}, ${pos?.longitude}', style: dm(c: C.dim)),
      ],
    );
  }
}

class _Step6Photos extends StatelessWidget {
  final List<File> exterior, interior, bathrooms;
  final bool loading;
  final bool aiGenerating;
  final Future<void> Function(String, File) onAdd;
  final Function(String, int) onRemove;
  final VoidCallback onGenerateAi;

  const _Step6Photos({
    required this.exterior,
    required this.interior,
    required this.bathrooms,
    required this.loading,
    required this.aiGenerating,
    required this.onAdd,
    required this.onRemove,
    required this.onGenerateAi,
  });

  @override
  Widget build(BuildContext context) {
    final totalPhotos = exterior.length + interior.length + bathrooms.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _photoRow('Exterior View', exterior, 'EXTERIOR'),
        const SizedBox(height: 24),
        _photoRow('Interior & Rooms', interior, 'INTERIOR'),
        const SizedBox(height: 24),
        _photoRow('Bathrooms', bathrooms, 'BATHROOM'),
        const SizedBox(height: 32),

        // ── NVIDIA Vision Assistant Banner ──
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                C.card,
                C.brand.withOpacity(0.08),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: C.brand.withOpacity(0.35), width: 1.2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: C.brand.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.auto_awesome, color: C.brand, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'NVIDIA Vision AI Assistant',
                          style: syne(sz: 14, w: FontWeight.w700, c: C.text),
                        ),
                        Text(
                          'Auto-generate description & detect amenities from photos',
                          style: dm(sz: 11, c: C.dim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: (loading || aiGenerating) ? null : onGenerateAi,
                  icon: aiGenerating
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: C.bg,
                          ),
                        )
                      : const Icon(Icons.psychology, size: 18),
                  label: Text(
                    aiGenerating
                        ? 'Analyzing Photos with NVIDIA Vision...'
                        : (totalPhotos > 0
                            ? 'Auto-Generate Description & Amenities'
                            : 'Pick Photo to Generate Details'),
                    style: syne(sz: 12, w: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: C.brand,
                    foregroundColor: C.bg,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _photoRow(String label, List<File> files, String cat) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        SizedBox(
          height: 100,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              GestureDetector(
                onTap: loading
                    ? null
                    : () async {
                        final f = await ImagePicker().pickImage(
                          source: ImageSource.gallery,
                        );
                        if (f != null) await onAdd(cat, File(f.path));
                      },
                child: Container(
                  width: 100,
                  decoration: BoxDecoration(
                    color: C.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: C.border),
                  ),
                  child: loading
                      ? const Padding(
                          padding: EdgeInsets.all(34),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.add_a_photo, color: C.dim),
                ),
              ),
              ...files.asMap().entries.map((entry) {
                final index = entry.key;
                final f = entry.value;
                return Stack(
                  children: [
                    Container(
                      width: 100,
                      height: 100,
                      margin: const EdgeInsets.only(left: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        image: DecorationImage(
                          image: FileImage(f),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: () => onRemove(cat, index),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close,
                              size: 12, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      ],
    );
  }
}

class _Step7Review extends StatelessWidget {
  final String title, role, propType, price, priceType;
  final String? mintEventId;
  final bool idVerified, faceVerified, gpsLocked, submitted, loading;
  final int photoCount;
  final VoidCallback onSubmit;

  const _Step7Review({
    required this.title,
    required this.role,
    required this.propType,
    required this.price,
    required this.priceType,
    this.mintEventId,
    required this.idVerified,
    required this.faceVerified,
    required this.gpsLocked,
    required this.submitted,
    required this.loading,
    required this.photoCount,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    if (submitted) return _success(context);
    return Column(
      children: [
        _reviewCard(
          'Identity Shard',
          idVerified && faceVerified ? 'Verified ?' : 'Required ?',
        ),
        _reviewCard('GPS Node', gpsLocked ? 'Locked ?' : 'Required ?'),
        _reviewCard(
          'Photos',
          photoCount > 0 ? '$photoCount Uploaded ?' : 'Required ?',
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: loading ? null : onSubmit,
            child: Text(loading ? 'MINTING...' : 'Synthesize & Mint'),
          ),
        ),
      ],
    );
  }

  Widget _reviewCard(String label, String val) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: syne(sz: 14)),
          Text(val, style: syne(c: C.dim)),
        ],
      ),
    );
  }

  Widget _success(BuildContext ctx) {
    return Center(
      child: Column(
        children: [
          Icon(Icons.stars, size: 80, color: C.brand),
          const SizedBox(height: 24),
          Text(
            'Listing Minted!',
            style: syne(sz: 24, w: FontWeight.w900, c: C.brand),
          ),
          Text(
            'Your event ID: ${mintEventId ?? "PENDING"}',
            style: dm(c: C.dim),
          ),
          const SizedBox(height: 48),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Back to Home'),
          ),
        ],
      ),
    );
  }
}

// -- Helpers -----------------------------------------------------------------

Widget _label(String text) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Text(
    text.toUpperCase(),
    style: syne(sz: 11, w: FontWeight.bold, c: C.dim, ls: 1),
  ),
);

Widget _input(
  TextEditingController ctrl,
  String hint, {
  int maxLines = 1,
  TextInputType keyboard = TextInputType.text,
}) => TextField(
  controller: ctrl,
  maxLines: maxLines,
  keyboardType: keyboard,
  style: dm(),
  decoration: InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: C.card,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: C.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: C.border),
    ),
  ),
);

Widget _chip(String label, bool sel, VoidCallback onTap) => GestureDetector(
  onTap: onTap,
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: sel ? C.brand.withOpacity(.1) : C.card,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: sel ? C.brand : C.border),
    ),
    child: Text(
      label,
      style: syne(sz: 13, w: FontWeight.w700, c: sel ? C.brand : C.dim),
    ),
  ),
);

class _ScannerOverlayPainter extends CustomPainter {
  final bool documentMode;
  final bool holdingMode;
  final double progress;

  _ScannerOverlayPainter({required this.documentMode, this.holdingMode = false, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = Colors.black.withOpacity(0.55);
    final bgPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    if (holdingMode) {
      // ── HOLDING MODE: ID guide on left, face guide on right ──
      const topPad = 38.0;
      const bottomPad = 42.0;
      const sidePad = 12.0;
      const gap = 12.0;

      final availableW = size.width - (sidePad * 2) - gap;
      final faceW = availableW * 0.40;
      final idW = availableW * 0.60;
      final areaH = size.height - topPad - bottomPad;

      // Keep both guides inside the shallow landscape viewport without
      // cropping the face or the four edges of the document.
      final faceH = areaH * 0.82;
      final faceTop = topPad + (areaH - faceH) / 2;
      final faceRect = Rect.fromLTWH(
        sidePad + idW + gap,
        faceTop,
        faceW,
        faceH,
      );
      final faceRRect = RRect.fromRectAndRadius(faceRect, const Radius.circular(20));

      // Left ID card area (landscape standard 1.55 ratio)
      final idH = (idW / 1.55).clamp(0.0, areaH * 0.82);
      final idTop = topPad + (areaH - idH) / 2;
      final idRect = Rect.fromLTWH(sidePad, idTop, idW, idH);
      final idRRect = RRect.fromRectAndRadius(idRect, const Radius.circular(16));

      // Combine cutouts from dark translucent backdrop
      final combinedCutout = Path.combine(
        PathOperation.union,
        Path()..addRRect(faceRRect),
        Path()..addRRect(idRRect),
      );
      final maskPath = Path.combine(PathOperation.difference, bgPath, combinedCutout);
      canvas.drawPath(maskPath, bgPaint);

      // Cyan corner brackets on Face area (exact match to screenshot)
      final faceBracketPaint = Paint()
        ..color = const Color(0xFF00E5FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round;
      final fr = faceRect;
      const fLen = 22.0;
      const fRad = 18.0;

      // Top-left
      canvas.drawPath(Path()..moveTo(fr.left, fr.top + fLen)..lineTo(fr.left, fr.top + fRad)..arcToPoint(Offset(fr.left + fRad, fr.top), radius: const Radius.circular(fRad))..lineTo(fr.left + fLen, fr.top), faceBracketPaint);
      // Top-right
      canvas.drawPath(Path()..moveTo(fr.right - fLen, fr.top)..lineTo(fr.right - fRad, fr.top)..arcToPoint(Offset(fr.right, fr.top + fRad), radius: const Radius.circular(fRad))..lineTo(fr.right, fr.top + fLen), faceBracketPaint);
      // Bottom-left
      canvas.drawPath(Path()..moveTo(fr.left, fr.bottom - fLen)..lineTo(fr.left, fr.bottom - fRad)..arcToPoint(Offset(fr.left + fRad, fr.bottom), radius: const Radius.circular(fRad))..lineTo(fr.left + fLen, fr.bottom), faceBracketPaint);
      // Bottom-right
      canvas.drawPath(Path()..moveTo(fr.right - fLen, fr.bottom)..lineTo(fr.right - fRad, fr.bottom)..arcToPoint(Offset(fr.right, fr.bottom - fRad), radius: const Radius.circular(fRad))..lineTo(fr.right, fr.bottom - fLen), faceBracketPaint);

      // Yellow rounded rectangle border on ID area
      final idBorder = Paint()
        ..color = const Color(0xFFFFD54F)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2;
      canvas.drawRRect(idRRect, idBorder);

      return;
    }

    Path cutoutPath;
    Rect cutoutRect;

    if (documentMode) {
      final w = size.width * 0.83;
      final h = w / 1.586;
      cutoutRect = Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: w,
        height: h,
      );
      cutoutPath = Path()
        ..addRRect(
          RRect.fromRectAndRadius(cutoutRect, const Radius.circular(22)),
        );
    } else {
      final h = size.height * 0.85;
      final w = h * 0.72;
      cutoutRect = Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: w,
        height: h,
      );
      cutoutPath = Path()..addOval(cutoutRect);
    }

    final maskPath = Path.combine(PathOperation.difference, bgPath, cutoutPath);
    canvas.drawPath(maskPath, bgPaint);

    if (documentMode) {
      final docBorderPaint = Paint()
        ..color = C.text.withOpacity(0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.drawPath(cutoutPath, docBorderPaint);
    } else {
      final dimPaint = Paint()
        ..color = C.text.withOpacity(0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawOval(cutoutRect, dimPaint);

      final sweepPaint = Paint()
        ..color = const Color(0xFF00E5FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3);

      final startAngle =
          (progress * 2 * 3.141592653589793) - (3.141592653589793 / 2);
      const sweepAngle = 3.141592653589793 * 0.45;
      canvas.drawArc(cutoutRect, startAngle, sweepAngle, false, sweepPaint);
      canvas.drawArc(
        cutoutRect,
        startAngle + 3.141592653589793,
        sweepAngle,
        false,
        sweepPaint,
      );

      final cx = size.width / 2;
      final cy = size.height / 2;
      const padding = 14.0;
      final hw = cutoutRect.width / 2 + padding;
      final hh = cutoutRect.height / 2 + padding;
      const len = 22.0;

      final cornerPaint = Paint()
        ..color = C.text.withOpacity(0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round;

      canvas.drawPath(
        Path()
          ..moveTo(cx - hw, cy - hh + len)
          ..lineTo(cx - hw, cy - hh)
          ..lineTo(cx - hw + len, cy - hh),
        cornerPaint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(cx + hw - len, cy - hh)
          ..lineTo(cx + hw, cy - hh)
          ..lineTo(cx + hw, cy - hh + len),
        cornerPaint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(cx - hw, cy + hh - len)
          ..lineTo(cx - hw, cy + hh)
          ..lineTo(cx - hw + len, cy + hh),
        cornerPaint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(cx + hw, cy + hh - len)
          ..lineTo(cx + hw, cy + hh)
          ..lineTo(cx + hw - len, cy + hh),
        cornerPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ScannerOverlayPainter oldDelegate) {
    return oldDelegate.documentMode != documentMode ||
        oldDelegate.holdingMode != holdingMode ||
        oldDelegate.progress != progress;
  }
}
