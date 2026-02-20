import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'package:nyota_app/pages/public_profile_page.dart';
import 'package:nyota_app/services/notification_service.dart';

class DeepLinkService {
  final AppLinks _appLinks = AppLinks();

  void init(BuildContext context) {
    _appLinks.uriLinkStream.listen((uri) {
      if (uri == null) return;

      // https://nyota.africa/profile/USER_ID
      if (uri.pathSegments.length == 2 && uri.pathSegments[0] == 'profile') {
        final sellerId = uri.pathSegments[1];

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PublicProfilePage(sellerId: sellerId),
          ),
        );
      }

      // https://nyota.africa/chat/CONVERSATION_ID
      if (uri.pathSegments.length == 2 && uri.pathSegments[0] == 'chat') {
        final conversationId = uri.pathSegments[1];
        NotificationService.instance.openChatByConversationId(conversationId);
      }
    });
  }
}
