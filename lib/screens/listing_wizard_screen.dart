import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import '../theme.dart';
import '../app_state.dart';
import '../services/listing_sync_service.dart';
import '../services/firebase_vault_service.dart';
import '../services/ai_service.dart';
import '../utils/error_handler.dart';
import '../main.dart' show cameras;

// ─────────────────────────────────────────────────────────────────────────────
// NECXA — 7-Step Property Listing Wizard (Enhanced with ShieldSDK)
// ─────────────────────────────────────────────────────────────────────────────
class ListingWizardScreen extends StatefulWidget {
  final AppState state;
  const ListingWizardScreen({super.key, required this.state});

  @override
  State<ListingWizardScreen> createState() => _ListingWizardState();
}

class _ListingWizardState extends State<ListingWizardScreen> {
  int _step = 0;
  bool _loading = false;

  // ── Step 1: Basics ────────────────────────────────────────────────────────
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _districtCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  String _propType = 'apartment';
  String _purpose = 'rent';
  String _role = 'owner'; // 'owner' or 'agent'

  // ── Step 2: Pricing ───────────────────────────────────────────────────────
  final _priceCtrl = TextEditingController();
  String _priceType = 'monthly';
  int _bedrooms = 0;
  int _bathrooms = 1;
  int _sqft = 0;
  Set<String> _amenities = {};

  // ── Step 3: Identity Shard (ShieldSDK) ────────────────────────────────────
  String? _identityShardId;

  // ── Step 4: Utility Shard ──────────────────────────────────────────────────
  final _umemeCtrl = TextEditingController();
  final _nwscCtrl = TextEditingController();
  final _landBlockCtrl = TextEditingController();
  final _landPlotCtrl = TextEditingController();
  final _lc1OfficerCtrl = TextEditingController();
  File? _lc1StampPhoto;
  File? _landTitlePhoto;
  File? _brsLicensePhoto; // Extra slot for agents
  String? _utilityShardId;

  // ── Step 5: GPS Lock ──────────────────────────────────────────────────────
  Position? _gpsPosition;
  bool _gpsLocked = false;
  String? _gpsNodeId;

  // ── Step 6: Photos ────────────────────────────────────────────────────────
  final List<File> _exteriorPhotos = [];
  final List<File> _interiorPhotos = [];
  final List<File> _bathroomPhotos = [];

  // ── Step 7: Final ─────────────────────────────────────────────────────────
  bool _submitted = false;
  String? _mintEventId;
  final GlobalKey<_NeuralScannerOverlayState> _scannerKey = GlobalKey();

  @override
  void dispose() {
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
    ('Role & Basics', '🏠', 'Distinguish Agent vs Owner'),
    ('Pricing & Specs', '💰', 'Price, bedrooms, size'),
    ('Identity Shard', '🛡️', 'ShieldSDK Biometric Match'),
    ('Utility Shard', '⚡', 'Utility & Authority Docs'),
    ('GPS Node Lock', '📍', 'Lock physical coordinates'),
    ('Property Photos', '📷', 'Upload visual assets'),
    ('Review & Mint', '✅', 'Final neural synthesis'),
  ];

  bool get _canGoNext {
    switch (_step) {
      case 0: return _titleCtrl.text.isNotEmpty && _districtCtrl.text.isNotEmpty;
      case 1: return _priceCtrl.text.isNotEmpty;
      case 2: return (widget.state.lastIDResult?.verified ?? false) && 
                     (widget.state.lastIDBackResult?.verified ?? false) &&
                     (widget.state.lastHoldingResult?.verified ?? false) &&
                     (widget.state.lastSelfieResult?.faceMatch ?? false);
      case 3: return _umemeCtrl.text.isNotEmpty || _role == 'agent'; // Simplified
      case 4: return _gpsLocked;
      case 5: return _exteriorPhotos.isNotEmpty;
      case 6: return true;
      default: return false;
    }
  }

