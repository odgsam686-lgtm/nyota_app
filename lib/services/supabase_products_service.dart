// lib/services/supabase_products_service.dart
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseProductsService {
  final SupabaseClient supabase = Supabase.instance.client;

  // ============================
  // 🔥 CATÉGORIES & MOTS-CLÉS
  // ============================
  static final Map<String, List<String>> _keywords = {
    'phone_accessory': [
      'phone',
      'iphone',
      'samsung',
      'charger',
      'powerbank',
      'écouteur',
      'earbud',
      'huawei',
      'xiaomi',
      'accessoire'
    ],
    'fashion': [
      'jean',
      'robe',
      't-shirt',
      'chaussure',
      'vêtement',
      'mode',
      'chemise',
      'pantalon',
      'sneaker',
      'sac'
    ],
    'beauty': [
      'parfum',
      'cosmétique',
      'maquillage',
      'crème',
      'huile',
      'beauté',
      'shampoing',
      'gel',
      'peau'
    ],
    'food': [
      'riz',
      'huile',
      'lait',
      'alimentation',
      'nourriture',
      'jus',
      'biscuit',
      'épice',
      'aliment'
    ],
    'accessories': ['montre', 'lunette', 'bracelet', 'bijou', 'accessoire'],
    'home': [
      'drap',
      'coussin',
      'ustensile',
      'cuisine',
      'décoration',
      'lampe',
      'rideau',
      'meuble'
    ],
    'appliance': [
      'mixeur',
      'ventilateur',
      'réfrigérateur',
      'cuiseur',
      'fer',
      'appareil',
      'cuisiniere'
    ],
    'others': ['other'],
  };

  static final Map<String, String> categoryLabels = {
    'all': 'Tous les produits',
    'phone_accessory': 'Téléphones & Accessoires',
    'fashion': 'Mode & Vêtements',
    'beauty': 'Beauté & Cosmétiques',
    'food': 'Alimentation',
    'accessories': 'Accessoires & Bijoux',
    'home': 'Maison & Décoration',
    'appliance': 'Électroménager',
    'others': 'Autres produits',
  };

  // ==========================================
  // 🔥 FETCH TOUS LES PRODUITS
  // ==========================================
  Future<List<Map<String, dynamic>>> fetchAllProducts() async {
    final res = await supabase
        .from('posts')
        .select()
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(res);
  }

  Future<List<Map<String, dynamic>>> fetchAllProductsLite({
    int? limit,
    int offset = 0,
  }) async {
    const liteSelect =
        'id, seller_id, media_url, media_type, is_video, video_variants, '
        'thumbnail_url, thumbnail_path, description, created_at, category';
    try {
      return await _fetchRankedPostsSlice(
        category: null,
        subcategorySlug: null,
        postSelect: liteSelect,
        limit: limit,
        offset: offset,
      );
    } catch (e) {
      debugPrint("fetchAllProductsLite ranked fallback: $e");
      final query = supabase.from('posts').select(liteSelect);
      query.order('created_at', ascending: false);
      if (limit != null && limit > 0) {
        query.range(offset, offset + limit - 1);
      }
      final res = await query;
      return List<Map<String, dynamic>>.from(res);
    }
  }

  // ==========================================
  // 🔥 CLASSIFICATION AUTOMATIQUE
  // ==========================================
  String classifyCategory({
    required String title,
    required String description,
    List<String>? tags,
  }) {
    final text = "$title $description ${(tags ?? []).join(' ')}".toLowerCase();

    int bestScore = 0;
    String bestCategory = "others";

    _keywords.forEach((category, words) {
      int score = 0;
      for (final kw in words) {
        if (text.contains(kw)) score++;
      }
      if (score > bestScore) {
        bestScore = score;
        bestCategory = category;
      }
    });

    return bestCategory;
  }

  // ==========================================
  // 🔥 INSERT PRODUIT (IMAGE / VIDÉO CORRECT)
  // ==========================================
  Future<PostInsertResult> insertProductAutoClassify({
    required String sellerId,
    required String sellerName,
    required String title,
    required String description,
    required double? price,
    String currency = 'XOF',
    String? mediaUrl,
    String? thumbnailUrl, // ✅ AJOUT
    bool isVideo = false,
    List<String>? tags,
  }) async {
    final category =
        classifyCategory(title: title, description: description, tags: tags);

    final payload = {
      'seller_id': sellerId,
      'seller_name': sellerName,
      'title': title,
      'description': description,
      'category': category,
      'price': price,
      'currency': currency,
      'media_url': mediaUrl,
      // ✅ AJOUTS OBLIGATOIRES
      'media_type': isVideo ? 'video' : 'image',
      'thumbnail_url': isVideo ? thumbnailUrl : null,

      // ⚠️ conservé pour compatibilité
      'is_video': isVideo,
    };

    try {
      final res =
          await supabase.from('posts').insert(payload).select().single();

      return PostInsertResult(success: true, returned: res);
    } catch (e) {
      return PostInsertResult(success: false, error: e.toString());
    }
  }

  // ==========================================
  // 🔥 FETCH PAR CATÉGORIE
  // ==========================================
  Future<List<Map<String, dynamic>>> fetchProductsByCategory({
    required String category,
    bool newestFirst = true,
    String? subcategorySlug,
  }) async {
    try {
      final ordered = await _fetchRankedPostsSlice(
        category: category,
        subcategorySlug: subcategorySlug,
        postSelect:
            'id, seller_id, seller_name, description, media_url, media_type, '
            'thumbnail_url, category, price, currency, created_at, likes',
      );
      if (ordered.isNotEmpty) return ordered;

      final query = supabase.from('posts').select(
            'id, seller_id, seller_name, description, media_url, media_type, '
            'thumbnail_url, category, price, currency, created_at, likes',
          );
      if (category != 'all') query.eq('category', category);
      query.order('created_at', ascending: !newestFirst);
      final raw = await query;
      return List<Map<String, dynamic>>.from(raw);
    } catch (e) {
      debugPrint("fetchProductsByCategory error: $e");
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> fetchProductsByCategoryLite({
    required String category,
    bool newestFirst = true,
    int? limit,
    int offset = 0,
    String? subcategorySlug,
  }) async {
    try {
      const liteSelect =
          'id, seller_id, media_url, media_type, is_video, video_variants, '
          'thumbnail_url, thumbnail_path, description, created_at, category';
      final ordered = await _fetchRankedPostsSlice(
        category: category,
        subcategorySlug: subcategorySlug,
        postSelect: liteSelect,
        limit: limit,
        offset: offset,
      );
      if (ordered.isNotEmpty) return ordered;

      final query = supabase.from('posts').select(liteSelect);
      if (category != 'all') query.eq('category', category);
      query.order('created_at', ascending: !newestFirst);
      if (limit != null && limit > 0) {
        query.range(offset, offset + limit - 1);
      }
      final raw = await query;
      return List<Map<String, dynamic>>.from(raw);
    } catch (e) {
      debugPrint("fetchProductsByCategoryLite error: $e");
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> fetchProductsMetaByIds(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return [];
    try {
      final raw = await supabase
          .from('posts')
          .select('id, seller_name, avatar_url, likes, price, currency')
          .inFilter('id', ids);
      return List<Map<String, dynamic>>.from(raw);
    } catch (e) {
      debugPrint("fetchProductsMetaByIds error: $e");
      return [];
    }
  }

  Future<Map<String, int>> fetchCommentCountsByPostIds(List<String> ids) async {
    if (ids.isEmpty) return <String, int>{};
    try {
      final raw = await supabase
          .from('comments')
          .select('post_id')
          .inFilter('post_id', ids);
      final counts = <String, int>{};
      for (final row in raw) {
        final postId = (row['post_id'] ?? '').toString();
        if (postId.isEmpty) continue;
        counts[postId] = (counts[postId] ?? 0) + 1;
      }
      return counts;
    } catch (e) {
      debugPrint("fetchCommentCountsByPostIds error: $e");
      return <String, int>{};
    }
  }

  // ==========================================
  // 🔥 FETCH CATÉGORIES
  // ==========================================
  Future<List<Map<String, dynamic>>> fetchCategories() async {
    try {
      final ranked = await supabase
          .from('catalogue_ranked_posts_mv')
          .select('category');
      final counts = <String, int>{};
      for (final row in ranked) {
        final rawCategory = (row['category'] ?? '').toString().trim();
        if (rawCategory.isEmpty) continue;
        counts[rawCategory] = (counts[rawCategory] ?? 0) + 1;
      }

      if (counts.isNotEmpty) {
        final sorted = counts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        return [
          {'slug': 'all', 'label': 'Tous les produits'},
          ...sorted.map((e) {
            final slug = e.key;
            return {
              'slug': slug,
              'label': categoryLabels[slug] ?? _humanizeCategory(slug),
            };
          }),
        ];
      }
    } catch (_) {}

    return [
      {'slug': 'all', 'label': 'Tous les produits'},
      ..._keywords.keys.map((k) => {
            'slug': k,
            'label': categoryLabels[k] ?? k,
          })
    ];
  }

  Future<List<Map<String, dynamic>>> fetchSubcategories({
    required String category,
    int limit = 20,
  }) async {
    if (category == 'all') return [];
    try {
      final raw = await supabase
          .from('catalog_subcategories')
          .select('category, slug, label, confidence, posts_count')
          .eq('is_active', true)
          .eq('category', category)
          .order('confidence', ascending: false)
          .order('posts_count', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(raw);
    } catch (e) {
      debugPrint("fetchSubcategories error: $e");
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchRankedPostsSlice({
    required String? category,
    required String? subcategorySlug,
    required String postSelect,
    int? limit,
    int offset = 0,
  }) async {
    dynamic query = supabase
        .from('catalogue_ranked_posts_mv')
        .select('post_id, category, total_score, jitter');

    if (category != null && category != 'all') {
      query = query.eq('category', category);
    }

    query = query
        .order('total_score', ascending: false)
        .order('jitter', ascending: false)
        .order('post_id', ascending: false);

    if (limit != null && limit > 0) {
      query = query.range(offset, offset + limit - 1);
    }

    final rankedRaw = await query;
    var rankedRows = List<Map<String, dynamic>>.from(rankedRaw);
    if (rankedRows.isEmpty) return [];

    var postIds = rankedRows
        .map((r) => r['post_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    if (postIds.isEmpty) return [];

    final hasSubcategory = subcategorySlug != null &&
        subcategorySlug.trim().isNotEmpty &&
        subcategorySlug != 'all' &&
        category != null &&
        category != 'all';

    bool usedSqlSubcategoryFilter = false;
    if (hasSubcategory) {
      final cat = category;
      final sub = subcategorySlug;
      final sqlMatched = await _tryFetchSubcategoryPostIdsSql(
        category: cat,
        subcategorySlug: sub,
        rankedPostIds: postIds,
      );
      if (sqlMatched != null) {
        usedSqlSubcategoryFilter = true;
        rankedRows = rankedRows.where((r) {
          final id = r['post_id']?.toString() ?? '';
          return id.isNotEmpty && sqlMatched.contains(id);
        }).toList();
        postIds = rankedRows
            .map((r) => r['post_id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toList();
        if (postIds.isEmpty) return [];
      }
    }

    final postRaw = await supabase
        .from('posts')
        .select(postSelect)
        .inFilter('id', postIds);
    final postRows = List<Map<String, dynamic>>.from(postRaw);
    if (postRows.isEmpty) return [];

    final byId = <String, Map<String, dynamic>>{};
    for (final row in postRows) {
      final id = row['id']?.toString();
      if (id == null || id.isEmpty) continue;
      byId[id] = row;
    }

    final ordered = <Map<String, dynamic>>[];
    for (final r in rankedRows) {
      final id = r['post_id']?.toString() ?? '';
      final post = byId[id];
      if (post == null) continue;
      post['category'] = (post['category'] ?? r['category']);
      post['catalog_total_score'] = r['total_score'];
      post['catalog_jitter'] = r['jitter'];
      ordered.add(post);
    }
    if (subcategorySlug == null ||
        subcategorySlug.trim().isEmpty ||
        subcategorySlug == 'all' ||
        usedSqlSubcategoryFilter) {
      return ordered;
    }
    return ordered
        .where((p) => _matchesSubcategory(p, subcategorySlug))
        .toList();
  }

  Future<Set<String>?> _tryFetchSubcategoryPostIdsSql({
    required String category,
    required String subcategorySlug,
    required List<String> rankedPostIds,
  }) async {
    if (rankedPostIds.isEmpty) return <String>{};
    try {
      final raw = await supabase
          .from('catalog_post_subcategories')
          .select('post_id')
          .eq('category', category)
          .eq('slug', subcategorySlug)
          .inFilter('post_id', rankedPostIds);
      final ids = <String>{};
      for (final row in raw) {
        final id = (row['post_id'] ?? '').toString();
        if (id.isNotEmpty) ids.add(id);
      }
      return ids;
    } catch (_) {
      return null;
    }
  }

  String _humanizeCategory(String slug) {
    final normalized = slug.trim().toLowerCase();
    if (normalized.isEmpty) return 'Divers';
    return normalized
        .replaceAll('_', ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  bool _matchesSubcategory(Map<String, dynamic> post, String subcategorySlug) {
    final text = _normalizeText(post['description']?.toString() ?? '');
    if (text.isEmpty) return false;

    final normalizedSlug = _normalizeText(
      subcategorySlug.replaceAll('_', ' ').replaceAll('-', ' '),
    );
    if (normalizedSlug.isEmpty) return false;

    if (text.contains(normalizedSlug)) return true;

    final tokens = normalizedSlug
        .split(RegExp(r'\s+'))
        .where((t) => t.trim().length >= 3)
        .toList();
    if (tokens.isEmpty) return false;
    for (final token in tokens) {
      if (text.contains(token)) return true;
    }
    return false;
  }

  String _normalizeText(String input) {
    var s = input.toLowerCase();
    const replacements = {
      'à': 'a',
      'á': 'a',
      'â': 'a',
      'ä': 'a',
      'ã': 'a',
      'å': 'a',
      'ç': 'c',
      'è': 'e',
      'é': 'e',
      'ê': 'e',
      'ë': 'e',
      'ì': 'i',
      'í': 'i',
      'î': 'i',
      'ï': 'i',
      'ñ': 'n',
      'ò': 'o',
      'ó': 'o',
      'ô': 'o',
      'ö': 'o',
      'õ': 'o',
      'ù': 'u',
      'ú': 'u',
      'û': 'u',
      'ü': 'u',
      'ý': 'y',
      'ÿ': 'y',
    };
    replacements.forEach((k, v) {
      s = s.replaceAll(k, v);
    });
    return s;
  }
}

// ===============================================
// 🔥 RÉSULTAT INSERT
// ===============================================
class PostInsertResult {
  final bool success;
  final dynamic returned;
  final String? error;

  PostInsertResult({required this.success, this.returned, this.error});
}
