import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/storage_url.dart';
import 'package:flutter/foundation.dart';

class MediaUploadService {
  static const String bucketName = 'posts';

  static String _buildPath(String userId, String uploadId, String filename) {
    // Always keep the bucket prefix inside the object path
    return 'posts/$userId/$uploadId/$filename';
  }

  static Future<Map<String, dynamic>> uploadMedia({
    required File file,
    required bool isVideo,
    required String userId,
    String? thumbnailFilePath,
    String? objectId,
  }) async {
    final supabase = Supabase.instance.client;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final uploadId = objectId ?? 'upload_$timestamp';
    String mediaPath;
    String mediaUrl;
    String? thumbnailPath;
    String? thumbnailUrl;

    // ==========================
    // VIDEO
    // ==========================
    if (isVideo) {
      // Upload thumbnail only if provided
      if (thumbnailFilePath != null) {
        final thumbFile = File(thumbnailFilePath);
        if (thumbFile.existsSync()) {
          thumbnailPath = _buildPath(userId, uploadId, 'thumb.jpg');
          print("UPLOAD bucket=$bucketName path=$thumbnailPath");
          await supabase.storage
              .from(bucketName)
              .upload(thumbnailPath, thumbFile);
          thumbnailUrl = storagePublicUrl(bucketName, thumbnailPath);
        }
      }

      // Upload video
      final ext = file.path.split('.').last;
      mediaPath = _buildPath(userId, uploadId, 'media.$ext');
      print("UPLOAD bucket=$bucketName path=$mediaPath");
      await supabase.storage.from(bucketName).upload(mediaPath, file);
      mediaUrl = storagePublicUrl(bucketName, mediaPath);
    }

    // ==========================
    // IMAGE
    // ==========================
    else {
      final ext = file.path.split('.').last;
      mediaPath = _buildPath(userId, uploadId, 'media.$ext');
      print("UPLOAD bucket=$bucketName path=$mediaPath");
      await supabase.storage.from(bucketName).upload(mediaPath, file);
      mediaUrl = storagePublicUrl(bucketName, mediaPath);
    }

    return {
      'media_url': mediaUrl,
      'thumbnail_url': thumbnailUrl,
      'media_path': mediaPath,
      'thumbnail_path': thumbnailPath,
      'is_video': isVideo,
    };
  }
}
