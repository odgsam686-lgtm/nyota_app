// lib/models/product_hive.dart
import 'dart:io';
import 'package:hive/hive.dart';

part 'product_hive.g.dart';

@HiveType(typeId: 1)
class ProductHive extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  // stocke chemin local si média téléchargé; null sinon
  @HiveField(2)
  String? localMediaPath;

  @HiveField(3)
  double price;

  @HiveField(4)
  bool isVideo;

  @HiveField(5)
  double? latitude;

  @HiveField(6)
  double? longitude;

  @HiveField(7)
  bool isPromo;

  @HiveField(8)
  bool isTrending;

  @HiveField(9)
  int updatedAt; // epoch millis pour gestion conflits/sync

  ProductHive({
    required this.id,
    required this.name,
    this.localMediaPath,
    this.price = 0.0,
    this.isVideo = false,
    this.latitude,
    this.longitude,
    this.isPromo = false,
    this.isTrending = false,
    int? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  // convert from simple map (from Firestore)
  factory ProductHive.fromMap(Map<String, dynamic> m) {
    return ProductHive(
      id: m['id'] ?? m['docId'] ?? '',
      name: m['name'] ?? '',
      localMediaPath: m['localMediaPath'],
      price: (m['price'] ?? 0).toDouble(),
      isVideo: m['isVideo'] ?? false,
      latitude: m['latitude'] != null ? (m['latitude'] as num).toDouble() : null,
      longitude: m['longitude'] != null ? (m['longitude'] as num).toDouble() : null,
      isPromo: m['isPromo'] ?? false,
      isTrending: m['isTrending'] ?? false,
      updatedAt: m['updatedAt'] ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'localMediaPath': localMediaPath,
      'price': price,
      'isVideo': isVideo,
      'latitude': latitude,
      'longitude': longitude,
      'isPromo': isPromo,
      'isTrending': isTrending,
      'updatedAt': updatedAt,
    };
  }
}
