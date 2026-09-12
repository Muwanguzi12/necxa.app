import 'dart:async';
import 'package:image/image.dart' as img;
import 'package:universal_io/io.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../theme.dart';
import '../app_state.dart';
import '../services/listing_sync_service.dart';
import '../services/ai_service.dart';
import '../utils/error_handler.dart';
import '../main.dart' show cameras;

// -----------------------------------------------------------------------------
// NECXA – 7-Step Property Listing Wizard (ShieldSDK Optimized)
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
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _districtCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  String _priceType = 'Monthly';
  int _bedrooms = 1, _bathrooms = 1, _sqft = 500;
  String _role = 'owner';
  String _propType = 'apartment';
  String _submissionIdempotencyKey = '';
  bool _identityAdvanceScheduled = false;
  Set<String> _amenities = {};

  // -- Step 3: Identity Shard (ShieldSDK) ------------------------------------
  String? _identityShardId;

  // -- Step 4: Utility Shard --------------------------------------------------
  final _umemeCtrl = TextEditingController();
  final _nwscCtrl = TextEditingController();
  final _landBlockCtrl = TextEditingController();
  final _landPlotCtrl = TextEditingController();
  final _lc1OfficerCtrl = TextEditingController();
  File? _utilityBillPhoto, _lc1StampPhoto, _landTitlePhoto, _brsLicensePhoto;
  String? _utilityShardId;

  // -- Step 5: GPS Lock ------------------------------------------------------
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
    _submissionIdempotencyKey = 'listing-$userId-${DateTime.now().microsecondsSinceEpoch}';
    for (final controller in [_titleCtrl, _districtCtrl, _cityCtrl, _priceCtrl]) {
      controller.addListener(_refreshNavigationGate);
    }
  }

  void _refreshNavigationGate() => setState(() {});

  @override
  void dispose() {
    for (final c in [_titleCtrl, _descCtrl, _districtCtrl, _cityCtrl, _priceCtrl, _umemeCtrl, _nwscCtrl, _landBlockCtrl, _landPlotCtrl, _lc1OfficerCtrl]) {
      c.dispose();
    }
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  static const _steps = [
    ('Role & Basics', '🏠', 'Distinguish Agent vs Owner'),
    ('Pricing & Specs', '💰', 'Price, bedrooms, size'),
    ('Identity Shard', '🛡️', 'ShieldSDK Biometric Match'),
    ('Utility Shard', '⚡', 'Utility & Authority Docs'),
    ('GPS Node Lock', '📍', 'Lock physical coordinates'),
    ('Property Photos', '📸', 'Upload visual assets'),
    ('Review & Mint', '✨', 'Final neural synthesis'),
  ];

  bool get _canGoNext {
    switch (_step) {
      case 0: return _titleCtrl.text.trim().isNotEmpty && _districtCtrl.text.trim().isNotEmpty && _cityCtrl.text.trim().isNotEmpty;
      case 1: return (int.tryParse(_priceCtrl.text.replaceAll(',', '').trim()) ?? 0) > 0;
      case 2: return (widget.state.lastIDResult?.verified ?? false) && (widget.state.idBackImage != null) && (widget.state.lastHoldingResult?.verified ?? false) && (widget.state.lastSelfieResult?.faceMatch ?? false) && (widget.state.identityShardId?.isNotEmpty ?? false);
      case 3: return _utilityShardId?.isNotEmpty ?? false;
      case 4: return _gpsLocked && (_gpsNodeId?.isNotEmpty ?? false);
      case 5: return _exteriorPhotos.isNotEmpty && _interiorPhotos.isNotEmpty && _bathroomPhotos.isNotEmpty;
      default: return false;
    }
  }

  void _next() { if (_canGoNext) setState(() => _step++); }
  void _back() { if (_step > 0) setState(() => _step--); }

  @override
  Widget build(BuildContext context) {
    final bool isHoldIDLayout = _step == 2 && widget.state.verificationSubStep == 2;
    if (isHoldIDLayout) {
      return Scaffold(
        backgroundColor: const Color(0xFF030E17),
        body: OrientationBuilder(
          builder: (context, orientation) {
            final bool isLandscape = orientation == Orientation.landscape;
            Widget content = _buildStepBody();
            if (!isLandscape) {
              return RotatedBox(
                quarterTurns: 1, 
                child: SizedBox(
                  width: MediaQuery.of(context).size.height,
                  height: MediaQuery.of(context).size.width,
                  child: content,
                ),
              );
            }
            return content;
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.bg, elevation: 0,
        title: Text('List a Property', style: syne(sz: 17, w: FontWeight.w700)),
        leading: IconButton(icon: Icon(Icons.close, color: C.text), onPressed: () => widget.state.go('home')),
      ),
      body: Column(
        children: [
          _buildProgress(),
          _buildStepHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              physics: const BouncingScrollPhysics(),
              child: AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: _buildStepBody()),
            ),
          ),
          if (!_submitted && _step < _steps.length - 1) _buildBottomNav(),
        ],
      ),
    );
  }

  Widget _buildProgress() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: Row(children: List.generate(_steps.length, (i) => Expanded(child: Container(height: 4, margin: EdgeInsets.only(right: i == _steps.length - 1 ? 0 : 4), decoration: BoxDecoration(color: i <= _step ? C.brand : C.border, borderRadius: BorderRadius.circular(2)))))),
  );

  Widget _buildStepHeader() {
    final s = _steps[_step];
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
      child: Row(
        children: [
          Text(s.$2, style: const TextStyle(fontSize: 28)),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(s.$1, style: syne(sz: 18, w: FontWeight.w800)), Text(s.$3, style: dm(sz: 11, c: C.dim))])),
          Text('${_step + 1}/${_steps.length}', style: syne(sz: 12, w: FontWeight.w700, c: C.dim)),
        ],
      ),
    );
  }

  Widget _buildStepBody() {
    switch (_step) {
      case 0: return _Step1(role: _role, propType: _propType, titleCtrl: _titleCtrl, districtCtrl: _districtCtrl, cityCtrl: _cityCtrl, onRole: (v) => setState(() => _role = v), onType: (v) => setState(() => _propType = v));
      case 1: return _Step2(priceCtrl: _priceCtrl, priceType: _priceType, bedrooms: _bedrooms, bathrooms: _bathrooms, sqft: _sqft, amenities: _amenities, onPriceType: (v) => setState(() => _priceType = v), onBeds: (v) => setState(() => _bedrooms = v), onBaths: (v) => setState(() => _bathrooms = v), onSqft: (v) => setState(() => _sqft = v), onAmenities: (v) => setState(() => _amenities = v));
      case 2: return _Step3Identity(state: widget.state, idVerified: widget.state.lastIDResult?.verified ?? false, faceVerified: widget.state.lastSelfieResult?.faceMatch ?? false, onVerify: _runIdentityVerification, loading: _loading, subStep: widget.state.verificationSubStep, scannerKey: _scannerKey);
      case 3: return _Step4Utility(role: _role, umemeCtrl: _umemeCtrl, nwscCtrl: _nwscCtrl, landBlockCtrl: _landBlockCtrl, landPlotCtrl: _landPlotCtrl, lc1OfficerCtrl: _lc1OfficerCtrl, utilityBillPhoto: _utilityBillPhoto, lc1StampPhoto: _lc1StampPhoto, landTitlePhoto: _landTitlePhoto, brsLicensePhoto: _brsLicensePhoto, loading: _loading, utilityShardId: _utilityShardId, onPickUtilityBill: (f) => setState(() => _utilityBillPhoto = f), onPickLc1: (f) => setState(() => _lc1StampPhoto = f), onPickTitle: (f) => setState(() => _landTitlePhoto = f), onPickBrs: (f) => setState(() => _brsLicensePhoto = f), onSave: _runUtilityVerification);
      case 4: return _Step5Gps(gpsPosition: widget.state.currentGps, locked: _gpsLocked, loading: _loading, onLock: _runGpsLock);
      case 5: return _Step6Photos(exterior: _exteriorPhotos, interior: _interiorPhotos, bathroom: _bathroomPhotos, onAddExterior: (f) => setState(() => _exteriorPhotos.add(f)), onAddInterior: (f) => setState(() => _interiorPhotos.add(f)), onAddBathroom: (f) => setState(() => _bathroomPhotos.add(f)), onRemoveExterior: (i) => setState(() => _exteriorPhotos.removeAt(i)), onRemoveInterior: (i) => setState(() => _interiorPhotos.removeAt(i)), onRemoveBathroom: (i) => setState(() => _bathroomPhotos.removeAt(i)));
      case 6: return _Step7Review(title: _titleCtrl.text, role: _role, propType: _propType, price: _priceCtrl.text, priceType: _priceType, idVerified: widget.state.lastIDResult?.verified ?? false, faceVerified: widget.state.lastSelfieResult?.faceMatch ?? false, gpsLocked: _gpsLocked, photoCount: _exteriorPhotos.length + _interiorPhotos.length, submitted: _submitted, mintEventId: _mintEventId, loading: _loading, onSubmit: _runFinalSubmission);
      default: return const SizedBox.shrink();
    }
  }

  Widget _buildBottomNav() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(color: C.bg, border: Border(top: BorderSide(color: C.border))),
    child: Row(children: [
      Expanded(child: TextButton(onPressed: _step > 0 ? _back : null, child: Text('Back', style: syne(c: _step > 0 ? C.text : C.dim, w: FontWeight.bold)))),
      const SizedBox(width: 20),
      Expanded(flex: 2, child: ElevatedButton(onPressed: _canGoNext ? _next : null, child: const Text('Continue'))),
    ]),
  );

  IDResult _idResultFrom(Map<String, dynamic> data) {
    String extract(dynamic v) => (v is Map) ? (v['id'] ?? v['sessionId'] ?? v.toString()) : (v?.toString() ?? '');
    final sid = extract(data['verificationSessionId'] ?? data['sessionId']);
    return IDResult(verified: (data['verified'] == true || data['faceMatch'] == true) && sid.isNotEmpty, sessionId: sid);
  }

  SelfieResult _selfieResultFrom(Map<String, dynamic> data) {
    String extract(dynamic v) => (v is Map) ? (v['id'] ?? v['sessionId'] ?? v.toString()) : (v?.toString() ?? '');
    double? sc;
    if (data['score'] is num) sc = (data['score'] as num).toDouble();
    else if (data['similarityScore'] is num) sc = (data['similarityScore'] as num).toDouble();
    return SelfieResult(faceMatch: data['faceMatch'] == true || data['verified'] == true, sessionId: extract(data['verificationSessionId'] ?? data['sessionId']), score: sc);
  }

  String _aiFeedback(Map<String, dynamic> data, String fallback) {
    final f = data['feedback']?.toString().trim();
    if (data['verified'] != true && data['faceMatch'] != true && f != null && f.toLowerCase().contains('verified')) return fallback;
    return (f != null && f.isNotEmpty) ? f : (data['error']?.toString() ?? data['reason']?.toString() ?? fallback);
  }

  Future<void> _runIdentityVerification() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final state = widget.state;
      final sub = state.verificationSubStep;
      final scanner = _scannerKey.currentState;
      if (scanner == null) throw Exception('Scanner not ready.');
      final lens = sub == 3 ? CameraLensDirection.front : CameraLensDirection.back;
      final ctrl = await scanner.ensureCamera(lens);

      if (sub == 0 || sub == 1) {
        final res = await NecxaAI.verifyID(File((await ctrl.takePicture()).path), userId: state.user?.id, action: sub == 0 ? 'verify-id-front' : 'verify-id-back');
        final idR = _idResultFrom(res);
        if (!idR.verified) throw UserMessageException(_aiFeedback(res, sub == 0 ? 'ID front scan failed.' : 'ID back scan failed.'));
        if (sub == 0) state.lastIDResult = idR; else { state.lastIDBackResult = idR; await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]); await Future.delayed(const Duration(milliseconds: 500)); }
        state.verificationSubStep = sub + 1;
      } else if (sub == 2) {
        final raw = File((await ctrl.takePicture()).path);
        state.idHoldingImage = await ListingSyncService.compressImage(raw);
        final res = await NecxaAI.verifyID(state.idHoldingImage!, userId: state.user?.id, action: 'verify-id-holding');
        final idR = _idResultFrom(res);
        if (!idR.verified) throw UserMessageException(_aiFeedback(res, 'Holding-ID scan failed.'));
        state.lastHoldingResult = idR;
        state.verificationSubStep = 3;
        await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
        await scanner.switchCamera(CameraLensDirection.front);
        await Future.delayed(const Duration(milliseconds: 500));
      } else if (sub == 3) {
        final frames = await scanner.captureLivenessFrames();
        if (frames.length < 3) throw Exception('Capture incomplete.');
        final pano = await scanner.stitchFramesToPanorama(frames);
        state.faceImage = pano;
        final res = await NecxaAI.verifyLivenessPanorama(await NecxaAI.fileToBase64(pano), userId: state.user?.id);
        final bio = _selfieResultFrom(res);
        if (!bio.faceMatch || bio.sessionId.isEmpty) throw UserMessageException(_aiFeedback(res, 'Liveness failed.'));
        state.lastSelfieResult = bio;
        final syncRes = await ListingSyncService.submitIdentityShard(country: 'Uganda', docType: 'National ID', docNumber: '', idFront: state.idImage!, idBack: state.idBackImage!, idHolding: state.idHoldingImage!, facePhoto: state.faceImage!, frontVerificationId: state.lastIDResult!.sessionId, backVerificationId: state.lastIDBackResult!.sessionId, holdingVerificationId: state.lastHoldingResult!.sessionId, biometricVerificationId: bio.sessionId, idempotencyKey: '$_submissionIdempotencyKey:identity');
        final sid = (syncRes['identity_shard_id'] ?? syncRes['id'] ?? '').toString();
        if (syncRes['verified'] != true || sid.isEmpty) throw UserMessageException(syncRes['message']?.toString() ?? 'Identity not approved.');
        state.identityShardId = sid; _identityShardId = sid;
        try { await ListingSyncService.cacheFaceSession(sessionId: bio.sessionId, identityShardId: sid, faceMatch: bio.faceMatch, score: bio.score ?? 0); } catch (_) {}
        state.verificationSubStep = 4;
      }
      state.notify(); setState(() => _loading = false);
      if (state.verificationSubStep >= 4 && !_identityAdvanceScheduled) { _identityAdvanceScheduled = true; Future.delayed(const Duration(milliseconds: 800), () { if (mounted && _step == 2) _next(); }); }
    } catch (e) { widget.state.setShieldFeedback(getUserFriendlyError(e)); setState(() => _loading = false); }
  }

  Future<void> _runUtilityVerification() async {
    setState(() => _loading = true);
    try {
      final res = await ListingSyncService.submitUtilityShard(country: "Uganda", umemeMeter: _umemeCtrl.text, nwscAccount: _nwscCtrl.text, utilityBillPhoto: _utilityBillPhoto!, lc1StampPhoto: _lc1StampPhoto!, lc1OfficerName: _lc1OfficerCtrl.text, landTitlePhoto: _landTitlePhoto!, landBlock: _landBlockCtrl.text, landPlot: _landPlotCtrl.text, brsLicensePhoto: _brsLicensePhoto, idempotencyKey: '$_submissionIdempotencyKey:utility');
      final uid = (res['utility_shard_id'] ?? res['id'] ?? '').toString();
      if (res['verified'] != true || uid.isEmpty) throw UserMessageException(res['message']?.toString() ?? 'Utility verification failed.');
      setState(() { _utilityShardId = uid; _loading = false; });
      Future.delayed(const Duration(milliseconds: 800), () { if (mounted && _step == 3) _next(); });
    } catch (e) { _showError(getUserFriendlyError(e)); setState(() => _loading = false); }
  }

  Future<void> _runGpsLock() async {
    setState(() => _loading = true);
    try {
      final pos = widget.state.currentGps;
      if (pos == null) throw Exception('GPS not locked.');
      final res = await ListingSyncService.submitGpsLock(lat: pos.latitude, lng: pos.longitude, accuracy: pos.accuracy, reportedAddress: _cityCtrl.text, reportedDistrict: _districtCtrl.text, idempotencyKey: '$_submissionIdempotencyKey:gps');
      final gid = (res['gps_node_id'] ?? res['id'] ?? '').toString();
      if (gid.isEmpty) throw Exception('GPS lock failed.');
      setState(() { _gpsNodeId = gid; _gpsLocked = true; _loading = false; });
      Future.delayed(const Duration(milliseconds: 800), () { if (mounted && _step == 4) _next(); });
    } catch (e) { _showError(getUserFriendlyError(e)); setState(() => _loading = false); }
  }

  Future<void> _runFinalSubmission() async {
    setState(() => _loading = true);
    try {
      final res = await ListingSyncService.submitNeuralSynthesis(identityShardId: _identityShardId!, utilityShardId: _utilityShardId!, gpsNodeId: _gpsNodeId!, title: _titleCtrl.text, description: _descCtrl.text, propertyType: _propType, price: double.parse(_priceCtrl.text.replaceAll(',', '')), priceType: _priceType, bedrooms: _bedrooms, bathrooms: _bathrooms, sqft: _sqft, amenities: _amenities.toList(), exteriorPhotos: _exteriorPhotos, interiorPhotos: _interiorPhotos, bathroomPhotos: _bathroomPhotos, idempotencyKey: _submissionIdempotencyKey);
      setState(() { _mintEventId = res['mint_event_id']?.toString(); _submitted = true; _loading = false; });
    } catch (e) { _showError(getUserFriendlyError(e)); setState(() => _loading = false); }
  }

  void _showError(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: Colors.redAccent));
}

