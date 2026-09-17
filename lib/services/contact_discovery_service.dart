import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';

class ContactDiscoveryService {
  SupabaseClient get client => Supabase.instance.client;

  Future<List<Map<String, dynamic>>> discoverFriends() async {
    try {
      // 0. Platform Check
      if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        debugPrint('Contact Discovery not supported on Desktop');
        return [];
      }

      // 1. Request Permissions
      final status = await Permission.contacts.request();
      if (!status.isGranted) {
        debugPrint('Contact permission denied');
        return [];
      }

      // 2. Fetch Contacts with Emails
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      final List<String> emailList = [];
      
      for (var contact in contacts) {
        for (var email in contact.emails) {
          if (email.address.isNotEmpty) {
            emailList.add(email.address.toLowerCase());
          }
        }
      }

      if (emailList.isEmpty) return [];

      // 3. Bulk Match in Supabase via specialized RPC
      final List<dynamic> matchingProfiles = await client.rpc(
        'sync_contacts_by_email',
        params: {'p_emails': emailList.toSet().toList()},
      );

      // Map backend fields to frontend expectations if necessary
      return matchingProfiles.map((p) => {
        ...p,
        'display_name': p['full_name'], // Standardize for UI
        'photo_url': p['avatar_url'],        'email': p['email'],
      }).toList().cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('Contact Discovery Error: $e');
      return [];
    }
  }
}
