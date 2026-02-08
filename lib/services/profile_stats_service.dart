import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileStats {
  final int followers;
  final int following;
  final int views;
  final int likes;

  ProfileStats({
    required this.followers,
    required this.following,
    required this.views,
    required this.likes,
  });
}

class ProfileStatsService {
  static final _supabase = Supabase.instance.client;

  /// 🔥 SOURCE UNIQUE DE VÉRITÉ
  static Future<ProfileStats> loadStats(String userId) async {
    // 🔹 Posts du vendeur
    final postsRes = await _supabase
        .from('posts')
        .select('id')
        .eq('seller_id', userId);

    final postIds = postsRes.map((p) => p['id']).toList();

    // 🔹 Vues
    final viewsRes = postIds.isEmpty
        ? []
        : await _supabase
            .from('post_views')
            .select('id')
            .inFilter('post_id', postIds);

    // 🔹 Likes
    final likesRes = postIds.isEmpty
        ? []
        : await _supabase
            .from('likes')
            .select('id')
            .inFilter('post_id', postIds);

    // 🔹 Followers
    final followersRes = await _supabase
        .from('followers')
        .select('id')
        .eq('seller_id', userId);

    // 🔹 Following
    final followingRes = await _supabase
        .from('followers')
        .select('id')
        .eq('follower_id', userId);

    return ProfileStats(
      followers: followersRes.length,
      following: followingRes.length,
      views: viewsRes.length,
      likes: likesRes.length,
    );
  }
}
