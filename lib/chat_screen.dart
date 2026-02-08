import 'package:flutter/material.dart';
import 'package:nyota_app/widgets/nyota_background.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';

final ScrollController _scrollController = ScrollController();

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final String receiverId;
  final String currentUserId;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.receiverId,
    required this.currentUserId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final supabase = Supabase.instance.client;
  final TextEditingController _controller = TextEditingController();
  late final String currentUserId;
  int _lastMessageCount = 0;
  final List<Map<String, dynamic>> _localMessages = [];

  @override
  void initState() {
    super.initState();
    currentUserId = FirebaseAuth.instance.currentUser!.uid;
    _markMessagesAsRead();
  }

  @override
  void dispose() {
    _setTyping(false);
    super.dispose();
  }

  Future<void> _markMessagesAsRead() async {
    await supabase
        .from('messages')
        .update({
          'is_read': true,
          'read_at': DateTime.now().toIso8601String(),
        })
        .eq('conversation_id', widget.conversationId)
        .neq('sender_id', currentUserId)
        .eq('is_read', false);
  }

  Future<void> _setTyping(bool typing) async {
    await supabase.from('conversations').update({
      'typing_user_id': typing ? currentUserId : null,
    }).eq('id', widget.conversationId);
  }

  Stream<String?> _typingStream() {
    return supabase
        .from('conversations')
        .stream(primaryKey: ['id'])
        .eq('id', widget.conversationId)
        .map((rows) => rows.isEmpty ? null : rows.first['typing_user_id']);
  }

  Stream<List<Map<String, dynamic>>> _messagesStream() {
    return supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', widget.conversationId)
        .order('created_at', ascending: true) // ✅ ORDRE NORMAL
        .map((rows) => List<Map<String, dynamic>>.from(rows));
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final tempMessage = {
      'id': 'local_${DateTime.now().millisecondsSinceEpoch}',
      'conversation_id': widget.conversationId,
      'sender_id': currentUserId,
      'receiver_id': widget.receiverId,
      'content': text,
      'created_at': DateTime.now().toIso8601String(),
      'is_read': false,
      'is_local': true, // 👈 IMPORTANT
    };

    setState(() {
      _localMessages.add(tempMessage);
    });

    _controller.clear();
    _scrollToBottom();

    await supabase.from('messages').insert({
      'conversation_id': widget.conversationId,
      'sender_id': currentUserId,
      'receiver_id': widget.receiverId,
      'content': text,
      'is_read': false,
    });

    await supabase.from('conversations').update({
      'last_message': text,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', widget.conversationId);
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(
        _scrollController.position.maxScrollExtent,
      );
    }
  }

  String _formatTime(String iso) {
    final d = DateTime.parse(iso);
    return "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}";
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final date = DateTime(d.year, d.month, d.day);

    if (date == today) return "Aujourd’hui";
    if (date == yesterday) return "Hier";
    return "${d.day}/${d.month}/${d.year}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent, // 👈 AJOUT
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text(
          "Discussion",
          style: TextStyle(color: Colors.black),
        ),
        iconTheme: const IconThemeData(color: Colors.black),
        elevation: 1,
      ),

      body: NyotaBackground(
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _messagesStream(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(
                      child: CircularProgressIndicator(),
                    );
                  }
                  final messages = [
                    ...snapshot.data!,
                    ..._localMessages,
                  ];

                  DateTime? lastDate;
                  _localMessages.removeWhere((local) => snapshot.data!.any(
                      (server) =>
                          server['content'] == local['content'] &&
                          server['sender_id'] == local['sender_id']));

                  // ✅ ON MARQUE LU MAIS ON NE FORCE PLUS LE SCROLL ICI
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _markMessagesAsRead();

                    // 🔥 Scroll SEULEMENT s'il y a un nouveau message
                    if (messages.length != _lastMessageCount) {
                      _lastMessageCount = messages.length;

                      if (_scrollController.hasClients) {
                        _scrollController.animateTo(
                          _scrollController.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      }
                    }
                  });

                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      final isMe = msg['sender_id'] == currentUserId;
                      final date = DateTime.parse(msg['created_at']);
                      final showDate =
                          lastDate == null || lastDate!.day != date.day;
                      lastDate = date;

                      return Column(
                        children: [
                          if (showDate)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                _formatDate(date),
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12),
                              ),
                            ),
                          Align(
                            alignment: isMe
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              padding: const EdgeInsets.all(12),
                              constraints: const BoxConstraints(maxWidth: 280),
                              decoration: BoxDecoration(
                                color: isMe
                                    ? Colors.deepPurple
                                    : Colors.grey.shade300,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: isMe
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    msg['content'],
                                    style: TextStyle(
                                        color:
                                            isMe ? Colors.white : Colors.black),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _formatTime(msg['created_at']),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: isMe
                                          ? Colors.white70
                                          : Colors.black54,
                                    ),
                                  ),
                                  if (isMe)
                                    Text(
                                      msg['is_read'] == true ? "Vu" : "Envoyé",
                                      style: const TextStyle(
                                          fontSize: 10, color: Colors.white70),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            StreamBuilder<String?>(
              stream: _typingStream(),
              builder: (_, snap) {
                if (snap.data != null && snap.data != currentUserId) {
                  return const Padding(
                    padding: EdgeInsets.only(left: 12, bottom: 4),
                    child: Text(
                      "L’utilisateur est en train d’écrire…",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        onChanged: (v) => _setTyping(v.isNotEmpty),
                        decoration: const InputDecoration(
                          hintText: "Écrire un message",
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: _sendMessage,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
