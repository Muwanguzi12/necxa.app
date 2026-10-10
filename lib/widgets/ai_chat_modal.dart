import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import 'dart:ui';

class AiChatModal extends StatefulWidget {
  final AppState state;
  const AiChatModal({super.key, required this.state});

  @override
  State<AiChatModal> createState() => _AiChatModalState();
}

class _AiChatModalState extends State<AiChatModal> {
  final TextEditingController _msgCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  String _selectedLang = 'English';
  final List<String> _languages = ['English', 'Swahili', 'Luganda', 'French', 'Arabic', 'Somali', 'Amharic'];

  void _send() {
    if (_msgCtrl.text.trim().isEmpty) return;
    widget.state.askNecxa(_msgCtrl.text.trim(), language: _selectedLang);
    _msgCtrl.clear();
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent, 
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: C.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
        border: Border(top: BorderSide(color: C.dim)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Column(
            children: [
              _buildHeader(),
              Expanded(child: _buildChatList()),
              _buildInputArea(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.dim))),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.blue.withAlpha(26), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.auto_awesome, color: Colors.blue, size: 20),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('NECXA AI ASSISTANT', style: syne(sz: 14, w: FontWeight.w800, ls: 2, c: C.text)),
              Text('Powered by Multilingual Linguistic Engine', style: dm(sz: 10, c: C.dim)),
            ],
          ),
          const Spacer(),
          IconButton(icon: Icon(Icons.close, color: C.dim), onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
  }

  Widget _buildChatList() {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final logs = widget.state.chatLog;
        if (logs.isEmpty) return _buildIntro();

        return ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(24),
          itemCount: logs.length + (widget.state.isAiThinking ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == logs.length) return _buildThinking();
            final msg = logs[i];
            final isUser = msg.senderId != 'necxa-ai';
            return _ChatBubble(text: msg.text, isUser: isUser);
          },
        );
      }
    );
  }

  Widget _buildIntro() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, color: Colors.blue.withAlpha(51), size: 64),
          const SizedBox(height: 24),
          Text('HOW CAN I ASSIST YOU?', style: syne(sz: 12, w: FontWeight.w800, ls: 4, c: C.dim)),
          const SizedBox(height: 8),
          Text('Verification � Listings � Market Insights', style: dm(sz: 10, c: C.dim)),
          const SizedBox(height: 24),
          // Language Selector
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: C.text.withAlpha(13),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: C.dim),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedLang,
                icon: Icon(Icons.arrow_drop_down, color: C.dim),
                dropdownColor: C.bg,
                style: dm(sz: 12, c: C.sub),
                onChanged: (String? newValue) {
                  if (newValue != null) {
                    setState(() {
                      _selectedLang = newValue;
                    });
                  }
                },
                items: _languages.map<DropdownMenuItem<String>>((String value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThinking() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.blue, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text('Necxa is thinking...', style: dm(sz: 12, c: C.dim, fs: FontStyle.italic)),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      decoration: BoxDecoration(color: Colors.black, border: Border(top: BorderSide(color: C.dim))),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: C.text.withAlpha(13), borderRadius: BorderRadius.circular(16)),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _msgCtrl,
                style: dm(sz: 14),
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(hintText: 'Type your message...', hintStyle: dm(sz: 14, c: C.dim), border: InputBorder.none),
              ),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: _send,
            child: Container(padding: EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.blue, shape: BoxShape.circle), child: Icon(Icons.send_rounded, color: C.text, size: 20)),
          ),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final String text;
  final bool isUser;
  const _ChatBubble({required this.text, required this.isUser});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 24),
        padding: const EdgeInsets.all(16),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: isUser ? Colors.blue.withAlpha(26) : C.text.withAlpha(13),
          borderRadius: BorderRadius.circular(18).copyWith(
            bottomRight: isUser ? const Radius.circular(0) : null,
            bottomLeft: !isUser ? const Radius.circular(0) : null,
          ),
          border: Border.all(color: isUser ? Colors.blue.withAlpha(51) : C.text.withAlpha(13)),
        ),
        child: Text(text, style: dm(sz: 14, h: 1.5, c: isUser ? C.text : C.sub)),
      ),
    );
  }
}


