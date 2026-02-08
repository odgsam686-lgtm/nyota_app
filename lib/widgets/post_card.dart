import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class PostCard extends StatelessWidget {
  final Map<String, dynamic> post;

  const PostCard({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    final mediaUrl = post['media_url'] ?? '';
    final type = post['media_type']; // image | video
    final thumb = post['thumbnail_url'];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      height: 420,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl:
                  type == 'video' && thumb != null && thumb.isNotEmpty
                      ? thumb
                      : mediaUrl,
              fit: BoxFit.cover,
              placeholder: (_, __) =>
                  Container(color: Colors.black12),
              errorWidget: (_, __, ___) =>
                  Container(color: Colors.black26),
            ),

            // 🟣 indication vidéo (sans icône play)
            if (type == 'video')
              Positioned(
                right: 8,
                bottom: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    "00:01",
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
