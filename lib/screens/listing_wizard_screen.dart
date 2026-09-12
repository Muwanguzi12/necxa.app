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
      controller.addListener(() => setState(() {}));
    }
  }

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
      case 2: return widget.state.identityShardId != null;
      case 3: return _utilityShardId != null;
      case 4: return _gpsLocked;
      case 5: return _exteriorPhotos.isNotEmpty && _interiorPhotos.isNotEmpty;
      default: return true;
    }
  }

  void _next() { if (_canGoNext) setState(() => _step++); }
  void _back() { if (_step > 0) setState(() => _step--); }

  @override
  Widget build(BuildContext context) {
    final bool isHoldIDStep = _step == 2 && widget.state.verificationSubStep == 2;
    if (isHoldIDStep) {
      return Scaffold(
        backgroundColor: const Color(0xFF030E17),
        body: _Step3Identity(state: widget.state, loading: _loading, subStep: 2, onVerify: _runIdentityVerification, scannerKey: _scannerKey),
      );
    }

    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.bg, elevation: 0,
        title: Text('List a Property', style: syne(sz: 17, w: FontWeight.w700)),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => widget.state.go('home')),
      ),
      body: Column(
        children: [
          _buildProgress(),
          _buildStepHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              physics: const BouncingScrollPhysics(),
              child: _buildStepBody(),
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
      case 2: return _Step3Identity(state: widget.state, loading: _loading, subStep: widget.state.verificationSubStep, onVerify: _runIdentityVerification, scannerKey: _scannerKey);
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

  Future<void> _runIdentityVerification() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final state = widget.state;
      final sub = state.verificationSubStep;
      final scanner = _scannerKey.currentState;
      if (scanner == null) throw Exception('Scanner not ready.');

      if (sub == 0 || sub == 1) {
        final ctrl = await scanner.ensureCamera(CameraLensDirection.back);
        final res = await NecxaAI.verifyID(File((await ctrl.takePicture()).path), userId: state.user?.id, action: sub == 0 ? 'verify-id-front' : 'verify-id-back');
        if (res['verified'] == true) {
          if (sub == 0) {
            state.lastIDResult = IDResult(verified: true, sessionId: res['sessionId']);
            state.idImage = File((await ctrl.takePicture()).path); // Ensure we save the file
          } else {
            state.lastIDBackResult = IDResult(verified: true, sessionId: res['sessionId']);
            state.idBackImage = File((await ctrl.takePicture()).path);
            await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
          }
          state.verificationSubStep = sub + 1;
        } else { throw Exception(res['feedback'] ?? 'Scan failed.'); }
      } else if (sub == 2) {
        final ctrl = await scanner.ensureCamera(CameraLensDirection.back);
        final raw = File((await ctrl.takePicture()).path);
        final res = await NecxaAI.verifyID(raw, userId: state.user?.id, action: 'verify-id-holding');
        if (res['verified'] == true) {
          state.lastHoldingResult = IDResult(verified: true, sessionId: res['sessionId']);
          state.idHoldingImage = raw;
          await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
          state.verificationSubStep = 3;
        } else { throw Exception(res['feedback'] ?? 'Verification failed.'); }
      } else if (sub == 3) {
        final frames = await scanner.captureLivenessFrames();
        final pano = await scanner.stitchFramesToPanorama(frames);
        state.faceImage = pano;
        final res = await NecxaAI.verifyLivenessPanorama(await NecxaAI.fileToBase64(pano), userId: state.user?.id);
        if (res['verified'] == true) {
          state.lastSelfieResult = SelfieResult(faceMatch: true, sessionId: res['sessionId']);
          final sync = await ListingSyncService.submitIdentityShard(
            country: 'Uganda', 
            docType: 'National ID', 
            docNumber: '', 
            idFront: state.idImage!, 
            idBack: state.idBackImage!, 
            idHolding: state.idHoldingImage!, 
            facePhoto: pano, 
            frontVerificationId: state.lastIDResult!.sessionId, 
            backVerificationId: state.lastIDBackResult!.sessionId, 
            holdingVerificationId: state.lastHoldingResult!.sessionId, 
            biometricVerificationId: res['sessionId'], 
            idempotencyKey: _submissionIdempotencyKey
          );
          state.identityShardId = sync['identity_shard_id']?.toString();
          if (mounted && _step == 2) _next();
        } else { throw Exception(res['feedback'] ?? 'Liveness failed.'); }
      }
      state.notify();
    } catch (e) { widget.state.setShieldFeedback(e.toString()); }
    finally { setState(() => _loading = false); }
  }

  Future<void> _runUtilityVerification() async {
    setState(() => _loading = true);
    try {
      final res = await ListingSyncService.submitUtilityShard(country: "Uganda", umemeMeter: _umemeCtrl.text, nwscAccount: _nwscCtrl.text, utilityBillPhoto: _utilityBillPhoto!, lc1StampPhoto: _lc1StampPhoto!, lc1OfficerName: _lc1OfficerCtrl.text, landTitlePhoto: _landTitlePhoto!, landBlock: _landBlockCtrl.text, landPlot: _landPlotCtrl.text, brsLicensePhoto: _brsLicensePhoto, idempotencyKey: '$_submissionIdempotencyKey:utility');
      if (res['verified'] == true) { 
        setState(() { 
          _utilityShardId = res['utility_shard_id']?.toString(); 
          _step++; 
        }); 
      }
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
    finally { setState(() => _loading = false); }
  }

  Future<void> _runGpsLock() async {
    setState(() => _loading = true);
    try {
      await widget.state.captureGps();
      final pos = widget.state.currentGps;
      if (pos != null) {
        final res = await ListingSyncService.submitGpsLock(lat: pos.latitude, lng: pos.longitude, accuracy: pos.accuracy, reportedAddress: _cityCtrl.text, reportedDistrict: _districtCtrl.text, idempotencyKey: '$_submissionIdempotencyKey:gps');
        if (res['gps_node_id'] != null) { 
          setState(() { 
            _gpsNodeId = res['gps_node_id']?.toString(); 
            _gpsLocked = true; 
            _step++; 
          }); 
        }
      }
    } finally { setState(() => _loading = false); }
  }

  Future<void> _runFinalSubmission() async {
    setState(() => _loading = true);
    try {
      final res = await ListingSyncService.submitNeuralSynthesis(identityShardId: widget.state.identityShardId!, utilityShardId: _utilityShardId!, gpsNodeId: _gpsNodeId!, title: _titleCtrl.text, description: _descCtrl.text, propertyType: _propType, price: double.parse(_priceCtrl.text.replaceAll(',', '')), priceType: _priceType, bedrooms: _bedrooms, bathrooms: _bathrooms, sqft: _sqft, amenities: _amenities.toList(), exteriorPhotos: _exteriorPhotos, interiorPhotos: _interiorPhotos, bathroomPhotos: _bathroomPhotos, idempotencyKey: _submissionIdempotencyKey);
      setState(() { _mintEventId = res['mint_event_id']?.toString(); _submitted = true; });
    } finally { setState(() => _loading = false); }
  }
}

