// feed_page_supabase.dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:nyota_app/widgets/nyota_background.dart';
import 'package:video_player/video_player.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/fullscreen_media_actions.dart';
import '../utils/media_resolver.dart';
import 'comments_page.dart';

class FeedPage extends StatefulWidget {
  const FeedPage({super.key});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  int currentIndex = 0;

  // Posts loaded from Supabase (paged)
  final List<Map<String, dynamic>> posts = [];
  bool isLoading = false;
  bool hasMore = true;
  final int limit = 6; // ajustable
  bool _isFastScrolling = false;

  // Video controllers keyed by postId (stabler que par index)
  final Map<String, VideoPlayerController> videoControllers = {};
  final Set<String> _loggedPosts = {};

  // Pour animation like
  final Set<String> likedLocal = {}; // posts liked locally (UI)
  final Map<String, int> localLikes = {}; // overrides for optimistic UI
  final supabase = Supabase.instance.client;
  String? _doubleTapPostId;
  bool _showBigHeart = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMorePosts();
    // ... ton code existant ...
    FirebaseAuth.instance.authStateChanges().listen((user) {
      // quand le user change, reload likes (et posts si besoin)
      _loadLikesForPosts();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    for (var c in videoControllers.values) {
      try {
        c.pause();
        c.dispose();
      } catch (_) {}
    }
    videoControllers.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseAllVideos();
    } else if (state == AppLifecycleState.resumed) {
      _playCurrentIfNeeded();
    }
  }

  Future<void> _loadMorePosts() async {
    if (isLoading || !hasMore) return;

    if (!mounted) return;
    setState(() => isLoading = true);

    final from = posts.length;
    final to = from + limit - 1;

    List<dynamic> res = [];

    try {
      res = await supabase
          .from('posts')
          .select(
              'id, seller_id, seller_name, avatar_url, media_url, thumbnail_url, thumbnail_path, video_variants, is_video, description, timestamp, likes')
          .order('timestamp', ascending: false)
          .range(from, to);

      if (!mounted) return;

      if (res.isEmpty) {
        hasMore = false;
      } else {
        for (var r in res) {
          r['id'] = r['id']?.toString();
              r['likes'] = (r['likes'] is int)
                  ? r['likes']
                  : int.tryParse(r['likes']?.toString() ?? "0") ?? 0;

              posts.add(r);
              localLikes[r['id']] = r['likes'];

              final id = r['id']?.toString();
              if (id != null && !_loggedPosts.contains(id)) {
                _loggedPosts.add(id);
                debugPrint(
                    "FEED render post=$id is_video=${r['is_video']} media_url=${r['media_url']} thumb=${r['thumbnail_url'] ?? r['thumbnail_path']} variants=${r['video_variants'] != null}");
              }
            }

        if (posts.length <= 2) {
          _maybeInitAroundIndex(0);
        }
      }

      // ⚠️ precacheImage utilise CONTEXT → mounted obligatoire
      if (!mounted) return;

        for (var r in res) {
          final rawMediaUrl = r['media_url']?.toString() ?? '';
          final isVideo = r['is_video'] == true;

          if (!isVideo && rawMediaUrl.isNotEmpty) {
            final mediaUrl = resolveMediaUrl(rawMediaUrl);
            precacheImage(
              CachedNetworkImageProvider(mediaUrl),
              context,
            );
        }
      }
    } catch (e, st) {
      debugPrint("Erreur load posts : $e\n$st");
    } finally {
      if (!mounted) return;
      setState(() => isLoading = false);
    }

    // ❗ IMPORTANT : async + possible navigation
    if (!mounted) return;
    await _loadLikesForPosts();
  }