  void _next() { if (_canGoNext) setState(() => _step++); }
  void _back() { if (_step > 0) setState(() => _step--); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.bg,
        elevation: 0,
        title: Text('List a Property', style: syne(sz: 17, w: FontWeight.w700)),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
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
          if (!_submitted) _buildBottomNav(),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: List.generate(_steps.length, (i) => Expanded(
          child: Container(
            height: 4,
            margin: EdgeInsets.only(right: i == _steps.length - 1 ? 0 : 4),
            decoration: BoxDecoration(
              color: i <= _step ? C.brand : C.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        )),
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
          Text('${_step + 1}/${_steps.length}', style: syne(sz: 12, w: FontWeight.w700, c: C.dim)),
        ],
      ),
    );
  }

  Widget _buildStepBody() {
    switch (_step) {
      case 0: return _Step1(
        titleCtrl: _titleCtrl, districtCtrl: _districtCtrl, 
        cityCtrl: _cityCtrl, descCtrl: _descCtrl,
        propType: _propType, purpose: _purpose, role: _role,
        onType: (v) => setState(() => _propType = v),
        onPurpose: (v) => setState(() => _purpose = v),
        onRole: (v) => setState(() => _role = v),
      );
      case 1: return _Step2(
        priceCtrl: _priceCtrl, priceType: _priceType,
        bedrooms: _bedrooms, bathrooms: _bathrooms, sqft: _sqft, amenities: _amenities,
        onPriceType: (v) => setState(() => _priceType = v),
        onBeds: (v) => setState(() => _bedrooms = v),
        onBaths: (v) => setState(() => _bathrooms = v),
        onSqft: (v) => setState(() => _sqft = v),
        onAmenities: (v) => setState(() => _amenities = v),
      );
      case 2: return _Step3Identity(
        state: widget.state, 
        idVerified: widget.state.lastIDResult?.verified ?? false, 
        faceVerified: widget.state.lastSelfieResult?.faceMatch ?? false,
        onVerify: (ctrl) => _runIdentityVerification(ctrl), 
        loading: _loading, 
        subStep: widget.state.verificationSubStep,
        scannerKey: _scannerKey,
      );
      case 3: return _Step4Utility(
        role: _role, umemeCtrl: _umemeCtrl, nwscCtrl: _nwscCtrl, 
        landBlockCtrl: _landBlockCtrl, landPlotCtrl: _landPlotCtrl,
        lc1OfficerCtrl: _lc1OfficerCtrl, 
        lc1StampPhoto: _lc1StampPhoto, landTitlePhoto: _landTitlePhoto,
        brsLicensePhoto: _brsLicensePhoto, loading: _loading,
        onPickLc1: (f) => setState(() => _lc1StampPhoto = f),
        onPickTitle: (f) => setState(() => _landTitlePhoto = f),
        onPickBrs: (f) => setState(() => _brsLicensePhoto = f),
        onSave: _runUtilityVerification, utilityShardId: _utilityShardId,
      );
      case 4: return _Step5GPS(
        pos: _gpsPosition, locked: _gpsLocked, loading: _loading, onLock: _lockGps,
      );
      case 5: return _Step6Photos(
        exterior: _exteriorPhotos, interior: _interiorPhotos, bathrooms: _bathroomPhotos,
        onAdd: (cat, f) => setState(() {
          if (cat == 'EXTERIOR') {
            _exteriorPhotos.add(f);
          } else if (cat == 'INTERIOR') _interiorPhotos.add(f);
          else _bathroomPhotos.add(f);
        }),
        onRemove: (cat, i) => setState(() {
          if (cat == 'EXTERIOR') {
            _exteriorPhotos.removeAt(i);
          } else if (cat == 'INTERIOR') _interiorPhotos.removeAt(i);
          else _bathroomPhotos.removeAt(i);
        }),
      );
      case 6: return _Step7Review(
        title: _titleCtrl.text, role: _role, propType: _propType, 
        price: _priceCtrl.text, priceType: _priceType,
        idVerified: widget.state.lastIDResult?.verified ?? false, 
        faceVerified: widget.state.lastSelfieResult?.faceMatch ?? false,
        gpsLocked: _gpsLocked, photoCount: _exteriorPhotos.length + _interiorPhotos.length,
        loading: _loading, submitted: _submitted, mintEventId: _mintEventId,
        onSubmit: _submitListing,
      );
      default: return const SizedBox();
    }
  }

  Widget _buildBottomNav() {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 16),
      decoration: BoxDecoration(color: C.card, border: Border(top: BorderSide(color: C.border))),
      child: Row(
        children: [
          if (_step > 0)
            Expanded(child: OutlinedButton(
              onPressed: _loading ? null : _back,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: C.border), 
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: Text('Back', style: syne(c: C.dim, w: FontWeight.w700)),
            )),
          if (_step > 0) const SizedBox(width: 12),
          Expanded(flex: 2, child: ElevatedButton(
            onPressed: (_canGoNext && !_loading) ? _next : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: C.brand,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: _loading 
              ? SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: C.bg, strokeWidth: 2))
              : Text(_step == _steps.length - 1 ? 'Finish' : 'Continue', style: syne(c: C.bg, w: FontWeight.w800)),
          )),
        ],
      ),
    );
  }

  IDResult _idResultFrom(Map<String, dynamic> data) {
    final rawScore = data['score'];
    final score = rawScore is num ? rawScore : num.tryParse(rawScore?.toString() ?? '');
    final verified = data['verified'] == true || (score != null && score >= 70);
    return IDResult(
      verified: verified,
      sessionId: data['sessionLink']?.toString() ??
          data['sessionId']?.toString() ??
          'ID-${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  SelfieResult _selfieResultFrom(Map<String, dynamic> data) {
    final rawScore = data['score'];
    final score = rawScore is num ? rawScore : num.tryParse(rawScore?.toString() ?? '');
    final faceMatch = data['faceMatch'] == true ||
        data['verified'] == true ||
        (score != null && score >= 70);
    return SelfieResult(
      faceMatch: faceMatch,
      sessionId: data['sessionLink']?.toString() ??
          data['sessionId']?.toString() ??
          'BIO-${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  String _aiFeedback(Map<String, dynamic> data, String fallback) =>
      data['feedback']?.toString() ??
      data['error']?.toString() ??
      data['reason']?.toString() ??
      fallback;

  Future<void> _runIdentityVerification(CameraController? cameraCtrl) async {
    setState(() => _loading = true);
    try {
      final state = widget.state;
      state.setShieldFeedback(null);
      if (cameraCtrl == null || !cameraCtrl.value.isInitialized) {
        throw Exception('Camera is not ready yet. Please wait a moment and try again.');
      }

      if (state.verificationSubStep == 0) {
        await _scannerKey.currentState?.switchCamera(CameraLensDirection.back);
        await Future.delayed(const Duration(milliseconds: 300));
        state.captureGps().timeout(const Duration(seconds: 5), onTimeout: () {}).catchError((e) {});
        final xfile = await cameraCtrl.takePicture();
        state.idImage = File(xfile.path);
        final result = await NecxaAI.verifyID(
          state.idImage!,
          userId: state.user?.id,
          action: 'verify-id-front',
        );
        final idResult = _idResultFrom(result);
        if (!idResult.verified) {
          throw Exception(_aiFeedback(result, 'National ID front scan failed. Please retake a clearer photo.'));
        }
        state.lastIDResult = idResult;
        state.verificationSubStep = 1;
      } else if (state.verificationSubStep == 1) {
        await _scannerKey.currentState?.switchCamera(CameraLensDirection.back);
        await Future.delayed(const Duration(milliseconds: 300));
        final xfile = await cameraCtrl.takePicture();
        state.idBackImage = File(xfile.path);
        final result = await NecxaAI.verifyID(
          state.idBackImage!,
          userId: state.user?.id,
          action: 'verify-id-back',
        );
        final idResult = _idResultFrom(result);
        if (!idResult.verified) {
          throw Exception(_aiFeedback(result, 'National ID back scan failed. Please retake the back side clearly.'));
        }
        state.lastIDBackResult = idResult;
        state.verificationSubStep = 2;
      } else if (state.verificationSubStep == 2) {
        await _scannerKey.currentState?.switchCamera(CameraLensDirection.back);
        await Future.delayed(const Duration(milliseconds: 300));
        final xfile = await cameraCtrl.takePicture();
        state.idHoldingImage = File(xfile.path);
        final result = await NecxaAI.verifyID(
          state.idHoldingImage!,
          userId: state.user?.id,
          action: 'verify-id-holding',
        );
        final idResult = _idResultFrom(result);
        if (!idResult.verified) {
          throw Exception(_aiFeedback(result, 'Holding-ID scan failed. Keep your face and ID visible, then retry.'));
        }
        state.lastHoldingResult = idResult;
        state.verificationSubStep = 3;
        
        // Auto-toggle to selfie camera for 3D Biometric Match
        await _scannerKey.currentState?.switchCamera(CameraLensDirection.front);
        await Future.delayed(const Duration(milliseconds: 300));
      } else if (state.verificationSubStep == 3) {
        final xfile = await cameraCtrl.takePicture();
        state.faceImage = File(xfile.path);
        final selfieResult = await NecxaAI.verifySelfie(
          state.faceImage!,
          state.idImage!,
          userId: state.user?.id,
        );
        final biometric = _selfieResultFrom(selfieResult);
        if (!biometric.faceMatch) {
          throw Exception(_aiFeedback(selfieResult, 'Biometric face match failed. Please retry in better light.'));
        }
        state.lastSelfieResult = biometric;
        
        final res = await ListingSyncService.submitIdentityShard(
          country: 'Uganda',
          docType: 'National ID',
          docNumber: 'UNKNOWN',
          idFront: state.idImage!,
          idBack: state.idBackImage!,
          idHolding: state.idHoldingImage!,
          facePhoto: state.faceImage!,
        );
        
        state.identityShardId = res['identity_shard_id'] ?? 'MOCK_SHARD';
        _identityShardId = state.identityShardId;
        state.verificationSubStep = 4;
      }

      state.notify();
      setState(() => _loading = false);

      if (state.verificationSubStep >= 4) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) _next();
        });
      }
    } catch (e) {
      widget.state.setShieldFeedback(getUserFriendlyError(e));
      setState(() => _loading = false);
      _showError(getUserFriendlyError(e));
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
        lc1StampPhoto: _lc1StampPhoto,
        landTitlePhoto: _landTitlePhoto,
      );
      setState(() {
        _utilityShardId = res['utility_shard_id'];
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
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.best);
      final result = await ListingSyncService.submitGpsLock(
        lat: pos.latitude, lng: pos.longitude, accuracy: pos.accuracy,
        reportedAddress: _districtCtrl.text, reportedDistrict: _districtCtrl.text,
      );
      setState(() {
        _gpsPosition = pos;
        _gpsLocked = true;
        _gpsNodeId = result['gps_node_id']?.toString() ?? result['id']?.toString();
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
      final result = await ListingSyncService.submitNeuralSynthesis(
        identityShardId: _identityShardId!,
        utilityShardId: _utilityShardId ?? "LEGACY",
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
      );

      final mintEventId = result['mint_event_id']?.toString() ??
          result['event_id']?.toString() ??
          'NECXA-MINT-${DateTime.now().millisecondsSinceEpoch}';
      try {
        await FirebaseVaultService().logListingMint(
          userId: widget.state.user!.id,
          listingId: result['listing_id']?.toString() ?? '',
          mintEventId: mintEventId,
          title: _titleCtrl.text,
          priceUgx: int.tryParse(_priceCtrl.text.replaceAll(',', '')) ?? 0,
        );
      } catch (e) {
        debugPrint('Firebase listing mint audit failed: $e');
      }

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

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.redAccent));
  }
}

