import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../utils/error_handler.dart';

class ArtistAuthScreen extends StatefulWidget {
  final AppState state;
  const ArtistAuthScreen({super.key, required this.state});

  @override
  State<ArtistAuthScreen> createState() => _ArtistAuthScreenState();
}

class _ArtistAuthScreenState extends State<ArtistAuthScreen> {
  bool _isLogin = false;
  final _formKey = GlobalKey<FormState>();
  
  // Fields
  String _artistName = '';
  String _legalName = '';
  String _genre = '';
  String _distributorLink = '';
  String _email = '';
  String _password = '';

  void _submit() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    try {
      if (_isLogin) {
        // Mock login
        widget.state.setArtistStatus(true);
        _success("Artist Login Successful!");
      } else {
        // Mock signup with distributor links
        widget.state.setArtistStatus(true);
        _success("Artist Program Joined!");
      }
    } catch (e) {
      _err(getUserFriendlyError(e));
    }
  }

  void _success(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: C.green));
    Navigator.pop(context);
    widget.state.go('upload');
  }

  void _err(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: C.red));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.black, Colors.deepPurple.shade900.withOpacity(0.3), Colors.black],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                   const SizedBox(height: 40),
                   const Text('??', style: TextStyle(fontSize: 60), textAlign: TextAlign.center),
                   const SizedBox(height: 16),
                   Text(_isLogin ? 'Artist Login' : 'Artist Program', 
                      style: syne(sz: 28, w: FontWeight.w900, ls: 1), textAlign: TextAlign.center),
                   Text(_isLogin ? 'Welcome back to your studio' : 'Join the verified distribution program', 
                      style: dm(sz: 14, c: C.dim), textAlign: TextAlign.center),
                   const SizedBox(height: 48),

                   if (!_isLogin) ...[
                     _field('Artist Name', (v) => _artistName = v!),
                     const SizedBox(height: 16),
                     _field('Legal Name', (v) => _legalName = v!),
                     const SizedBox(height: 16),
                     _field('Primary Genre', (v) => _genre = v!),
                     const SizedBox(height: 16),
                     _field('Distributor Link (Spotify/SoundCloud)', (v) => _distributorLink = v!, hint: 'https://...'),
                     const SizedBox(height: 16),
                   ],

                   _field('Email Address', (v) => _email = v!),
                   const SizedBox(height: 16),
                   _field('Password', (v) => _password = v!, obscure: true),

                   const SizedBox(height: 40),
                   ElevatedButton(
                     onPressed: _submit,
                     style: ElevatedButton.styleFrom(
                       backgroundColor: C.brand,
                       foregroundColor: Colors.black,
                       padding: const EdgeInsets.symmetric(vertical: 18),
                       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                     ),
                     child: Text(_isLogin ? 'LOG IN' : 'JOIN PROGRAM', style: syne(sz: 16, w: FontWeight.w900, ls: 1.5)),
                   ),

                   const SizedBox(height: 24),
                   TextButton(
                     onPressed: () => setState(() => _isLogin = !_isLogin),
                     child: Text(_isLogin ? "Don't have an artist account? Sign up" : "Already in the program? Log in", 
                        style: dm(sz: 13, c: C.brand)),
                   ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(String label, Function(String?) onSave, {bool obscure = false, String? hint}) {
    return TextFormField(
      obscureText: obscure,
      onSaved: onSave,
      style: dm(sz: 15, c: C.text),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: dm(sz: 13, c: C.dim),
        labelStyle: dm(sz: 14, c: C.sub),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: C.dim)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: C.brand)),
        filled: true,
        fillColor: C.text.withOpacity(.05),
      ),
      validator: (v) => v == null || v.isEmpty ? 'Required field' : null,
    );
  }
}