// -- UI Step Components ------------------------------------------------------

class _Step1 extends StatelessWidget {
  final String role, propType;
  final TextEditingController titleCtrl, districtCtrl, cityCtrl;
  final ValueChanged<String> onRole, onType;
  const _Step1({required this.role, required this.propType, required this.titleCtrl, required this.districtCtrl, required this.cityCtrl, required this.onRole, required this.onType});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _label('Your Role'),
    Row(children: [Expanded(child: _roleBtn('Owner', 'owner', role == 'owner', () => onRole('owner'))), const SizedBox(width: 12), Expanded(child: _roleBtn('Agent', 'agent', role == 'agent', () => onRole('agent')))]),
    const SizedBox(height: 24),
    _label('Listing Title'), _input(titleCtrl, 'e.g. Modern 2BR Apartment'),
    const SizedBox(height: 16),
    _label('Location'), Row(children: [Expanded(child: _input(districtCtrl, 'District')), const SizedBox(width: 12), Expanded(child: _input(cityCtrl, 'City'))]),
  ]);
  Widget _roleBtn(String l, String v, bool a, VoidCallback t) => GestureDetector(onTap: t, child: Container(padding: const EdgeInsets.symmetric(vertical: 14), decoration: BoxDecoration(color: a ? C.brand : C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: a ? C.brand : C.border)), child: Center(child: Text(l, style: syne(sz: 14, w: FontWeight.bold, c: a ? Colors.black : C.text)))));
}