// ── Components ─────────────────────────────────────────────────────────────

class _Step1 extends StatelessWidget {
  final TextEditingController titleCtrl, districtCtrl, cityCtrl, descCtrl;
  final String propType, purpose, role;
  final ValueChanged<String> onType, onPurpose, onRole;
  const _Step1({required this.titleCtrl, required this.districtCtrl, required this.cityCtrl, required this.descCtrl, required this.propType, required this.purpose, required this.role, required this.onType, required this.onPurpose, required this.onRole});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Distinguish Role'),
        Row(
          children: [
            _roleBtn('Individual Owner', 'owner', role == 'owner', () => onRole('owner')),
            const SizedBox(width: 12),
            _roleBtn('Certified Agent', 'agent', role == 'agent', () => onRole('agent')),
          ],
        ),
        const SizedBox(height: 24),
        _label('Property Title'),
        _input(titleCtrl, 'e.g. Modern Villa with Pool'),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_label('District'), _input(districtCtrl, 'e.g. Kololo')])),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_label('City'), _input(cityCtrl, 'e.g. Kampala')])),
          ],
        ),
        const SizedBox(height: 16),
        _label('Description'),
        _input(descCtrl, 'Describe your property...', maxLines: 3),
        const SizedBox(height: 16),
        _label('Property Type'),
        Wrap(spacing: 8, children: ['apartment', 'house', 'villa', 'commercial'].map((t) => _chip(t, propType == t, () => onType(t))).toList()),
        const SizedBox(height: 16),
        _label('Purpose'),
        Wrap(spacing: 8, children: ['rent', 'sale'].map((p) => _chip(p, purpose == p, () => onPurpose(p))).toList()),
      ],
    );
  }

  Widget _roleBtn(String label, String value, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(color: active ? C.brand.withOpacity(.1) : C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: active ? C.brand : C.border)),
          child: Center(child: Text(label, style: syne(sz: 12, w: FontWeight.w700, c: active ? C.brand : C.dim))),
        ),
      ),
    );
  }
}

