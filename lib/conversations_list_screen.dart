import 'package:flutter/material.dart';
import 'package:nyota_app/widgets/nyota_background.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_screen.dart';
import 'package:nyota_app/pages/public_profile_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConversationsListScreen extends StatelessWidget {
  final String currentUserId;
  static final Map<String, Map<String, dynamic>> _profileCache = {};

  const ConversationsListScreen({
    super.key,
    required this.currentUserId,
  });

  /// 🔹 Récupérer display_name/username/avatar_url depuis public_profiles
  Future<Map<String, dynamic>?> fetchUserProfile(String userId) async {
    if (_profileCache.containsKey(userId)) {
      return _profileCache[userId];
    }
    try {
      final publicProfile = await Supabase.instance.client
          .from('public_profiles')
          .select()
          .eq('user_id', userId)
          .maybeSingle();

      if (publicProfile == null) {
        debugPrint("PROFILE NULL for user=$userId");
        final fallback = await Supabase.instance.client
            .from('users')
            .select('display_name, username, photo_url')
            .eq('firebase_uid', userId)
            .maybeSingle();
        if (fallback != null) {
          final normalized = {
            'name': (fallback['display_name']?.toString().trim().isNotEmpty ==
                    true)
                ? fallback['display_name']
                : (fallback['username']?.toString().trim().isNotEmpty == true)
                    ? fallback['username']
                    : 'Utilisateur',
            'photo': (fallback['photo_url']?.toString().trim().isNotEmpty ==
                    true)
                ? fallback['photo_url']
                : null,
          };
          _profileCache[userId] = normalized;
          return normalized;
        }
        return null;
      }

      final displayName = publicProfile['display_name'] ??
          publicProfile['displayname'];
      final username = publicProfile['username'];
      final avatarUrl = publicProfile['avatar_url'] ??
          publicProfile['photo_url'];

      final normalized = {
        'name': (displayName?.toString().trim().isNotEmpty == true)
            ? displayName
            : (username?.toString().trim().isNotEmpty == true)
                ? username
                : 'Utilisateur',
        'photo': (avatarUrl?.toString().trim().isNotEmpty == true)
            ? avatarUrl
            : null,
      };
      _profileCache[userId] = normalized;
      return normalized;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _getDraftText(String conversationId, String userId) async {
    final key = "chat_draft_${conversationId}_$userId";
    final prefs = await SharedPreferences.getInstance();
    final draft = prefs.getString(key);
    return draft;
  }

  String _getDisplayName(Map<String, dynamic>? profile) {
    final name = profile?['name']?.toString().trim();
    if (name != null && name.isNotEmpty) return name;
    return 'Utilisateur';
  }

  String? _getAvatarUrl(Map<String, dynamic>? profile) {
    final url = profile?['photo']?.toString().trim();
    if (url != null && url.isNotEmpty) return url;
    return null;
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
                    final username = _getDisplayName(profile);
                    final avatarUrl = _getAvatarUrl(profile);

                    return FutureBuilder<String?>(
                      future: _getDraftText(convo['id'], currentUserId),
                      builder: (context, draftSnap) {
                        final draft = draftSnap.data?.trim();
                        final hasDraft = draft != null && draft.isNotEmpty;
                        final subtitleText =
                            hasDraft ? "Brouillon : $draft" : (convo['last_message'] ?? '');

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
                            subtitleText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: hasDraft
                                ? const TextStyle(color: Colors.redAccent)
                                : null,
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(
                                  conversationId: convo['id'],
                                  receiverId: otherUserId,
                                  currentUserId: currentUserId,
                                  initialDisplayName: username,
                                  initialPhotoUrl: avatarUrl,
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
            );
          },
        ),
      ),
    );
  }
}
