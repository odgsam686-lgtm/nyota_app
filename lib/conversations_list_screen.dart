import 'package:flutter/material.dart';
import 'package:nyota_app/widgets/nyota_background.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_screen.dart';
import 'package:nyota_app/pages/public_profile_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConversationsListScreen extends StatefulWidget {
  final String currentUserId;
  static final Map<String, Map<String, dynamic>> _profileCache = {};

  const ConversationsListScreen({
    super.key,
    required this.currentUserId,
  });

  @override
  State<ConversationsListScreen> createState() => _ConversationsListScreenState();
}

class _ConversationsListScreenState extends State<ConversationsListScreen> {
  final Map<String, int> _localUnreadOverride = {};
  final Map<String, DateTime> _clearedAt = {};

  /// 🔹 Récupérer display_name/username/avatar_url depuis public_profiles
  Future<Map<String, dynamic>?> fetchUserProfile(String userId) async {
    if (ConversationsListScreen._profileCache.containsKey(userId)) {
      return ConversationsListScreen._profileCache[userId];
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
          ConversationsListScreen._profileCache[userId] = normalized;
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
      ConversationsListScreen._profileCache[userId] = normalized;
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
              .from('conversations_with_unread')
              .stream(primaryKey: ['id', 'user_id'])
              .eq('user_id', widget.currentUserId)
              .order('updated_at', ascending: false)
              .map((rows) {
                final all = List<Map<String, dynamic>>.from(rows);
                return all
                    .where((c) =>
                        c['user_a'] == widget.currentUserId ||
                        c['user_b'] == widget.currentUserId)
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

                final otherUserId = convo['user_a'] == widget.currentUserId
                    ? convo['user_b']
                    : convo['user_a'];

                final int unreadCount = (convo['unread_count'] is int)
                    ? convo['unread_count']
                    : int.tryParse(convo['unread_count']?.toString() ?? '0') ?? 0;
                final convoId = convo['id']?.toString() ?? '';
                final override = _localUnreadOverride[convoId];
                int effectiveUnread = override ?? unreadCount;
                final clearedAt = _clearedAt[convoId];
                DateTime? updatedAt;
                try {
                  final raw = convo['updated_at']?.toString();
                  if (raw != null) updatedAt = DateTime.parse(raw);
                } catch (_) {}
                if (override != null &&
                    clearedAt != null &&
                    updatedAt != null &&
                    updatedAt.isAfter(clearedAt)) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    setState(() {
                      _localUnreadOverride.remove(convoId);
                      _clearedAt.remove(convoId);
                    });
                  });
                  effectiveUnread = unreadCount;
                }
                final bool hasUnread = effectiveUnread > 0;

                return FutureBuilder<Map<String, dynamic>?>(
                  future: fetchUserProfile(otherUserId),
                  builder: (context, snap) {
                    final profile = snap.data;
                    final username = _getDisplayName(profile);
                    final avatarUrl = _getAvatarUrl(profile);

                    return FutureBuilder<String?>(
                      future: _getDraftText(convo['id'], widget.currentUserId),
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
                          trailing: hasUnread
                              ? Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: const BoxDecoration(
                                    color: Colors.green,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    effectiveUnread > 99
                                        ? '99+'
                                        : effectiveUnread.toString(),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                )
                              : null,
                          onTap: () {
                            if (convoId.isNotEmpty) {
                              setState(() {
                                _localUnreadOverride[convoId] = 0;
                                _clearedAt[convoId] = DateTime.now();
                              });
                            }
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(
                                  conversationId: convo['id'],
                                  receiverId: otherUserId,
                                  currentUserId: widget.currentUserId,
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