class _Step2 extends StatelessWidget {
  final TextEditingController priceCtrl; final String priceType; final int bedrooms, bathrooms, sqft; final Set<String> amenities;
  final ValueChanged<String> onPriceType; final ValueChanged<int> onBeds, onBaths, onSqft; final ValueChanged<Set<String>> onAmenities;
  const _Step2({required this.priceCtrl, required this.priceType, required this.bedrooms, required this.bathrooms, required this.sqft, required this.amenities, required this.onPriceType, required this.onBeds, required this.onBaths, required this.onSqft, required this.onAmenities});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Price (UGX)'),
        Row(
          children: [
            Expanded(child: _input(priceCtrl, 'e.g. 5,000,000', keyboard: TextInputType.number)),
            const SizedBox(width: 12),
            _chip('monthly', priceType == 'monthly', () => onPriceType('monthly')),
            const SizedBox(width: 8),
            _chip('nightly', priceType == 'nightly', () => onPriceType('nightly')),
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
        Wrap(spacing: 8, runSpacing: 8, children: ['WiFi', 'Pool', 'Parking', 'Security', 'Gym', 'AC'].map((a) {
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
        }).toList()),
      ],
    );
  }

  Widget _counter(String label, int val, ValueChanged<int> onChanged) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)),
      child: Column(children: [
        Text(label, style: syne(sz: 11, c: C.dim)),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(onPressed: val > 0 ? () => onChanged(val - 1) : null, icon: const Icon(Icons.remove, size: 16)),
          Text('$val', style: syne(sz: 18, w: FontWeight.bold)),
          IconButton(onPressed: () => onChanged(val + 1), icon: const Icon(Icons.add, size: 16)),
        ]),
      ]),
    );
  }
}

