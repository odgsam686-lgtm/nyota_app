import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

import 'package:nyota_app/chat_screen.dart';
import 'package:nyota_app/services/unread_counter_service.dart';
import 'package:nyota_app/services/presence_service.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final SupabaseClient _supabase = Supabase.instance.client;
  static const List<String> _functionsBases = <String>[
    'https://uczycvteyfgdhfjeuglw.supabase.co/functions/v1',
  ];

  GlobalKey<NavigatorState>? _navigatorKey;
  GlobalKey<ScaffoldMessengerState>? _messengerKey;

  String? _userId;
  String? _activeConversationId;

  StreamSubscription<List<Map<String, dynamic>>>? _messageStreamSub;
  StreamSubscription<List<Map<String, dynamic>>>? _activityNotifStreamSub;
  StreamSubscription<String>? _tokenRefreshSub;

  final Set<String> _seenMessageIds = {};
  final Set<String> _seenActivityNotificationIds = {};
  bool _streamInitialized = false;
  bool _activityStreamInitialized = false;
  bool _tapHandlersBound = false;

  void bind({
    required GlobalKey<NavigatorState> navigatorKey,
    required GlobalKey<ScaffoldMessengerState> messengerKey,
  }) {
    _navigatorKey = navigatorKey;
    _messengerKey = messengerKey;
  }

  void setActiveConversationId(String? conversationId) {
    _activeConversationId = conversationId;
    PresenceService.instance.setActiveConversationId(conversationId);
  }

  Future<void> initForUser(String? userId) async {
    if (userId == null || userId.isEmpty) return;
    if (_userId == userId) return;
    _userId = userId;

    await _messaging.requestPermission(alert: true, badge: true, sound: true);
    await _registerDevice();

    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = _messaging.onTokenRefresh.listen((token) async {
      await _registerDevice(tokenOverride: token);
    });

    _listenInAppMessages();
    _listenInAppActivityNotifications();
    _handleNotificationTaps();
  }

  Future<void> _registerDevice({String? tokenOverride}) async {
    try {
      final uid = _userId ?? FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final token = tokenOverride ?? await _messaging.getToken();
      if (token == null || token.isEmpty) return;
      final idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (idToken == null) return;
      final platform = Platform.isIOS
          ? 'ios'
          : Platform.isAndroid
              ? 'android'
              : 'web';
      http.Response? lastResponse;
      Object? lastError;
      for (final base in _functionsBases) {
        try {
          final res = await http.post(
            Uri.parse('$base/register-device'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode({
              'user_id': uid,
              'fcm_token': token,
              'platform': platform,
            }),
          );
          if (res.statusCode >= 200 && res.statusCode < 300) {
            debugPrint(
              'register-device success user=$uid platform=$platform token=${token.substring(0, token.length > 12 ? 12 : token.length)}...',
            );
            return;
          }
          lastResponse = res;
        } catch (e) {
          lastError = e;
        }
      }
      if (lastResponse != null) {
        final body = lastResponse.body;
        final preview = body.length > 300 ? '${body.substring(0, 300)}...' : body;
        debugPrint(
          'register-device failed: ${lastResponse.statusCode} $preview',
        );
      } else if (lastError != null) {
        debugPrint('register-device failed: $lastError');
      }
    } catch (e) {
      debugPrint('register-device skipped (network/token): $e');
    }
  }

  void _listenInAppMessages() {
    final uid = _userId;
    if (uid == null) return;

    _messageStreamSub?.cancel();
    _messageStreamSub = _supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('receiver_id', uid)
        .order('created_at', ascending: true)
        .listen((rows) async {
      if (!_streamInitialized) {
        for (final row in rows) {
          final id = row['id']?.toString();
          if (id != null) _seenMessageIds.add(id);
        }
        _streamInitialized = true;
        return;
      }

      for (final row in rows) {
        final id = row['id']?.toString();
        if (id == null || _seenMessageIds.contains(id)) continue;
        _seenMessageIds.add(id);

        final conversationId = row['conversation_id']?.toString();
        if (conversationId != null &&
            _activeConversationId == conversationId) {
          continue; // pas de bannière si chat ouvert
        }

        final senderId = row['sender_id']?.toString();
        final preview = _buildPreview(row);
        final senderName = await _fetchSenderName(senderId);

        _showInAppBanner(
          title: 'Nyota Africa',
          body: '$senderName: $preview',
          onTap: () {
            if (conversationId != null) {
              openChatByConversationId(conversationId);
            }
          },
        );
      }

      // garde le compteur total à jour
      UnreadCounterService.instance.start(uid);
    }, onError: (e) {
      debugPrint('messages stream error: $e');
    });
  }

  void _listenInAppActivityNotifications() {
    final uid = _userId;
    if (uid == null) return;

    _activityNotifStreamSub?.cancel();
    _activityNotifStreamSub = _supabase
        .from('app_notifications')
        .stream(primaryKey: ['id'])
        .eq('user_id', uid)
        .order('created_at', ascending: true)
        .listen((rows) async {
      if (!_activityStreamInitialized) {
        for (final row in rows) {
          final id = row['id']?.toString();
          if (id != null) _seenActivityNotificationIds.add(id);
        }
        _activityStreamInitialized = true;
        return;
      }

      for (final row in rows) {
        final id = row['id']?.toString();
        if (id == null || _seenActivityNotificationIds.contains(id)) continue;
        _seenActivityNotificationIds.add(id);

        final actorId = row['actor_id']?.toString();
        if (actorId != null && actorId == uid) continue;

        final actorName = await _fetchSenderName(actorId);
        final body = _buildInteractionPreview(row, actorName: actorName);

        _showInAppBanner(
          title: 'Nyota Africa',
          body: body,
          onTap: () => _openActivityNotification(row),
        );
      }
    }, onError: (e) {
      debugPrint('activity notifications stream error: $e');
    });
  }

  Future<String> _fetchSenderName(String? senderId) async {
    if (senderId == null || senderId.isEmpty) return 'Nouveau message';
    final profile = await _supabase
        .from('public_profiles')
        .select('display_name, username')
        .eq('user_id', senderId)
        .maybeSingle();
    final displayName = profile?['display_name']?.toString().trim();
    final username = profile?['username']?.toString().trim();
    if (displayName != null && displayName.isNotEmpty) return displayName;
    if (username != null && username.isNotEmpty) return username;
    return 'Nouveau message';
  }

  String _buildPreview(Map<String, dynamic> msg) {
    final type = msg['message_type']?.toString();
    if (type == 'image') return 'Photo';
    if (type == 'video') return 'Vidéo';
    final content = msg['content']?.toString().trim();
    if (content != null && content.isNotEmpty) return content;
    return 'Message';
  }

  String _buildInteractionPreview(
    Map<String, dynamic> row, {
    required String actorName,
  }) {
    final kind = row['kind']?.toString() ?? '';
    switch (kind) {
      case 'follow':
        return '$actorName a commencé à vous suivre';
      case 'post_like':
        return '$actorName a aimé votre publication';
      case 'post_comment':
        return '$actorName a commenté votre publication';
      case 'comment_reply':
        return '$actorName a répondu à votre commentaire';
      case 'comment_like':
        return '$actorName a aimé votre commentaire';
      default:
        return '$actorName a interagi avec vous';
    }
  }

  void _openActivityNotification(Map<String, dynamic> row) {
    final nav = _navigatorKey?.currentState;
    if (nav == null) return;

    final kind = row['kind']?.toString();
    final postId = row['post_id']?.toString();
    final actorId = row['actor_id']?.toString();

    if (postId != null &&
        postId.isNotEmpty &&
        (kind == 'post_comment' ||
            kind == 'comment_reply' ||
            kind == 'post_like' ||
            kind == 'comment_like')) {
      nav.pushNamed('/comments', arguments: postId);
      return;
    }

    if (actorId != null && actorId.isNotEmpty) {
      nav.pushNamed('/publicProfile', arguments: actorId);
    }
  }

  void _showInAppBanner({
    required String title,
    required String body,
    VoidCallback? onTap,
  }) {
    final messenger = _messengerKey?.currentState;
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text('$title — $body'),
        action: onTap != null
            ? SnackBarAction(label: 'Ouvrir', onPressed: onTap)
            : null,
      ),
    );
  }

  void _handleNotificationTaps() async {
    if (_tapHandlersBound) return;
    _tapHandlersBound = true;
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final conversationId = message.data['conversationId']?.toString();
      if (conversationId != null) {
        openChatByConversationId(conversationId);
        return;
      }
      _handlePushInteractionTap(message.data);
    });

    final initial = await _messaging.getInitialMessage();
    if (initial != null) {
      final conversationId = initial.data['conversationId']?.toString();
      if (conversationId != null) {
        openChatByConversationId(conversationId);
        return;
      }
      _handlePushInteractionTap(initial.data);
    }
  }

  void _handlePushInteractionTap(Map<String, dynamic> data) {
    final kind = data['kind']?.toString();
    final postId = data['postId']?.toString();
    final actorId = data['actorId']?.toString();

    if (kind == null || kind.isEmpty) return;
    if (postId != null &&
        postId.isNotEmpty &&
        (kind == 'post_comment' ||
            kind == 'comment_reply' ||
            kind == 'post_like' ||
            kind == 'comment_like')) {
      _navigatorKey?.currentState?.pushNamed('/comments', arguments: postId);
      return;
    }
    if (actorId != null && actorId.isNotEmpty) {
      _navigatorKey?.currentState?.pushNamed('/publicProfile', arguments: actorId);
    }
  }

  Future<void> openChatByConversationId(String conversationId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final nav = _navigatorKey?.currentState;
    if (nav == null) return;

    final convo = await _supabase
        .from('conversations')
        .select('id, user_a, user_b')
        .eq('id', conversationId)
        .maybeSingle();

    if (convo == null) return;
    final userA = convo['user_a']?.toString();
    final userB = convo['user_b']?.toString();
    final receiverId = userA == uid ? userB : userA;
    if (receiverId == null) return;

    final profile = await _supabase
        .from('public_profiles')
        .select('display_name, username, avatar_url')
        .eq('user_id', receiverId)
        .maybeSingle();
    final displayName = profile?['display_name']?.toString().trim();
    final username = profile?['username']?.toString().trim();
    final photoUrl = profile?['avatar_url']?.toString().trim();
    final initialName = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : (username != null && username.isNotEmpty ? username : null);

    nav.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          conversationId: conversationId,
          receiverId: receiverId,
          currentUserId: uid,
          initialDisplayName: initialName,
          initialPhotoUrl: photoUrl,
        ),
      ),
    );
  }

  void dispose() {
    _messageStreamSub?.cancel();
    _activityNotifStreamSub?.cancel();
    _tokenRefreshSub?.cancel();
    _messageStreamSub = null;
    _activityNotifStreamSub = null;
    _tokenRefreshSub = null;
    _userId = null;
    _activeConversationId = null;
    _seenMessageIds.clear();
    _seenActivityNotificationIds.clear();
    _streamInitialized = false;
    _activityStreamInitialized = false;
    _tapHandlersBound = false;
  }
}