class _Step3Identity extends StatelessWidget {
  final AppState state; final bool loading; final int subStep; final Future<void> Function() onVerify; final GlobalKey<_NeuralScannerOverlayState> scannerKey;
  const _Step3Identity({required this.state, required this.loading, required this.subStep, required this.onVerify, required this.scannerKey});

  @override
  Widget build(BuildContext context) {
    if (subStep == 2) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Column(children: [
          Row(children: [
            IconButton(icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20), onPressed: () => state.go('home')),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Identity Shard', style: syne(sz: 18, w: FontWeight.w900, c: Colors.white)), Text('Landscape verification', style: dm(sz: 11, c: Colors.white54))]),
            const Spacer(),
            Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF0F2631), borderRadius: BorderRadius.circular(12)), child: Row(children: [const Icon(Icons.verified_user, color: Colors.green, size: 14), const SizedBox(width: 6), Text('Secure session', style: dm(sz: 10, c: Colors.white))])),
          ]),
          const SizedBox(height: 10),
          Text('Fit face and ID inside the frames', style: syne(sz: 16, w: FontWeight.bold, c: Colors.white)),
          const SizedBox(height: 10),
          Expanded(child: Center(child: AspectRatio(aspectRatio: 2.3, child: Stack(children: [
            ClipRRect(borderRadius: BorderRadius.circular(24), child: _NeuralScannerOverlay(key: scannerKey, documentMode: false, subStep: subStep)),
            Positioned(top: 15, left: 15, child: Row(children: [const _PulsingLight(), const SizedBox(width: 6), Text('LIVE', style: dm(sz: 10, w: FontWeight.bold, c: Colors.white))])),
            Positioned(bottom: 15, left: 0, right: 0, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [_guideLabel('ID', Colors.yellow), const SizedBox(width: 220), _guideLabel('Face', Colors.cyan)])),
            Positioned(right: 15, top: 0, bottom: 0, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              _iconBtn(Icons.bolt, () => scannerKey.currentState?.toggleFlash()),
              const SizedBox(height: 16),
              _iconBtn(Icons.cached, () => scannerKey.currentState?.switchLens()),
            ])),
          ])))),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [_info('Lighting'), _info('ID Readable'), _info('No Glasses')]),
          const SizedBox(height: 12),
          Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF081622), borderRadius: BorderRadius.circular(16)), child: Row(children: [
            Text('3 of 4 verified', style: dm(sz: 12, c: Colors.white70)),
            const Spacer(),
            ElevatedButton.icon(onPressed: loading ? null : onVerify, style: ElevatedButton.styleFrom(backgroundColor: C.brand, foregroundColor: Colors.black), icon: const Icon(Icons.camera_alt), label: Text(loading ? 'VERIFYING...' : 'SCAN HOLDING ID PHOTO')),
          ])),
        ]),
      );
    }

    return Column(children: [
      SizedBox(height: 270, child: _NeuralScannerOverlay(key: scannerKey, documentMode: subStep < 2, subStep: subStep)),
      const SizedBox(height: 20),
      _IdentityCaptureProgress(completedStages: [state.lastIDResult?.verified ?? false, state.idBackImage != null, state.lastHoldingResult?.verified ?? false, state.lastSelfieResult?.faceMatch ?? false]),
      const SizedBox(height: 40),
      SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: loading ? null : onVerify, style: ElevatedButton.styleFrom(backgroundColor: C.brand, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 16)), icon: const Icon(Icons.camera_alt), label: Text(loading ? 'VERIFYING...' : 'SCAN PHOTO'))),
    ]);
  }

  Widget _guideLabel(String t, Color c) => Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20), border: Border.all(color: c)), child: Text(t, style: dm(sz: 10, w: FontWeight.bold, c: Colors.white)));
  Widget _iconBtn(IconData i, VoidCallback t) => GestureDetector(onTap: t, child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.white10, shape: BoxShape.circle), child: Icon(i, color: Colors.white, size: 20)));
  Widget _info(String t) => Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [const Icon(Icons.check_circle, color: C.brand, size: 14), const SizedBox(width: 6), Text(t, style: dm(sz: 10, c: Colors.white70))]));
}

