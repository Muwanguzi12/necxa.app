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
  final _districtCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String _priceType = 'Monthly', _role = 'owner', _propType = 'apartment', _submissionIdempotencyKey = '';
  final _umemeCtrl = TextEditingController(), _nwscCtrl = TextEditingController(), _landBlockCtrl = TextEditingController(), _landPlotCtrl = TextEditingController(), _lc1OfficerCtrl = TextEditingController();
  File? _utilityBillPhoto, _lc1StampPhoto, _landTitlePhoto, _brsLicensePhoto;
  bool _submitted = false, _gpsLocked = false;
  String? _identityShardId, _utilityShardId, _gpsNodeId, _mintEventId;
  final List<File> _exteriorPhotos = [], _interiorPhotos = [], _bathroomPhotos = [];
  final GlobalKey<_NeuralScannerOverlayState> _scannerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _submissionIdempotencyKey = 'listing-${widget.state.user?.id}-${DateTime.now().microsecondsSinceEpoch}';
    for (final c in [_titleCtrl, _districtCtrl, _cityCtrl, _priceCtrl]) { c.addListener(() => setState(() {})); }
  }

  @override
  void dispose() {
    for (final c in [_titleCtrl, _descCtrl, _districtCtrl, _cityCtrl, _priceCtrl, _umemeCtrl, _nwscCtrl, _landBlockCtrl, _landPlotCtrl, _lc1OfficerCtrl]) { c.dispose(); }
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _next() => setState(() => _step++);
  void _back() => setState(() => _step--);

  @override
  Widget build(BuildContext context) {
    final bool isHoldIDStep = _step == 2 && widget.state.verificationSubStep == 2;
    
    // NO ROTATED BOX, NO ORIENTATION BUILDER - CLEAN FULLSCREEN SCAFFOLD
    if (isHoldIDStep) {
      return Scaffold(
        backgroundColor: const Color(0xFF030E17),
        body: _Step3Identity(
          state: widget.state, 
          loading: _loading, 
          subStep: widget.state.verificationSubStep, 
          onVerify: _runIdentityVerification, 
          scannerKey: _scannerKey
        ),
      );
    }

    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.bg, elevation: 0,
        title: Text('List a Property', style: syne(sz: 17, w: FontWeight.w700)),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => widget.state.go('home')),
      ),
      body: Column(children: [
        _buildProgress(),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 20), child: _buildStepBody())),
        if (!_submitted && _step < 6) _buildBottomNav(),
      ]),
    );
  }

  Widget _buildProgress() => Padding(
    padding: const EdgeInsets.all(20),
    child: Row(children: List.generate(7, (i) => Expanded(child: Container(height: 4, margin: const EdgeInsets.only(right: 4), decoration: BoxDecoration(color: i <= _step ? C.brand : C.border, borderRadius: BorderRadius.circular(2)))))),
  );

  Widget _buildStepBody() {
    switch (_step) {
      case 2: return _Step3Identity(state: widget.state, loading: _loading, subStep: widget.state.verificationSubStep, onVerify: _runIdentityVerification, scannerKey: _scannerKey);
      default: return Container(height: 300, alignment: Alignment.center, child: Text('Step ${_step + 1} Content'));
    }
  }

  Widget _buildBottomNav() => Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: C.bg, border: Border(top: BorderSide(color: C.border))), child: Row(children: [
    Expanded(child: TextButton(onPressed: _step > 0 ? _back : null, child: const Text('Back'))),
    const SizedBox(width: 20),
    Expanded(flex: 2, child: ElevatedButton(onPressed: _next, child: const Text('Continue'))),
  ]));

  Future<void> _runIdentityVerification() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final sub = widget.state.verificationSubStep;
      final scanner = _scannerKey.currentState;
      if (scanner == null) throw Exception('Scanner not ready.');

      if (sub == 0 || sub == 1) {
        final ctrl = await scanner.ensureCamera(CameraLensDirection.back);
        final res = await NecxaAI.verifyID(File((await ctrl.takePicture()).path), userId: widget.state.user?.id, action: sub == 0 ? 'verify-id-front' : 'verify-id-back');
        if (res['verified'] == true) {
          if (sub == 0) widget.state.lastIDResult = IDResult(verified: true, sessionId: res['sessionId']);
          else {
            widget.state.lastIDBackResult = IDResult(verified: true, sessionId: res['sessionId']);
            // HARD LOCK TO LANDSCAPE FOR HOLD ID
            await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
          }
          widget.state.verificationSubStep = sub + 1;
        } else { throw Exception(res['feedback'] ?? 'Scan failed.'); }
      } else if (sub == 2) {
        final ctrl = await scanner.ensureCamera(CameraLensDirection.back);
        final raw = File((await ctrl.takePicture()).path);
        final res = await NecxaAI.verifyID(raw, userId: widget.state.user?.id, action: 'verify-id-holding');
        if (res['verified'] == true) {
          widget.state.lastHoldingResult = IDResult(verified: true, sessionId: res['sessionId']);
          widget.state.idHoldingImage = raw;
          // VERIFIED: NOW SWITCH BACK TO PORTRAIT
          await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
          widget.state.verificationSubStep = 3;
        } else { throw Exception(res['feedback'] ?? 'Verification failed.'); }
      } else if (sub == 3) {
        final frames = await scanner.captureLivenessFrames();
        final pano = await scanner.stitchFramesToPanorama(frames);
        final res = await NecxaAI.verifyLivenessPanorama(await NecxaAI.fileToBase64(pano), userId: widget.state.user?.id);
        if (res['verified'] == true) {
          widget.state.lastSelfieResult = SelfieResult(faceMatch: true, sessionId: res['sessionId']);
          widget.state.faceImage = pano;
          setState(() => _step++);
        } else { throw Exception(res['feedback'] ?? 'Liveness failed.'); }
      }
      widget.state.notify();
    } catch (e) { widget.state.setShieldFeedback(e.toString()); }
    finally { setState(() => _loading = false); }
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
  CameraController? cameraCtrl; CameraLensDirection _curD = CameraLensDirection.back; Future<void>? _initF;

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
    final c = await ensureCamera(CameraLensDirection.front); final fs = <File>[];
    for (int i = 0; i < 3; i++) { await Future.delayed(const Duration(milliseconds: 700)); fs.add(File((await c.takePicture()).path)); }
    return fs;
  }

  Future<File> stitchFramesToPanorama(List<File> frames) async {
    final i1 = img.decodeImage(await frames[0].readAsBytes()), i2 = img.decodeImage(await frames[1].readAsBytes()), i3 = img.decodeImage(await frames[2].readAsBytes());
    final p = img.Image(width: i1!.width * 3, height: i1.height);
    img.compositeImage(p, i1, dstX: 0); img.compositeImage(p, i2!, dstX: i1.width); img.compositeImage(p, i3!, dstX: i1.width * 2);
    final f = File('${(await getTemporaryDirectory()).path}/lp.jpg'); await f.writeAsBytes(img.encodeJpg(p)); return f;
  }

  @override void dispose() { cameraCtrl?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Stack(children: [
    if (cameraCtrl != null && cameraCtrl!.value.isInitialized) Positioned.fill(child: ClipRect(child: Center(child: CameraPreview(cameraCtrl!)))),
    IgnorePointer(child: CustomPaint(size: Size.infinite, painter: _ScannerOverlayPainter(documentMode: widget.documentMode, isHold: widget.subStep == 2))),
  ]);
}

