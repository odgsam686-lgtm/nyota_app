import 'dart:io';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:nyota_app/models/product_hive.dart';

class OfflineManager {
  static final OfflineManager _instance = OfflineManager._internal();
  factory OfflineManager() => _instance;
  OfflineManager._internal();

  final Box cacheBox = Hive.box('cacheBox');

  // --- API statique attendue par main.dart ---
  static List<ProductHive> getLocalProducts() {
    return OfflineManager()._getLocalProducts();
  }

  static Future<void> saveLocalProduct(ProductHive product) {
    return OfflineManager()._saveLocalProduct(product);
  }

  static Future<void> syncProductsWithFirestore() async {
    // TODO: implémenter une vraie sync si nécessaire
    return;
  }

  // Enregistrer un produit
  Future<void> cacheProduct(String id, Map<String, dynamic> data, {File? media}) async {
    if (media != null) {
      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/$id';
      await media.copy(filePath);
      data['localPath'] = filePath;
    }
    await cacheBox.put(id, data);
  }

  Future<void> _saveLocalProduct(ProductHive product) async {
    final data = product.toMap();
    final mediaFile = product.localMediaPath != null
        ? File(product.localMediaPath!)
        : null;
    await cacheProduct(product.id, data, media: mediaFile);
  }

  // Récupérer tous les produits
  List<Map<String, dynamic>> getCachedProducts() {
    return cacheBox.values.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  List<ProductHive> _getLocalProducts() {
    return cacheBox.values.map((e) {
      if (e is ProductHive) return e;
      final map = Map<String, dynamic>.from(e as Map);
      if (map['localMediaPath'] == null && map['localPath'] != null) {
        map['localMediaPath'] = map['localPath'];
      }
      return ProductHive.fromMap(map);
    }).toList();
  }

  // Vérifier si média existe localement
  File? getMediaFile(String id) {
    final data = cacheBox.get(id);
    if (data != null && data['localPath'] != null) {
      final f = File(data['localPath']);
      if (f.existsSync()) return f;
    }
    return null;
  }

  // Supprimer cache si besoin
  Future<void> clearCache() async {
    for (var key in cacheBox.keys) {
      final data = cacheBox.get(key);
      if (data != null && data['localPath'] != null) {
        final f = File(data['localPath']);
        if (f.existsSync()) f.deleteSync();
      }
    }
    await cacheBox.clear();
  }
}
