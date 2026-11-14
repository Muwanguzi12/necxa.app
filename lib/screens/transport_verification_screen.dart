import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:universal_io/io.dart';
import '../theme.dart';
import '../services/ai_service.dart';
import '../app_state.dart';

class TransportVerificationScreen extends StatefulWidget {
  final AppState state;
  const TransportVerificationScreen({super.key, required this.state});

  @override
  State<TransportVerificationScreen> createState() => _TransportVerificationScreenState();
}

class _TransportVerificationScreenState extends State<TransportVerificationScreen> {
  final ImagePicker _picker = ImagePicker();
  late final TextEditingController _countryController;
  
  File? _selfieFile;
  File? _permitFile;
  File? _vehicleFile;
  
  bool _isScanning = false;
  int _currentScanningStep = 0; // 0=idle, 1=Selfie, 2=Permit, 3=Vehicle, 4=Finalizing
  String _currentScanningStatus = '';
  int? _failedStep;
  bool _aiProcessingConsent = false;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _countryController = TextEditingController(
      text: WidgetsBinding.instance.platformDispatcher.locale.countryCode ?? '',
    );
  }

  @override
  void dispose() {
    _countryController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(int step) async {
    const source = ImageSource.camera;
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 75,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    
    if (picked != null) {
      setState(() {
        if (_failedStep == step) _failedStep = null;
        if (step == 1) {
          _selfieFile = File(picked.path);
        } else if (step == 2) {
          _permitFile = File(picked.path);
        } else if (step == 3) {
          _vehicleFile = File(picked.path);
        }
      });
    }
  }

  Future<void> _runAIVerification() async {
    final countryCode = _countryController.text.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(countryCode)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the 2-letter country code that issued the permit, for example GB, NG, ZA, KE or UG.')),
      );
      return;
    }
    if (_selfieFile == null || _permitFile == null || _vehicleFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all 3 photo uploads first.')),
      );
      return;
    }

    setState(() {
      _isScanning = true;
      _currentScanningStep = 1;
      _currentScanningStatus = 'Analyzing Photo 1: Live Selfie...';
      _failedStep = null;
      _result = null;
    });

    final res = await NecxaAI.verifyTransportDriver(
      driverSelfie: _selfieFile!,
      permitImage: _permitFile!,
      vehicleImage: _vehicleFile!,
      issuingCountryCode: countryCode,
      aiProcessingConsent: _aiProcessingConsent,
      onStepProgress: (step, message) {
        if (mounted) {
          setState(() {
            _currentScanningStep = step;
            _currentScanningStatus = message;
          });
        }
      },
    );

    if (!mounted) return;

    setState(() {
      _isScanning = false;
      _result = res;
      if (res['step_failed'] != null) {
        _failedStep = res['step_failed'] as int;
      }
    });

    if (res['verified'] == true) {
      await widget.state.checkDriverStatus();
      await widget.state.fetchAvailableDrivers();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Verification Successful! Plate: ${res['number_plate']}'),
          backgroundColor: Colors.green,
        ),
      );
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) Navigator.pop(context, true);
      });
    } else if (res['decision'] == 'manual_review') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Submitted for review: ${res['error'] ?? "We need a closer verification."}'),
          backgroundColor: Colors.orange,
        ),
      );
    } else {
      final stepFailedMsg = _failedStep != null ? ' (Photo $_failedStep failed)' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Verification Failed$stepFailedMsg: ${res['error'] ?? "Documents rejected."}'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Widget _buildStep(int step, String title, String subtitle, IconData icon, File? file) {
    final isCurrentStepScanning = _isScanning && _currentScanningStep == step;
    final isFailed = _failedStep == step;

    Color borderColor = C.dim;
    if (isCurrentStepScanning) {
      borderColor = C.gold;
    } else if (isFailed) {
      borderColor = Colors.redAccent;
    } else if (file != null) {
      borderColor = C.brand;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor, width: isCurrentStepScanning || isFailed ? 2 : 1),
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: CircleAvatar(
              backgroundColor: isFailed
                  ? Colors.red.withOpacity(0.2)
                  : file != null
                      ? C.brand
                      : C.dim,
              child: isCurrentStepScanning
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: C.text),
                    )
                  : Icon(
                      isFailed
                          ? Icons.error_outline
                          : file != null
                              ? Icons.check
                              : icon,
                      color: isFailed ? Colors.redAccent : C.text,
                    ),
            ),
            title: Row(
              children: [
                Text('Photo $step: $title', style: syne(sz: 16, w: FontWeight.w700, c: C.text)),
                if (isCurrentStepScanning) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: C.gold.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('Scanning...', style: dm(sz: 11, c: C.gold, w: FontWeight.w700)),
                  ),
                ]
              ],
            ),
            subtitle: Text(
              isCurrentStepScanning ? 'AI Vision model inspecting single photo...' : subtitle,
              style: dm(sz: 13, c: isCurrentStepScanning ? C.gold : C.sub),
            ),
            trailing: file != null
                ? GestureDetector(
                    onTap: _isScanning ? null : () => _pickImage(step),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Image.file(file, width: 60, height: 60, fit: BoxFit.cover),
                          if (isFailed)
                            Container(
                              width: 60,
                              height: 60,
                              color: Colors.black54,
                              child: const Icon(Icons.refresh, color: Colors.white),
                            ),
                        ],
                      ),
                    ),
                  )
                : TextButton(
                    onPressed: _isScanning ? null : () => _pickImage(step),
                    child: Text('Upload', style: dm(c: C.brand)),
                  ),
          ),
          if (isFailed)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.redAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Photo $step failed AI check. Tap retake to upload a clearer image.',
                      style: dm(sz: 12, c: Colors.redAccent),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Courier Verification', style: syne(sz: 18, w: FontWeight.w700, c: C.text)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Become a Courier', style: syne(sz: 28, w: FontWeight.w900, c: C.text)),
            const SizedBox(height: 8),
            Text(
              'Sequential AI Vision checks inspect each photo individually (Photo 1 Selfie ➔ Photo 2 Permit ➔ Photo 3 Vehicle).',
              style: dm(sz: 14, c: C.sub),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _countryController,
              textCapitalization: TextCapitalization.characters,
              maxLength: 2,
              enabled: !_isScanning,
              style: dm(sz: 16, c: C.text),
              decoration: InputDecoration(
                labelText: 'Permit issuing country',
                hintText: '2-letter code, e.g. BR, CA, IN, NG',
                helperText: 'Use the country printed on the driving permit.',
                prefixIcon: const Icon(Icons.public),
                counterText: '',
                filled: true,
                fillColor: C.card,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 28),

            if (_isScanning)
              Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: C.gold.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: C.gold.withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: C.gold),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Sequential AI Vision Scanning', style: syne(sz: 14, w: FontWeight.w700, c: C.gold)),
                          const SizedBox(height: 2),
                          Text(_currentScanningStatus, style: dm(sz: 12, c: C.text)),
                        ],
                      ),
                    )
                  ],
                ),
              ),

            _buildStep(1, 'Live Selfie', 'Take a quick photo of your face', Icons.face, _selfieFile),
            _buildStep(2, 'Driving Permit', 'Capture your official driving permit', Icons.badge, _permitFile),
            _buildStep(3, 'Vehicle License Plate', 'Capture a clear photo of the plate', Icons.directions_car, _vehicleFile),

            CheckboxListTile(
              value: _aiProcessingConsent,
              onChanged: _isScanning ? null : (value) => setState(() => _aiProcessingConsent = value == true),
              contentPadding: EdgeInsets.zero,
              activeColor: C.brand,
              title: Text('Allow secure AI verification', style: syne(sz: 14, w: FontWeight.w700, c: C.text)),
              subtitle: Text(
                'Your photos are evaluated one by one using specialized single-image Vision models.',
                style: dm(sz: 12, c: C.sub),
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),

            if (_result != null && _result!['verified'] == false)
              Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: (_result!['decision'] == 'manual_review' ? Colors.orange : Colors.red).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _result!['decision'] == 'manual_review'
                      ? 'Manual review required: ${_result!['error'] ?? "We need a closer verification."}'
                      : 'Verification rejected: ${_result!['error'] ?? "Documents did not match requirements."}',
                  style: dm(c: _result!['decision'] == 'manual_review' ? Colors.orange : Colors.redAccent),
                ),
              ),

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: C.brand,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: (_selfieFile != null && _permitFile != null && _vehicleFile != null && _aiProcessingConsent && !_isScanning)
                    ? _runAIVerification
                    : null,
                child: Text(_isScanning ? 'Scanning Sequential AI...' : 'Run Single-Photo AI Verification',
                    style: syne(sz: 16, w: FontWeight.w800, c: C.text)),
              ),
            )
          ],
        ),
      ),
    );
  }
}
