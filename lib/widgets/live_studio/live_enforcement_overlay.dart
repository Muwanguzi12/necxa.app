import 'package:flutter/material.dart';
import 'dart:ui';
import '../../theme.dart';

class LiveEnforcementOverlay extends StatelessWidget {
  final String? enforcementReason;
  final VoidCallback onClose;

  LiveEnforcementOverlay({
    super.key,
    required this.enforcementReason,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          color: Colors.black87,
          child: Center(
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: 24),
              padding: EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.black, // Assuming NecxaColors.surface is dark
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3), width: 1),
                boxShadow: [
                  BoxShadow(color: Colors.redAccent.withOpacity(0.1), blurRadius: 40, spreadRadius: -10),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.gavel_rounded, color: Colors.redAccent, size: 48),
                  ),
                  SizedBox(height: 24),
                  Text(
                    "Stream Terminated",
                    style: TextStyle(color: C.text, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                  ),
                  SizedBox(height: 12),
                  Text(
                    "This stream has been terminated due to a violation of our community safety guidelines.\n\nReason: ${enforcementReason ?? 'Dangerous or inappropriate content.'}",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: C.text.withOpacity(0.7), fontSize: 15, height: 1.5),
                  ),
                  SizedBox(height: 32),
                  GestureDetector(
                    onTap: onClose,
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Center(
                        child: Text(
                          "CLOSE STUDIO",
                          style: TextStyle(color: C.text, fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


