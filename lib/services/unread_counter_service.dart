import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

class UnreadCounterService {
  UnreadCounterService._();

  static final UnreadCounterService instance = UnreadCounterService._();

  final ValueNotifier<int> totalUnread = ValueNotifier<int>(0);

  StreamSubscription<List<Map<String, dynamic>>>? _unreadSub;
  String? _userId;
  bool _refreshing = false;

  void start(String? userId) {
    if (userId == null || userId.isEmpty) {
      stop();
      return;
    }
    if (_userId == userId && _unreadSub != null) return;
    stop();
    _userId = userId;

    // ✅ Compteur temps-réel direct sur les messages non lus
    _unreadSub = Supabase.instance.client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('receiver_id', userId)
        .listen((rows) {
      int count = 0;
      for (final row in rows) {
        final readAt = row['read_at'];
        final senderId = row['sender_id']?.toString();
        if (readAt == null && senderId != userId) {
          count++;
        }
      }
      totalUnread.value = count;
    }, onError: (e) {
      debugPrint('UnreadCounter unread stream error: $e');
    });
  }

  void stop() {
    _unreadSub?.cancel();
    _unreadSub = null;
    _userId = null;
    totalUnread.value = 0; 
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    final uid = _userId;
    if (uid == null) return;
    _refreshing = true;
    try {
      final rows = await Supabase.instance.client
          .from('conversations_with_unread')
          .select('unread_count')
          .eq('user_id', uid);
      int sum = 0;
      for (final row in rows) {
        final v = row['unread_count'];
        if (v is int) {
          sum += v;
        } else if (v != null) {
          sum += int.tryParse(v.toString()) ?? 0;
        }
      }
      totalUnread.value = sum;
    } catch (e) {
      debugPrint('UnreadCounter refresh error: $e');
    } finally {
      _refreshing = false;
    }
  }
}
