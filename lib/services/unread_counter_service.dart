import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class UnreadCounterService {
  UnreadCounterService._();

  static final UnreadCounterService instance = UnreadCounterService._();

  final ValueNotifier<int> totalUnread = ValueNotifier<int>(0);

  RealtimeChannel? _channel;
  String? _userId;
  bool _refreshing = false;

  void start(String? userId) {
    if (userId == null || userId.isEmpty) {
      stop();
      return;
    }
    if (_userId == userId && _channel != null) return;
    stop();
    _userId = userId;
    _refresh();

    _channel = Supabase.instance.client
        .channel('unread_counter_$userId')
      ..on(
        RealtimeListenTypes.postgresChanges,
        ChannelFilter(event: '*', schema: 'public', table: 'messages'),
        (payload, [ref]) => _refresh(),
      )
      ..on(
        RealtimeListenTypes.postgresChanges,
        ChannelFilter(
          event: '*',
          schema: 'public',
          table: 'conversation_reads',
          filter: 'user_id=eq.$userId',
        ),
        (payload, [ref]) => _refresh(),
      )
      ..subscribe();
  }

  void stop() {
    _channel?.unsubscribe();
    _channel = null;
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
