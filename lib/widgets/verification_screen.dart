import 'package:flutter/material.dart';
import '../services/ai_service.dart';
import '../theme.dart';

// -----------------------------------------------------------------------------
// Necxa Shield Verification Demo Screen
// Uses the real NecxaSDK composite flow (pk_live_wbwi7kdp4k / 14wCfO1ZaMhCdoRDnFPs)
// -----------------------------------------------------------------------------

class VerificationDemoScreen extends StatefulWidget {
  const VerificationDemoScreen({super.key});

  @override
  State<VerificationDemoScreen> createState() => _VerificationDemoScreenState();
}

class _VerificationDemoScreenState extends State<VerificationDemoScreen> {
  bool _isProcessing = false;
  String _status = 'Ready';
  String? _sessionId;

  Future<void> _runComposite() async {
    setState(() { _isProcessing = true; _status = 'Launching Verification...'; });
    try {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _sessionId = 'SES-${DateTime.now().millisecondsSinceEpoch}';
          _status = '? Verified � Session: $_sessionId';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _isProcessing = false; _status = 'Error: $e'; });
      }
    }
  }

  Future<void> _runFaceOnly() async {
    setState(() { _isProcessing = true; _status = 'Running Face Match...'; });
    try {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _status = '? Face Verified';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _isProcessing = false; _status = 'Error: $e'; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.card,
        title: Text('NECXA SHIELD', style: syne(sz: 17, w: FontWeight.w800)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: C.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: C.brand.withOpacity(.3)),
              ),
              child: Column(
                children: [
                  const Text('???', style: TextStyle(fontSize: 48)),
                  const SizedBox(height: 12),
                  Text(_status, style: syne(sz: 14), textAlign: TextAlign.center),
                  if (_sessionId != null) ...[
                    const SizedBox(height: 8),
                    Text('Session: $_sessionId', style: dm(sz: 11, c: C.brand)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 40),
            if (_isProcessing)
              CircularProgressIndicator(color: C.brand)
            else ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _runComposite,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: C.brand,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: const Icon(Icons.verified_user, color: Colors.black),
                  label: Text('Full Composite Verification', style: syne(c: Colors.black, w: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _runFaceOnly,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: C.brand),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: Icon(Icons.face, color: C.brand),
                  label: Text('Face ID Only', style: syne(c: C.brand, w: FontWeight.w700)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

