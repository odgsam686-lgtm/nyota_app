import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import '../services/supabase_products_service.dart';
import '../services/crashlytics_logger.dart';
import '../utils/media_resolver.dart';
import '../widgets/fullscreen_media_actions.dart';
import 'comments_page.dart';

class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key});

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  final SupabaseProductsService svc = SupabaseProductsService();
  static const int _catalogPageSize = 28;
  static const double _loadMoreThresholdPx = 700;

  List<Map<String, dynamic>> categories = [];
  String selectedCategory = 'all';
  List<Map<String, dynamic>> subcategories = [];
  String selectedSubcategory = 'all';
  Map<String, List<Map<String, dynamic>>> _categoryPreviewPosts = {};
  List<Map<String, dynamic>> products = [];
  bool loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _nextOffset = 0;
  int _productsRequestEpoch = 0;
  final ScrollController _gridScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    CrashlyticsLogger.log('catalogue:open');
    _gridScrollController.addListener(_onGridScroll);
    _loadCategoriesAndProducts();
  }

  @override
  void dispose() {
    _gridScrollController.removeListener(_onGridScroll);
    _gridScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadCategoriesAndProducts() async {
    if (mounted) {
      setState(() => loading = true);
    }

    final fetched = await svc.fetchCategories();
    final normalized = fetched.map((c) {
      final id = (c['id'] ?? c['slug'] ?? 'all').toString();
      final label = (c['label'] ?? id).toString();
      final count = int.tryParse((c['count'] ?? c['rows_count'] ?? '0').toString()) ?? 0;
      return <String, dynamic>{'id': id, 'label': label, 'count': count};
    }).toList();
    normalized.removeWhere((c) => c['id'] == 'all');

    if (!mounted) return;
    setState(() {
      categories = normalized;
      selectedCategory = 'all';
      subcategories = [];
      selectedSubcategory = 'all';
      products = [];
    });
    await _loadCategoryCards();
  }

  void _onGridScroll() {
    if (!_gridScrollController.hasClients) return;
    if (selectedCategory == 'all') return;
    if (loading || _loadingMore || !_hasMore) return;
    final pos = _gridScrollController.position;
    if (pos.extentAfter <= _loadMoreThresholdPx) {
      unawaited(_loadMoreProducts());
    }
  }

  Future<void> _loadCategoryCards() async {
    final requestEpoch = ++_productsRequestEpoch;
    if (mounted) {
      setState(() {
        loading = true;
        selectedCategory = 'all';
        selectedSubcategory = 'all';
        subcategories = [];
      });
    }

    final futures = categories.map((c) async {
      final cid = (c['id'] ?? c['slug'] ?? '').toString();
      if (cid.isEmpty) return MapEntry<String, List<Map<String, dynamic>>>(cid, []);
      try {
        final rows = await svc.fetchProductsByCategoryLite(
          category: cid,
          limit: 3,
          offset: 0,
        );
        return MapEntry<String, List<Map<String, dynamic>>>(
          cid,
          List<Map<String, dynamic>>.from(rows),
        );
      } catch (_) {
        return MapEntry<String, List<Map<String, dynamic>>>(cid, []);
      }
    }).toList();

    final results = await Future.wait(futures);
    if (!mounted || requestEpoch != _productsRequestEpoch) return;

    final previewMap = <String, List<Map<String, dynamic>>>{};
    final visibleCategories = <Map<String, dynamic>>[];
    for (final entry in results) {
      if (entry.key.isEmpty || entry.value.isEmpty) continue;
      previewMap[entry.key] = entry.value;
      final cat = categories.firstWhere(
        (c) => (c['id'] ?? '').toString() == entry.key,
        orElse: () => {'id': entry.key, 'label': entry.key, 'count': entry.value.length},
      );
      visibleCategories.add(cat);
    }

    visibleCategories.sort((a, b) {
      final aId = (a['id'] ?? '').toString().toLowerCase();
      final bId = (b['id'] ?? '').toString().toLowerCase();
      if (aId == 'divers' && bId != 'divers') return -1;
      if (bId == 'divers' && aId != 'divers') return 1;
      final aCount = int.tryParse((a['count'] ?? '0').toString()) ?? 0;
      final bCount = int.tryParse((b['count'] ?? '0').toString()) ?? 0;
      return bCount.compareTo(aCount);
    });

    setState(() {
      categories = visibleCategories;
      _categoryPreviewPosts = previewMap;
      loading = false;
      products = [];
      _hasMore = false;
      _loadingMore = false;
    });
  }

  Future<void> _loadSubcategoriesFor(String category, int requestEpoch) async {
    if (category == 'all') {
      if (!mounted || requestEpoch != _productsRequestEpoch) return;
      setState(() {
        subcategories = [];
        selectedSubcategory = 'all';
      });
      return;
    }
    final rows = await svc.fetchSubcategories(category: category);
    if (!mounted || requestEpoch != _productsRequestEpoch) return;
    setState(() {
      subcategories = rows;
      final exists = rows.any(
        (s) => (s['slug'] ?? '').toString() == selectedSubcategory,
      );
      if (!exists) {
        selectedSubcategory = 'all';
      }
    });
  }

  Future<void> _loadProductsFor(
    String category, {
    String subcategory = 'all',
  }) async {
    CrashlyticsLogger.log(
      'catalogue:load category=$category subcategory=$subcategory',
    );
    final requestEpoch = ++_productsRequestEpoch;
    _hasMore = true;
    _nextOffset = 0;
    _loadingMore = false;
    if (mounted) {
      setState(() {
        loading = true;
        selectedCategory = category;
        selectedSubcategory = subcategory;
      });
    }

    if (category == 'all') {
      await _loadCategoryCards();
      return;
    }

    unawaited(_loadSubcategoriesFor(category, requestEpoch));

    try {
      final subcategoryFilter =
          subcategory != 'all' ? subcategory : null;
      final limit = subcategoryFilter == null ? _catalogPageSize : 120;
      final raw = category == 'all'
          ? await svc.fetchAllProductsLite(limit: limit, offset: 0)
          : await svc.fetchProductsByCategoryLite(
              category: category,
              subcategorySlug: subcategoryFilter,
              limit: limit,
              offset: 0,
            );
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
      _nextOffset = subcategoryFilter == null ? raw.length : 0;
      _hasMore = subcategoryFilter == null && raw.length >= _catalogPageSize;
      setState(() {
        products = normalized;
        loading = false;
      });

      if (_gridScrollController.hasClients) {
        _gridScrollController.jumpTo(0);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_gridScrollController.hasClients) {
            _gridScrollController.jumpTo(0);
          }
        });
      }

      _precacheProductImages(normalized, maxItems: 20);
      _hydrateProductsMeta(ids, requestEpoch);
      _hydrateCommentCounts(ids, requestEpoch);
    } catch (e) {
      debugPrint('Catalogue load error: $e');
      unawaited(CrashlyticsLogger.recordNonFatal(
        e,
        StackTrace.current,
        reason: 'catalogue_load',
      ));
      if (!mounted || requestEpoch != _productsRequestEpoch) return;
      setState(() => loading = false);
    }
  }

  Future<void> _refreshCurrentView() async {
    await _loadProductsFor(
      selectedCategory,
      subcategory: selectedSubcategory,
    );
  }

  Future<void> _loadMoreProducts() async {
    if (loading || _loadingMore || !_hasMore) return;
    if (selectedSubcategory != 'all') return;
    final requestEpoch = _productsRequestEpoch;
    final category = selectedCategory;

    if (mounted) {
      setState(() => _loadingMore = true);
    } else {
      _loadingMore = true;
    }

    try {
      final raw = category == 'all'
          ? await svc.fetchAllProductsLite(
              limit: _catalogPageSize,
              offset: _nextOffset,
            )
          : await svc.fetchProductsByCategoryLite(
              category: category,
              subcategorySlug: null,
              limit: _catalogPageSize,
              offset: _nextOffset,
            );
      if (!mounted || requestEpoch != _productsRequestEpoch) return;

      final normalized = <Map<String, dynamic>>[];
      final ids = <String>[];
      final existingIds = products
          .map((p) => p['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();

      for (final p in raw) {
        final id = p['id']?.toString();
        if (id == null || id.isEmpty || existingIds.contains(id)) continue;
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
          'seller_name': p['seller_name'] ?? 'Utilisateur',
          'avatar_url': p['avatar_url'],
          'likes': p['likes'] ?? 0,
          'comments_count': p['comments_count'] ?? 0,
          'price': p['price'],
          'currency': p['currency'] ?? 'XOF',
        });
        ids.add(id);
      }

      _nextOffset += raw.length;
      _hasMore = raw.length >= _catalogPageSize;

      if (!mounted || requestEpoch != _productsRequestEpoch) return;
      if (normalized.isNotEmpty) {
        setState(() {
          products = [...products, ...normalized];
        });
        _precacheProductImages(normalized, maxItems: 12);
        _hydrateProductsMeta(ids, requestEpoch);
        _hydrateCommentCounts(ids, requestEpoch);
      }
    } catch (e) {
      debugPrint('Catalogue load more error: $e');
      unawaited(CrashlyticsLogger.recordNonFatal(
        e,
        StackTrace.current,
        reason: 'catalogue_load_more',
      ));
    } finally {
      if (mounted && requestEpoch == _productsRequestEpoch) {
        setState(() => _loadingMore = false);
      } else {
        _loadingMore = false;
      }
    }
  }

  void _precacheProductImages(
    List<Map<String, dynamic>> rows, {
    int maxItems = 20,
  }) {
    if (!mounted) return;
    for (final p in rows.take(maxItems)) {
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
          p['price'] = meta['price'] ?? p['price'];
          p['currency'] = meta['currency'] ?? p['currency'];
        }
      });
    } catch (e) {
      debugPrint('Catalogue hydrate error: $e');
      unawaited(CrashlyticsLogger.recordNonFatal(
        e,
        StackTrace.current,
        reason: 'catalogue_hydrate_meta',
      ));
    }
  }

  Future<void> _hydrateCommentCounts(List<String> ids, int requestEpoch) async {
    if (ids.isEmpty) return;
    try {
      final counts = await svc.fetchCommentCountsByPostIds(ids);
      if (!mounted || requestEpoch != _productsRequestEpoch) return;
      setState(() {
        for (final p in products) {
          final id = p['id']?.toString();
          if (id == null || !ids.contains(id)) continue;
          p['comments_count'] = counts[id] ?? 0;
        }
      });
    } catch (e) {
      debugPrint('Catalogue comments count hydrate error: $e');
    }
  }

  String _activeFilterLabel() {
    final categoryLabel = categories
            .firstWhere(
              (c) => (c['id'] ?? c['slug'] ?? '').toString() == selectedCategory,
              orElse: () => {'label': selectedCategory},
            )['label']
            ?.toString() ??
        selectedCategory;

    if (selectedSubcategory == 'all') return categoryLabel;
    final subLabel = subcategories
            .firstWhere(
              (s) => (s['slug'] ?? '').toString() == selectedSubcategory,
              orElse: () => {'label': selectedSubcategory},
            )['label']
            ?.toString() ??
        selectedSubcategory;
    return '$categoryLabel • $subLabel';
  }

  Widget _buildLoadingGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth < 430 ? 3 : 4;
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: 12,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 0.7,
          ),
          itemBuilder: (_, __) => ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              color: Colors.grey.shade200,
            ),
          ),
        );
      },
    );
  }

  Widget _buildCategoryPreviewMedia(Map<String, dynamic> p, String uniqueKey) {
    final media = p['media_url']?.toString() ?? '';
    if (media.isEmpty) {
      return Container(color: Colors.grey.shade300);
    }
    final resolvedMedia = resolveMediaUrl(media);
    final rawVariants = p['video_variants'];
    final variants = rawVariants is Map
        ? Map<String, dynamic>.from(rawVariants)
        : null;
    final rawThumb = p['thumbnail_url'] ?? p['thumbnail_path'];
    final thumbnailUrl = rawThumb != null && rawThumb.toString().isNotEmpty
        ? resolveMediaUrl(rawThumb.toString())
        : null;
    final isVideo = p['media_type'] == 'video' ||
        p['is_video'] == true ||
        p['is_video']?.toString() == 'true';

    if (isVideo) {
      return VideoPreviewTile(
        key: ValueKey('catalog_cat_video_$uniqueKey'),
        mediaPath: media,
        variants: variants,
        thumbnailUrl: thumbnailUrl,
      );
    }
    return CachedNetworkImage(
      imageUrl: resolvedMedia,
      fit: BoxFit.cover,
      placeholder: (_, __) => Container(color: Colors.grey.shade300),
      errorWidget: (_, __, ___) => Container(
        color: Colors.grey.shade300,
        child: const Icon(Icons.broken_image),
      ),
    );
  }

  Widget _buildCategoryCard(Map<String, dynamic> category) {
    final cid = (category['id'] ?? category['slug'] ?? '').toString();
    final label = (category['label'] ?? cid).toString();
    final count = int.tryParse((category['count'] ?? '0').toString()) ?? 0;
    final previews = _categoryPreviewPosts[cid] ?? const <Map<String, dynamic>>[];
    if (cid.isEmpty || previews.isEmpty) return const SizedBox.shrink();

    final first = previews[0];
    final second = previews.length > 1 ? previews[1] : first;
    final third = previews.length > 2 ? previews[2] : second;

    Widget stackedLayer(
      Map<String, dynamic> post,
      String key, {
      required double top,
      required double left,
      required double right,
      required double bottom,
      double opacity = 1,
    }) {
      return Positioned(
        top: top,
        left: left,
        right: right,
        bottom: bottom,
        child: Opacity(
          opacity: opacity,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(0xFFFFFFFF),
                width: 1.2,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x22000000),
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: _buildCategoryPreviewMedia(post, key),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () => _loadProductsFor(cid),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                stackedLayer(
                  third,
                  '${cid}_back2',
                  top: 14,
                  left: -12,
                  right: 12,
                  bottom: -14,
                  opacity: 0.36,
                ),
                stackedLayer(
                  second,
                  '${cid}_back1',
                  top: 8,
                  left: -6,
                  right: 6,
                  bottom: -8,
                  opacity: 0.62,
                ),
                stackedLayer(
                  first,
                  '${cid}_front',
                  top: 0,
                  left: 0,
                  right: 0,
                  bottom: 0,
                ),
                const Center(
                  child: CircleAvatar(
                    radius: 20,
                    backgroundColor: Color(0x8AFFFFFF),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Color(0xFF6D7FA6),
                      size: 26,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.w700,
              fontSize: 22,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$count',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.black45,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoriesLanding() {
    if (loading) return _buildLoadingGrid();
    if (categories.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: Text('Aucune categorie disponible')),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: _loadCategoriesAndProducts,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final crossAxisCount = constraints.maxWidth < 600 ? 2 : 3;
          return GridView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(10),
            itemCount: categories.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.72,
            ),
            itemBuilder: (_, i) => _buildCategoryCard(categories[i]),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
      ),
      body: selectedCategory == 'all'
          ? _buildCategoriesLanding()
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                        onPressed: () => _loadProductsFor('all'),
                      ),
                      Expanded(
                        child: Text(
                          _activeFilterLabel(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Text(
                        '${products.length}',
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (subcategories.isNotEmpty)
                  SizedBox(
                    height: 48,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: subcategories.length + 1,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final bool isAll = i == 0;
                        final sid = isAll
                            ? 'all'
                            : (subcategories[i - 1]['slug'] ?? '').toString();
                        final label = isAll
                            ? 'Tous'
                            : (subcategories[i - 1]['label'] ??
                                    subcategories[i - 1]['slug'] ??
                                    '')
                                .toString();
                        final isSel = sid == selectedSubcategory;

                        return GestureDetector(
                          onTap: () => _loadProductsFor(
                            selectedCategory,
                            subcategory: sid,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: isSel
                                  ? Colors.deepPurple.shade400
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isSel
                                    ? Colors.deepPurple.shade400
                                    : Colors.grey.shade300,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                label,
                                style: TextStyle(
                                  color: isSel ? Colors.white : Colors.black87,
                                  fontSize: 12,
                                  fontWeight:
                                      isSel ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refreshCurrentView,
                    child: loading
                        ? _buildLoadingGrid()
                        : products.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  SizedBox(height: 120),
                                  Center(
                                    child: Text(
                                      'Aucun produit dans cette categorie',
                                    ),
                                  ),
                                ],
                              )
                            : LayoutBuilder(
                                builder: (context, constraints) {
                                  final crossAxisCount =
                                      constraints.maxWidth < 430 ? 3 : 4;
                                  return GridView.builder(
                                    controller: _gridScrollController,
                                    cacheExtent: 900,
                                    padding: const EdgeInsets.all(8),
                                    physics: const AlwaysScrollableScrollPhysics(),
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: crossAxisCount,
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
                                      final thumbnailUrl = rawThumb != null &&
                                              rawThumb.toString().isNotEmpty
                                          ? resolveMediaUrl(rawThumb.toString())
                                          : null;
                                      final isVideo = p['media_type'] == 'video' ||
                                          p['is_video'] == true ||
                                          p['is_video']?.toString() == 'true';
                                      final title =
                                          (p['description'] ?? '').toString();

                                      return GestureDetector(
                                        key: ValueKey('catalog_item_${p['id']}'),
                                        onTap: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  CatalogFullscreenFeedViewerPage(
                                                products: products,
                                                initialIndex: idx,
                                              ),
                                            ),
                                          );
                                        },
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: RepaintBoundary(
                                            child: GridTile(
                                              footer: Container(
                                                color: Colors.black54,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 4,
                                                ),
                                                child: Text(
                                                  title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                              child: isVideo
                                                  ? VideoPreviewTile(
                                                      key: ValueKey(
                                                        'catalog_video_${p['id']}',
                                                      ),
                                                      mediaPath: media,
                                                      variants: variants,
                                                      thumbnailUrl: thumbnailUrl,
                                                    )
                                                  : CachedNetworkImage(
                                                      imageUrl: resolvedMedia,
                                                      fit: BoxFit.cover,
                                                      placeholder: (_, __) =>
                                                          const Center(
                                                        child:
                                                            CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                        ),
                                                      ),
                                                      errorWidget: (_, __, ___) =>
                                                          Container(
                                                        color:
                                                            Colors.grey.shade300,
                                                        child: const Icon(
                                                          Icons.broken_image,
                                                        ),
                                                      ),
                                                    ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
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
  int _initEpoch = 0;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  @override
  void didUpdateWidget(covariant VideoPreviewTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = oldWidget.mediaPath != widget.mediaPath ||
        oldWidget.thumbnailUrl != widget.thumbnailUrl;
    if (!sourceChanged) return;

    _initEpoch++;
    _retryAfter = null;
    _error = false;

    if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty) {
      unawaited(_disposeController());
      if (mounted) {
        setState(() {
          _ready = true;
        });
      } else {
        _ready = true;
      }
      return;
    }

    unawaited(_disposeController());
    if (mounted) {
      setState(() {
        _ready = false;
      });
    } else {
      _ready = false;
    }
    unawaited(_initController(force: true));
  }

  Future<void> _initController({bool force = false}) async {
    if (_loading && !force) return;
    if (!force &&
        _retryAfter != null &&
        DateTime.now().isBefore(_retryAfter!)) {
      return;
    }

    final epoch = ++_initEpoch;

    if (mounted) {
      setState(() {
        _loading = true;
      });
    } else {
      _loading = true;
    }

    try {
      if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty) {
        await _disposeController();
        if (_initEpoch != epoch) return;
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

      if (_initEpoch != epoch) {
        await nextController.dispose();
        return;
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
      if (_initEpoch != epoch || !mounted) return;
      setState(() {
        _ready = true;
        _error = true;
        _retryAfter = DateTime.now().add(const Duration(seconds: 8));
      });
    } finally {
      if (_initEpoch == epoch) {
        if (mounted) {
          setState(() {
            _loading = false;
          });
        } else {
          _loading = false;
        }
      }
    }
  }

  @override
  void dispose() {
    unawaited(_disposeController());
    super.dispose();
  }

  Future<void> _disposeController() async {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    try {
      await c.dispose();
    } catch (_) {}
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

class CatalogFullscreenFeedViewerPage extends StatefulWidget {
  final List<Map<String, dynamic>> products;
  final int initialIndex;

  const CatalogFullscreenFeedViewerPage({
    super.key,
    required this.products,
    required this.initialIndex,
  });

  @override
  State<CatalogFullscreenFeedViewerPage> createState() =>
      _CatalogFullscreenFeedViewerPageState();
}

class _CatalogFullscreenFeedViewerPageState
    extends State<CatalogFullscreenFeedViewerPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, int> _videoInitEpoch = {};
  final Set<String> _videoInitInFlight = {};
  final Set<String> _videoInitFailed = {};
  final Map<String, DateTime> _videoRetryAfter = {};

  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.products.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.products.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    unawaited(_maybeInitAroundIndex(_currentIndex));
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _videoControllers.values) {
      try {
        c.pause();
        c.dispose();
      } catch (_) {}
    }
    _videoControllers.clear();
    _videoInitEpoch.clear();
    _videoInitInFlight.clear();
    _videoInitFailed.clear();
    _videoRetryAfter.clear();
    super.dispose();
  }

  bool _isVideo(Map<String, dynamic> doc) {
    return doc['media_type'] == 'video' ||
        doc['is_video'] == true ||
        doc['is_video']?.toString() == 'true';
  }

  String _postIdForIndex(int index) {
    if (index < 0 || index >= widget.products.length) return '';
    return widget.products[index]['id']?.toString() ?? index.toString();
  }

  Future<void> _initializeVideoForIndex(int index) async {
    if (index < 0 || index >= widget.products.length) return;
    final doc = widget.products[index];
    if (!_isVideo(doc)) return;

    final mediaPath = doc['media_url']?.toString() ?? '';
    if (mediaPath.isEmpty) return;
    final postId = _postIdForIndex(index);
    if (postId.isEmpty) return;
    if (_videoControllers.containsKey(postId)) return;
    if (_videoInitInFlight.contains(postId)) return;
    final blockedUntil = _videoRetryAfter[postId];
    if (blockedUntil != null && DateTime.now().isBefore(blockedUntil)) return;

    final rawVariants = doc['video_variants'];
    final variants = rawVariants is Map<String, dynamic>
        ? rawVariants
        : (rawVariants is Map ? Map<String, dynamic>.from(rawVariants) : null);

    _videoInitInFlight.add(postId);
    final epoch = DateTime.now().microsecondsSinceEpoch;
    _videoInitEpoch[postId] = epoch;
    debugPrint('catalog-fullscreen video:init post=$postId');

    try {
      final resolvedUrl = await resolveBestVideoUrl(
        mediaPath: mediaPath,
        variants: variants,
      );
      if (_videoInitEpoch[postId] != epoch) return;

      final urls = <String>[resolvedUrl];
      final fallbackUrl = resolveMediaUrl(mediaPath);
      if (fallbackUrl.isNotEmpty && !urls.contains(fallbackUrl)) {
        urls.add(fallbackUrl);
      }

      VideoPlayerController? controller;
      Object? lastError;
      for (final url in urls) {
        VideoPlayerController? testController;
        try {
          testController = createVideoController(url);
          await testController.initialize();
          controller = testController;
          break;
        } catch (e) {
          lastError = e;
          try {
            await testController?.dispose();
          } catch (_) {}
        }
      }
      if (controller == null) {
        throw lastError ?? Exception('Video source error');
      }
      if (_videoInitEpoch[postId] != epoch) {
        try {
          await controller.dispose();
        } catch (_) {}
        return;
      }

      controller
        ..setLooping(true)
        ..setVolume(1.0);
      _videoControllers[postId] = controller;
      _videoInitFailed.remove(postId);
      _videoRetryAfter.remove(postId);

      if (_currentIndex == index) {
        try {
          await controller.play();
        } catch (_) {}
      } else {
        try {
          await controller.pause();
        } catch (_) {}
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('catalog-fullscreen video:error post=$postId error=$e');
      _videoInitFailed.add(postId);
      _videoRetryAfter[postId] = DateTime.now().add(const Duration(seconds: 8));
      _videoControllers.remove(postId);
    } finally {
      _videoInitInFlight.remove(postId);
    }
  }

  Future<void> _maybeInitAroundIndex(int index) async {
    await _initializeVideoForIndex(index);
    unawaited(_initializeVideoForIndex(index + 1));
    unawaited(_initializeVideoForIndex(index - 1));
    _pruneVideoControllers(index);
  }

  void _pruneVideoControllers(int centerIndex) {
    final keep = <String>{};
    for (final i in [centerIndex - 1, centerIndex, centerIndex + 1]) {
      final id = _postIdForIndex(i);
      if (id.isNotEmpty) keep.add(id);
    }
    final ids = _videoControllers.keys.toList();
    for (final id in ids) {
      if (keep.contains(id)) continue;
      final c = _videoControllers.remove(id);
      _videoInitEpoch.remove(id);
      _videoInitInFlight.remove(id);
      if (c != null) {
        try {
          c.pause();
          c.dispose();
        } catch (_) {}
      }
      debugPrint('catalog-fullscreen video:dispose post=$id');
    }
  }

  void _pauseAllExcept(String? keepId) {
    _videoControllers.forEach((id, c) {
      if (id == keepId) return;
      try {
        if (c.value.isPlaying) c.pause();
      } catch (_) {}
    });
  }

  Future<void> _onPageChanged(int index) async {
    _currentIndex = index;
    final currentId = _postIdForIndex(index);
    _pauseAllExcept(currentId);

    final currentController = _videoControllers[currentId];
    if (currentController != null && currentController.value.isInitialized) {
      try {
        await currentController.play();
      } catch (_) {}
    }

    unawaited(_maybeInitAroundIndex(index));
    if (mounted) setState(() {});
  }

  void _togglePlayPause(String postId) {
    final ctrl = _videoControllers[postId];
    if (ctrl == null || !ctrl.value.isInitialized) return;
    try {
      if (ctrl.value.isPlaying) {
        ctrl.pause();
      } else {
        _pauseAllExcept(postId);
        ctrl.play();
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  int _asInt(dynamic v) {
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '0') ?? 0;
  }

  Future<void> _openCommentsFor(Map<String, dynamic> post) async {
    final postId = post['id']?.toString();
    if (postId == null || postId.isEmpty) return;
    await openComments(context, postId);
    await _refreshCommentsCount(postId);
  }

  Future<void> _refreshCommentsCount(String postId) async {
    try {
      final rows = await _supabase.from('comments').select('id').eq('post_id', postId);
      if (!mounted) return;
      final count = rows.length;
      for (final p in widget.products) {
        if (p['id']?.toString() == postId) {
          p['comments_count'] = count;
          break;
        }
      }
      setState(() {});
    } catch (_) {}
  }

  void _openProfile(String? sellerId) {
    if (sellerId == null || sellerId.isEmpty) return;
    Navigator.of(context).pushNamed('/publicProfile', arguments: sellerId);
  }

  Widget _buildVideoFallback({
    required String postId,
    required String? thumbnailUrl,
    required bool loading,
    VoidCallback? onRetry,
  }) {
    final bg = (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
        ? CachedNetworkImage(
            imageUrl: thumbnailUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            placeholder: (c, s) => const SizedBox.shrink(),
            errorWidget: (c, s, e) =>
                const Center(child: Icon(Icons.broken_image, color: Colors.white70)),
          )
        : Container(color: Colors.black);

    final ctrl = _videoControllers[postId];
    final showPlayOverlay = ctrl == null || !ctrl.value.isPlaying;

    return Stack(
      fit: StackFit.expand,
      children: [
        bg,
        if (loading)
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (showPlayOverlay && !loading)
          const Center(
            child: Icon(
              Icons.play_circle_fill,
              size: 54,
              color: Colors.white70,
            ),
          ),
        if (onRetry != null)
          Center(
            child: ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reessayer'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black87,
                foregroundColor: Colors.white,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFullscreenVideo(
    String postId,
    String mediaPath,
    String? thumbnailUrl,
  ) {
    final controller = _videoControllers[postId];
    if (controller == null) {
      final isFailed = _videoInitFailed.contains(postId);
      return _buildVideoFallback(
        postId: postId,
        thumbnailUrl: thumbnailUrl,
        loading: !isFailed,
        onRetry: isFailed ? () => _retryVideoInit(postId) : null,
      );
    }

    if (!controller.value.isInitialized || controller.value.hasError) {
      return _buildVideoFallback(
        postId: postId,
        thumbnailUrl: thumbnailUrl,
        loading: !controller.value.hasError,
        onRetry:
            controller.value.hasError ? () => _retryVideoInit(postId) : null,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
        if (!controller.value.isPlaying)
          const Center(
            child: Icon(
              Icons.play_circle_fill,
              size: 54,
              color: Colors.white70,
            ),
          ),
      ],
    );
  }

  void _retryVideoInit(String postId) {
    _videoInitFailed.remove(postId);
    _videoRetryAfter.remove(postId);
    _videoInitEpoch.remove(postId);
    final idx = widget.products.indexWhere((p) => p['id']?.toString() == postId);
    if (idx >= 0) {
      unawaited(_initializeVideoForIndex(idx));
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.products.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            'Aucun média',
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              pageSnapping: true,
              physics: const PageScrollPhysics(),
              itemCount: widget.products.length,
              onPageChanged: (index) {
                unawaited(_onPageChanged(index));
              },
              itemBuilder: (context, index) {
                final doc = widget.products[index];
                final postId = _postIdForIndex(index);
                final sellerId = doc['seller_id']?.toString() ?? '';
                final rawMedia = doc['media_url']?.toString() ?? '';
                final mediaUrl = rawMedia.isEmpty ? '' : resolveMediaUrl(rawMedia);
                final rawThumb = doc['thumbnail_url'] ?? doc['thumbnail_path'];
                final thumbnailUrl =
                    rawThumb != null && rawThumb.toString().isNotEmpty
                        ? resolveMediaUrl(rawThumb.toString())
                        : null;
                final isVideo = _isVideo(doc);
                final title = (doc['description'] ?? '').toString();
                final price = doc['price']?.toString() ?? '';
                final currency = (doc['currency'] ?? 'XOF').toString();
                final likesCount = _asInt(doc['likes']);
                final commentsCount = _asInt(doc['comments_count']);

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (isVideo && postId.isNotEmpty) {
                      _togglePlayPause(postId);
                    }
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (isVideo && rawMedia.isNotEmpty)
                        _buildFullscreenVideo(postId, rawMedia, thumbnailUrl)
                      else if (mediaUrl.isNotEmpty)
                        CachedNetworkImage(
                          imageUrl: mediaUrl,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                          placeholder: (_, __) => thumbnailUrl != null
                              ? CachedNetworkImage(
                                  imageUrl: thumbnailUrl,
                                  fit: BoxFit.cover,
                                )
                              : const Center(
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                          errorWidget: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image, color: Colors.white70),
                          ),
                        )
                      else
                        Container(color: Colors.black54),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 260,
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.transparent, Colors.black87],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 16,
                        bottom: 36,
                        right: 88,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (title.isNotEmpty)
                              Text(
                                title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                ),
                              ),
                            if (price.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                '$price $currency',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      FullScreenMediaActions(
                        postId: postId,
                        sellerId: sellerId,
                        avatarUrl: doc['avatar_url']?.toString(),
                        likesCount: likesCount,
                        commentsCount: commentsCount,
                        isLiked: false,
                        onLike: () {},
                        onComment: () => _openCommentsFor(doc),
                        onOpenProfile: () => _openProfile(sellerId),
                      ),
                    ],
                  ),
                );
              },
            ),
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
          ],
        ),
      ),
    );
  }
}

