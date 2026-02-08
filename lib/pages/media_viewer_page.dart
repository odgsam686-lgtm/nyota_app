import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/post_model.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/storage_url.dart';

bool _viewRegistered = false;
Timer? _imageViewTimer;

class MediaViewerPage extends StatefulWidget {
  final List<PostModel> posts;
  final int initialIndex;

  const MediaViewerPage({
    super.key,
    required this.posts,
    required this.initialIndex,
  });

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  late PageController _pageController;
  VideoPlayerController? _videoController;
  int currentIndex = 0;

  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: currentIndex);
    _loadVideoIfNeeded(currentIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final post = widget.posts[currentIndex];

      if (!post.isVideo) {
        _imageViewTimer = Timer(const Duration(seconds: 2), () {
          if (mounted && !_viewRegistered) {
            _viewRegistered = true;
            _registerView(post);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> toggleLike(PostModel post) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final res = await Supabase.instance.client
        .from('likes') // ✅ table correcte
        .select('id')
        .eq('post_id', post.id)
        .eq('user_id', uid);

    if (res.isEmpty) {
      // 👍 LIKE
      await Supabase.instance.client.from('likes').insert({
        'post_id': post.id,
        'user_id': uid,
      });
    } else {
      // 💔 UNLIKE
      await Supabase.instance.client
          .from('likes')
          .delete()
          .eq('post_id', post.id)
          .eq('user_id', uid);
    }

    setState(() {}); // 🔄 refresh UI
  }

  Future<void> _registerView(PostModel post) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // Vérifie si l’utilisateur a déjà vu ce post
    final res = await Supabase.instance.client
        .from('post_views')
        .select('id')
        .eq('post_id', post.id)
        .eq('viewer_id', uid);

    if (res.isEmpty) {
      await Supabase.instance.client.from('post_views').insert({
        'post_id': post.id,
        'viewer_id': uid,
      });
    }
  }

  // =======================
  // 🎥 LOAD VIDEO AUTOPLAY
  // =======================
  Future<void> _loadVideoIfNeeded(int index) async {
    _videoController?.dispose();
    _videoController = null;

    final post = widget.posts[index];
    if (!post.isVideo) {
      setState(() {});
      return;
    }

    final mediaUrl = post.mediaUrl.startsWith('http')
        ? post.mediaUrl
        : storagePublicUrl('posts', post.mediaUrl);

    final controller = VideoPlayerController.networkUrl(Uri.parse(mediaUrl));
    await controller.initialize();

    controller
      ..setLooping(true)
      ..play();
    controller.addListener(() {
      if (_viewRegistered) return;

      final value = controller.value;

      if (value.isPlaying && value.position.inMilliseconds >= 2000) {
        _viewRegistered = true;
        _registerView(widget.posts[currentIndex]);
      }
    });

    setState(() {
      _videoController = controller;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        itemCount: widget.posts.length,
        onPageChanged: (index) {
          currentIndex = index;

          // reset vue
          _viewRegistered = false;
          _imageViewTimer?.cancel();

          _loadVideoIfNeeded(index);

          final post = widget.posts[index];

          // 🖼 IMAGE → vue après 2 secondes
          if (!post.isVideo) {
            _imageViewTimer = Timer(const Duration(seconds: 2), () {
              if (mounted && !_viewRegistered) {
                _viewRegistered = true;
                _registerView(post);
              }
            });
          }
        },
        itemBuilder: (context, index) {
          final post = widget.posts[index];

          return Stack(
            alignment: Alignment.center,
            children: [
              post.isVideo ? _buildVideo() : _buildImage(post),
              Positioned(
                top: 90,
                right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.remove_red_eye,
                            color: Colors.white, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          '${post.viewsCount ?? 0}',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.favorite,
                            color: Colors.white, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          '${post.likesCount ?? 0}',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // 🔙 RETOUR
              Positioned(
                top: 40,
                left: 16,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),

              // ▶️ BARRE DE PROGRESSION
              if (post.isVideo && _videoController != null)
                Positioned(
                  bottom: 20,
                  left: 12,
                  right: 12,
                  child: VideoProgressIndicator(
                    _videoController!,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                      playedColor: Colors.white,
                      bufferedColor: Colors.white38,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // =======================
  // 🎥 VIDEO WIDGET
  // =======================
  Widget _buildVideo() {
    if (_videoController == null || !_videoController!.value.isInitialized) {
      return const CircularProgressIndicator(color: Colors.white);
    }

    return GestureDetector(
      onTap: () {
        if (_videoController!.value.isPlaying) {
          _videoController!.pause();
        } else {
          _videoController!.play();
        }
        setState(() {});
      },
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: _videoController!.value.size.width,
          height: _videoController!.value.size.height,
          child: VideoPlayer(_videoController!),
        ),
      ),
    );
  }

  // =======================
  // 🖼 IMAGE FULLSCREEN
  // =======================
  Widget _buildImage(PostModel post) {
    final imageUrl = post.mediaUrl.startsWith('http')
        ? post.mediaUrl
        : storagePublicUrl('posts', post.mediaUrl);

    return InteractiveViewer(
      child: Image.network(
        imageUrl,
        fit: BoxFit.contain,
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return const CircularProgressIndicator(color: Colors.white);
        },
        errorBuilder: (_, __, ___) => const Text(
          "Impossible de charger l'image",
          style: TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