  Future<void> _initializeVideoForIndex(int index) async {
    if (index < 0 || index >= posts.length) return;
    final doc = posts[index];
    final bool isVideo =
        doc['is_video'] == true || (doc['is_video']?.toString() == 'true');
    final mediaPath = doc['media_url']?.toString() ?? '';
    final dynamic rawVariants = doc['video_variants'];
    final Map<String, dynamic>? variants =
        rawVariants is Map ? Map<String, dynamic>.from(rawVariants) : null;
    final postId = doc['id']?.toString() ?? index.toString();

    if (!isVideo || mediaPath.isEmpty) return;
    if (videoControllers.containsKey(postId)) return;

    try {
      final resolvedUrl = await resolveBestVideoUrl(
        mediaPath: mediaPath,
        variants: variants,
      );
      final controller = createVideoController(resolvedUrl);
      videoControllers[postId] = controller;
      await controller.initialize();
      controller.setLooping(true);
      setState(() {});
    } catch (e) {
      debugPrint("Erreur init video ($postId): $e");
      videoControllers.remove(postId);
    }
  }

  void _maybeInitAroundIndex(int index) {
    _initializeVideoForIndex(index); // actuel
    _initializeVideoForIndex(index + 1); // prochain
    _initializeVideoForIndex(index - 1); // précédent
  }

  void _pauseVideoByIndex(int index) {
    if (index < 0 || index >= posts.length) return;
    final id = posts[index]['id']?.toString();
    if (id == null) return;
    final c = videoControllers[id];
    if (c != null && c.value.isPlaying) c.pause();
  }

  void _pauseAllVideos() {
    for (var c in videoControllers.values) {
      try {
        if (c.value.isPlaying) c.pause();
      } catch (_) {}
    }
  }

  void openPublicProfile(String sellerId) {
    Navigator.pushNamed(
      context,
      '/publicProfile',
      arguments: sellerId,
    );
  }

  void _playCurrentIfNeeded() {
    Future.microtask(() {
      if (currentIndex < 0 || currentIndex >= posts.length) return;

      final id = posts[currentIndex]['id']?.toString();
      if (id == null) return;

      final c = videoControllers[id];
      if (c != null && c.value.isInitialized && !c.value.isPlaying) {
        c.play();
      }
    });
  }

  void _onPageChanged(int index) {
    _isFastScrolling = true;

    _pauseVideoByIndex(currentIndex);
    currentIndex = index;

    // ⏱️ On attend que le scroll se stabilise
    Future.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) return;

