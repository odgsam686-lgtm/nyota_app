import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import '../models/post_model.dart';
import '../utils/storage_url.dart';

class MediaViewerPage extends StatefulWidget {
  final List<PostModel> posts;
  final int initialIndex;
  final bool allowDelete;

  const MediaViewerPage({
    super.key,
    required this.posts,
    required this.initialIndex,
    this.allowDelete = true,
  });

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  static const Duration _viewThreshold = Duration(seconds: 2);

  late PageController _pageController;
  VideoPlayerController? _videoController;
  int currentIndex = 0;
  bool _deleting = false;

  Timer? _imageViewTimer;
  Timer? _videoViewTimer;
  final Set<String> _viewRegisteredPostIds = {};
  final Set<String> _viewInFlightPostIds = {};

  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: currentIndex);
    _startViewTracking(currentIndex);
    _loadVideoIfNeeded(currentIndex);
  }

  @override
  void dispose() {
    _cancelViewTracking();
    _videoController?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _cancelViewTracking() {
    _imageViewTimer?.cancel();
    _imageViewTimer = null;
    _videoViewTimer?.cancel();
    _videoViewTimer = null;
  }

  void _startViewTracking(int index) {
    _cancelViewTracking();
    if (index < 0 || index >= widget.posts.length) return;
    final post = widget.posts[index];
    if (post.isVideo) return;
    if (_viewRegisteredPostIds.contains(post.id)) return;

    _imageViewTimer = Timer(_viewThreshold, () async {
      if (!mounted || currentIndex != index) return;
      await _registerView(post.id);
    });
  }

  void _scheduleVideoViewTracking(String postId) {
    _videoViewTimer?.cancel();
    if (_viewRegisteredPostIds.contains(postId)) return;

    _videoViewTimer = Timer(_viewThreshold, () async {
      if (!mounted) return;
      if (currentIndex < 0 || currentIndex >= widget.posts.length) return;
      final currentPost = widget.posts[currentIndex];
      if (!currentPost.isVideo || currentPost.id != postId) return;
      final controller = _videoController;
      if (controller == null ||
          !controller.value.isInitialized ||
          !controller.value.isPlaying) {
        return;
      }
      await _registerView(postId);
    });
  }

  Future<void> _registerView(String postId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (_viewRegisteredPostIds.contains(postId)) return;
    if (_viewInFlightPostIds.contains(postId)) return;

    _viewInFlightPostIds.add(postId);
    bool success = false;
    try {
      try {
        await Supabase.instance.client.from('post_views').upsert(
          {
            'post_id': postId,
            'viewer_id': uid,
          },
          onConflict: 'post_id,viewer_id',
        );
        success = true;
      } catch (_) {
        final existing = await Supabase.instance.client
            .from('post_views')
            .select('id')
            .eq('post_id', postId)
            .eq('viewer_id', uid)
            .limit(1);
        if (existing.isEmpty) {
          await Supabase.instance.client.from('post_views').insert({
            'post_id': postId,
            'viewer_id': uid,
          });
        }
        success = true;
      }
    } catch (e) {
      debugPrint('register view error post=$postId user=$uid error=$e');
    } finally {
      if (success) {
        _viewRegisteredPostIds.add(postId);
      }
      _viewInFlightPostIds.remove(postId);
    }
  }

  Future<void> _confirmDelete(PostModel post) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || post.sellerId != uid) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Supprimer ?"),
        content: const Text("Supprimer cette publication ?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Annuler"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Supprimer"),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _deleting = true);
    try {
      await Supabase.instance.client.from('posts').delete().eq('id', post.id);

      if (!mounted) return;
      widget.posts.removeAt(currentIndex);
      if (widget.posts.isEmpty) {
        Navigator.pop(context, true);
        return;
      }
      if (currentIndex >= widget.posts.length) {
        currentIndex = widget.posts.length - 1;
      }
      _pageController.jumpToPage(currentIndex);
      _startViewTracking(currentIndex);
      _loadVideoIfNeeded(currentIndex);
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur suppression: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> toggleLike(PostModel post) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final res = await Supabase.instance.client
        .from('likes')
        .select('id')
        .eq('post_id', post.id)
        .eq('user_id', uid);

    if (res.isEmpty) {
      await Supabase.instance.client.from('likes').insert({
        'post_id': post.id,
        'user_id': uid,
      });
    } else {
      await Supabase.instance.client
          .from('likes')
          .delete()
          .eq('post_id', post.id)
          .eq('user_id', uid);
    }

    setState(() {});
  }

  Future<void> _loadVideoIfNeeded(int index) async {
    _videoViewTimer?.cancel();
    _videoController?.dispose();
    _videoController = null;

    if (index < 0 || index >= widget.posts.length) return;
    final post = widget.posts[index];
    if (!post.isVideo) {
      if (mounted) setState(() {});
      return;
    }

    final mediaUrl = post.mediaUrl.startsWith('http')
        ? post.mediaUrl
        : storagePublicUrl('posts', post.mediaUrl);

    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(mediaUrl));
      await controller.initialize();
      if (!mounted || currentIndex != index) {
        await controller.dispose();
        return;
      }

      controller
        ..setLooping(true)
        ..play();

      _videoController = controller;
      _scheduleVideoViewTracking(post.id);
      setState(() {});
    } catch (e) {
      debugPrint('MediaViewer _loadVideoIfNeeded error post=${post.id}: $e');
      if (!mounted) return;
      setState(() {
        _videoController = null;
      });
    }
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
          _startViewTracking(index);
          _loadVideoIfNeeded(index);
        },
        itemBuilder: (context, index) {
          final post = widget.posts[index];

          return Stack(
            alignment: Alignment.center,
            children: [
              post.isVideo ? _buildVideo(post) : _buildImage(post),
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
              Positioned(
                top: 40,
                left: 16,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              if (widget.allowDelete &&
                  post.sellerId == FirebaseAuth.instance.currentUser?.uid)
                Positioned(
                  top: 40,
                  right: 16,
                  child: IconButton(
                    icon: _deleting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.delete, color: Colors.white),
                    onPressed: _deleting ? null : () => _confirmDelete(post),
                  ),
                ),
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

  Widget _buildVideo(PostModel post) {
    if (_videoController == null || !_videoController!.value.isInitialized) {
      final thumb = post.thumbnailUrl;
      final thumbUrl = (thumb != null && thumb.isNotEmpty)
          ? (thumb.startsWith('http')
              ? thumb
              : storagePublicUrl('posts', thumb))
          : null;
      return thumbUrl != null
          ? Image.network(
              thumbUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const CircularProgressIndicator(color: Colors.white),
            )
          : const CircularProgressIndicator(color: Colors.white);
    }

    return GestureDetector(
      onTap: () {
        if (_videoController!.value.isPlaying) {
          _videoController!.pause();
          _videoViewTimer?.cancel();
        } else {
          _videoController!.play();
          _scheduleVideoViewTracking(post.id);
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
