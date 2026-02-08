import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'package:nyota_app/pages/public_profile_page.dart';

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
    });
  }
}
