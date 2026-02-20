import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import '../widgets/fullscreen_media_actions.dart';
import '../utils/media_resolver.dart';
import 'comments_page.dart';

class ProductDetailPage extends StatefulWidget {
  final Map<String, dynamic> product;
  const ProductDetailPage({super.key, required this.product});

  @override
  State<ProductDetailPage> createState() => _ProductDetailPageState();
}

class _ProductDetailPageState extends State<ProductDetailPage> {
  VideoPlayerController? _videoController;
@override
void initState() {
  super.initState();

  final type = widget.product['media_type'];
  final media = widget.product['media_url']?.toString() ?? '';
  final dynamic rawVariants = widget.product['video_variants'];
  final Map<String, dynamic>? variants =
      rawVariants is Map ? Map<String, dynamic>.from(rawVariants) : null;

  if (type == 'video' && media.isNotEmpty) {
    _initVideoController(media, variants);
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
  _videoController = controller;

  await controller.initialize();

  if (!mounted) return;

  // Forcer la première frame
  await controller.play();
  await Future.delayed(const Duration(milliseconds: 300));
  await controller.pause();
  await controller.seekTo(Duration.zero);

  setState(() {});
}


  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.product['media_url']?.toString() ?? '';
    final resolvedMedia = resolveMediaUrl(media);
    final type = widget.product['media_type'];
    final title =
        widget.product['title'] ?? widget.product['description'] ?? '';
    final seller = widget.product['seller_name'] ?? '';
    final price = widget.product['price'] != null
        ? widget.product['price'].toString()
        : '';
    final currency = widget.product['currency'] ?? 'XOF';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            /// 🔹 MEDIA (IMAGE OU VIDÉO)
            Positioned.fill(
              child: type == 'video'
                  ? (_videoController != null &&
                          _videoController!.value.isInitialized
                      ? FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: _videoController!.value.size.width,
                            height: _videoController!.value.size.height,
                            child: VideoPlayer(_videoController!),
                          ),
                        )
                      : const Center(child: CircularProgressIndicator()))
                  : (media.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: resolvedMedia,
                          fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              const Center(child: CircularProgressIndicator()),
                          errorWidget: (_, __, ___) => const Center(
                              child: Icon(Icons.broken_image,
                                  color: Colors.white)),
                        )
                      : Container(color: Colors.grey.shade900)),
            ),

            /// 🔹 BOUTON RETOUR
            Positioned(
              left: 8,
              top: 8,
              child: CircleAvatar(
                backgroundColor: Colors.black54,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),

            /// 🔹 PLAY / PAUSE POUR VIDÉO
            if (type == 'video' && _videoController != null)
              Positioned(
                right: 12,
                top: 12,
                child: CircleAvatar(
                  backgroundColor: Colors.black54,
                  child: IconButton(
                    icon: Icon(
                      _videoController!.value.isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      setState(() {
                        _videoController!.value.isPlaying
                            ? _videoController!.pause()
                            : _videoController!.play();
                      });
                    },
                  ),
                ),
              ),

            /// 🔹 INFOS PRODUIT
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.85)
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Vendu par $seller',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$price $currency',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        ElevatedButton.icon(
                          icon: const Icon(Icons.shopping_cart_outlined),
                          label: const Text('Ajouter au panier'),
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Ajouté au panier (MVP)')),
                            );
                          },
                        ),
                      ],
                    )
                  ],
                ),
              ),
            ),
            FullScreenMediaActions(
              postId: widget.product['id'],
              sellerId: widget.product['seller_id'],
              avatarUrl: widget.product['avatar_url'],
              likesCount: widget.product['likes'] ?? 0,
              commentsCount: widget.product['comments_count'] ?? 0,
              isLiked: false, // ou calculé si connecté
              onLike: () {
                // même logique que le feed
              },
              onComment: () {
                openComments(context, widget.product['id']);
              },
              onOpenProfile: () {
                Navigator.pushNamed(
                  context,
                  '/publicProfile',
                  arguments: widget.product['seller_id'],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
