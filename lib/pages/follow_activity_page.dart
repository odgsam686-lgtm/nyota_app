import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:nyota_app/pages/public_profile_page.dart';
import 'package:nyota_app/widgets/nyota_background.dart';

class FollowActivityPage extends StatefulWidget {
  final String currentUserId;

  const FollowActivityPage({
    super.key,
    required this.currentUserId,
  });

  @override
  State<FollowActivityPage> createState() => _FollowActivityPageState();
}

class _FollowActivityPageState extends State<FollowActivityPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final Set<String> _followingIds = <String>{};
  final Set<String> _busyFollowIds = <String>{};
  final Map<String, Map<String, dynamic>> _profileCache = <String, Map<String, dynamic>>{};

  bool _loadingFollowing = true;
  bool _loadingSuggestions = true;
  List<Map<String, dynamic>> _suggestions = const <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    unawaited(_markFollowNotificationsRead());
    unawaited(_loadFollowingAndSuggestions());
  }

  Future<void> _markFollowNotificationsRead() async {
    try {
      await _supabase
          .from('app_notifications')
          .update({
            'is_read': true,
            'read_at': DateTime.now().toIso8601String(),
          })
          .eq('user_id', widget.currentUserId)
          .eq('kind', 'follow')
          .eq('is_read', false);
    } catch (e) {
      debugPrint('follow activity mark read error: $e');
    }
  }

  Future<void> _loadFollowingAndSuggestions() async {
    await _loadFollowingIds();
    await _loadSuggestions();
  }

  Future<void> _loadFollowingIds() async {
    setState(() => _loadingFollowing = true);
    try {
      final rows = await _supabase
          .from('followers')
          .select('seller_id')
          .eq('follower_id', widget.currentUserId);

      _followingIds
        ..clear()
        ..addAll(rows
            .map((r) => r['seller_id']?.toString() ?? '')
            .where((id) => id.isNotEmpty));
    } catch (e) {
      debugPrint('follow activity load following ids error: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingFollowing = false);
      }
    }
  }

  Future<void> _loadSuggestions() async {
    if (mounted) {
      setState(() => _loadingSuggestions = true);
    }
    try {
      final profiles = await _supabase
          .from('public_profiles')
          .select('user_id, display_name, displayname, username, avatar_url, photo_url')
          .limit(60);

      final filtered = profiles.where((row) {
        final userId = row['user_id']?.toString();
        if (userId == null || userId.isEmpty) return false;
        if (userId == widget.currentUserId) return false;
        if (_followingIds.contains(userId)) return false;
        return true;
      }).take(20).toList();

      for (final row in filtered) {
        final uid = row['user_id']?.toString();
        if (uid == null || uid.isEmpty) continue;
        _profileCache[uid] = _normalizeProfile(row);
      }

      if (mounted) {
        setState(() {
          _suggestions = List<Map<String, dynamic>>.from(filtered);
          _loadingSuggestions = false;
        });
      }
    } catch (e) {
      debugPrint('follow activity suggestions error: $e');
      if (mounted) {
        setState(() {
          _suggestions = const <Map<String, dynamic>>[];
          _loadingSuggestions = false;
        });
      }
    }
  }

  Map<String, dynamic> _normalizeProfile(Map<String, dynamic> row) {
    final displayName = row['display_name'] ?? row['displayname'];
    final username = row['username'];
    final avatar = row['avatar_url'] ?? row['photo_url'];
    return <String, dynamic>{
      'user_id': row['user_id'],
      'name': (displayName?.toString().trim().isNotEmpty == true)
          ? displayName
          : (username?.toString().trim().isNotEmpty == true ? username : 'Utilisateur'),
      'username': username,
      'photo': (avatar?.toString().trim().isNotEmpty == true) ? avatar : null,
    };
  }

  Future<Map<String, dynamic>?> _fetchProfile(String userId) async {
    final cached = _profileCache[userId];
    if (cached != null) return cached;
    try {
      final row = await _supabase
          .from('public_profiles')
          .select('user_id, display_name, displayname, username, avatar_url, photo_url')
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) return null;
      final normalized = _normalizeProfile(row);
      _profileCache[userId] = normalized;
      return normalized;
    } catch (e) {
      debugPrint('follow activity fetch profile error ($userId): $e');
      return null;
    }
  }

  Future<void> _toggleFollow(String targetUserId) async {
    if (targetUserId.isEmpty || _busyFollowIds.contains(targetUserId)) return;
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == null) return;

    final wasFollowing = _followingIds.contains(targetUserId);
    setState(() {
      _busyFollowIds.add(targetUserId);
      if (wasFollowing) {
        _followingIds.remove(targetUserId);
      } else {
        _followingIds.add(targetUserId);
      }
    });

    try {
      if (wasFollowing) {
        await _supabase
            .from('followers')
            .delete()
            .eq('seller_id', targetUserId)
            .eq('follower_id', me);
      } else {
        await _supabase.from('followers').insert({
          'seller_id': targetUserId,
          'follower_id': me,
        });
      }
      await _loadSuggestions();
    } catch (e) {
      debugPrint('follow activity toggle follow error: $e');
      if (!mounted) return;
      setState(() {
        if (wasFollowing) {
          _followingIds.add(targetUserId);
        } else {
          _followingIds.remove(targetUserId);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur follow: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyFollowIds.remove(targetUserId);
        });
      }
    }
  }

  void _openProfile(String userId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PublicProfilePage(sellerId: userId),
      ),
    );
  }

  String _formatAgo(String raw) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inSeconds < 60) return 'À l’instant';
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'Il y a ${diff.inHours} h';
    if (diff.inDays < 7) return 'Il y a ${diff.inDays} j';
    return 'Il y a ${(diff.inDays / 7).floor()} sem';
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 15,
          color: Colors.black87,
        ),
      ),
    );
  }

  Widget _followButton(String targetUserId) {
    final isFollowing = _followingIds.contains(targetUserId);
    final busy = _busyFollowIds.contains(targetUserId);

    return SizedBox(
      height: 34,
      child: ElevatedButton(
        onPressed: busy ? null : () => _toggleFollow(targetUserId),
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: isFollowing ? Colors.grey.shade200 : Colors.black,
          foregroundColor: isFollowing ? Colors.black : Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(
          busy ? '...' : (isFollowing ? 'Abonné' : 'Suivre'),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _userRow({
    required String userId,
    required String title,
    String? subtitle,
    String? avatarUrl,
    bool showFollowButton = true,
  }) {
    return ListTile(
      dense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: GestureDetector(
        onTap: () => _openProfile(userId),
        child: CircleAvatar(
          radius: 22,
          backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
          child: avatarUrl == null ? const Icon(Icons.person) : null,
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle == null || subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: showFollowButton ? _followButton(userId) : null,
      onTap: () => _openProfile(userId),
    );
  }

  Widget _buildNewFollowsSection() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _supabase
          .from('app_notifications')
          .stream(primaryKey: ['id'])
          .eq('user_id', widget.currentUserId)
          .order('created_at', ascending: false),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Erreur notifications: ${snapshot.error}',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          );
        }
        final rows = (snapshot.data ?? const <Map<String, dynamic>>[])
            .where((r) => r['kind']?.toString() == 'follow')
            .toList();
        if (rows.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Aucun nouveau suivi pour le moment',
              style: TextStyle(color: Colors.black54),
            ),
          );
        }

        final visible = rows.take(15).toList();
        return Column(
          children: visible.map((row) {
            final actorId = row['actor_id']?.toString() ?? '';
            final createdAt = row['created_at']?.toString();
            return FutureBuilder<Map<String, dynamic>?>(
              future: _fetchProfile(actorId),
              builder: (context, snap) {
                final profile = snap.data;
                final title = profile?['name']?.toString() ?? 'Utilisateur';
                final avatar = profile?['photo']?.toString();
                final subtitle = createdAt != null && createdAt.isNotEmpty
                    ? 'Nouveau suivi • ${_formatAgo(createdAt)}'
                    : 'Nouveau suivi';
                return _userRow(
                  userId: actorId,
                  title: title,
                  subtitle: subtitle,
                  avatarUrl: (avatar != null && avatar.isNotEmpty) ? avatar : null,
                  showFollowButton: actorId.isNotEmpty,
                );
              },
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildFollowersSection() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _supabase
          .from('followers')
          .stream(primaryKey: ['seller_id', 'follower_id'])
          .eq('seller_id', widget.currentUserId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Erreur abonnés: ${snapshot.error}',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          );
        }
        final rows = snapshot.data ?? const <Map<String, dynamic>>[];
        if (rows.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Aucun abonné pour le moment',
              style: TextStyle(color: Colors.black54),
            ),
          );
        }
        final followerIds = rows
            .map((e) => e['follower_id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toList();
        final uniqueIds = followerIds.toSet().toList();
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: _fetchProfilesByIds(uniqueIds),
          builder: (context, snap) {
            final profiles = snap.data ?? const <Map<String, dynamic>>[];
            if (profiles.isEmpty && snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            final byId = <String, Map<String, dynamic>>{
              for (final p in profiles) (p['user_id']?.toString() ?? ''): p,
            };
            return Column(
              children: uniqueIds.map((uid) {
                final profile = byId[uid];
                final title = profile?['name']?.toString() ?? uid;
                final avatar = profile?['photo']?.toString();
                return _userRow(
                  userId: uid,
                  title: title,
                  subtitle: 'Abonné',
                  avatarUrl: (avatar != null && avatar.isNotEmpty) ? avatar : null,
                  showFollowButton: true,
                );
              }).toList(),
            );
          },
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _fetchProfilesByIds(List<String> ids) async {
    if (ids.isEmpty) return const <Map<String, dynamic>>[];
    final missing = ids.where((id) => !_profileCache.containsKey(id)).toList();
    if (missing.isNotEmpty) {
      try {
        final rows = await _supabase
            .from('public_profiles')
            .select('user_id, display_name, displayname, username, avatar_url, photo_url')
            .inFilter('user_id', missing);
        for (final row in rows) {
          final uid = row['user_id']?.toString();
          if (uid == null || uid.isEmpty) continue;
          _profileCache[uid] = _normalizeProfile(row);
        }
      } catch (e) {
        debugPrint('follow activity batch profile error: $e');
      }
    }
    return ids.map((id) => _profileCache[id]).whereType<Map<String, dynamic>>().toList();
  }

  Widget _buildSuggestionsSection() {
    if (_loadingFollowing || _loadingSuggestions) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_suggestions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          'Aucune suggestion pour le moment',
          style: TextStyle(color: Colors.black54),
        ),
      );
    }
    return Column(
      children: _suggestions.map((row) {
        final uid = row['user_id']?.toString() ?? '';
        final profile = _profileCache[uid] ?? _normalizeProfile(row);
        final title = profile['name']?.toString() ?? 'Utilisateur';
        final username = profile['username']?.toString();
        final avatar = profile['photo']?.toString();
        return _userRow(
          userId: uid,
          title: title,
          subtitle: (username != null && username.isNotEmpty && username != title)
              ? '@$username'
              : 'Suggestion',
          avatarUrl: (avatar != null && avatar.isNotEmpty) ? avatar : null,
          showFollowButton: true,
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black),
        title: const Text(
          'Suivis & suggestions',
          style: TextStyle(color: Colors.black),
        ),
        elevation: 1,
      ),
      body: NyotaBackground(
        child: RefreshIndicator(
          onRefresh: _loadFollowingAndSuggestions,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _sectionTitle('Nouveaux suivis'),
              _buildNewFollowsSection(),
              _sectionTitle('Abonnés'),
              _buildFollowersSection(),
              _sectionTitle('Suggestions de suivis'),
              _buildSuggestionsSection(),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
