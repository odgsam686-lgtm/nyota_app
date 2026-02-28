import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:nyota_app/pages/public_profile_page.dart';
import 'package:nyota_app/widgets/nyota_background.dart';

enum _NotifFilter {
  all,
  unread,
  follows,
  interactions,
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final Map<String, Map<String, dynamic>> _profileCache = <String, Map<String, dynamic>>{};
  _NotifFilter _filter = _NotifFilter.all;
  bool _markAllBusy = false;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    unawaited(_markAllReadOnOpen());
  }

  Stream<List<Map<String, dynamic>>> _notificationsStream() {
    final uid = _uid;
    if (uid == null) return const Stream<List<Map<String, dynamic>>>.empty();
    return _supabase
        .from('app_notifications')
        .stream(primaryKey: ['id'])
        .eq('user_id', uid)
        .order('created_at', ascending: false);
  }

  Future<void> _markAllReadOnOpen() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _supabase
          .from('app_notifications')
          .update({
            'is_read': true,
            'read_at': DateTime.now().toIso8601String(),
          })
          .eq('user_id', uid)
          .eq('is_read', false);
    } catch (e) {
      debugPrint('notifications auto mark read error: $e');
    }
  }

  bool _matchesFilter(Map<String, dynamic> row) {
    final kind = row['kind']?.toString() ?? '';
    final isRead = row['is_read'] == true;
    switch (_filter) {
      case _NotifFilter.all:
        return true;
      case _NotifFilter.unread:
        return !isRead;
      case _NotifFilter.follows:
        return kind == 'follow';
      case _NotifFilter.interactions:
        return kind != 'follow';
    }
  }

  Future<Map<String, dynamic>?> _fetchProfile(String? userId) async {
    if (userId == null || userId.isEmpty) return null;
    final cached = _profileCache[userId];
    if (cached != null) return cached;
    try {
      final row = await _supabase
          .from('public_profiles')
          .select('user_id, display_name, displayname, username, avatar_url, photo_url')
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) return null;
      final displayName = row['display_name'] ?? row['displayname'];
      final username = row['username'];
      final avatar = row['avatar_url'] ?? row['photo_url'];
      final normalized = <String, dynamic>{
        'user_id': row['user_id'],
        'name': (displayName?.toString().trim().isNotEmpty == true)
            ? displayName
            : (username?.toString().trim().isNotEmpty == true ? username : 'Utilisateur'),
        'photo': (avatar?.toString().trim().isNotEmpty == true) ? avatar : null,
      };
      _profileCache[userId] = normalized;
      return normalized;
    } catch (e) {
      debugPrint('notifications profile error: $e');
      return null;
    }
  }

  String _formatAgo(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final dt = DateTime.tryParse(raw);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inSeconds < 60) return 'À l’instant';
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'Il y a ${diff.inHours} h';
    if (diff.inDays < 7) return 'Il y a ${diff.inDays} j';
    return 'Il y a ${(diff.inDays / 7).floor()} sem';
  }

  String _notifText(Map<String, dynamic> row, String actorName) {
    final kind = row['kind']?.toString() ?? '';
    switch (kind) {
      case 'follow':
        return '$actorName a commencé à vous suivre';
      case 'post_like':
        return '$actorName a aimé votre publication';
      case 'post_comment':
        return '$actorName a commenté votre publication';
      case 'comment_reply':
        return '$actorName a répondu à votre commentaire';
      case 'comment_like':
        return '$actorName a aimé votre commentaire';
      default:
        return '$actorName a interagi avec vous';
    }
  }

  IconData _notifIcon(Map<String, dynamic> row) {
    switch (row['kind']?.toString()) {
      case 'follow':
        return Icons.person_add_alt_1;
      case 'post_like':
      case 'comment_like':
        return Icons.favorite;
      case 'post_comment':
      case 'comment_reply':
        return Icons.mode_comment_outlined;
      default:
        return Icons.notifications_none;
    }
  }

  Color _notifIconColor(Map<String, dynamic> row) {
    switch (row['kind']?.toString()) {
      case 'follow':
        return Colors.blueAccent;
      case 'post_like':
      case 'comment_like':
        return Colors.redAccent;
      case 'post_comment':
      case 'comment_reply':
        return Colors.deepPurple;
      default:
        return Colors.black54;
    }
  }

  Future<void> _markRead(String notificationId) async {
    if (notificationId.isEmpty) return;
    try {
      await _supabase.from('app_notifications').update({
        'is_read': true,
        'read_at': DateTime.now().toIso8601String(),
      }).eq('id', notificationId);
    } catch (e) {
      debugPrint('notifications mark read error: $e');
    }
  }

  Future<void> _markAllRead() async {
    final uid = _uid;
    if (uid == null || _markAllBusy) return;
    setState(() => _markAllBusy = true);
    try {
      await _supabase
          .from('app_notifications')
          .update({
            'is_read': true,
            'read_at': DateTime.now().toIso8601String(),
          })
          .eq('user_id', uid)
          .eq('is_read', false);
    } catch (e) {
      debugPrint('notifications mark all read error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _markAllBusy = false);
    }
  }

  void _openNotification(Map<String, dynamic> row) {
    final id = row['id']?.toString() ?? '';
    unawaited(_markRead(id));

    final kind = row['kind']?.toString();
    final postId = row['post_id']?.toString();
    final actorId = row['actor_id']?.toString();

    if (postId != null &&
        postId.isNotEmpty &&
        (kind == 'post_like' ||
            kind == 'post_comment' ||
            kind == 'comment_reply' ||
            kind == 'comment_like')) {
      Navigator.of(context).pushNamed('/comments', arguments: postId);
      return;
    }

    if (actorId != null && actorId.isNotEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PublicProfilePage(sellerId: actorId),
        ),
      );
    }
  }

  Widget _filterChip(String label, _NotifFilter value) {
    final selected = _filter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _filter = value),
      selectedColor: Colors.black,
      labelStyle: TextStyle(
        color: selected ? Colors.white : Colors.black87,
        fontWeight: FontWeight.w600,
      ),
      backgroundColor: Colors.grey.shade200,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) {
      return const Scaffold(
        body: Center(child: Text('Utilisateur non connecté')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black),
        title: const Text(
          'Notifications',
          style: TextStyle(color: Colors.black),
        ),
        actions: [
          TextButton(
            onPressed: _markAllBusy ? null : _markAllRead,
            child: Text(_markAllBusy ? '...' : 'Tout lire'),
          ),
        ],
        elevation: 1,
      ),
      body: NyotaBackground(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip('Tout', _NotifFilter.all),
                    const SizedBox(width: 8),
                    _filterChip('Non lus', _NotifFilter.unread),
                    const SizedBox(width: 8),
                    _filterChip('Suivis', _NotifFilter.follows),
                    const SizedBox(width: 8),
                    _filterChip('Interactions', _NotifFilter.interactions),
                  ],
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _notificationsStream(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('Erreur notifications: ${snapshot.error}'));
                  }

                  final rows = (snapshot.data ?? const <Map<String, dynamic>>[])
                      .where(_matchesFilter)
                      .toList();
                  if (rows.isEmpty) {
                    return const Center(
                      child: Text(
                        'Aucune notification',
                        style: TextStyle(color: Colors.black54),
                      ),
                    );
                  }

                  return ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final actorId = row['actor_id']?.toString();
                      final notificationId = row['id']?.toString() ?? '';
                      final isRead = row['is_read'] == true;
                      final createdAt = row['created_at']?.toString();

                      return FutureBuilder<Map<String, dynamic>?>(
                        future: _fetchProfile(actorId),
                        builder: (context, profileSnap) {
                          final profile = profileSnap.data;
                          final actorName = profile?['name']?.toString() ?? 'Utilisateur';
                          final avatarUrl = profile?['photo']?.toString();
                          final subtitle = _formatAgo(createdAt);

                          return ListTile(
                            tileColor: isRead ? null : Colors.blue.withOpacity(0.04),
                            leading: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                CircleAvatar(
                                  backgroundImage: (avatarUrl != null && avatarUrl.isNotEmpty)
                                      ? NetworkImage(avatarUrl)
                                      : null,
                                  child: (avatarUrl == null || avatarUrl.isEmpty)
                                      ? const Icon(Icons.person)
                                      : null,
                                ),
                                Positioned(
                                  right: -2,
                                  bottom: -2,
                                  child: Container(
                                    width: 16,
                                    height: 16,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 1.5),
                                    ),
                                    child: Icon(
                                      _notifIcon(row),
                                      size: 12,
                                      color: _notifIconColor(row),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            title: Text(
                              _notifText(row, actorName),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isRead ? FontWeight.w400 : FontWeight.w600,
                              ),
                            ),
                            subtitle: subtitle.isEmpty ? null : Text(subtitle),
                            trailing: !isRead
                                ? Container(
                                    width: 8,
                                    height: 8,
                                    decoration: const BoxDecoration(
                                      color: Colors.blueAccent,
                                      shape: BoxShape.circle,
                                    ),
                                  )
                                : null,
                            onTap: () => _openNotification(row),
                            onLongPress: () => _markRead(notificationId),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
