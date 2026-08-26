import 'package:universal_io/io.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme.dart';
import '../../models/music_models.dart';
import '../../utils/error_handler.dart';

class MusicManagementAdmin extends StatefulWidget {
  const MusicManagementAdmin({super.key});

  @override
  State<MusicManagementAdmin> createState() => _MusicManagementAdminState();
}

class _MusicManagementAdminState extends State<MusicManagementAdmin> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final _formKey = GlobalKey<FormState>();

  // Controllers
  final _titleCtrl = TextEditingController();
  final _artistCtrl = TextEditingController();
  final _genreCtrl = TextEditingController();
  final _albumCtrl = TextEditingController();
  final _isrcCtrl = TextEditingController();
  final _royaltyCtrl = TextEditingController(text: '0.0');

  File? _audioFile;
  File? _artFile;
  String? _audioUrl;
  String? _artUrl;
  bool _isUploading = false;
  String _licenseType = 'platform_owned';
  
  List<Map<String, dynamic>> _tracks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    setState(() => _isLoading = true);
    try {
      final response = await _supabase
          .from('music_tracks')
          .select()
          .order('created_at', ascending: false);
      setState(() => _tracks = List<Map<String, dynamic>>.from(response));
    } catch (e) {
      debugPrint('Load Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickAndUpload(String type) async {
    final result = await FilePicker.platform.pickFiles(
      type: type == 'audio' ? FileType.audio : FileType.image,
    );

    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      setState(() {
        if (type == 'audio') {
          _audioFile = file;
        } else {
          _artFile = file;
        }
        _isUploading = true;
      });

      try {
        final ext = result.files.single.extension ?? (type == 'audio' ? 'mp3' : 'jpg');
        final path = 'music/${type}s/${DateTime.now().millisecondsSinceEpoch}.$ext';
        
        await _supabase.storage.from('music').upload(path, file);
        final url = _supabase.storage.from('music').getPublicUrl(path);

        setState(() {
          if (type == 'audio') {
            _audioUrl = url;
          } else {
            _artUrl = url;
          }
        });
      } catch (e) {
        _msg('Upload failed. ${getUserFriendlyError(e)}');
      } finally {
        setState(() => _isUploading = false);
      }
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_audioUrl == null) {
      _msg('Audio file is required');
      return;
    }

    setState(() => _isUploading = true);
    try {
      await _supabase.rpc('admin_add_platform_music', params: {
        'p_title': _titleCtrl.text,
        'p_artist_name': _artistCtrl.text,
        'p_audio_url': _audioUrl,
        'p_duration': 30, // Mock duration
        'p_genre': _genreCtrl.text,
        'p_album_art_url': _artUrl,
        'p_album_name': _albumCtrl.text,
        'p_isrc_code': _isrcCtrl.text,
        'p_royalty_rate': double.tryParse(_royaltyCtrl.text) ?? 0,
        'p_license_type': _licenseType,
      });

      _msg('Track added successfully');
      _resetForm();
      _loadTracks();
    } catch (e) {
      _msg('Submission failed. ${getUserFriendlyError(e)}');
    } finally {
      setState(() => _isUploading = false);
    }
  }

  void _resetForm() {
    _titleCtrl.clear();
    _artistCtrl.clear();
    _genreCtrl.clear();
    _albumCtrl.clear();
    _isrcCtrl.clear();
    _royaltyCtrl.text = '0.0';
    setState(() {
      _audioFile = null;
      _artFile = null;
      _audioUrl = null;
      _artUrl = null;
    });
  }

  void _msg(String s) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text('MUSIC ADMIN', style: syne(sz: 18, w: FontWeight.w900, ls: 2, c: C.text)),
          bottom: TabBar(
            indicatorColor: C.brand,
            labelStyle: syne(sz: 12, w: FontWeight.bold),
            tabs: const [Tab(text: 'ADD TRACK'), Tab(text: 'CATALOG')],
          ),
        ),
        body: TabBarView(
          children: [
            _buildAddTab(),
            _buildCatalogTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildAddTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            _buildPickerRow(),
            const SizedBox(height: 32),
            _buildField(_titleCtrl, 'Track Title', Icons.title, true),
            _buildField(_artistCtrl, 'Artist Name', Icons.person, true),
            _buildField(_genreCtrl, 'Genre (e.g. Amapiano)', Icons.category, false),
            _buildField(_albumCtrl, 'Album Name', Icons.album, false),
            _buildField(_isrcCtrl, 'ISRC Code', Icons.qr_code, false),
            _buildField(_royaltyCtrl, 'Royalty Rate (%)', Icons.monetization_on, false, isNum: true),
            
            const SizedBox(height: 24),
            DropdownButtonFormField<String>(
              initialValue: _licenseType,
              dropdownColor: Colors.grey[900],
              style: dm(c: C.text),
              decoration: _inputDeco('License Type', Icons.gavel),
              items: ['platform_owned', 'licensed', 'artist_upload'].map((l) => DropdownMenuItem(value: l, child: Text(l.toUpperCase()))).toList(),
              onChanged: (v) => setState(() => _licenseType = v!),
            ),

            const SizedBox(height: 40),
            GestureDetector(
              onTap: _isUploading ? null : _submit,
              child: Container(
                height: 60,
                decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(30)),
                child: Center(
                  child: _isUploading 
                    ? const CircularProgressIndicator(color: Colors.black)
                    : Text('PUBLISH TO PLATFORM', style: syne(sz: 14, w: FontWeight.w900, c: Colors.black, ls: 1)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPickerRow() {
    return Row(
      children: [
        Expanded(child: _pickerCard('Audio File', _audioFile != null, Icons.audiotrack, () => _pickAndUpload('audio'))),
        const SizedBox(width: 16),
        Expanded(child: _pickerCard('Album Art', _artFile != null, Icons.image, () => _pickAndUpload('image'))),
      ],
    );
  }

  Widget _pickerCard(String label, bool hasFile, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 100,
        decoration: BoxDecoration(
          color: hasFile ? C.brand.withOpacity(0.1) : C.text.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: hasFile ? C.brand : C.dim),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: hasFile ? C.brand : C.dim),
            const SizedBox(height: 8),
            Text(label, style: syne(sz: 10, w: FontWeight.bold, c: hasFile ? C.brand : C.dim)),
          ],
        ),
      ),
    );
  }

  Widget _buildField(TextEditingController ctrl, String label, IconData icon, bool req, {bool isNum = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: ctrl,
        style: dm(c: C.text),
        keyboardType: isNum ? TextInputType.number : TextInputType.text,
        decoration: _inputDeco(label, icon),
        validator: (v) => (req && (v == null || v.isEmpty)) ? 'Required' : null,
      ),
    );
  }

  InputDecoration _inputDeco(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      labelStyle: dm(c: C.dim),
      prefixIcon: Icon(icon, color: C.dim, size: 20),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: C.dim)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: C.brand)),
      filled: true,
      fillColor: C.text.withOpacity(0.05),
    );
  }

  Widget _buildCatalogTab() {
    if (_isLoading) return Center(child: CircularProgressIndicator(color: C.brand));
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _tracks.length,
      itemBuilder: (context, i) {
        final t = _tracks[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: C.text.withOpacity(0.05), borderRadius: BorderRadius.circular(16)),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: t['album_art_url'] != null 
                  ? Image.network(t['album_art_url'], width: 48, height: 48, fit: BoxFit.cover)
                  : Container(width: 48, height: 48, color: C.dim, child: Icon(Icons.music_note, color: C.dim)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t['title'], style: syne(sz: 14, w: FontWeight.bold, c: C.text)),
                  Text(t['artist_name'], style: dm(sz: 12, c: C.dim)),
                ]),
              ),
              Switch(
                value: t['is_active'] ?? true, 
                activeThumbColor: C.brand,
                onChanged: (v) async {
                  await _supabase.rpc('admin_update_music', params: {'p_track_id': t['id'], 'p_is_active': v});
                  _loadTracks();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}