class _Step2 extends StatelessWidget {
  final TextEditingController priceCtrl;
  final String priceType;
  final int bedrooms, bathrooms, sqft;
  final Set<String> amenities;
  final ValueChanged<String> onPriceType;
  final ValueChanged<int> onBeds, onBaths, onSqft;
  final ValueChanged<Set<String>> onAmenities;
  const _Step2({required this.priceCtrl, required this.priceType, required this.bedrooms, required this.bathrooms, required this.sqft, required this.amenities, required this.onPriceType, required this.onBeds, required this.onBaths, required this.onSqft, required this.onAmenities});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _label('Price & Cycle'), Row(children: [Expanded(flex: 2, child: _input(priceCtrl, 'Amount', icon: Icons.payments_outlined)), const SizedBox(width: 12), Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 12), decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)), child: DropdownButton<String>(value: priceType, underline: const SizedBox(), items: ['Monthly', 'Daily', 'Total'].map((s) => DropdownMenuItem(value: s, child: Text(s, style: syne(sz: 13)))).toList(), onChanged: (v) => onPriceType(v!))))]),
    const SizedBox(height: 24),
    Row(children: [Expanded(child: _counter('Bedrooms', bedrooms, onBeds)), const SizedBox(width: 12), Expanded(child: _counter('Bathrooms', bathrooms, onBaths))]),
  ]);
  Widget _counter(String l, int v, ValueChanged<int> c) => Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)), child: Column(children: [Text(l, style: syne(sz: 11, c: C.dim)), Row(mainAxisAlignment: MainAxisAlignment.center, children: [IconButton(onPressed: v > 0 ? () => c(v - 1) : null, icon: const Icon(Icons.remove, size: 16)), Text('$v', style: syne(sz: 18, w: FontWeight.bold)), IconButton(onPressed: () => c(v + 1), icon: const Icon(Icons.add, size: 16))])]));
}