class _Step3Identity extends StatelessWidget {
  final AppState state; final bool idVerified, faceVerified, loading; final int subStep;
  final Function(dynamic) onVerify;
  final GlobalKey<_NeuralScannerOverlayState> scannerKey;
  const _Step3Identity({required this.state, required this.idVerified, required this.faceVerified, required this.loading, required this.subStep, required this.onVerify, required this.scannerKey});

  @override
  Widget build(BuildContext context) {
    // scannerKey is now passed from parent to maintain stability

    final instructions = [
      ('National ID (Front)', 'Ensure the text is clearly visible and within the frame.', Icons.badge_outlined),
      ('National ID (Back)', 'Flip your card and scan the reverse side barcode/details.', Icons.qr_code_scanner),
      ('Holding ID Photo', 'Hold your ID next to your face. Ensure both are clearly visible.', Icons.front_hand_outlined),
      ('3D Biometric Match', 'Hold your phone at eye level for a live biometric synthesis.', Icons.face_retouching_natural),
    ];

    final currentInstr = instructions[subStep.clamp(0, 3)];

    return Column(
      children: [
        Stack(
          children: [
            _NeuralScannerOverlay(key: scannerKey),
            if (loading)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(color: C.brand),
                      const SizedBox(height: 16),
                      Text('NEURAL SYNTHESIS IN PROGRESS...', style: syne(sz: 10, c: C.brand, ls: 2, w: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(4, (i) => Container(
            width: 8, height: 8,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: i == subStep ? C.brand : (i < subStep ? C.green : C.border),
              shape: BoxShape.circle,
            ),
          )),
        ),
        
        const SizedBox(height: 24),
        _InstructionCard(
          title: currentInstr.$1,
          desc: currentInstr.$2,
          icon: currentInstr.$3,
        ),

        if (state.shieldFeedback != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.red.withOpacity(.1), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(state.shieldFeedback!, style: dm(sz: 11, c: Colors.redAccent))),
            ]),
          ),
        ],
        
        const SizedBox(height: 40),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: loading ? null : () {
            final ctrl = scannerKey.currentState?.cameraCtrl;
            onVerify(ctrl);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: C.brand,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          icon: const Icon(Icons.camera_alt_outlined),
          label: Text(loading ? 'VERIFYING...' : 'SCAN ${currentInstr.$1.toUpperCase()}', style: syne(c: Colors.white, w: FontWeight.w800, ls: .5)),
        )),
      ],
    );
  }
}

