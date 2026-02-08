import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'chat_page.dart';

class ConversationsPage extends StatefulWidget {
  const ConversationsPage({super.key});

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> {
  final supabase = Supabase.instance.client;
  late final String currentUserId;

  @override
  void initState() {
    super.initState();
    currentUserId = FirebaseAuth.instance.currentUser!.uid;
  }

  /// 🔵 STREAM DES CONVERSATIONS (Realtime)
  Stream<List<Map<String, dynamic>>> _conversationsStream() {
    return supabase
        .from('conversations')
        .select()
        .or('user_a.eq.$currentUserId,user_b.eq.$currentUserId')
        .order('updated_at', ascending: false)
        .asStream();
  }

  String _getOtherUser(Map<String, dynamic> convo) {
    return convo['user_a'] == currentUserId ? convo['user_b'] : convo['user_a'];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Messages"),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _conversationsStream(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final conversations = snapshot.data!;

          if (conversations.isEmpty) {
            return const Center(
              child: Text("Aucune conversation"),
            );
          }

          return ListView.builder(
            itemCount: conversations.length,
            itemBuilder: (context, index) {
              final convo = conversations[index];
              final otherUserId = _getOtherUser(convo);

              return ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.person),
                ),
                title: Text(
                  "Utilisateur",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  convo['last_message'] ?? "Aucun message",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatPage(
                        conversationId: convo['id'],
                        otherUserId: otherUserId,
                        otherUsername: convo['other_username'] ?? 'Utilisateur',
                        otherAvatar: convo['other_avatar'],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
