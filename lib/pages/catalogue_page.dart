// lib/pages/catalog_page.dart
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';

import '../services/supabase_products_service.dart';
import 'product_detail_page.dart';
import '../utils/media_resolver.dart';

class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key});

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  final SupabaseProductsService svc = SupabaseProductsService();

  List<Map<String, dynamic>> categories = [];
  String selectedCategory = 'all';
  List<Map<String, dynamic>> products = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadCategoriesAndProducts();
  }

  Future<void> _loadCategoriesAndProducts() async {
    setState(() => loading = true);

    categories = await svc.fetchCategories();

    // ✅ catégorie virtuelle "Tous"
    categories.insert(0, {'id': 'all', 'label': 'Tous'});

    selectedCategory = 'all';
    await _loadProductsFor(selectedCategory);

    if (mounted) setState(() => loading = false);
  }

  Future<void> _loadProductsFor(String category) async {
    setState(() => loading = true);

    if (category == 'all') {
      products = await svc.fetchAllProducts();
    } else {
      products = await svc.fetchProductsByCategory(category: category);
    }

    if (mounted) {
      setState(() {
        selectedCategory = category;
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
      ),
      body: Column(
        children: [
          /// 🔹 Catégories
          SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: categories.length,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final c = categories[i];
                final cid = c['id'];
                final label = c['label'] ?? cid;
                final isSel = cid == selectedCategory;

                return GestureDetector(
                  onTap: () => _loadProductsFor(cid),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSel ? Colors.deepPurple : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Center(
                      child: Text(
                        label.toString(),
                        style: TextStyle(
                          color: isSel ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          /// 🔹 Produits
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : products.isEmpty
                    ? const Center(
                        child: Text('Aucun produit dans cette catégorie'),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                          childAspectRatio: 0.7,
                        ),
                        itemCount: products.length,
                        itemBuilder: (context, idx) {
                          final p = products[idx];

                          final media = p['media_url']?.toString() ?? '';
                          final resolvedMedia = resolveMediaUrl(media);
                          final dynamic rawVariants = p['video_variants'];
                          final Map<String, dynamic>? variants =
                              rawVariants is Map ? Map<String, dynamic>.from(rawVariants) : null;
                          final type = p['media_type']; // image | video
                          final title =
                              p['title'] ?? p['description'] ?? '';

                          return GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ProductDetailPage(product: p),
                                ),
                              );
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: GridTile(
                                footer: Container(
                                  color: Colors.black54,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 4),
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),

                                /// 🔐 DÉCISION FERME IMAGE / VIDÉO
                                child: type == 'video'
                                    ? VideoPreviewTile(
                                        mediaPath: media,
                                        variants: variants,
                                      )
                                    : CachedNetworkImage(
                                        imageUrl: resolvedMedia,
                                        fit: BoxFit.cover,
                                        placeholder: (_, __) =>
                                            const Center(
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        ),
                                        errorWidget: (_, __, ___) => Container(
                                          color: Colors.grey.shade300,
                                          child: const Icon(
                                            Icons.broken_image,
                                          ),
                                        ),
                                      ),
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

/// ======================================================
/// 🎬 PRÉVIEW VIDÉO — JOUE 1s PUIS PAUSE (MVP SAFE)
/// ======================================================
class VideoPreviewTile extends StatefulWidget {
  final String mediaPath;
  final Map<String, dynamic>? variants;

  const VideoPreviewTile({
    super.key,
    required this.mediaPath,
    this.variants,
  });

  @override
  State<VideoPreviewTile> createState() => _VideoPreviewTileState();
}

class _VideoPreviewTileState extends State<VideoPreviewTile> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();

    _initController();
  }

  Future<void> _initController() async {
    final resolvedUrl = await resolveBestVideoUrl(
      mediaPath: widget.mediaPath,
      variants: widget.variants,
    );
    final controller = createVideoController(resolvedUrl);
    _controller = controller;
    await controller.initialize();
    controller
      ..setVolume(0)
      ..play();

    // ▶️ jouer 1 seconde pour afficher une frame
    await Future.delayed(const Duration(seconds: 1));
    controller.pause();

    if (mounted) {
      setState(() => _ready = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return "$m:${s.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _controller == null) {
      return Container(
        color: Colors.grey.shade300,
        child: const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _controller!.value.size.width,
            height: _controller!.value.size.height,
            child: VideoPlayer(_controller!),
          ),
        ),

        /// ⏱️ durée vidéo
        Positioned(
          right: 6,
          bottom: 6,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _formatDuration(_controller!.value.duration),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
