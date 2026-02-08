import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import '../models/post_model.dart';
import '../utils/media_resolver.dart';

class PublicationPreviewPage extends StatefulWidget {
  final PostModel post;

  const PublicationPreviewPage({super.key, required this.post});

  @override
  State<PublicationPreviewPage> createState() => _PublicationPreviewPageState();
}

class _PublicationPreviewPageState extends State<PublicationPreviewPage> {
  VideoPlayerController? _controller;
  bool _isPlaying = true;

  @override
  void initState() {
    super.initState();

    if (widget.post.isVideo) {
      final dynamic rawVariants = (widget.post as dynamic).videoVariants;
      final Map<String, dynamic>? variants =
          rawVariants is Map ? Map<String, dynamic>.from(rawVariants) : null;
      _initVideoController(widget.post.mediaUrl, variants);
    }
  }

  Future<void> _initVideoController(
    String mediaPath,
    Map<String, dynamic>? variants,
  ) async {
    final resolvedUrl = await resolveBestVideoUrl(
      mediaPath: mediaPath,
      variants: variants,
    );
    final controller = createVideoController(resolvedUrl);
    _controller = controller;

    await controller.initialize();
    if (!mounted) return;

    // Forcer la première frame (preview)
    await controller.play();
    await Future.delayed(const Duration(milliseconds: 300));
    await controller.pause();
    await controller.seekTo(Duration.zero);

    setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // ✅ CONFIRMATION AVANT SUPPRESSION
  Future<void> _confirmDelete(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text("Confirmation"),
          content: const Text(
            "Voulez-vous vraiment supprimer cette publication ? Cette action est irréversible.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Annuler"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Supprimer"),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      _deletePost(context);
    }
  }

  // ✅ SUPPRESSION RÉELLE
  Future<void> _deletePost(BuildContext context) async {
    try {
      final supabase = Supabase.instance.client;

      final uri = Uri.parse(widget.post.mediaUrl);
      final filePath = uri.path.replaceFirst('/storage/v1/object/public/', '');

      await supabase.storage.from('posts').remove([filePath]);
      await supabase.from('posts').delete().eq('id', widget.post.id);

      Navigator.pop(context, true);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Erreur suppression")),
      );
    }
  }

  // ✅ TAP PLAY / PAUSE
  void _togglePlay() {
    if (_controller == null) return;

    setState(() {
      if (_controller!.value.isPlaying) {
        _controller!.pause();
        _isPlaying = false;
      } else {
        _controller!.play();
        _isPlaying = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,

      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: () => _confirmDelete(context),
          ),
        ],
      ),

      body: Center(
        child: widget.post.isVideo
            ? _controller != null && _controller!.value.isInitialized
                ? GestureDetector(
                    onTap: _togglePlay,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AspectRatio(
                          aspectRatio: _controller!.value.aspectRatio,
                          child: VideoPlayer(_controller!),
                        ),

                        // ✅ Icône pause/play au centre
                        if (!_controller!.value.isPlaying)
                          const Icon(
                            Icons.play_circle_fill,
                            color: Colors.white,
                            size: 80,
                          ),

                        // ✅ BARRE DE PROGRESSION EN BAS
                        Positioned(
                          bottom: 20,
                          left: 20,
                          right: 20,
                          child: VideoProgressIndicator(
                            _controller!,
                            allowScrubbing: true,
                            colors: const VideoProgressColors(
                              playedColor: Colors.white,
                              backgroundColor: Colors.grey,
                              bufferedColor: Colors.grey,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const CircularProgressIndicator(color: Colors.white)
              : Image.network(
                  resolveMediaUrl(widget.post.mediaUrl),
                  fit: BoxFit.contain,
                ),
      ),
    );
  }
}
