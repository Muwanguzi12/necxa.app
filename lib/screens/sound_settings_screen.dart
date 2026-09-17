import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../services/audio_service.dart';

class SoundSettingsScreen extends StatefulWidget {
  final AppState state;
  const SoundSettingsScreen({super.key, required this.state});

  @override
  State<SoundSettingsScreen> createState() => _SoundSettingsScreenState();
}

class _SoundSettingsScreenState extends State<SoundSettingsScreen> {
  final _audio = AudioService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('SOUNDS & RINGTONES', style: syne(sz: 16, w: FontWeight.w800, ls: 1)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, size: 20),
          onPressed: () => widget.state.go('profile'),
        ),
      ),
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity != null && details.primaryVelocity! > 0) {
            widget.state.go('profile');
          }
        },
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _sectionHeader('GENERAL'),
            _toggleTile(
              'In-App Sounds', 
              'Play sounds for sent and received messages', 
              widget.state.soundEnabled, 
              (v) => widget.state.setSoundEnabled(v)
            ),
            
            const SizedBox(height: 32),
            _sectionHeader('NOTIFICATION TONES'),
            _soundTile('Default Notification', 'System default sound', () => _audio.playNotification()),
            _soundTile('Incoming Ringtone', 'Play your active phone ringtone', () => _audio.playRingtone()),
            _soundTile('Alarm Tone', 'Test your system alarm sound', () => _audio.playAlarm()),
            
            const SizedBox(height: 32),
            _sectionHeader('NECXA PREMIUM FX'),
            _soundTile('Crystal Click', 'Signature Necxa UI sound', () => _audio.playUiSound()),
            _soundTile('Message Sent', 'Subtle confirmation chime', () => _audio.playSentMessage(widget.state)),
            
            const SizedBox(height: 40),
            Center(
              child: Text(
                'Ringtones and system sounds are managed by your device settings.',
                textAlign: TextAlign.center,
                style: dm(sz: 11, c: C.dim),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 16),
      child: Text(title, style: syne(sz: 11, w: FontWeight.w800, c: C.dim, ls: 1.2)),
    );
  }

  Widget _toggleTile(String title, String sub, bool val, Function(bool) onChanged) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.border),
      ),
      child: SwitchListTile(
        value: val,
        onChanged: onChanged,
        activeThumbColor: C.brand,
        title: Text(title, style: syne(sz: 14, w: FontWeight.w600)),
        subtitle: Text(sub, style: dm(sz: 11, c: C.dim)),
      ),
    );
  }

  Widget _soundTile(String title, String sub, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.border),
      ),
      child: ListTile(
        onTap: onTap,
        title: Text(title, style: syne(sz: 14, w: FontWeight.w600)),
        subtitle: Text(sub, style: dm(sz: 11, c: C.dim)),
        trailing: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: C.brand.withOpacity(.1), shape: BoxShape.circle),
          child: Icon(Icons.play_arrow_rounded, color: C.brand, size: 20),
        ),
      ),
    );
  }
}