class _Step3Identity extends StatelessWidget {
  final AppState state; final bool loading; final int subStep; final Future<void> Function() onVerify; final GlobalKey<_NeuralScannerOverlayState> scannerKey;
  const _Step3Identity({required this.state, required this.loading, required this.subStep, required this.onVerify, required this.scannerKey});

  @override
  Widget build(BuildContext context) {
    if (subStep == 2) {
      final done = [state.lastIDResult?.verified ?? false, state.idBackImage != null, state.lastHoldingResult?.verified ?? false, state.lastSelfieResult?.faceMatch ?? false];
      final cnt = done.where((v) => v).length;
      return SafeArea(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16), child: Column(children: [
        Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back_ios, color: Colors.white), onPressed: () => state.go('home')), const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Identity Shard', style: syne(sz: 18, w: FontWeight.w900, c: Colors.white)), Text('ID and face verification', style: dm(sz: 11, c: Colors.white54))]),
          const Spacer(), Column(children: [Row(children: List.generate(7, (i) => Container(width: 24, height: 3.5, margin: const EdgeInsets.symmetric(horizontal: 2), decoration: BoxDecoration(color: i < 3 ? C.brand : Colors.white12, borderRadius: BorderRadius.circular(2))))), const SizedBox(height: 4), Text('3 / 7', style: dm(sz: 10, w: FontWeight.bold, c: Colors.white38))]),
          const Spacer(), Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF0F2631), borderRadius: BorderRadius.circular(12)), child: Row(children: [const Icon(Icons.verified_user_rounded, color: Color(0xFF4CAF50), size: 16), const SizedBox(width: 6), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Secure session', style: dm(sz: 10, w: FontWeight.bold, c: Colors.white)), Text('Data is encrypted', style: dm(sz: 8, c: Colors.white38))])])),
        ]),
        const SizedBox(height: 12), Text('Fit face and ID inside the frames', style: syne(sz: 16, w: FontWeight.bold, c: Colors.white)),
        const SizedBox(height: 12), Expanded(child: Center(child: AspectRatio(aspectRatio: 2.3, child: Stack(children: [
          ClipRRect(borderRadius: BorderRadius.circular(24), child: _NeuralScannerOverlay(key: scannerKey, documentMode: false, subStep: subStep)),
          Positioned(top: 20, left: 20, child: Row(children: [const _PulsingLight(), const SizedBox(width: 6), Text('LIVE', style: dm(sz: 11, w: FontWeight.bold, c: Colors.white))])),
          Positioned(bottom: 20, left: 0, right: 0, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [_guideLabel('ID', Colors.yellow), const SizedBox(width: 220), _guideLabel('Face', Colors.cyan)])),
          Positioned(right: 16, top: 0, bottom: 0, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [GestureDetector(onTap: () => scannerKey.currentState?.toggleFlash(), child: _iconBtn(Icons.bolt)), const SizedBox(height: 20), GestureDetector(onTap: () => scannerKey.currentState?.switchLens(), child: _iconBtn(Icons.cached))])),
        ])))),
        const SizedBox(height: 16), Row(mainAxisAlignment: MainAxisAlignment.center, children: [_info(Icons.wb_sunny_outlined, 'Lighting'), _info(Icons.shield_outlined, 'Readable'), _info(Icons.visibility_off_outlined, 'No Glasses')]),
        const SizedBox(height: 16), Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF081622), borderRadius: BorderRadius.circular(20)), child: Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('$cnt of 4 verified', style: syne(sz: 12, w: FontWeight.w600, c: Colors.white70)), const SizedBox(height: 8), Row(children: [_statusChip('Front', done[0]), _statusChip('Back', done[1]), _statusChip('Holding ID', done[2], active: true), _statusChip('Face match', done[3])])]),
          const Spacer(), SizedBox(height: 54, child: ElevatedButton.icon(onPressed: loading ? null : onVerify, style: ElevatedButton.styleFrom(backgroundColor: C.brand, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(horizontal: 24), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), icon: const Icon(Icons.camera_alt), label: Text(loading ? 'VERIFYING...' : 'SCAN HOLDING ID PHOTO', style: syne(w: FontWeight.w900, ls: 0.5)))),
        ])),
      ])));
    }
    final inst = [('National ID (Front)', 'Ensure text is clear.', Icons.badge_outlined), ('National ID (Back)', 'Scan reverse side.', Icons.qr_code_scanner), ('Holding ID Photo', 'Face and ID clear.', Icons.front_hand_outlined), ('3D Biometric Match', 'Hold at eye level.', Icons.face_retouching_natural)][subStep.clamp(0, 3)];
    final done = [state.lastIDResult?.verified ?? false, state.idBackImage != null, state.lastHoldingResult?.verified ?? false, state.lastSelfieResult?.faceMatch ?? false];
    return Column(children: [
      SizedBox(height: 270, child: _NeuralScannerOverlay(key: scannerKey, documentMode: subStep < 2, subStep: subStep)),
      const SizedBox(height: 20), _InstructionCard(title: inst.$1, desc: inst.$2, icon: inst.$3),
      const SizedBox(height: 14), _IdentityCaptureProgress(completedStages: done, completedCount: done.where((v)=>v).length),
      if (state.shieldFeedback != null) ...[const SizedBox(height: 16), Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.red.withOpacity(.1), borderRadius: BorderRadius.circular(12)), child: Row(children: [const Icon(Icons.error_outline, color: Colors.redAccent, size: 16), const SizedBox(width: 8), Expanded(child: Text(state.shieldFeedback!, style: dm(sz: 11, c: Colors.redAccent)))]))],
      const SizedBox(height: 36), SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: loading ? null : onVerify, style: ElevatedButton.styleFrom(backgroundColor: C.brand, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), icon: const Icon(Icons.camera_alt_outlined), label: Text(loading ? 'VERIFYING...' : 'SCAN ${inst.$1.toUpperCase()}'))),
    ]);
  }

  Widget _guideLabel(String t, Color c) => Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(color: Colors.black.withOpacity(.6), borderRadius: BorderRadius.circular(30), border: Border.all(color: c.withOpacity(.5))), child: Text(t, style: dm(sz: 10, w: FontWeight.bold, c: Colors.white)));
  Widget _iconBtn(IconData i) => Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.white.withOpacity(.1), shape: BoxShape.circle), child: Icon(i, color: Colors.white, size: 20));
  Widget _info(IconData i, String t) => Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [Icon(i, color: C.brand, size: 14), const SizedBox(width: 6), Text(t, style: dm(sz: 10, c: Colors.white70))]));
  Widget _statusChip(String l, bool v, {bool active = false}) { final color = v ? const Color(0xFF00E5FF) : (active ? C.brand : Colors.white10); return Container(margin: const EdgeInsets.only(right: 8), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: active ? color.withOpacity(.1) : Colors.transparent, borderRadius: BorderRadius.circular(20), border: Border.all(color: active || v ? color : Colors.white10)), child: Text(l, style: dm(sz: 9, w: FontWeight.bold, c: v || active ? Colors.white : Colors.white24))); }
}