class _ScannerOverlayPainter extends CustomPainter {
  final bool documentMode, isHold;
  _ScannerOverlayPainter({required this.documentMode, required this.isHold});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.65);
    final path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    if (isHold) {
      final idR = RRect.fromRectAndRadius(Rect.fromLTWH(size.width * 0.1, size.height * 0.25, size.width * 0.35, size.height * 0.5), const Radius.circular(16));
      final fcR = RRect.fromRectAndRadius(Rect.fromLTWH(size.width * 0.55, size.height * 0.15, size.width * 0.35, size.height * 0.7), const Radius.circular(100));
      canvas.drawPath(Path.combine(PathOperation.difference, path, Path()..addRRect(idR)..addRRect(fcR)), paint);
      canvas.drawRRect(idR, Paint()..color = Colors.yellow..style = PaintingStyle.stroke..strokeWidth = 2);
      canvas.drawRRect(fcR, Paint()..color = Colors.cyan..style = PaintingStyle.stroke..strokeWidth = 2);
    } else {
      final w = size.width * 0.85, h = w / 1.586;
      final cp = Path()..addRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(size.width/2, size.height/2), width: w, height: h), const Radius.circular(22)));
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
  @override Widget build(BuildContext context) => FadeTransition(opacity: _c, child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle)));
}
