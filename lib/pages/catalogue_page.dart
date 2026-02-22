import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/supabase_products_service.dart';
import '../utils/media_resolver.dart';
import 'product_detail_page.dart';

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
  int _productsRequestEpoch = 0;

  @override
  void initState() {
    super.initState();
    _loadCategoriesAndProducts();
  }

  Future<void> _loadCategoriesAndProducts() async {
    if (mounted) {
      setState(() => loading = true);
    }

    final fetched = await svc.fetchCategories();
    final normalized = fetched.map((c) {
      final id = (c['id'] ?? c['slug'] ?? 'all').toString();
      final label = (c['label'] ?? id).toString();
      return <String, dynamic>{'id': id, 'label': label};
    }).toList();

    if (!normalized.any((c) => c['id'] == 'all')) {
      normalized.insert(0, {'id': 'all', 'label': 'Tous'});
    }

    if (!mounted) return;
    setState(() {
      categories = normalized;
      selectedCategory = 'all';
    });
    await _loadProductsFor('all');
  }

  Future<void> _loadProductsFor(String category) async {
    final requestEpoch = ++_productsRequestEpoch;
    if (mounted) {
      setState(() => loading = true);
    }

    try {
      final raw = category == 'all'
          ? await svc.fetchAllProductsLite()
          : await svc.fetchProductsByCategoryLite(category: category);
      if (!mounted || requestEpoch != _productsRequestEpoch) return;

      final normalized = <Map<String, dynamic>>[];
      final ids = <String>[];

      for (final p in raw) {
        final id = p['id']?.toString();
        if (id == null || id.isEmpty) continue;

        normalized.add({
          'id': id,
          'seller_id': p['seller_id'],
          'media_url': p['media_url'],
          'media_type': p['media_type'],
          'is_video': p['is_video'],
          'video_variants': p['video_variants'],
          'thumbnail_url': p['thumbnail_url'],
          'thumbnail_path': p['thumbnail_path'],
          'description': p['description'] ?? '',
          'created_at': p['created_at'],
          // Phase 2 fields are hydrated asynchronously.
          'seller_name': p['seller_name'] ?? 'Utilisateur',
          'avatar_url': p['avatar_url'],
          'likes': p['likes'] ?? 0,
          'comments_count': p['comments_count'] ?? 0,
          'price': p['price'],
          'currency': p['currency'] ?? 'XOF',
        });
        ids.add(id);
      }

      if (!mounted || requestEpoch != _productsRequestEpoch) return;
      setState(() {
        products = normalized;
        selectedCategory = category;
        loading = false;
      });

      _precacheProductImages(normalized);
      _hydrateProductsMeta(ids, requestEpoch);
    } catch (e) {
      debugPrint('Catalogue load error: $e');
      if (!mounted || requestEpoch != _productsRequestEpoch) return;
      setState(() => loading = false);
    }
  }

  void _precacheProductImages(List<Map<String, dynamic>> rows) {
    if (!mounted) return;
    for (final p in rows) {
      final isVideo = p['media_type'] == 'video' ||
          p['is_video'] == true ||
          p['is_video']?.toString() == 'true';

      if (isVideo) {
        final rawThumb = p['thumbnail_url'] ?? p['thumbnail_path'];
        if (rawThumb != null && rawThumb.toString().isNotEmpty) {
          precacheImage(
            CachedNetworkImageProvider(resolveMediaUrl(rawThumb.toString())),
            context,
          );
        }
        continue;
      }

      final media = p['media_url']?.toString() ?? '';
      if (media.isEmpty) continue;
      precacheImage(
        CachedNetworkImageProvider(resolveMediaUrl(media)),
        context,
      );
    }
  }

  Future<void> _hydrateProductsMeta(List<String> ids, int requestEpoch) async {
    if (ids.isEmpty) return;
    try {
      final rows = await svc.fetchProductsMetaByIds(ids);
      if (!mounted || requestEpoch != _productsRequestEpoch) return;
      if (rows.isEmpty) return;

      final byId = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final id = row['id']?.toString();
        if (id == null || id.isEmpty) continue;
        byId[id] = row;
      }

      if (byId.isEmpty) return;
      setState(() {
        for (final p in products) {
          final id = p['id']?.toString();
          if (id == null) continue;
          final meta = byId[id];
          if (meta == null) continue;
          p['seller_name'] = meta['seller_name'] ?? p['seller_name'];
          p['avatar_url'] = meta['avatar_url'];
          p['likes'] = meta['likes'] ?? p['likes'];
          p['comments_count'] = meta['comments_count'] ?? p['comments_count'];
          p['price'] = meta['price'] ?? p['price'];
          p['currency'] = meta['currency'] ?? p['currency'];
        }
      });
    } catch (e) {
      debugPrint('Catalogue hydrate error: $e');
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
          SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: categories.length,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final c = categories[i];
                final cid = (c['id'] ?? c['slug'] ?? 'all').toString();
                final label = (c['label'] ?? cid).toString();
                final isSel = cid == selectedCategory;

                return GestureDetector(
                  onTap: () => _loadProductsFor(cid),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSel ? Colors.deepPurple : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Center(
                      child: Text(
                        label,
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
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : products.isEmpty
                    ? const Center(
                        child: Text('Aucun produit dans cette categorie'),
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
                          final rawVariants = p['video_variants'];
                          final variants = rawVariants is Map
                              ? Map<String, dynamic>.from(rawVariants)
                              : null;
                          final rawThumb =
                              p['thumbnail_url'] ?? p['thumbnail_path'];
                          final thumbnailUrl =
                              rawThumb != null && rawThumb.toString().isNotEmpty
                                  ? resolveMediaUrl(rawThumb.toString())
                                  : null;
                          final isVideo = p['media_type'] == 'video' ||
                              p['is_video'] == true ||
                              p['is_video']?.toString() == 'true';
                          final title = (p['description'] ?? '').toString();

                          return GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ProductDetailPage(product: p),
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
                                child: isVideo
                                    ? VideoPreviewTile(
                                        mediaPath: media,
                                        variants: variants,
                                        thumbnailUrl: thumbnailUrl,
                                      )
                                    : CachedNetworkImage(
                                        imageUrl: resolvedMedia,
                                        fit: BoxFit.cover,
                                        placeholder: (_, __) => const Center(
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        ),
                                        errorWidget: (_, __, ___) => Container(
                                          color: Colors.grey.shade300,
                                          child: const Icon(Icons.broken_image),
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

class VideoPreviewTile extends StatefulWidget {
  final String mediaPath;
  final Map<String, dynamic>? variants;
  final String? thumbnailUrl;

  const VideoPreviewTile({
    super.key,
    required this.mediaPath,
    this.variants,
    this.thumbnailUrl,
  });

  @override
  State<VideoPreviewTile> createState() => _VideoPreviewTileState();
}

class _VideoPreviewTileState extends State<VideoPreviewTile> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _error = false;
  bool _loading = false;
  DateTime? _retryAfter;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  Future<void> _initController({bool force = false}) async {
    if (_loading) return;
    if (!force &&
        _retryAfter != null &&
        DateTime.now().isBefore(_retryAfter!)) {
      return;
    }

    if (mounted) {
      setState(() {
        _loading = true;
      });
    } else {
      _loading = true;
    }

    try {
      if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _ready = true;
          _error = false;
          _retryAfter = null;
        });
        return;
      }

      final urls = <String>[];
      try {
        final resolvedUrl = await resolveBestVideoUrl(
          mediaPath: widget.mediaPath,
          variants: widget.variants,
        ).timeout(const Duration(seconds: 6));
        urls.add(resolvedUrl);
      } catch (e) {
        debugPrint('VideoPreviewTile resolveBestVideoUrl error: $e');
      }

      final fallbackUrl = resolveMediaUrl(widget.mediaPath);
      if (fallbackUrl.isNotEmpty && !urls.contains(fallbackUrl)) {
        urls.add(fallbackUrl);
      }
      if (urls.isEmpty) {
        throw Exception('No video URL');
      }

      VideoPlayerController? nextController;
      Object? lastError;
      for (final url in urls) {
        VideoPlayerController? testController;
        try {
          testController = createVideoController(url);
          await testController.initialize().timeout(const Duration(seconds: 6));
          testController
            ..setVolume(0)
            ..setLooping(true)
            ..pause();
          nextController = testController;
          break;
        } catch (e) {
          lastError = e;
          try {
            await testController?.dispose();
          } catch (_) {}
        }
      }

      if (nextController == null) {
        throw lastError ?? Exception('Video source error');
      }

      if (!mounted) {
        await nextController.dispose();
        return;
      }

      final old = _controller;
      _controller = nextController;
      if (old != null) {
        try {
          await old.dispose();
        } catch (_) {}
      }

      setState(() {
        _ready = true;
        _error = false;
        _retryAfter = null;
      });
    } catch (e) {
      debugPrint('VideoPreviewTile error (${widget.mediaPath}): $e');
      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = true;
        _retryAfter = DateTime.now().add(const Duration(seconds: 8));
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      } else {
        _loading = false;
      }
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

  Widget _buildFallback({VoidCallback? onRetry}) {
    final thumb = widget.thumbnailUrl;
    final bg = thumb != null && thumb.isNotEmpty
        ? CachedNetworkImage(
            imageUrl: thumb,
            fit: BoxFit.cover,
            placeholder: (_, __) => Container(color: Colors.grey.shade300),
            errorWidget: (_, __, ___) => Container(color: Colors.grey.shade300),
          )
        : Container(color: Colors.grey.shade300);

    return Stack(
      fit: StackFit.expand,
      children: [
        bg,
        if (_loading)
          const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (!_loading)
          const Center(
            child: Icon(
              Icons.play_circle_fill,
              size: 34,
              color: Colors.white70,
            ),
          ),
        if (onRetry != null)
          Positioned(
            right: 6,
            top: 6,
            child: InkWell(
              onTap: onRetry,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.refresh, color: Colors.white, size: 14),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return _buildFallback(onRetry: () => _initController(force: true));
    }

    final controller = _controller;
    if (!_ready ||
        controller == null ||
        !controller.value.isInitialized ||
        controller.value.hasError) {
      return _buildFallback();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
        const Center(
          child: Icon(
            Icons.play_circle_fill,
            size: 34,
            color: Colors.white70,
          ),
        ),
        Positioned(
          right: 6,
          bottom: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _formatDuration(controller.value.duration),
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