      _isFastScrolling = false;
      _maybeInitAroundIndex(index);
      _playCurrentIfNeeded();
    });

    if (index >= posts.length - 3) {
      _loadMorePosts();
    }
  }

  void _playCurrentIfReady() {
    final postId = posts[currentIndex]['id'].toString();
    final controller = videoControllers[postId];

    if (controller != null &&
        controller.value.isInitialized &&
        !controller.value.isPlaying) {
      controller.play(); // ⚡ instantané
    }
  }

  Future<void> _initVideoIfNeeded(int index) async {
    if (index < 0 || index >= posts.length) return;

    final post = posts[index];
    final postId = post['id'].toString();
    final mediaPath = post['media_url']?.toString() ?? '';
    final dynamic rawVariants = post['video_variants'];
    final Map<String, dynamic>? variants =
        rawVariants is Map ? Map<String, dynamic>.from(rawVariants) : null;
    final isVideo = post['is_video'] == true;

    if (!isVideo || mediaPath.isEmpty) return;
    if (videoControllers.containsKey(postId)) return;

    try {
      final resolvedUrl = await resolveBestVideoUrl(
        mediaPath: mediaPath,
        variants: variants,
      );
      final controller = createVideoController(resolvedUrl);
      videoControllers[postId] = controller;

      await controller.initialize(); // 🔥 LE SECRET
      controller.setLooping(true);
    } catch (e) {
      videoControllers.remove(postId);
    }
  }

  Future<void> _refreshFeed() async {
    setState(() {
      posts.clear();
      hasMore = true;
      isLoading = false;
    });

    for (var c in videoControllers.values) {
      try {
        c.pause();
        c.dispose();
      } catch (_) {}
    }
    videoControllers.clear();
    localLikes.clear();
    likedLocal.clear();

    await _loadMorePosts();
  }

  // -------------------- LIKE (animation + update supabase) --------------------
  // Optimistic UI: on like pressed -> animate + increment local value, then update server
  Future<void> _likePostAnimated(String postId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userId = user.uid;

    // Empêche double like
    if (likedLocal.contains(postId)) return;

    // LIKE OPTIMISTIQUE (affichage immédiat)
    setState(() {
      likedLocal.add(postId);
      localLikes[postId] = (localLikes[postId] ?? 0) + 1;
    });

    try {
      // -------------------------------
      // 1️⃣ INSERT DANS LA TABLE LIKES
      // -------------------------------
      await Supabase.instance.client.from('likes').insert({
        'post_id': postId,
        'user_id': userId,
        'created_at': DateTime.now().toIso8601String(),
      });

      // -------------------------------
      // 2️⃣ UPDATE DE LA TABLE POSTS
      // -------------------------------
      await Supabase.instance.client
          .from('posts')
          .update({'likes': localLikes[postId]}).eq('id', postId);
    } catch (e) {
      debugPrint("ERROR LIKE: $e");
    }

    // -------------------------------
    // 3️⃣ Après tout → rechargement fiable
    // -------------------------------
    await _loadLikesForPosts();
  }

  Future<void> _loadLikesForPosts() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userId = user.uid;

    if (posts.isEmpty) return;

    final postIds = posts.map((e) => e['id'].toString()).toList();

    final data = await Supabase.instance.client
        .from('likes')
        .select()
        .inFilter('post_id', postIds);

    likedLocal.clear();
    localLikes.clear();

    for (final like in data) {
      final pid = like['post_id'].toString();

      localLikes[pid] = (localLikes[pid] ?? 0) + 1;

      if (like['user_id'] == userId) {
        likedLocal.add(pid);
      }
    }
    if (!mounted) return;
    setState(() {});
  }

  // -------------------- WIDGET BUILD --------------------
  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty && isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (posts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.rss_feed, size: 64, color: Colors.grey),
            const SizedBox(height: 12),
            const Text("Aucun post disponible", style: TextStyle(fontSize: 16)),
            const SizedBox(height: 12),
            ElevatedButton(
                onPressed: _loadMorePosts, child: const Text("Recharger")),
          ],
        ),
      );
    }

    return NyotaBackground(
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            pageSnapping: true,
            physics: const PageScrollPhysics(),
            itemCount: posts.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) {
              if (_isFastScrolling) {
                return const ColoredBox(color: Colors.black);
              }

              final doc = posts[index];
                final rawMediaUrl = doc['media_url']?.toString();
                final mediaUrl =
                    rawMediaUrl == null ? null : resolveMediaUrl(rawMediaUrl);
                final rawThumb = doc['thumbnail_url'] ?? doc['thumbnail_path'];
                final thumbnailUrl = rawThumb != null &&
                        rawThumb.toString().isNotEmpty
                    ? resolveMediaUrl(rawThumb.toString())
                    : null;
                final isVideo = doc['is_video'] == true ||
                    (doc['is_video']?.toString() == 'true');
                final sellerName = doc['seller_name'] ?? 'Utilisateur';
              final sellerId = doc['seller_id'];
              final description = doc['description'] ?? '';
              final postId = doc['id']?.toString() ?? index.toString();

              final likesCount = localLikes[postId] ?? (doc['likes'] ?? 0);

              return GestureDetector(
                behavior: HitTestBehavior.opaque,

                // ✅ DOUBLE TAP = LIKE + FEU D’ARTIFICE DE CŒUR
                onDoubleTap: () {
                  if (!likedLocal.contains(postId)) {
                    _likePostAnimated(postId);
                  }

                  setState(() {
                    _doubleTapPostId = postId;
                    _showBigHeart = true;
                  });

                  Future.delayed(const Duration(milliseconds: 700), () {
                    if (mounted) {
                      setState(() {
                        _showBigHeart = false;
                      });
                    }
                  });
                },

                // ✅ SIMPLE TAP = PLAY / PAUSE
                onTap: () {
                    if (isVideo && mediaUrl != null && mediaUrl.isNotEmpty) {
                      final ctrl = videoControllers[postId];
                      if (ctrl != null && ctrl.value.isInitialized) {
                        if (ctrl.value.isPlaying) {
                        ctrl.pause();
                      } else {
                        ctrl.play();
                      }
                      setState(() {});
                    }
                  }
                },

                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isVideo && mediaUrl != null && mediaUrl.isNotEmpty)
                      _buildVideoWidget(postId, mediaUrl, thumbnailUrl)
                    else if (mediaUrl != null && mediaUrl.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: mediaUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        placeholder: (c, s) => const Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        errorWidget: (c, s, e) =>
                            const Center(child: Icon(Icons.broken_image)),
                      )
                    else
                      Container(color: Colors.black54),

                    // Gradient for readability
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 260,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.transparent, Colors.black54],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                    ),

                    // Seller info
                    Positioned(
                      left: 16,
                      bottom: 40,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ❌ SUPPRIMER L’AVATAR ICI
                          // ❌ SUPPRIMER L’EMAIL ICI

                          const SizedBox(height: 6),

                          // ✅ GARDER LA DESCRIPTION
                          SizedBox(
                            width: MediaQuery.of(context).size.width * 0.6,
                            child: Text(
                              description,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (_showBigHeart && _doubleTapPostId == postId)
                      Center(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.3, end: 1.4),
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.elasticOut,
                          builder: (context, scale, child) {
                            return Transform.scale(
                              scale: scale,
                              child: const Icon(
                                Icons.favorite,
                                color: Colors.red,
                                size: 120,
                              ),
                            );
                          },
                        ),
                      ),

                    FullScreenMediaActions(
                      postId: postId,
                      sellerId: sellerId,
                      avatarUrl: doc['avatar_url'],
                      likesCount: likesCount,
                      commentsCount: doc['comments_count'] ?? 0,
                      isLiked: likedLocal.contains(postId),
                      onLike: () => _likePostAnimated(postId),
                      onComment: () => _openComments(postId),
                      onOpenProfile: () => openPublicProfile(sellerId), // ✅ ICI
                    ),
                  ],
                ),
              );
            },
          ),

          // Top-right controls

          if (isLoading)
            const Positioned(
                bottom: 24,
                left: 0,
                right: 0,
                child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }

  Widget _buildVideoWidget(String postId, String mediaUrl, String? thumbnailUrl) {
    final controller = videoControllers[postId];
    if (controller == null) {
      final idx = posts.indexWhere((d) => d['id']?.toString() == postId);
      if (idx != -1) _initializeVideoForIndex(idx);

      if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
        return Center(
          child: CachedNetworkImage(
            imageUrl: thumbnailUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            placeholder: (c, s) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (c, s, e) =>
                const Center(child: Icon(Icons.broken_image)),
          ),
        );
      }
      return const Center(child: Icon(Icons.broken_image));
    }

    if (!controller.value.isInitialized) {
      if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
        return Center(
          child: CachedNetworkImage(
            imageUrl: thumbnailUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            placeholder: (c, s) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (c, s, e) =>
                const Center(child: Icon(Icons.broken_image)),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
          width: controller.value.size.width,
          height: controller.value.size.height,
          child: VideoPlayer(controller)),
    );
  }

  void _openComments(String postId) {
    openComments(context, postId);
  }

  void _openProduct(Map<String, dynamic> data) {
    Navigator.pushNamed(context, '/product', arguments: data);
  }

  void _showDebugDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text("Debug Posts Feed"),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            itemCount: posts.length,
            itemBuilder: (context, index) {
              final d = posts[index];
              return ListTile(
                title: Text(d['description'] ?? 'Pas de description'),
                subtitle: Text('@${d['seller_name'] ?? "?"} • id:${d['id']}'),
                trailing: Text((d['is_video'] == true) ? 'Video' : 'Image'),
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("Fermer"))
        ],
      ),
    );
  }
}