class _IdentityCaptureProgress extends StatelessWidget {
  final List<bool> completedStages;
  const _IdentityCaptureProgress({required this.completedStages});
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: List.generate(4, (i) => Icon(completedStages[i] ? Icons.check_circle : Icons.radio_button_unchecked, color: completedStages[i] ? C.brand : C.dim, size: 20))));
}

class _NeuralScannerOverlay extends StatefulWidget {
  final bool documentMode; final int subStep;
  const _NeuralScannerOverlay({super.key, required this.documentMode, this.subStep = 0});
  @override State<_NeuralScannerOverlay> createState() => _NeuralScannerOverlayState();
}

class _NeuralScannerOverlayState extends State<_NeuralScannerOverlay> {
  CameraController? cameraCtrl; CameraLensDirection _curD = CameraLensDirection.back; Future<void>? _initF; String? _livenessPrompt;
  @override void initState() { super.initState(); unawaited(switchCamera(CameraLensDirection.back).catchError((_) {})); }
  Future<void> _init(CameraLensDirection d) async {
    if (cameras.isEmpty) return; final cam = cameras.firstWhere((c) => c.lensDirection == d, orElse: () => cameras.first);
    await cameraCtrl?.dispose(); final next = CameraController(cam, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
    cameraCtrl = next; try { await next.initialize(); _curD = d; if (mounted) setState(() {}); } catch (_) {}
  }
  Future<void> switchCamera(CameraLensDirection d) async {
    if (_initF != null) await _initF; if (_curD == d && cameraCtrl != null && cameraCtrl!.value.isInitialized) return;
    final f = _init(d); _initF = f; try { await f; } finally { _initF = null; }
  }
  Future<CameraController> ensureCamera(CameraLensDirection d) async { await switchCamera(d); return cameraCtrl!; }
  Future<void> toggleFlash() async { if (cameraCtrl != null) await cameraCtrl!.setFlashMode(cameraCtrl!.value.flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off); }
  Future<void> switchLens() async { await switchCamera(_curD == CameraLensDirection.back ? CameraLensDirection.front : CameraLensDirection.back); }
  Future<List<File>> captureLivenessFrames() async {
    final c = await ensureCamera(CameraLensDirection.front); final fs = <File>[]; const pms = ['Center', 'Left', 'Center'];
    for (int i = 0; i < 3; i++) { if (mounted) setState(() => _livenessPrompt = pms[i]); await Future.delayed(const Duration(milliseconds: 700)); fs.add(File((await c.takePicture()).path)); }
    if (mounted) setState(() => _livenessPrompt = null); return fs;
  }
  Future<File> stitchFramesToPanorama(List<File> frames) async {
    final i1 = img.decodeImage(await frames[0].readAsBytes()), i2 = img.decodeImage(await frames[1].readAsBytes()), i3 = img.decodeImage(await frames[2].readAsBytes());
    final p = img.Image(width: i1!.width * 3, height: i1.height); img.compositeImage(p, i1, dstX: 0); img.compositeImage(p, i2!, dstX: i1.width); img.compositeImage(p, i3!, dstX: i1.width * 2);
    final f = File('${(await getTemporaryDirectory()).path}/lp.jpg'); await f.writeAsBytes(img.encodeJpg(p)); return f;
  }
  @override void dispose() { cameraCtrl?.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Stack(children: [
    if (cameraCtrl != null && cameraCtrl!.value.isInitialized) Positioned.fill(child: LayoutBuilder(builder: (context, c) { double pa = cameraCtrl!.value.aspectRatio; final isP = MediaQuery.of(context).orientation == Orientation.portrait; if (isP && pa > 1.0) pa = 1.0 / pa; else if (!isP && pa < 1.0) pa = 1.0 / pa; final va = c.maxWidth / c.maxHeight; double sc = (va > pa) ? va / pa : pa / va; if (widget.subStep == 2) sc *= 0.82; return ClipRect(child: Transform.scale(scale: sc, child: Center(child: CameraPreview(cameraCtrl!)))); })),
    if (_livenessPrompt != null) Positioned.fill(child: Container(color: Colors.black45, child: Center(child: Text(_livenessPrompt!, style: syne(sz: 24, w: FontWeight.w900, c: C.brand))))),
    IgnorePointer(child: CustomPaint(size: Size.infinite, painter: _ScannerOverlayPainter(documentMode: widget.documentMode, isHold: widget.subStep == 2))),
  ]);
}

class _ScannerOverlayPainter extends CustomPainter {
  final bool documentMode, isHold; _ScannerOverlayPainter({required this.documentMode, required this.isHold});
  @override void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.65); final path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    if (isHold) {
      final idR = RRect.fromRectAndRadius(Rect.fromLTWH(size.width * 0.1, size.height * 0.25, size.width * 0.35, size.height * 0.5), const Radius.circular(16));
      final fcR = RRect.fromRectAndRadius(Rect.fromLTWH(size.width * 0.55, size.height * 0.15, size.width * 0.35, size.height * 0.7), const Radius.circular(100));
      canvas.drawPath(Path.combine(PathOperation.difference, path, Path()..addRRect(idR)..addRRect(fcR)), paint);
      canvas.drawRRect(idR, Paint()..color = Colors.yellow..style = PaintingStyle.stroke..strokeWidth = 2); canvas.drawRRect(fcR, Paint()..color = Colors.cyan..style = PaintingStyle.stroke..strokeWidth = 2);
    } else {
      final w = size.width * 0.85, h = w / 1.586; final cp = Path()..addRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(size.width/2, size.height/2), width: w, height: h), const Radius.circular(22)));
      canvas.drawPath(Path.combine(PathOperation.difference, path, cp), paint); canvas.drawPath(cp, Paint()..color = Colors.white70..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }
  @override bool shouldRepaint(CustomPainter old) => true;
}

class _PulsingLight extends StatefulWidget { const _PulsingLight(); @override State<_PulsingLight> createState() => _PulsingLightState(); }
class _PulsingLightState extends State<_PulsingLight> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat(reverse: true);
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => FadeTransition(opacity: _c, child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle)));
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
  @override Widget build(BuildContext context) => Column(children: [const SizedBox(height: 40), Icon(Icons.location_on, size: 80, color: locked ? C.brand : C.dim), const SizedBox(height: 32), Text(locked ? 'GPS Coordinates Locked' : 'Waiting for High-Accuracy GPS...', style: syne(sz: 16, w: FontWeight.w700)), const SizedBox(height: 48), if (!locked) SizedBox(width: double.infinity, child: ElevatedButton(onPressed: loading ? null : onLock, child: const Text('Lock coordinates')))]);
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