class _IdentityCaptureProgress extends StatelessWidget {
  final List<bool> completedStages;
  final int completedCount;
  const _IdentityCaptureProgress({required this.completedStages, required this.completedCount});
  @override
  Widget build(BuildContext context) {
    const labels = ['Front', 'Back', 'Holding ID', 'Face match'];
    return Container(width: double.infinity, padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$completedCount of 4 verified', style: syne(sz: 11, w: FontWeight.w700, c: C.dim)), const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: List.generate(labels.length, (i) { final c = completedStages[i]; return Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6), decoration: BoxDecoration(color: c ? C.brand.withOpacity(.12) : C.text.withOpacity(.04), borderRadius: BorderRadius.circular(20), border: Border.all(color: c ? C.brand.withOpacity(.5) : C.border)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(c ? Icons.check_circle : Icons.radio_button_unchecked, size: 14, color: c ? C.brand : C.dim), const SizedBox(width: 5), Text(labels[i], style: dm(sz: 10, c: c ? C.brand : C.dim))])); })),
    ]));
  }
}

class _InstructionCard extends StatelessWidget {
  final String title, desc; final IconData icon;
  const _InstructionCard({required this.title, required this.desc, required this.icon});
  @override
  Widget build(BuildContext context) => Row(children: [Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: C.brand, size: 24)), const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: syne(sz: 14, w: FontWeight.bold)), Text(desc, style: dm(sz: 11, c: C.dim))]))]);
}