class _InstructionCard extends StatelessWidget {
  final String title, desc; final IconData icon;
  const _InstructionCard({required this.title, required this.desc, required this.icon});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: C.brand, size: 24)),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: syne(sz: 14, w: FontWeight.bold)), Text(desc, style: dm(sz: 11, c: C.dim))])),
      ],
    );
  }
}

class _NeuralScannerOverlay extends StatefulWidget {
  const _NeuralScannerOverlay({super.key});
  @override
  State<_NeuralScannerOverlay> createState() => _NeuralScannerOverlayState();
}

class _NeuralScannerOverlayState extends State<_NeuralScannerOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  CameraController? cameraCtrl;
  CameraLensDirection _currentDirection = CameraLensDirection.back;

  @override
  void initState() {
    super.initState();
    _initCamera(CameraLensDirection.back);
  }

  Future<void> _initCamera(CameraLensDirection direction) async {
    if (cameras.isEmpty) return;
    
    // Find the camera with the desired direction
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == direction,
      orElse: () => cameras.first,
    );

    if (cameraCtrl != null) {
      await cameraCtrl!.dispose();
    }

    cameraCtrl = CameraController(
      camera, 
      ResolutionPreset.high, // CORRECT RESOLUTION FOR AI CLARITY
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await cameraCtrl!.initialize();
      _currentDirection = direction;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Camera initialization error: $e');
    }
  }

  Future<void> switchCamera(CameraLensDirection direction) async {
    await _initCamera(direction);
  }
  
  Future<void> toggleCamera() async {
    final newDirection = _currentDirection == CameraLensDirection.back 
        ? CameraLensDirection.front 
        : CameraLensDirection.back;
    await switchCamera(newDirection);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    cameraCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200, width: double.infinity,
      decoration: BoxDecoration(color: C.cardDk, borderRadius: BorderRadius.circular(20), border: Border.all(color: C.brand.withOpacity(.3))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            if (cameraCtrl != null && cameraCtrl!.value.isInitialized)
              SizedBox.expand(
                child: AspectRatio(
                  aspectRatio: cameraCtrl!.value.aspectRatio,
                  child: CameraPreview(cameraCtrl!),
                ),
              )
            else
              const Center(child: Opacity(opacity: 0.1, child: Icon(Icons.document_scanner, size: 100, color: C.brand))),
            
            // The Scanner Eye
            AnimatedBuilder(
              animation: _ctrl,
              builder: (context, child) => Positioned(
                top: _ctrl.value * 200, left: 0, right: 0,
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    boxShadow: const [BoxShadow(color: C.brand, blurRadius: 10, spreadRadius: 2)],
                    gradient: LinearGradient(colors: [C.brand.withOpacity(0), C.brand, C.brand.withOpacity(0)]),
                  ),
                ),
              ),
            ),
            const Positioned(top: 10, left: 10, child: _ScannerNodeStatus()),
            Positioned(
              top: 10,
              right: 10,
              child: IconButton(
                onPressed: toggleCamera,
                icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
                style: IconButton.styleFrom(backgroundColor: Colors.black45),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScannerNodeStatus extends StatelessWidget {
  const _ScannerNodeStatus();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PulsingLight(),
          const SizedBox(width: 6),
          Text('NEURAL PULSE ACTIVE', style: dm(sz: 8, w: FontWeight.w900, c: C.brand)),
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
class _PulsingLightState extends State<_PulsingLight> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _ctrl, child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: C.brand, shape: BoxShape.circle)));
}

