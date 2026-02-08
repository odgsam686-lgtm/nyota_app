import 'package:flutter/material.dart';
import 'package:nyota_app/widgets/nyota_background.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_screen.dart';
import 'package:nyota_app/pages/public_profile_page.dart';

class ConversationsListScreen extends StatelessWidget {
  final String currentUserId;

  const ConversationsListScreen({
    super.key,
    required this.currentUserId,
  });

  /// 🔹 Récupérer username + avatar depuis le profil public
  Future<Map<String, dynamic>?> fetchUserProfile(String userId) async {
    try {
      final res = await Supabase.instance.client
          .from('public_profiles')
          .select('username, avatar_url')
          .eq('user_id', userId)
          .single();

      return res;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final supabase = Supabase.instance.client;

    return Scaffold(
      backgroundColor: Colors.transparent, // 👈 AJOUTE ÇA
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text(
          'Messages',
          style: TextStyle(color: Colors.black),
        ),
        iconTheme: const IconThemeData(color: Colors.black),
        elevation: 1,
      ),

      body: NyotaBackground(
        child: StreamBuilder<List<Map<String, dynamic>>>(
          stream: supabase
              .from('conversations')
              .stream(primaryKey: ['id'])
              .order('updated_at', ascending: false)
              .map((rows) {
                final all = List<Map<String, dynamic>>.from(rows);
                return all
                    .where((c) =>
                        c['user_a'] == currentUserId ||
                        c['user_b'] == currentUserId)
                    .toList();
              }),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final conversations = snapshot.data!;

            if (conversations.isEmpty) {
              return const Center(
                child: Text(
                  "Aucune conversation",
                  style: TextStyle(color: Colors.black),
                ),
              );
            }
            return ListView.builder(
              itemCount: conversations.length,
              itemBuilder: (context, index) {
                final convo = conversations[index];

                final otherUserId = convo['user_a'] == currentUserId
                    ? convo['user_b']
                    : convo['user_a'];

                final bool hasUnread = (convo['unread_count'] ?? 0) > 0;

                return FutureBuilder<Map<String, dynamic>?>(
                  future: fetchUserProfile(otherUserId),
                  builder: (context, snap) {
                    final profile = snap.data;
                    final username = profile?['username'] ?? 'Utilisateur';
                    final avatarUrl = profile?['avatar_url'];

                    return ListTile(
                      leading: Stack(
                        children: [
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => PublicProfilePage(
                                    sellerId:
                                        otherUserId, // ✅ identité correcte
                                  ),
                                ),
                              );
                            },
                            child: CircleAvatar(
                              backgroundImage:
                                  avatarUrl != null && avatarUrl.isNotEmpty
                                      ? NetworkImage(avatarUrl)
                                      : null,
                              child: avatarUrl == null || avatarUrl.isEmpty
                                  ? const Icon(Icons.person)
                                  : null,
                            ),
                          ),
                          if (hasUnread)
                            Positioned(
                              right: 0,
                              top: 0,
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: const BoxDecoration(
                                  color: Colors.blue,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                        ],
                      ),
                      title: Text(
                        username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        convo['last_message'] ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(
                              conversationId: convo['id'],
                              receiverId: otherUserId,
                              currentUserId: currentUserId,
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}