class _NeuralScannerOverlay extends StatefulWidget {
  final bool documentMode; final int subStep;
  const _NeuralScannerOverlay({super.key, required this.documentMode, this.subStep = 0});
  @override State<_NeuralScannerOverlay> createState() => _NeuralScannerOverlayState();
}

class _NeuralScannerOverlayState extends State<_NeuralScannerOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  CameraController? cameraCtrl; CameraLensDirection _curD = CameraLensDirection.back; Future<void>? _initF; FlashMode _flash = FlashMode.off;
  String? _livenessPrompt;
  bool get isHolding => widget.subStep == 2;

  @override void initState() { super.initState(); unawaited(switchCamera(CameraLensDirection.back).catchError((_) {})); }

  Future<void> _init(CameraLensDirection d) async {
    if (cameras.isEmpty) return; final cam = cameras.firstWhere((c) => c.lensDirection == d, orElse: () => cameras.first);
    await cameraCtrl?.dispose(); final next = CameraController(cam, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
    cameraCtrl = next; try { await next.initialize(); _curD = d; if (widget.subStep >= 2) { final minZ = await next.getMinZoomLevel(); await next.setZoomLevel(minZ); } if (mounted) setState(() {}); } catch (_) {}
  }

  Future<void> switchCamera(CameraLensDirection d) async {
    if (_initF != null) await _initF; if (_curD == d && cameraCtrl != null && cameraCtrl!.value.isInitialized) return;
    final f = _init(d); _initF = f; try { await f; } finally { _initF = null; }
  }

  Future<CameraController> ensureCamera(CameraLensDirection d) async { await switchCamera(d); return cameraCtrl!; }
  Future<void> toggleFlash() async { if (cameraCtrl == null) return; _flash = _flash == FlashMode.off ? FlashMode.torch : FlashMode.off; await cameraCtrl!.setFlashMode(_flash); }
  Future<void> switchLens() async { await switchCamera(_curD == CameraLensDirection.back ? CameraLensDirection.front : CameraLensDirection.back); }

  Future<List<File>> captureLivenessFrames() async {
    final c = await ensureCamera(CameraLensDirection.front); final fs = <File>[];
    const pms = ['Center', 'Left', 'Center'];
    for (int i = 0; i < 3; i++) { if (mounted) setState(() => _livenessPrompt = pms[i]); await Future.delayed(const Duration(milliseconds: 700)); fs.add(File((await c.takePicture()).path)); }
    if (mounted) setState(() => _livenessPrompt = null); return fs;
  }

  Future<File> stitchFramesToPanorama(List<File> frames) async {
    final i1 = img.decodeImage(await frames[0].readAsBytes()), i2 = img.decodeImage(await frames[1].readAsBytes()), i3 = img.decodeImage(await frames[2].readAsBytes());
    final p = img.Image(width: i1!.width * 3, height: i1.height);
    img.compositeImage(p, i1, dstX: 0); img.compositeImage(p, i2!, dstX: i1.width); img.compositeImage(p, i3!, dstX: i1.width * 2);
    final f = File('${(await getTemporaryDirectory()).path}/lp.jpg'); await f.writeAsBytes(img.encodeJpg(p)); return f;
  }

  @override void dispose() { _ctrl.dispose(); cameraCtrl?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Container(width: double.infinity, decoration: BoxDecoration(color: C.cardDk, borderRadius: BorderRadius.circular(16)), child: ClipRRect(borderRadius: BorderRadius.circular(16), child: Stack(children: [
    if (cameraCtrl != null && cameraCtrl!.value.isInitialized) Positioned.fill(child: LayoutBuilder(builder: (context, c) { double pa = cameraCtrl!.value.aspectRatio; final isP = MediaQuery.of(context).orientation == Orientation.portrait; if (isP && pa > 1.0) pa = 1.0 / pa; else if (!isP && pa < 1.0) pa = 1.0 / pa; final va = c.maxWidth / c.maxHeight; double sc = (va > pa) ? va / pa : pa / va; if (isHolding) sc *= 0.82; return ClipRect(child: Transform.scale(scale: sc, child: Center(child: CameraPreview(cameraCtrl!)))); })),
    if (_livenessPrompt != null) Positioned.fill(child: Container(color: Colors.black45, child: Center(child: Text(_livenessPrompt!, style: syne(sz: 24, w: FontWeight.w900, c: C.brand))))),
    IgnorePointer(child: CustomPaint(size: Size.infinite, painter: _ScannerOverlayPainter(documentMode: widget.documentMode, isHold: widget.subStep == 2, progress: _ctrl.value))),
    if (widget.documentMode && !isHolding) AnimatedBuilder(animation: _ctrl, builder: (context, _) => Positioned(top: _ctrl.value * 270, left: 0, right: 0, child: Container(height: 2, decoration: BoxDecoration(boxShadow: const [BoxShadow(color: C.brand, blurRadius: 10, spreadRadius: 2)], gradient: LinearGradient(colors: [C.brand.withOpacity(0), C.brand, C.brand.withOpacity(0)]))))),
  ])));
}

class _ScannerOverlayPainter extends CustomPainter {
  final bool documentMode, isHold; final double progress;
  _ScannerOverlayPainter({required this.documentMode, required this.isHold, required this.progress});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.6);
    final path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    if (isHold) {
      final idR = RRect.fromRectAndRadius(Rect.fromLTWH(size.width * 0.1, size.height * 0.25, size.width * 0.35, size.height * 0.5), const Radius.circular(12));
      final fcR = RRect.fromRectAndRadius(Rect.fromLTWH(size.width * 0.55, size.height * 0.2, size.width * 0.3, size.height * 0.6), const Radius.circular(100));
      canvas.drawPath(Path.combine(PathOperation.difference, path, Path()..addRRect(idR)..addRRect(fcR)), paint);
      canvas.drawRRect(idR, Paint()..color = Colors.yellow..style = PaintingStyle.stroke..strokeWidth = 2);
      canvas.drawRRect(fcR, Paint()..color = Colors.cyan..style = PaintingStyle.stroke..strokeWidth = 2);
    } else {
      final w = size.width * 0.83, h = w / 1.586;
      final r = Rect.fromCenter(center: Offset(size.width / 2, size.height / 2), width: w, height: h);
      final cp = Path()..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(22)));
      canvas.drawPath(Path.combine(PathOperation.difference, path, cp), paint);
      canvas.drawPath(cp, Paint()..color = Colors.white70..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }
  @override bool shouldRepaint(CustomPainter old) => true;
}