class _Step4Utility extends StatelessWidget {
  final String role; final TextEditingController umemeCtrl, nwscCtrl, landBlockCtrl, landPlotCtrl, lc1OfficerCtrl;
  final File? lc1StampPhoto, landTitlePhoto, brsLicensePhoto;
  final bool loading; final String? utilityShardId;
  final ValueChanged<File> onPickLc1, onPickTitle, onPickBrs;
  final VoidCallback onSave;

  const _Step4Utility({required this.role, required this.umemeCtrl, required this.nwscCtrl, required this.landBlockCtrl, required this.landPlotCtrl, required this.lc1OfficerCtrl, this.lc1StampPhoto, this.landTitlePhoto, this.brsLicensePhoto, required this.loading, this.utilityShardId, required this.onPickLc1, required this.onPickTitle, required this.onPickBrs, required this.onSave});

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
          SizedBox(width: double.infinity, child: ElevatedButton(onPressed: loading ? null : onSave, child: Text(loading ? 'Syncing...' : 'Sync Shard'))),
        if (utilityShardId != null) const Center(child: Text('✅ Utility Shard Synced', style: TextStyle(color: C.brand))),
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
        decoration: BoxDecoration(color: file != null ? C.brand.withOpacity(.05) : C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: file != null ? C.brand : C.border)),
        child: Row(children: [
          Icon(file != null ? Icons.check_circle : Icons.camera_alt, color: file != null ? C.brand : C.dim),
          const SizedBox(width: 12),
          Text(label, style: syne(sz: 13, c: file != null ? C.brand : C.dim)),
        ]),
      ),
    );
  }
}

