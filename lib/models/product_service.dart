import 'dart:io';
import '../models/product.dart';
import 'package:nyota_app/offline_manager.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class ProductService {
  Future<List<Product>> getUserFeed() async {
    List<Product> finalFeed = [];

    // 1. Charger depuis cache
    final cached = OfflineManager().getCachedProducts();
    for (var c in cached) {
      finalFeed.add(Product(
        id: c['id'],
        name: c['name'],
        price: c['price'] ?? 0.0,
        media: c['localPath'] != null ? File(c['localPath']) : null,
        isVideo: c['isVideo'] ?? false,
      ));
    }

    // 2. Si internet dispo, récupère depuis Firestore et met à jour le cache
    // if (await Connectivity().checkConnectivity() != ConnectivityResult.none) {
    //   // Exemple pour Firestore
    //   var docs = await FirebaseFirestore.instance.collection('products').get();
    //   for (var doc in docs.docs) {
    //     var data = doc.data();
    //     // Met à jour le cache
    //     OfflineManager().cacheProduct({
    //       'id': doc.id,
    //       'name': data['name'],
    //       'price': data['price'],
    //       'isVideo': data['isVideo'] ?? false,
    //     });
    //   }
    // }

    return finalFeed;
  }
}