class _PulsingLight extends StatefulWidget {
  const _PulsingLight();
  @override State<_PulsingLight> createState() => _PulsingLightState();
}

class _PulsingLightState extends State<_PulsingLight> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat(reverse: true);
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => FadeTransition(opacity: _c, child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle)));
}

Widget _label(String t) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t.toUpperCase(), style: syne(sz: 11, w: FontWeight.bold, c: C.dim, ls: 1)));
Widget _input(TextEditingController c, String h, {IconData? icon}) => Container(decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)), child: TextField(controller: c, style: syne(sz: 14), decoration: InputDecoration(hintText: h, prefixIcon: icon != null ? Icon(icon, size: 18, color: C.dim) : null, border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12))));
Widget _filePick(String l, File? f, ValueChanged<File> o) => GestureDetector(onTap: () async { final p = await ImagePicker().pickImage(source: ImageSource.camera); if (p != null) o(File(p.path)); }, child: Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)), child: Row(children: [Icon(f != null ? Icons.check_circle : Icons.add_a_photo, color: f != null ? C.brand : C.dim), const SizedBox(width: 12), Expanded(child: Text(l, style: syne(sz: 13))), if (f != null) Text('Captured', style: dm(sz: 11, c: C.brand))])));

class _Step1 extends StatelessWidget {
  final String role, propType; final TextEditingController titleCtrl, districtCtrl, cityCtrl; final ValueChanged<String> onRole, onType;
  const _Step1({required this.role, required this.propType, required this.titleCtrl, required this.districtCtrl, required this.cityCtrl, required this.onRole, required this.onType});
  @override Widget build(BuildContext context) => Column(children: [_label('Your Role'), Row(children: [Expanded(child: _roleBtn('Owner', role == 'owner', () => onRole('owner'))), const SizedBox(width: 12), Expanded(child: _roleBtn('Agent', role == 'agent', () => onRole('agent')))]), const SizedBox(height: 24), _label('Listing Title'), _input(titleCtrl, 'e.g. Modern 2BR Apartment'), const SizedBox(height: 16), _label('Location'), Row(children: [Expanded(child: _input(districtCtrl, 'District')), const SizedBox(width: 12), Expanded(child: _input(cityCtrl, 'City'))])]);
  Widget _roleBtn(String l, bool a, VoidCallback t) => GestureDetector(onTap: t, child: Container(padding: const EdgeInsets.symmetric(vertical: 14), decoration: BoxDecoration(color: a ? C.brand : C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: a ? C.brand : C.border)), child: Center(child: Text(l, style: syne(sz: 14, w: FontWeight.bold, c: a ? Colors.black : C.text)))));
}
class _Step2 extends StatelessWidget {
  final TextEditingController priceCtrl; final String priceType; final int bedrooms, bathrooms, sqft; final Set<String> amenities; final ValueChanged<String> onPriceType; final ValueChanged<int> onBeds, onBaths, onSqft; final ValueChanged<Set<String>> onAmenities;
  const _Step2({required this.priceCtrl, required this.priceType, required this.bedrooms, required this.bathrooms, required this.sqft, required this.amenities, required this.onPriceType, required this.onBeds, required this.onBaths, required this.onSqft, required this.onAmenities});
  @override Widget build(BuildContext context) => Column(children: [_label('Price'), Row(children: [Expanded(flex: 2, child: _input(priceCtrl, 'Amount')), const SizedBox(width: 12), Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 12), decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)), child: DropdownButton<String>(value: priceType, underline: const SizedBox(), items: ['Monthly', 'Daily', 'Total'].map((s) => DropdownMenuItem(value: s, child: Text(s, style: syne(sz: 13)))).toList(), onChanged: (v) => onPriceType(v!))))]), const SizedBox(height: 24), Row(children: [Expanded(child: _counter('Bedrooms', bedrooms, onBeds)), const SizedBox(width: 12), Expanded(child: _counter('Bathrooms', bathrooms, onBaths))])]);
  Widget _counter(String l, int v, ValueChanged<int> c) => Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)), child: Column(children: [Text(l, style: syne(sz: 11, c: C.dim)), Row(mainAxisAlignment: MainAxisAlignment.center, children: [IconButton(onPressed: v > 0 ? () => c(v - 1) : null, icon: const Icon(Icons.remove, size: 16)), Text('$v', style: syne(sz: 18, w: FontWeight.bold)), IconButton(onPressed: () => c(v + 1), icon: const Icon(Icons.add, size: 16))])]));
}
class _Step4Utility extends StatelessWidget {
  final String role; final TextEditingController umemeCtrl, nwscCtrl, landBlockCtrl, landPlotCtrl, lc1OfficerCtrl; final File? utilityBillPhoto, lc1StampPhoto, landTitlePhoto, brsLicensePhoto; final bool loading; final String? utilityShardId; final ValueChanged<File> onPickUtilityBill, onPickLc1, onPickTitle, onPickBrs; final VoidCallback onSave;
  const _Step4Utility({required this.role, required this.umemeCtrl, required this.nwscCtrl, required this.landBlockCtrl, required this.landPlotCtrl, required this.lc1OfficerCtrl, this.utilityBillPhoto, this.lc1StampPhoto, this.landTitlePhoto, this.brsLicensePhoto, required this.loading, this.utilityShardId, required this.onPickUtilityBill, required this.onPickLc1, required this.onPickTitle, required this.onPickBrs, required this.onSave});
  @override Widget build(BuildContext context) => Column(children: [_label('Umeme'), _input(umemeCtrl, 'Meter #'), const SizedBox(height: 16), _filePick('Utility Bill', utilityBillPhoto, onPickUtilityBill), const SizedBox(height: 32), if (utilityShardId == null) SizedBox(width: double.infinity, child: ElevatedButton(onPressed: loading ? null : onSave, child: Text(loading ? 'Syncing...' : 'Sync Shard')))]);
}
class _Step5Gps extends StatelessWidget {
  final Position? gpsPosition; final bool locked, loading; final VoidCallback onLock;
  const _Step5Gps({required this.gpsPosition, required this.locked, required this.loading, required this.onLock});
  @override Widget build(BuildContext context) => Column(children: [const SizedBox(height: 40), Icon(Icons.location_on, size: 80, color: locked ? C.brand : C.dim), const SizedBox(height: 48), if (!locked) SizedBox(width: double.infinity, child: ElevatedButton(onPressed: loading ? null : onLock, child: const Text('Lock coordinates')))]);
}
class _Step6Photos extends StatelessWidget {
  final List<File> exterior, interior, bathroom; final ValueChanged<File> onAddExterior, onAddInterior, onAddBathroom; final ValueChanged<int> onRemoveExterior, onRemoveInterior, onRemoveBathroom;
  const _Step6Photos({required this.exterior, required this.interior, required this.bathroom, required this.onAddExterior, required this.onAddInterior, required this.onAddBathroom, required this.onRemoveExterior, required this.onRemoveInterior, required this.onRemoveBathroom});
  @override Widget build(BuildContext context) => Column(children: [_label('Exterior'), _photoGrid(exterior, onAddExterior, onRemoveExterior), const SizedBox(height: 24), _label('Interior'), _photoGrid(interior, onAddInterior, onRemoveInterior)]);
  Widget _photoGrid(List<File> files, ValueChanged<File> onAdd, ValueChanged<int> onRem) => SizedBox(height: 100, child: ListView(scrollDirection: Axis.horizontal, children: [GestureDetector(onTap: () async { final p = await ImagePicker().pickImage(source: ImageSource.camera); if (p != null) onAdd(File(p.path)); }, child: Container(width: 100, decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)), child: Icon(Icons.add_a_photo, color: C.dim))), ...files.asMap().entries.map((e) => Container(width: 100, margin: const EdgeInsets.only(left: 12), decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), image: DecorationImage(image: FileImage(e.value), fit: BoxFit.cover))))]));
}
class _Step7Review extends StatelessWidget {
  final String title, role, propType, price, priceType; final String? mintEventId; final bool idVerified, faceVerified, gpsLocked, submitted, loading; final int photoCount; final VoidCallback onSubmit;
  const _Step7Review({required this.title, required this.role, required this.propType, required this.price, required this.priceType, this.mintEventId, required this.idVerified, required this.faceVerified, required this.gpsLocked, required this.submitted, required this.loading, required this.photoCount, required this.onSubmit});
  @override Widget build(BuildContext context) => Center(child: Column(children: [const Icon(Icons.stars, size: 80, color: C.brand), const SizedBox(height: 48), ElevatedButton(onPressed: loading ? null : onSubmit, child: Text(loading ? 'MINTING...' : 'Mint Listing'))]));
}