class _Step5GPS extends StatelessWidget {
  final Position? pos; final bool locked; final bool loading; final VoidCallback onLock;
  const _Step5GPS({this.pos, required this.locked, required this.loading, required this.onLock});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(locked ? Icons.gps_fixed : Icons.location_off, size: 80, color: locked ? C.brand : C.dim),
        const SizedBox(height: 24),
        Text(locked ? 'Coordinates Locked' : 'GPS Verification', style: syne(sz: 18, w: FontWeight.w800)),
        const SizedBox(height: 8),
        Text('You must be physically present at the property to lock the coordinates.', textAlign: TextAlign.center, style: dm(c: C.dim)),
        const SizedBox(height: 40),
        if (!locked)
          SizedBox(width: 180, child: ElevatedButton(onPressed: loading ? null : onLock, child: Text(loading ? 'Scanning...' : 'Lock Now'))),
        if (locked) Text('${pos?.latitude}, ${pos?.longitude}', style: dm(c: C.dim)),
      ],
    );
  }
}

class _Step6Photos extends StatelessWidget {
  final List<File> exterior, interior, bathrooms;
  final Function(String, File) onAdd; final Function(String, int) onRemove;
  const _Step6Photos({required this.exterior, required this.interior, required this.bathrooms, required this.onAdd, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _photoRow('Exterior View', exterior, 'EXTERIOR'),
        const SizedBox(height: 24),
        _photoRow('Interior & Rooms', interior, 'INTERIOR'),
        const SizedBox(height: 24),
        _photoRow('Bathrooms', bathrooms, 'BATHROOM'),
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
                onTap: () async {
                  final f = await ImagePicker().pickImage(source: ImageSource.gallery);
                  if (f != null) onAdd(cat, File(f.path));
                },
                child: Container(width: 100, decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)), child: Icon(Icons.add_a_photo, color: C.dim)),
              ),
              ...files.map((f) => Container(width: 100, margin: const EdgeInsets.only(left: 12), decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), image: DecorationImage(image: FileImage(f), fit: BoxFit.cover)))),
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
  final int photoCount; final VoidCallback onSubmit;

  const _Step7Review({required this.title, required this.role, required this.propType, required this.price, required this.priceType, this.mintEventId, required this.idVerified, required this.faceVerified, required this.gpsLocked, required this.submitted, required this.loading, required this.photoCount, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    if (submitted) return _success(context);
    return Column(
      children: [
        _reviewCard('Identity Shard', idVerified && faceVerified ? 'Verified ✅' : 'Required ❌'),
        _reviewCard('GPS Node', gpsLocked ? 'Locked ✅' : 'Required ❌'),
        _reviewCard('Photos', photoCount > 0 ? '$photoCount Uploaded ✅' : 'Required ❌'),
        const SizedBox(height: 40),
        SizedBox(width: double.infinity, child: ElevatedButton(onPressed: loading ? null : onSubmit, child: Text(loading ? 'MINTING...' : 'Synthesize & Mint'))),
      ],
    );
  }

  Widget _reviewCard(String label, String val) {
    return Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label, style: syne(sz: 14)), Text(val, style: syne(c: C.dim))]));
  }

  Widget _success(BuildContext ctx) {
    return Center(
      child: Column(children: [
        const Icon(Icons.stars, size: 80, color: C.brand),
        const SizedBox(height: 24),
        Text('Listing Minted!', style: syne(sz: 24, w: FontWeight.w900, c: C.brand)),
        Text('Your event ID: ${mintEventId ?? "PENDING"}', style: dm(c: C.dim)),
        const SizedBox(height: 48),
        ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back to Home')),
      ]),
    );
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

Widget _label(String text) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(text.toUpperCase(), style: syne(sz: 11, w: FontWeight.bold, c: C.dim, ls: 1)));

Widget _input(TextEditingController ctrl, String hint, {int maxLines = 1, TextInputType keyboard = TextInputType.text}) => TextField(controller: ctrl, maxLines: maxLines, keyboardType: keyboard, style: dm(), decoration: InputDecoration(hintText: hint, filled: true, fillColor: C.card, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: C.border)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: C.border))));

Widget _chip(String label, bool sel, VoidCallback onTap) => GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: BoxDecoration(color: sel ? C.brand.withOpacity(.1) : C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: sel ? C.brand : C.border)), child: Text(label, style: syne(sz: 13, w: FontWeight.w700, c: sel ? C.brand : C.dim))));
