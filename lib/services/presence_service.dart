import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PresenceService with WidgetsBindingObserver {
  PresenceService._();

  static final PresenceService instance = PresenceService._();

  final SupabaseClient _supabase = Supabase.instance.client;

  String? _userId;
  String? _activeConversationId;
  bool _observerAttached = false;
  bool _activeConversationColumnMissing = false;
  bool? _lastSentOnline;
  String? _lastSentActiveConversationId;
  DateTime? _lastWriteAt;

  Future<void> start(String? userId) async {
    if (userId == null || userId.isEmpty) return;

    if (!_observerAttached) {
      WidgetsBinding.instance.addObserver(this);
      _observerAttached = true;
    }

    if (_userId != null && _userId != userId) {
      await _upsertPresence(_userId!, isOnline: false, force: true);
    }

    _userId = userId;
    await _upsertPresence(userId, isOnline: true, force: true);
  }

  Future<void> stop() async {
    final uid = _userId;
    if (_observerAttached) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAttached = false;
    }
    _userId = null;
    _activeConversationId = null;
    _lastSentOnline = null;
    _lastSentActiveConversationId = null;
    _lastWriteAt = null;
    if (uid == null || uid.isEmpty) return;
    await _upsertPresence(uid, isOnline: false, force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final uid = _userId;
    if (uid == null || uid.isEmpty) return;

    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_upsertPresence(uid, isOnline: true));
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        unawaited(_upsertPresence(uid, isOnline: false));
        break;
    }
  }

  void setActiveConversationId(String? conversationId) {
    if (_activeConversationId == conversationId) return;
    _activeConversationId = conversationId;
    final uid = _userId;
    if (uid == null || uid.isEmpty) return;
    unawaited(
      _upsertPresence(
        uid,
        isOnline: _lastSentOnline ?? true,
        force: true,
      ),
    );
  }

  Future<void> _upsertPresence(
    String userId, {
    required bool isOnline,
    bool force = false,
  }) async {
    final now = DateTime.now();
    if (!force) {
      if (_lastSentOnline == isOnline &&
          _lastSentActiveConversationId == _activeConversationId &&
          _lastWriteAt != null &&
          now.difference(_lastWriteAt!) < const Duration(seconds: 2)) {
        return;
      }
    }

    final payload = <String, dynamic>{
      'user_id': userId,
      'is_online': isOnline,
      'updated_at': now.toUtc().toIso8601String(),
      if (!isOnline) 'last_seen': now.toUtc().toIso8601String(),
    };
    if (!_activeConversationColumnMissing) {
      payload['active_conversation_id'] = isOnline ? _activeConversationId : null;
    }

    try {
      await _supabase.from('user_presence').upsert(
            payload,
            onConflict: 'user_id',
          );
      _lastSentOnline = isOnline;
      _lastSentActiveConversationId = isOnline ? _activeConversationId : null;
      _lastWriteAt = now;
      debugPrint(
        'presence upsert user=$userId online=$isOnline active=${isOnline ? _activeConversationId : null}',
      );
    } catch (e) {
      final text = e.toString();
      if (!_activeConversationColumnMissing &&
          text.contains('active_conversation_id')) {
        _activeConversationColumnMissing = true;
        try {
          final fallbackPayload = Map<String, dynamic>.from(payload)
            ..remove('active_conversation_id');
          await _supabase.from('user_presence').upsert(
                fallbackPayload,
                onConflict: 'user_id',
              );
          _lastSentOnline = isOnline;
          _lastSentActiveConversationId = null;
          _lastWriteAt = now;
          debugPrint(
            'presence upsert fallback(no active_conversation_id column) user=$userId online=$isOnline',
          );
          return;
        } catch (e2) {
          debugPrint(
            'presence upsert fallback error user=$userId online=$isOnline error=$e2',
          );
          return;
        }
      }
      debugPrint('presence upsert error user=$userId online=$isOnline error=$e');
    }
  }
}
