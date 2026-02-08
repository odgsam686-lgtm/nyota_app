// lib/offline/local_thumbnail_service.dart
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// Offline-only thumbnail generator for local video files.
class LocalThumbnailService {
  /// Generates a local JPEG thumbnail for [videoFile].
  /// Returns the local file path, or null if generation fails.
  static Future<String?> generateLocalThumbnail({
    required File videoFile,
  }) async {
    final dir = await _ensureThumbnailsDir();
    final fileName =
        'thumb_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final outputPath = '${dir.path}/$fileName';

    final thumbPath = await VideoThumbnail.thumbnailFile(
      video: videoFile.path,
      thumbnailPath: outputPath,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 320,
      timeMs: 3000,
      quality: 75,
    );

    return thumbPath;
  }

  static Future<Directory> _ensureThumbnailsDir() async {
    final baseDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${baseDir.path}/thumbnails');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }
}
