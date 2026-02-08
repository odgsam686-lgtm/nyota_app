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

      setState(() {
        posts = postsRes;
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

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final avatar = sellerData!['avatar_url'];
    final username = sellerData!['username'] ?? "Utilisateur";
    final bio = sellerData!['bio'] ?? "";

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.black),
        title: const Text("Profil", style: TextStyle(color: Colors.black)),
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

          /// Username
          Text(
            "@$username",
            style: const TextStyle(
              color: Colors.black,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),

          if (bio.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                bio,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black),
              ),
            ),
          ],

          /// Followers + Follow button (VENDEUR UNIQUEMENT)
          if (isSeller) ...[
            const SizedBox(height: 10),
            Text(
              "$followersCount abonnés",
              style: const TextStyle(color: Colors.black),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: 220,
              child: ElevatedButton(
                onPressed: () async {
                  if (!isFollowing) {
                    // 👉 S’ABONNER DIRECTEMENT
                    await toggleFollow();
                  } else {
                    // 👉 CONFIRMATION AVANT DÉSABONNEMENT
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
                      isFollowing ? Colors.white : Colors.red, // 🤍 ou 🔴
                  foregroundColor: Colors.black, // 🖤 texte noir
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: isFollowing
                        ? const BorderSide(color: Colors.black12)
                        : BorderSide.none,
                  ),
                  elevation: isFollowing ? 0 : 2,
                ),
                child: Text(
                  isFollowing ? "Se désabonner" : "Suivre",
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // 💬 BOUTON CHAT (NOUVEAU)
            SizedBox(
              width: 160,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.chat),
                label: const Text("Message"),
                onPressed: () async {
                  final conversationId =
                      await getOrCreateConversation(widget.sellerId);

                  if (!mounted) return;

                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        conversationId: conversationId,
                        receiverId: widget.sellerId,
                        currentUserId: FirebaseAuth.instance.currentUser!.uid,
                      ),
                    ),
                  );
                },
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
                      final postModel = PostModel.fromMap(post);

                      // URL SAFE (image uniquement)
                      final String imageUrl =
                          postModel.mediaUrl.startsWith('http')
                              ? postModel.mediaUrl
                              : storagePublicUrl('posts', postModel.mediaUrl);

                      return GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => MediaViewerPage(
                                posts: posts
                                    .map((e) => PostModel.fromMap(e))
                                    .toList(),
                                initialIndex: index,
                              ),
                            ),
                          );
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: postModel.isVideo
                                    // 🎥 VIDÉO = PLACEHOLDER (COMME PUBLICATION)
                                    ? Container(
                                        color: Colors.black,
                                        child: const Center(
                                          child: Icon(
                                            Icons.play_circle_fill,
                                            color: Colors.white,
                                            size: 50,
                                          ),
                                        ),
                                      )
                                    // 🖼 IMAGE = CHARGEMENT NORMAL
                                    : Image.network(
                                        imageUrl,
                                        fit: BoxFit.cover,
                                      ),
                              ),

                              // Icône vidéo
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
