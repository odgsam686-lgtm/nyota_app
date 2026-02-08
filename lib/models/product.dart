import 'dart:io';

class Product {
  final String id;
  final String name;
  final double price;
  final bool isVideo;
  final File? media;

  Product({
    required this.id,
    required this.name,
    required this.price,
    this.isVideo = false,
    this.media,
  });
}
