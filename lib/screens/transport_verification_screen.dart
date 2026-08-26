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
        if (step == 1) {
          _selfieFile = File(picked.path);
        } else if (step == 2) _permitFile = File(picked.path);
        else if (step == 3) _vehicleFile = File(picked.path);
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
      _result = null;
    });

    final res = await NecxaAI.verifyTransportDriver(
      driverSelfie: _selfieFile!,
      permitImage: _permitFile!,
      vehicleImage: _vehicleFile!,
      issuingCountryCode: countryCode,
      aiProcessingConsent: _aiProcessingConsent,
    );

    if (!mounted) return;

    setState(() {
      _isScanning = false;
      _result = res;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Verification Failed: ${res['error'] ?? "Documents rejected."}'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Widget _buildStep(int step, String title, String subtitle, IconData icon, File? file) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: file != null ? C.brand : C.dim),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: file != null ? C.brand : C.dim,
          child: Icon(file != null ? Icons.check : icon, color: C.text),
        ),
        title: Text(title, style: syne(sz: 16, w: FontWeight.w700, c: C.text)),
        subtitle: Text(subtitle, style: dm(sz: 13, c: C.sub)),
        trailing: file != null 
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(file, width: 60, height: 60, fit: BoxFit.cover)
            )
          : TextButton(
              onPressed: () => _pickImage(step),
              child: Text('Upload', style: dm(c: C.brand)),
            ),
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
      body: _isScanning
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: C.brand),
                  const SizedBox(height: 24),
                  Text('Necxa AI is scanning documents...', style: syne(sz: 16, c: C.text)),
                  const SizedBox(height: 8),
                  Text('Analyzing license plates and permits', style: dm(sz: 13, c: C.dim)),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Become a Courier', style: syne(sz: 28, w: FontWeight.w900, c: C.text)),
                  const SizedBox(height: 8),
                  Text('Submit your documents for secure multi-layer verification. Uncertain formats are sent for human review.', style: dm(sz: 15, c: C.sub)),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _countryController,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 2,
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
                  const SizedBox(height: 32),
                  
                  _buildStep(1, 'Live Selfie', 'Take a quick photo of your face', Icons.face, _selfieFile),
                  _buildStep(2, 'Driving Permit', 'Capture your official driving permit', Icons.badge, _permitFile),
                  _buildStep(3, 'Vehicle License Plate', 'Capture a clear photo of the plate', Icons.directions_car, _vehicleFile),

                  CheckboxListTile(
                    value: _aiProcessingConsent,
                    onChanged: (value) => setState(() => _aiProcessingConsent = value == true),
                    contentPadding: EdgeInsets.zero,
                    activeColor: C.brand,
                    title: Text('Allow secure AI verification', style: syne(sz: 14, w: FontWeight.w700, c: C.text)),
                    subtitle: Text(
                      'Your permit image may be processed by approved AI providers. Your selfie is reserved for the specialized biometric service.',
                      style: dm(sz: 12, c: C.sub),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),

                  if (_result != null && _result!['verified'] == false)
                    Container(
                      padding: const EdgeInsets.all(16),
                      margin: const EdgeInsets.only(bottom: 24),
                      decoration: BoxDecoration(
                        color: (_result!['decision'] == 'manual_review' ? Colors.orange : Colors.red).withValues(alpha: 0.1),
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
                      onPressed: (_selfieFile != null && _permitFile != null && _vehicleFile != null && _aiProcessingConsent)
                          ? _runAIVerification
                          : null,
                      child: Text('Run AI Verification', style: syne(sz: 16, w: FontWeight.w800, c: C.text)),
                    ),
                  )
                ],
              ),
            ),
    );
  }
}


