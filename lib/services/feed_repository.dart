import 'package:supabase_flutter/supabase_flutter.dart';

class FeedRankedItem {
  final String postId;
  final String userId;
  final double normalizedScore;
  final double randomScore;
  final double popularityScore;

  const FeedRankedItem({
    required this.postId,
    required this.userId,
    required this.normalizedScore,
    required this.randomScore,
    required this.popularityScore,
  });

  factory FeedRankedItem.fromMap(Map<String, dynamic> row) {
    double toDoubleValue(dynamic value) {
      if (value is double) return value;
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    return FeedRankedItem(
      postId: (row['post_id'] ?? '').toString(),
      userId: (row['user_id'] ?? '').toString(),
      normalizedScore: toDoubleValue(row['normalized_score']),
      randomScore: toDoubleValue(row['random_score']),
      popularityScore: toDoubleValue(row['popularity_score']),
    );
  }
}

class FeedCursor {
  final double lastScore;
  final String lastPostId;

  const FeedCursor({
    required this.lastScore,
    required this.lastPostId,
  });
}

class FeedPageResult {
  final List<FeedRankedItem> items;
  final FeedCursor? cursor;
  final bool hasMore;

  const FeedPageResult({
    required this.items,
    required this.cursor,
    required this.hasMore,
  });
}

class FeedRepository {
  FeedRepository({SupabaseClient? supabaseClient})
      : _supabase = supabaseClient ?? Supabase.instance.client;

  final SupabaseClient _supabase;

  Future<FeedPageResult> fetchFirstPage({
    required String viewerId,
    required int pageSize,
  }) async {
    final rows = await _supabase
        .from('feed_ranked_posts_normalized')
        .select(
            'post_id,user_id,normalized_score,random_score,popularity_score')
        .eq('user_id', viewerId)
        .order('normalized_score', ascending: false)
        .order('post_id', ascending: false)
        .limit(pageSize);

    final items = List<Map<String, dynamic>>.from(rows)
        .map(FeedRankedItem.fromMap)
        .where((e) => e.postId.isNotEmpty)
        .toList();

    return FeedPageResult(
      items: items,
      cursor: items.isEmpty
          ? null
          : FeedCursor(
              lastScore: items.last.normalizedScore,
              lastPostId: items.last.postId,
            ),
      hasMore: items.length >= pageSize,
    );
  }

  Future<FeedPageResult> fetchNextPage({
    required String viewerId,
    required FeedCursor cursor,
    required int pageSize,
  }) async {
    final score = cursor.lastScore.toString();
    final postId = cursor.lastPostId;
    final keysetFilter =
        'normalized_score.lt.$score,and(normalized_score.eq.$score,post_id.lt.$postId)';

    final rows = await _supabase
        .from('feed_ranked_posts_normalized')
        .select(
            'post_id,user_id,normalized_score,random_score,popularity_score')
        .eq('user_id', viewerId)
        .or(keysetFilter)
        .order('normalized_score', ascending: false)
        .order('post_id', ascending: false)
        .limit(pageSize);

    final items = List<Map<String, dynamic>>.from(rows)
        .map(FeedRankedItem.fromMap)
        .where((e) => e.postId.isNotEmpty)
        .toList();

    return FeedPageResult(
      items: items,
      cursor: items.isEmpty
          ? cursor
          : FeedCursor(
              lastScore: items.last.normalizedScore,
              lastPostId: items.last.postId,
            ),
      hasMore: items.length >= pageSize,
    );
  }
}
