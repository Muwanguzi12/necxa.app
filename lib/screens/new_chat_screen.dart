// lib/screens/new_chat_screen.dart
// NECXA — New Chat: Find users via email search, phone contacts, or saved contacts

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme.dart';
import '../app_state.dart';
import '../models/chat_models.dart';
import '../utils/error_handler.dart';

class NewChatScreen extends StatefulWidget {
  final AppState state;
  const NewChatScreen({super.key, required this.state});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen>
    with SingleTickerProviderStateMixin {

  late TabController _tabs;
  final TextEditingController _emailCtrl = TextEditingController();
  final _supabase = Supabase.instance.client;

  // Email search state
  bool   _emailSearching  = false;
  Map<String, dynamic>? _foundUser;
  String? _emailError;

  // Phone contacts state
  bool   _contactsLoading = false;
  bool   _contactsGranted = false;
  List<Contact>           _phoneContacts  = [];
  List<Map<String, dynamic>> _necxaMatches = [];
  String _contactFilter = '';

  // Saved contacts state
  List<Map<String, dynamic>> _savedContacts = [];
  bool   _savedLoading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    widget.state.fetchConversations();
    _loadSavedContacts();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  // ── EMAIL SEARCH ─────────────────────────────────────────────
  Future<void> _searchByEmail() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _emailError = 'Enter a valid email address');
      return;
    }
    setState(() { _emailSearching = true; _foundUser = null; _emailError = null; });

    try {
      final res = await _supabase
          .from('profiles')
          .select('id, full_name, avatar_url, email, is_agent, trust_score')
          .ilike('email', email)
          .maybeSingle();

      if (res == null) {
        setState(() { _emailError = 'No Necxa user found with that email'; _emailSearching = false; });
      } else if (res['id'] == widget.state.user?.id) {
        setState(() { _emailError = 'That\'s your own account 😅'; _emailSearching = false; });
      } else {
        setState(() { _foundUser = res; _emailSearching = false; });
      }
    } catch (e) {
      setState(() { _emailError = 'Search failed: ${getUserFriendlyError(e)}'; _emailSearching = false; });
    }
  }

  // ── PHONE CONTACTS ───────────────────────────────────────────
  Future<void> _loadPhoneContacts() async {
    setState(() => _contactsLoading = true);
    final status = await Permission.contacts.request();
    if (!status.isGranted) {
      setState(() { _contactsGranted = false; _contactsLoading = false; });
      return;
    }
    setState(() => _contactsGranted = true);

    final contacts = await FlutterContacts.getContacts(withProperties: true);
    
    // Sort contacts by name
    contacts.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    
    setState(() { _phoneContacts = contacts; _contactsLoading = false; });

    // Cross-reference with Necxa profiles by phone number
    final List<String> variations = [];
    for (var c in contacts) {
      for (var p in c.phones) {
        final digits = p.number.replaceAll(RegExp(r'\D'), '');
        if (digits.isEmpty) continue;
        
        // Variation 1: Exact digits
        variations.add(digits);
        // Variation 2: With plus prefix
        variations.add('+$digits');
        
        // Variation 3: Handle local prefixes (e.g. 07... -> 2567...)
        if (digits.startsWith('0') && digits.length >= 10) {
          final local = digits.substring(1);
          variations.add('256$local');
          variations.add('+256$local');
        }
      }
    }

    final uniqueVariations = variations.toSet().toList();

    if (uniqueVariations.isNotEmpty) {
      try {
        final matches = await _supabase
            .from('profiles')
            .select('id, full_name, avatar_url, phone, is_agent, trust_score')
            .inFilter('phone', uniqueVariations);
        setState(() => _necxaMatches = List<Map<String, dynamic>>.from(matches));
      } catch (e) {
        debugPrint('Contact match error: ${getUserFriendlyError(e)}');
      }
    }
  }

  // ── SAVED CONTACTS ───────────────────────────────────────────
  Future<void> _loadSavedContacts() async {
    setState(() => _savedLoading = true);
    try {
      final res = await _supabase
          .from('saved_contacts')
          .select('contact_id, nickname, saved_at, profiles:contact_id(id, full_name, avatar_url, is_agent, trust_score)')
          .eq('user_id', widget.state.user?.id ?? '')
          .order('saved_at', ascending: false);
      setState(() {
        _savedContacts = List<Map<String, dynamic>>.from(res);
        _savedLoading = false;
      });
    } catch (_) {
      setState(() => _savedLoading = false);
    }
  }

  // ── OPEN CHAT ────────────────────────────────────────────────
  Future<void> _openChatWith(String otherUserId, String otherName, String? otherAvatar) async {
    try {
      final res = await _supabase.rpc('get_or_create_direct_room', params: {
        'p_user_a': widget.state.user?.id,
        'p_user_b': otherUserId,
      });

      final roomId = res as String;

      final room = ChatRoom(
        id: roomId,
        agentId: otherUserId,
        otherName: otherName,
        otherAvatar: otherAvatar,
        createdAt: DateTime.now(),
      );

      widget.state.activeConversation = room;
      await widget.state.fetchMessages(roomId);
      if (mounted) widget.state.go('chat-detail');

      // Auto-save to saved_contacts
      await _supabase.from('saved_contacts').upsert({
        'user_id': widget.state.user?.id,
        'contact_id': otherUserId,
      }, onConflict: 'user_id,contact_id');

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to initialize chat: ${getUserFriendlyError(e)}'),
          backgroundColor: C.red,
        ));
      }
    }
  }

  // ════════════════════════════════════════════════════════════
  // BUILD
  // ════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => widget.state.goBack(),
        ),
        title: Text('New Message', style: syne(sz: 20, w: FontWeight.w800, c: Colors.white)),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: C.brand,
          labelColor: C.brand,
          unselectedLabelColor: Colors.white38,
          labelStyle: syne(sz: 12, w: FontWeight.w700, c: C.brand),
          tabs: const [
            Tab(icon: Icon(Icons.all_inbox), text: 'Inbox'),
            Tab(icon: Icon(Icons.email_outlined), text: 'Email'),
            Tab(icon: Icon(Icons.contacts_outlined), text: 'Contacts'),
            Tab(icon: Icon(Icons.star_outline), text: 'Saved'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildInboxTab(),
          _buildEmailTab(),
          _buildContactsTab(),
          _buildSavedTab(),
        ],
      ),
    );
  }

  // ── TAB 1: INBOX ───────────────────────────────────────────────
  Widget _buildInboxTab() {
    if (widget.state.isChatLoading) {
      return const Center(child: CircularProgressIndicator(color: C.brand));
    }
    
    final convos = widget.state.conversations;
    
    return Column(
      children: [
        // 🚀 Separate Creator Social Entry
        GestureDetector(
          onTap: () => widget.state.go('creator-chat-list'),
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF00E5FF), Color(0xFF00B2CC)]),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.2), blurRadius: 12)],
            ),
            child: Row(
              children: [
                const Icon(Icons.star_rounded, color: Colors.black),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'CREATOR SOCIAL',
                        style: syne(
                          sz: 13,
                          w: FontWeight.w900,
                          c: Colors.black,
                        ),
                      ),
                      Text(
                        'Exclusive interaction channel',
                        style: dm(sz: 11, c: Colors.black54),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.arrow_forward_ios,
                  size: 14,
                  color: Colors.black45,
                ),
              ],
            ),
          ),
        ),

        if (convos.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'No active conversations yet.',
                style: dm(sz: 14, c: Colors.white30),
              ),
            ),
          ),

        if (convos.isNotEmpty)
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: convos.length,
              separatorBuilder: (_, __) =>
                  Divider(color: Colors.white.withOpacity(0.05)),
              itemBuilder: (_, i) {
                final room = convos[i];
                final isUnread = room.myUnread > 0;

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  leading: CircleAvatar(
                    radius: 28,
                    backgroundColor: Colors.white.withOpacity(0.1),
                    // CachedNetworkImage — zero repeat egress after first load
                    backgroundImage: !room.isSupport && room.otherAvatar != null
                        ? CachedNetworkImageProvider(room.otherAvatar!)
                        : null,
                    child: room.isSupport
                        ? const Icon(
                            Icons.support_agent_rounded,
                            color: C.brand,
                            size: 28,
                          )
                        : room.otherAvatar == null
                        ? Text(
                            room.displayName[0].toUpperCase(),
                            style: syne(sz: 18, w: FontWeight.bold, c: C.brand),
                          )
                        : null,
                  ),
                  title: Text(
                    room.displayName,
                    style: syne(
                      sz: 16,
                      w: isUnread ? FontWeight.w900 : FontWeight.w600,
                      c: isUnread ? Colors.white : Colors.white70,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      room.isSupport
                          ? 'Necxa Support · ${room.lastMessage ?? 'Support conversation'}'
                          : (room.lastMessage ?? 'Started a conversation'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: dm(
                        sz: 13,
                        w: isUnread ? FontWeight.w600 : FontWeight.w400,
                        c: isUnread ? Colors.white : C.dim,
                      ),
                    ),
                  ),
                  trailing: isUnread
                      ? Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            color: C.red,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            room.myUnread.toString(),
                            style: dm(
                              sz: 11,
                              w: FontWeight.bold,
                              c: Colors.white,
                            ),
                          ),
                        )
                      : const Icon(
                          Icons.arrow_forward_ios,
                          size: 14,
                          color: Colors.white24,
                        ),
                  onTap: () async {
                    widget.state.activeConversation = room;
                    await widget.state.fetchMessages(room.id);
                    if (context.mounted) widget.state.go('chat-detail');
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  // ── TAB 2: EMAIL SEARCH ───────────────────────────────────────
  Widget _buildEmailTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Find by Email', style: syne(sz: 20, w: FontWeight.w900)),
          const SizedBox(height: 6),
          Text('Enter a Necxa user\'s email address', style: dm(sz: 13, c: C.dim)),
          const SizedBox(height: 24),

          // Input row
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  style: dm(),
                  decoration: InputDecoration(
                    hintText: 'user@example.com',
                    hintStyle: dm(c: C.dim),
                    filled: true,
                    fillColor: C.card,
                    prefixIcon: Icon(Icons.search, color: C.dim),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    errorText: _emailError,
                  ),
                  onSubmitted: (_) => _searchByEmail(),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _searchByEmail,
                child: Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    gradient: brandGrad,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [BoxShadow(color: C.brand.withOpacity(.3), blurRadius: 12)],
                  ),
                  child: _emailSearching
                      ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                      : const Icon(Icons.arrow_forward, color: Colors.black),
                ),
              ),
            ],
          ),

          const SizedBox(height: 32),

          // Result
          if (_foundUser != null) _userResultCard(_foundUser!),
        ],
      ),
    );
  }

  // ── TAB 2: PHONE CONTACTS ─────────────────────────────────────
  Widget _buildContactsTab() {
    if (_contactsLoading) {
      return const Center(child: CircularProgressIndicator(color: C.brand));
    }

    if (!_contactsGranted && _phoneContacts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: C.brand.withOpacity(.1),
                  border: Border.all(color: C.brand.withOpacity(.3)),
                ),
                child: const Icon(Icons.contacts, color: C.brand, size: 48),
              ),
              const SizedBox(height: 24),
              Text('Import Contacts', style: syne(sz: 20, w: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('Find which of your contacts are on Necxa',
                  style: dm(sz: 13, c: C.dim), textAlign: TextAlign.center),
              const SizedBox(height: 32),
              GestureDetector(
                onTap: _loadPhoneContacts,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  decoration: BoxDecoration(gradient: brandGrad, borderRadius: BorderRadius.circular(16)),
                  child: Text('Allow Access', style: syne(sz: 15, w: FontWeight.w800, c: Colors.black)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final matchPhones = _necxaMatches.map((m) => m['phone'].toString().replaceAll(RegExp(r'\D'), '')).toSet();

    final filteredMatches = _necxaMatches.where((u) {
      final name = (u['full_name'] ?? '').toString().toLowerCase();
      return name.contains(_contactFilter.toLowerCase());
    }).toList();

    final otherContacts = _phoneContacts.where((c) {
      final name = c.displayName.toLowerCase();
      final hasMatch = c.phones.any((p) {
        final digits = p.number.replaceAll(RegExp(r'\D'), '');
        return matchPhones.contains(digits) || 
               matchPhones.contains('256$digits') || 
               matchPhones.contains(digits.startsWith('0') ? digits.substring(1) : digits);
      });
      return !hasMatch && name.contains(_contactFilter.toLowerCase());
    }).toList();

    return Column(
      children: [
        // Filter bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _contactFilter = v),
            style: dm(),
            decoration: InputDecoration(
              hintText: 'Search contacts…',
              hintStyle: dm(c: C.dim),
              filled: true, fillColor: C.card,
              prefixIcon: Icon(Icons.search, color: C.dim, size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              // ── ON NECXA ───────────────────────────────────────────
              if (filteredMatches.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 0, 12),
                  child: Row(children: [
                    Container(width: 4, height: 16, decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 8),
                    Text('AVAILABLE ON NECXA', style: syne(sz: 11, w: FontWeight.w800, c: C.brand, ls: 1.2)),
                  ]),
                ),
                ...filteredMatches.map((u) => _userContactTile(u)),
                const SizedBox(height: 24),
              ],

              // ── OTHER CONTACTS ─────────────────────────────────────
              if (otherContacts.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 0, 12),
                  child: Row(children: [
                    Container(width: 4, height: 16, decoration: BoxDecoration(color: C.dim, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 8),
                    Text('ALL CONTACTS', style: syne(sz: 11, w: FontWeight.w800, c: C.dim, ls: 1.2)),
                  ]),
                ),
                ...otherContacts.map((c) => _phoneContactTile(c)),
              ],

              if (filteredMatches.isEmpty && otherContacts.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(40.0),
                    child: Text('No contacts found matching "$_contactFilter"', style: dm(sz: 14, c: C.dim)),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _phoneContactTile(Contact contact) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: C.card.withOpacity(.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.border.withOpacity(.5)),
      ),
      child: Row(
        children: [
          _avatar(null, contact.displayName, 42),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contact.displayName, style: syne(sz: 14, w: FontWeight.w600)),
                if (contact.phones.isNotEmpty)
                  Text(contact.phones.first.number, style: dm(sz: 11, c: C.dim)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              Share.share('Hey! Join me on Necxa, the ultimate mission control for financial freedom. Download here: https://necxa.app');
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: Text('Invite', style: syne(sz: 12, w: FontWeight.w700, c: Colors.white70)),
            ),
          ),
        ],
      ),
    );
  }

  // ── TAB 3: SAVED CONTACTS ─────────────────────────────────────
  Widget _buildSavedTab() {
    if (_savedLoading) return const Center(child: CircularProgressIndicator(color: C.brand));

    if (_savedContacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_outline, color: C.dim, size: 56),
            const SizedBox(height: 16),
            Text('No saved contacts yet', style: syne(sz: 18, w: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Contacts you chat with will appear here', style: dm(sz: 13, c: C.dim)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadSavedContacts,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _savedContacts.length,
        itemBuilder: (_, i) {
          final item = _savedContacts[i];
          final profile = item['profiles'] as Map<String, dynamic>? ?? {};
          return _userContactTile({
            'id':         profile['id'],
            'full_name':  item['nickname'] ?? profile['full_name'],
            'avatar_url': profile['avatar_url'],
            'is_agent':   profile['is_agent'],
            'trust_score': profile['trust_score'],
          });
        },
      ),
    );
  }

  // ── SHARED WIDGETS ────────────────────────────────────────────

  Widget _userResultCard(Map<String, dynamic> user) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.brand.withOpacity(.2)),
        boxShadow: [BoxShadow(color: C.brand.withOpacity(.06), blurRadius: 20)],
      ),
      child: Row(
        children: [
          _avatar(user['avatar_url'], user['full_name'] ?? '?', 52),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(user['full_name'] ?? 'Unknown', style: syne(sz: 16, w: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(user['email'] ?? '', style: dm(sz: 12, c: C.dim)),
              if (user['is_agent'] == true) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: C.gold.withOpacity(.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: C.gold.withOpacity(.3))),
                  child: Text('Verified Agent', style: dm(sz: 10, c: C.gold, w: FontWeight.w600)),
                ),
              ],
            ]),
          ),
          _chatBtn(user),
        ],
      ),
    );
  }

  Widget _userContactTile(Map<String, dynamic> user) {
    return GestureDetector(
      onTap: () => _openChatWith(user['id'], user['full_name'] ?? 'User', user['avatar_url']),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: C.border),
        ),
        child: Row(
          children: [
            _avatar(user['avatar_url'], user['full_name'] ?? '?', 46),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(user['full_name'] ?? 'Unknown', style: syne(sz: 15, w: FontWeight.w700)),
                if (user['is_agent'] == true)
                  Text('Necxa Agent', style: dm(sz: 11, c: C.gold)),
              ]),
            ),
            _chatBtn(user),
          ],
        ),
      ),
    );
  }

  Widget _chatBtn(Map<String, dynamic> user) => GestureDetector(
    onTap: () => _openChatWith(user['id'], user['full_name'] ?? 'User', user['avatar_url']),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        gradient: brandGrad,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: C.brand.withOpacity(.25), blurRadius: 8)],
      ),
      child: Text('Chat', style: syne(sz: 13, w: FontWeight.w800, c: Colors.black)),
    ),
  );

  Widget _avatar(String? url, String name, double size) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: C.card2,
        border: Border.all(color: C.brand.withOpacity(.2)),
      ),
      child: ClipOval(
        child: url != null
            // CachedNetworkImage: avatar downloaded once, served from disk cache
            ? CachedNetworkImage(
                imageUrl: url,
                width: size, height: size,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Center(
                  child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: syne(sz: size * 0.35, w: FontWeight.w800, c: C.brand)),
                ),
              )
            : Center(child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: syne(sz: size * 0.35, w: FontWeight.w800, c: C.brand))),
      ),
    );
  }
}
