import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nyota_app/chat_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/storage_url.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'media_viewer_page.dart';
import '../models/post_model.dart';
import '../services/profile_stats_service.dart';

class PublicProfilePage extends StatefulWidget {
  final String sellerId; // Firebase UID

  const PublicProfilePage({super.key, required this.sellerId});

  @override
  State<PublicProfilePage> createState() => _PublicProfilePageState();
}

class _PublicProfilePageState extends State<PublicProfilePage> {
  Map<String, dynamic>? sellerData;
  List<dynamic> posts = [];

  bool loading = true;
  bool isFollowing = false;
  bool isSeller = false;
  int followersCount = 0;
  int creatorViews = 0;
  int creatorLikes = 0;

  final supabase = Supabase.instance.client;
  int followingCount = 0;

  RealtimeChannel? followersChannel;
  RealtimeChannel? postViewsChannel;
  Timer? _postViewsRefreshDebounce;
  Stream<List<Map<String, dynamic>>> messagesStream(String conversationId) {
    final supabase = Supabase.instance.client;

    return supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true) // 👈 HAUT → BAS
        .map((rows) => List<Map<String, dynamic>>.from(rows));
  }

  @override
  void initState() {
    super.initState();
    loadProfile();
    initRealtimeFollowers();
    initRealtimePostViews();
  }

  @override
  void dispose() {
    _postViewsRefreshDebounce?.cancel();
    if (followersChannel != null) {
      supabase.removeChannel(followersChannel!);
    }
    if (postViewsChannel != null) {
      supabase.removeChannel(postViewsChannel!);
    }
    super.dispose();
  }

  Future<void> loadProfile() async {
    try {
      /// =========================
      /// ⚡ 1. PROFIL (RAPIDE)
      /// =========================
      final profile = await supabase
          .from('public_profiles')
          .select()
          .eq('user_id', widget.sellerId)
          .maybeSingle();

      sellerData = profile ??
          {
            'username': 'Utilisateur',
            'avatar_url': null,
            'bio': '',
            'is_seller': false,
          };

      isSeller = sellerData!['is_seller'] == true;

      /// 👉 ON AFFICHE LE PROFIL TOUT DE SUITE
      setState(() {
        loading = false;
      });

      /// =========================
      /// 🔄 2. POSTS (BACKGROUND)
      /// =========================
      final postsRes = await supabase
          .from('posts')
          .select()
          .eq('seller_id', widget.sellerId)
          .order('timestamp', ascending: false);

      final postIds = postsRes
          .map((p) => (p['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();
      final viewCounts = <String, int>{};
      if (postIds.isNotEmpty) {
        final views = await supabase
            .from('post_views')
            .select('post_id')
            .inFilter('post_id', postIds);
        for (final v in views) {
          final pid = (v['post_id'] ?? '').toString();
          if (pid.isEmpty) continue;
          viewCounts[pid] = (viewCounts[pid] ?? 0) + 1;
        }
      }

      final postsWithViews = postsRes.map((p) {
        final row = Map<String, dynamic>.from(p);
        final pid = (row['id'] ?? '').toString();
        row['views_count'] = viewCounts[pid] ?? 0;
        return row;
      }).toList();

      setState(() {
        posts = postsWithViews;
      });

      /// =========================
      /// 🔄 3. FOLLOW CHECK
      /// =========================
      final current = FirebaseAuth.instance.currentUser;
      if (current != null && isSeller) {
        final followCheck = await supabase
            .from('followers')
            .select('id')
            .eq('seller_id', widget.sellerId)
            .eq('follower_id', current.uid)
            .limit(1);

        setState(() {
          isFollowing = followCheck.isNotEmpty;
        });
      }

      /// =========================
      /// 🔄 4. STATS
      /// =========================
      final stats = await ProfileStatsService.loadStats(widget.sellerId);

      setState(() {
        followersCount = stats.followers;
        followingCount = stats.following;
        creatorViews = stats.views;
        creatorLikes = stats.likes;
      });
    } catch (e) {
      debugPrint("PROFILE LOAD ERROR: $e");
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> toggleFollow() async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null || !isSeller) return;

    try {
      final firebaseUid = FirebaseAuth.instance.currentUser!.uid;
      debugPrint("🔥 FIREBASE UID UTILISÉ = [$firebaseUid]");

      if (isFollowing) {
        await supabase
            .from('followers')
            .delete()
            .eq('seller_id', widget.sellerId)
            .eq('follower_id', current.uid);

        setState(() {
          isFollowing = false;
          followersCount--;
        });
      } else {
        await supabase.from('followers').insert({
          'seller_id': widget.sellerId,
          'follower_id': current.uid,
        });

        setState(() {
          isFollowing = true;
          followersCount++;
        });
      }
    } catch (e) {
      debugPrint("FOLLOW ERROR: $e");
    }
    await refreshCounters();
  }

  void initRealtimeFollowers() {
    followersChannel = supabase.channel('followers-${widget.sellerId}');

    followersChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'followers',
          callback: (_) {
            refreshCounters();
          },
        )
        .subscribe();
  }

  void initRealtimePostViews() {
    postViewsChannel = supabase.channel('post-views-${widget.sellerId}');
    postViewsChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'post_views',
          callback: (payload) {
            final postId = (payload.newRecord['post_id'] ??
                    payload.oldRecord['post_id'] ??
                    '')
                .toString();
            if (postId.isEmpty) return;
            final hasInGrid = posts.any(
              (p) => (p['id'] ?? '').toString() == postId,
            );
            if (!hasInGrid) return;
            _scheduleRefreshPostViews();
          },
        )
        .subscribe();
  }

  void _scheduleRefreshPostViews() {
    _postViewsRefreshDebounce?.cancel();
    _postViewsRefreshDebounce = Timer(
      const Duration(milliseconds: 220),
      _refreshPostViewsCounts,
    );
  }

  Future<void> _refreshPostViewsCounts() async {
    if (!mounted || posts.isEmpty) return;
    final ids = posts
        .map((p) => (p['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return;
    try {
      final rows = await supabase
          .from('post_views')
          .select('post_id')
          .inFilter('post_id', ids);
      if (!mounted) return;
      final counts = <String, int>{};
      for (final row in rows) {
        final pid = (row['post_id'] ?? '').toString();
        if (pid.isEmpty) continue;
        counts[pid] = (counts[pid] ?? 0) + 1;
      }
      setState(() {
        posts = posts.map((p) {
          final row = Map<String, dynamic>.from(p);
          final id = (row['id'] ?? '').toString();
          row['views_count'] = counts[id] ?? 0;
          return row;
        }).toList();
      });
    } catch (e) {
      debugPrint('public profile refresh views error: $e');
    }
  }

  Future<String> getOrCreateConversation(String otherUserId) async {
    final supabase = Supabase.instance.client;
    final currentUserId = FirebaseAuth.instance.currentUser!.uid;

    final res =
        await supabase.from('conversations').select('id, user_a, user_b').or(
              'user_a.eq.$currentUserId,user_b.eq.$currentUserId',
            );

    if (res.isNotEmpty) {
      for (final convo in res) {
        final a = convo['user_a'];
        final b = convo['user_b'];

        if ((a == currentUserId && b == otherUserId) ||
            (a == otherUserId && b == currentUserId)) {
          return convo['id'];
        }
      }
    }

    final insert = await supabase
        .from('conversations')
        .insert({
          'user_a': currentUserId,
          'user_b': otherUserId,
        })
        .select('id')
        .single();

    final conversationId = insert['id'];

    await supabase.from('conversations').update({
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', conversationId);

    return conversationId;
  }

  Future<void> refreshCounters() async {
    final followersRes = await supabase
        .from('followers')
        .select('id')
        .eq('seller_id', widget.sellerId);

    final followingRes = await supabase
        .from('followers')
        .select('id')
        .eq('follower_id', widget.sellerId);

    if (!mounted) return;

    setState(() {
      followersCount = followersRes.length;
      followingCount = followingRes.length;
    });
  }

  Widget _statItem(String label, int value) {
    return Column(
      children: [
        Text(
          value.toString(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white70),
        ),
      ],
    );
  }

  String _formatDuration(dynamic seconds) {
    final int? s =
        seconds is int ? seconds : int.tryParse(seconds?.toString() ?? '');
    if (s == null || s < 0) return "—:—";
    final m = s ~/ 60;
    final r = s % 60;
    return "${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final avatar = sellerData!['avatar_url'];
    final displayName = (sellerData!['display_name'] as String?)?.trim();
    final username = (sellerData!['username'] as String?)?.trim();
    final bio = (sellerData!['bio'] as String?)?.trim() ?? "";
    final hasUsername = username != null && username.isNotEmpty;
    final nameText = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : (hasUsername ? "@$username" : "Utilisateur");

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: Column(
        children: [
          const SizedBox(height: 20),

          /// Avatar
          CircleAvatar(
            radius: 50,
            backgroundImage: (avatar != null && avatar.isNotEmpty)
                ? CachedNetworkImageProvider(avatar)
                : const AssetImage("assets/images/avatar.png") as ImageProvider,
          ),

          const SizedBox(height: 12),

          /// Nom
          Text(
            nameText,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),

          if (hasUsername) ...[
            const SizedBox(height: 4),
            Text(
              "@$username",
              style: const TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ],

          if (bio.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                bio,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.black87),
              ),
            ),
          ],

          /// Followers + Follow button (VENDEUR UNIQUEMENT)
          if (isSeller) ...[
            const SizedBox(height: 10),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: ElevatedButton(
                        onPressed: () async {
                          if (!isFollowing) {
                            await toggleFollow();
                          } else {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text("Se désabonner"),
                                content: const Text(
                                  "Voulez-vous vraiment vous désabonner de ce vendeur ?",
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text("Annuler"),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                    ),
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text(
                                      "Se désabonner",
                                      style: TextStyle(color: Colors.black),
                                    ),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await toggleFollow();
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              isFollowing ? Colors.white : Colors.black,
                          foregroundColor:
                              isFollowing ? Colors.black : Colors.white,
                          side: isFollowing
                              ? const BorderSide(color: Colors.black12)
                              : null,
                        ),
                        child: Text(isFollowing ? "Abonné" : "Suivre"),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.chat),
                        label: const Text("Message"),
                        onPressed: () async {
                          final convoId =
                              await getOrCreateConversation(widget.sellerId);
                          if (!mounted) return;
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatScreen(
                                conversationId: convoId,
                                receiverId: widget.sellerId,
                                currentUserId:
                                    FirebaseAuth.instance.currentUser!.uid,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Column(
                children: [
                  Text(
                    "$followersCount",
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    "Abonnés",
                    style: TextStyle(color: Colors.black),
                  ),
                ],
              ),
              const SizedBox(width: 30),
              Column(
                children: [
                  Text(
                    "$followingCount",
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    "Suivis",
                    style: TextStyle(color: Colors.black),
                  ),
                ],
              ),
              const SizedBox(width: 30),
              Column(
                children: [
                  Text(
                    "$creatorViews",
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    "Vues",
                    style: TextStyle(color: Colors.black),
                  ),
                ],
              ),
              const SizedBox(width: 30),
              Column(
                children: [
                  Text(
                    "$creatorLikes",
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    "Likes",
                    style: TextStyle(color: Colors.black),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 20),

          /// Publications
          Expanded(
            child: posts.isEmpty
                ? const Center(
                    child: Text(
                      "Aucune publication",
                      style: TextStyle(color: Colors.black54),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 6,
                      mainAxisSpacing: 6,
                    ),
                    itemCount: posts.length,
                    itemBuilder: (context, index) {
                      final post = posts[index];
                      final normalized = Map<String, dynamic>.from(post);
                      if (normalized['thumbnail_url'] == null &&
                          normalized['thumbnail_path'] != null) {
                        normalized['thumbnail_url'] =
                            normalized['thumbnail_path'];
                      }
                      final postModel = PostModel.fromMap(normalized);
                      final thumbRaw = (normalized['thumbnail_url'] ??
                              normalized['thumbnail_path'])
                          ?.toString();
                      final fallbackRaw = postModel.mediaUrl;
                      final String? thumbOrMedia =
                          (thumbRaw != null && thumbRaw.isNotEmpty)
                              ? thumbRaw
                              : (fallbackRaw.isNotEmpty ? fallbackRaw : null);
                      final String? imageUrl = thumbOrMedia == null
                          ? null
                          : (thumbOrMedia.startsWith('http')
                              ? thumbOrMedia
                              : storagePublicUrl('posts', thumbOrMedia));
                      final durationSeconds = normalized['duration_seconds'] ??
                          normalized['durationSeconds'] ??
                          normalized['duration'];
                      final durationLabel = _formatDuration(durationSeconds);
                      final dynamic rawViews = normalized['views_count'] ??
                          normalized['viewsCount'] ??
                          0;
                      final int viewsCount = rawViews is int
                          ? rawViews
                          : (rawViews is num
                              ? rawViews.toInt()
                              : int.tryParse('$rawViews') ?? 0);

                      return GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => MediaViewerPage(
                                posts: posts.map((e) {
                                  final m = Map<String, dynamic>.from(e);
                                  if (m['thumbnail_url'] == null &&
                                      m['thumbnail_path'] != null) {
                                    m['thumbnail_url'] = m['thumbnail_path'];
                                  }
                                  return PostModel.fromMap(m);
                                }).toList(),
                                initialIndex: index,
                                allowDelete: false,
                              ),
                            ),
                          );
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: imageUrl == null
                                    ? Container(
                                        color: Colors.black12,
                                        child: const Center(
                                          child: Icon(
                                            Icons.play_circle_fill,
                                            color: Colors.white70,
                                            size: 40,
                                          ),
                                        ),
                                      )
                                    : Image.network(
                                        imageUrl,
                                        fit: BoxFit.cover,
                                        loadingBuilder:
                                            (context, child, progress) {
                                          if (progress == null) return child;
                                          return Container(
                                            color: Colors.black12,
                                            child: const Center(
                                              child: Icon(
                                                Icons.play_circle_fill,
                                                color: Colors.white70,
                                                size: 40,
                                              ),
                                            ),
                                          );
                                        },
                                        errorBuilder: (_, __, ___) => Container(
                                          color: Colors.black12,
                                          child: const Center(
                                            child: Icon(
                                              Icons.play_circle_fill,
                                              color: Colors.white70,
                                              size: 40,
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                              if (postModel.isVideo)
                                const Positioned(
                                  bottom: 6,
                                  right: 6,
                                  child: Icon(
                                    Icons.videocam,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ),
                              if (postModel.isVideo)
                                Positioned(
                                  bottom: 6,
                                  left: 6,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      durationLabel,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ),
                              Positioned(
                                bottom: postModel.isVideo ? 26 : 6,
                                left: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.remove_red_eye,
                                        color: Colors.white,
                                        size: 11,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '$viewsCount',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
