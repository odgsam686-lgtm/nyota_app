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

  Future<List<Map<String, dynamic>>> fetchAllProductsLite() async {
    final res = await supabase
        .from('posts')
        .select(
            'id, seller_id, media_url, media_type, is_video, video_variants, '
            'thumbnail_url, thumbnail_path, description, created_at')
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(res);
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
  }) async {
    try {
      final query = supabase.from('posts').select(
            'id, seller_id, seller_name, description, '
            'media_url, media_type, thumbnail_url, '
            'category, price, currency, created_at, likes',
          );

      if (category != 'all') {
        query.eq('category', category);
      }

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
  }) async {
    try {
      final query = supabase.from('posts').select(
            'id, seller_id, media_url, media_type, is_video, video_variants, '
            'thumbnail_url, thumbnail_path, description, created_at',
          );

      if (category != 'all') {
        query.eq('category', category);
      }

      query.order('created_at', ascending: !newestFirst);

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
          .select(
              'id, seller_name, avatar_url, likes, comments_count, price, currency')
          .inFilter('id', ids);
      return List<Map<String, dynamic>>.from(raw);
    } catch (e) {
      debugPrint("fetchProductsMetaByIds error: $e");
      return [];
    }
  }

  // ==========================================
  // 🔥 FETCH CATÉGORIES
  // ==========================================
  Future<List<Map<String, dynamic>>> fetchCategories() async {
    try {
      final raw = await supabase.from('categories').select('slug,label');
      return [
        {'slug': 'all', 'label': 'Tous les produits'},
        ...raw,
      ];
    } catch (_) {}

    return [
      {'slug': 'all', 'label': 'Tous les produits'},
      ..._keywords.keys.map((k) => {
            'slug': k,
            'label': categoryLabels[k] ?? k,
          })
    ];
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
