class PostModel {
  final String id;
  final String sellerId;
  final String sellerName;
  final String mediaUrl;
  final bool isVideo;
  final String? thumbnailUrl;
  final String description;
  final DateTime timestamp;
  final int likes;
  final int? likesCount;
  final int? viewsCount;

  PostModel({
    required this.id,
    required this.sellerId,
    required this.sellerName,
    required this.mediaUrl,
    required this.isVideo,
    required this.description,
    required this.timestamp,
    required this.likes,
    // 🔹 NOUVEAUX (optionnels)
    this.thumbnailUrl,
    this.likesCount,
    this.viewsCount,
  });

  factory PostModel.fromMap(Map<String, dynamic> map) {
    return PostModel(
      id: map['id'].toString(),
      sellerId: map['seller_id']?.toString() ?? '',
      sellerName: map['seller_name'] ?? '',
      mediaUrl: map['media_url'] ?? '',
      isVideo: map['is_video'] ?? false,
      description: map['description'] ?? '',
      thumbnailUrl: map['thumbnail_url']?.toString(),

      // ⭐ Supabase utilise "created_at"
      timestamp: DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.now(),

      likes: map['likes'] ?? 0,
      likesCount: map['likes_count'] as int?,
      viewsCount: map['views_count'] as int?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'seller_id': sellerId,
      'seller_name': sellerName,
      'media_url': mediaUrl,
      'is_video': isVideo,
      'thumbnail_url': thumbnailUrl,
      'description': description,
      'created_at': timestamp.toIso8601String(),
      'likes': likes,
    };
  }
}
